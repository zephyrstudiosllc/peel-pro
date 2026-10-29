import Foundation
import Darwin

private enum TestFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

nonisolated private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw TestFailure.message(message)
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    message: String,
    condition: () -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        usleep(1_000)
    }
    throw TestFailure.message(message)
}

private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("plas-\(getpid())-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(root.path, mode_t(0o700)) == 0 else {
        throw TestFailure.message("chmod temporary root failed: \(errno)")
    }
    guard let canonicalPath = Darwin.realpath(root.path, nil) else {
        throw TestFailure.message("realpath temporary root failed: \(errno)")
    }
    defer { Darwin.free(canonicalPath) }
    return URL(
        fileURLWithPath: String(cString: canonicalPath),
        isDirectory: true
    )
}

private func withTemporaryRoot(
    _ body: (URL) throws -> Void
) throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func makeAddress(path: String) throws -> (sockaddr_un, socklen_t) {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    try require(pathBytes.count + 1 <= capacity, "test socket path is too long")

    address.sun_family = sa_family_t(AF_UNIX)
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
    let length = pathOffset + pathBytes.count + 1
    address.sun_len = UInt8(length)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in pathBytes.enumerated() {
            destination[index] = byte
        }
    }
    return (address, socklen_t(length))
}

private func connectSocket(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw TestFailure.message("socket failed: \(errno)")
    }

    var noSigPipe: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        Darwin.close(descriptor)
        throw TestFailure.message("SO_NOSIGPIPE failed: \(errno)")
    }

    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0,
          fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        Darwin.close(descriptor)
        throw TestFailure.message("O_NONBLOCK failed: \(errno)")
    }

    let socketAddress = try makeAddress(path: path)
    var address = socketAddress.0
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socketAddress.1)
        }
    }
    if result != 0 && errno == EINPROGRESS {
        try waitForSocket(
            descriptor,
            events: Int16(POLLOUT),
            deadline: Date().addingTimeInterval(2)
        )
        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0, socketError == 0 else {
            let code = socketError == 0 ? errno : socketError
            Darwin.close(descriptor)
            throw TestFailure.message("connect failed: \(code)")
        }
    } else if result != 0 {
        let code = errno
        Darwin.close(descriptor)
        throw TestFailure.message("connect failed: \(code)")
    }
    return descriptor
}

private func sendBytes(
    _ data: Data,
    to descriptor: Int32,
    allowDisconnect: Bool = false
) throws {
    let deadline = Date().addingTimeInterval(2)
    var offset = 0
    while offset < data.count {
        let count: Int = data.withUnsafeBytes { buffer in
            let start = buffer.baseAddress!.advanced(by: offset)
            return Darwin.send(descriptor, start, data.count - offset, 0)
        }

        if count > 0 {
            offset += count
            continue
        }
        if count < 0 && errno == EINTR {
            continue
        }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            try waitForSocket(
                descriptor,
                events: Int16(POLLOUT),
                deadline: deadline
            )
            continue
        }
        if allowDisconnect && (errno == EPIPE || errno == ECONNRESET) {
            return
        }
        throw TestFailure.message("send failed: \(errno)")
    }
}

private func waitForSocket(
    _ descriptor: Int32,
    events: Int16,
    deadline: Date
) throws {
    while Date() < deadline {
        let remaining = deadline.timeIntervalSinceNow
        let milliseconds = max(1, min(2_000, Int32(remaining * 1_000)))
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: events,
            revents: 0
        )
        let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
        if pollResult > 0 {
            return
        }
        if pollResult == 0 {
            continue
        }
        if errno != EINTR {
            throw TestFailure.message("poll failed: \(errno)")
        }
    }
    throw TestFailure.message("timed out waiting for socket readiness")
}

private func readUntilNewlineOrClose(
    from descriptor: Int32,
    timeout: TimeInterval = 2
) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    var result = Data()

    while Date() < deadline {
        let milliseconds = max(
            1,
            Int32(deadline.timeIntervalSinceNow * 1_000)
        )
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
        if pollResult < 0 {
            if errno == EINTR {
                continue
            }
            throw TestFailure.message("poll failed: \(errno)")
        }
        if pollResult == 0 {
            break
        }

        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if count > 0 {
            result.append(contentsOf: bytes.prefix(Int(count)))
            if result.contains(0x0a) {
                return result
            }
            continue
        }
        if count == 0 {
            return result
        }
        if errno == EINTR {
            continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            continue
        }
        if errno == ECONNRESET {
            return result
        }
        throw TestFailure.message("recv failed: \(errno)")
    }

    throw TestFailure.message("timed out waiting for response or close")
}

private func requestData(
    id: UUID = UUID(),
    idString: String? = nil,
    version: Int = 1,
    method: String = "listDevices",
    params: Any = [String: Any]()
) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: [
        "version": version,
        "id": idString ?? id.uuidString,
        "method": method,
        "params": params,
    ])
    data.append(0x0a)
    return data
}

private func responseObject(_ data: Data) throws -> [String: Any] {
    guard data.last == 0x0a,
          let object = try JSONSerialization.jsonObject(
            with: Data(data.dropLast())
          ) as? [String: Any] else {
        throw TestFailure.message("response was not one newline-delimited JSON object")
    }
    return object
}

private func roundTrip(
    socketPath: String,
    request: Data
) throws -> [String: Any] {
    let descriptor = try connectSocket(path: socketPath)
    defer { Darwin.close(descriptor) }
    try sendBytes(request, to: descriptor)
    return try responseObject(readUntilNewlineOrClose(from: descriptor))
}

private func bindRawSocket(path: String, listening: Bool) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw TestFailure.message("raw socket failed: \(errno)")
    }

    let socketAddress = try makeAddress(path: path)
    var address = socketAddress.0
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socketAddress.1)
        }
    }
    guard result == 0, chmod(path, mode_t(0o600)) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw TestFailure.message("raw bind/chmod failed: \(code)")
    }
    if listening, Darwin.listen(descriptor, 4) != 0 {
        let code = errno
        Darwin.close(descriptor)
        throw TestFailure.message("raw listen failed: \(code)")
    }
    return descriptor
}

private func testMalformedAndOversizedRequests() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let calls = LockedBox(0)
        let server = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { _, completion in
            calls.withValue { $0 += 1 }
            completion(.success(.null))
        }
        try server.start()
        defer { try? server.stop() }

        var malformed = Data("not-json".utf8)
        malformed.append(0x0a)
        let malformedClient = try connectSocket(path: socketURL.path)
        try sendBytes(malformed, to: malformedClient)
        let malformedReply = try readUntilNewlineOrClose(from: malformedClient)
        Darwin.close(malformedClient)
        try require(malformedReply.isEmpty, "uncorrelated malformed request received a reply")

        var oversized = Data(
            repeating: 0x61,
            count: PeelLocalAgentServer.maximumMessageBytes + 1
        )
        oversized.append(0x0a)
        let oversizedClient = try connectSocket(path: socketURL.path)
        try sendBytes(
            oversized,
            to: oversizedClient,
            allowDisconnect: true
        )
        let oversizedReply = try readUntilNewlineOrClose(from: oversizedClient)
        Darwin.close(oversizedClient)
        try require(oversizedReply.isEmpty, "oversized request received a reply")
        try require(calls.withValue { $0 } == 0, "invalid input reached the handler")
    }
}

/// A realistic window capture (base64 JPEG at the adapter's 160000-character
/// cap) crosses the real transport; payloads whose JSON encoding would exceed
/// the limit through escaping, non-ASCII or nesting are refused.
private func testResponseSizeAccounting() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let results = LockedBox<[PeelLocalAgentJSONValue]>([])
        let server = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { _, completion in
            completion(.success(results.withValue { $0.removeFirst() }))
        }
        try server.start()
        defer { try? server.stop() }

        @MainActor func reply(_ value: PeelLocalAgentJSONValue) throws -> [String: Any] {
            results.withValue { $0.append(value) }
            return try roundTrip(socketPath: socketURL.path, request: requestData())
        }
        func refused(_ response: [String: Any]) -> Bool {
            (response["error"] as? [String: Any])?["code"] as? String == "response_too_large"
        }

        let base64 = Data((0..<120_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).base64EncodedString()
        try require(base64.utf8.count == 160_000, "fixture is a full-size capture")
        let capture = try reply(.object([
            "imageJPEGBase64": .string(base64), "width": .integer(1600), "height": .integer(1000),
            "inspectionId": .string(UUID().uuidString), "title": .string("Fixture \"quoted\" \\ é ✓"),
        ]))
        try require(
            (capture["result"] as? [String: Any])?["imageJPEGBase64"] as? String == base64,
            "full-size capture was not delivered intact"
        )

        let limit = PeelLocalAgentServer.maximumMessageBytes
        let plain = try reply(.string(String(repeating: "a", count: limit)))
        try require(refused(plain), "plain oversized string accepted")
        let quotes = try reply(.string(String(repeating: "\"", count: limit / 2)))
        try require(refused(quotes), "escaped quotes undercounted")
        let controls = try reply(.string(String(repeating: "\u{01}", count: limit / 6)))
        try require(refused(controls), "control escapes undercounted")
        let nonASCII = try reply(.string(String(repeating: "😀", count: limit / 4)))
        try require(refused(nonASCII), "non-ASCII undercounted")
        let array = try reply(.array(Array(repeating: .string(String(repeating: "a", count: 4096)), count: 64)))
        try require(refused(array), "oversized array accepted")
        var nested = PeelLocalAgentJSONValue.null
        for _ in 0..<70 { nested = .array([nested]) }
        let deep = try reply(nested)
        try require(refused(deep), "over-deep nesting accepted")
    }
}

private func testLowercaseIDIsEchoedExactly() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let observedDeadline = LockedBox<UInt64?>(nil)
        let server = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { request, completion in
            observedDeadline.withValue {
                $0 = request.deadlineUptimeNanoseconds
            }
            completion(.success(.null))
        }
        try server.start()
        defer { try? server.stop() }

        let lowercaseID = UUID().uuidString.lowercased()
        let success = try roundTrip(
            socketPath: socketURL.path,
            request: requestData(idString: lowercaseID)
        )
        try require(
            success["id"] as? String == lowercaseID,
            "success response changed lowercase request id"
        )
        try require(
            observedDeadline.withValue { $0 } != nil,
            "handler request did not expose its admitted deadline"
        )

        var malformed = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "id": lowercaseID,
            "params": [String: Any](),
        ])
        malformed.append(0x0a)
        let failure = try roundTrip(
            socketPath: socketURL.path,
            request: malformed
        )
        try require(
            failure["id"] as? String == lowercaseID,
            "recoverable error response changed lowercase request id"
        )
        let error = failure["error"] as? [String: Any]
        try require(
            error?["code"] as? String == "invalid_request",
            "recoverable malformed request did not return invalid_request"
        )
    }
}

private func testStaleSocketCleanupAndLiveSocketRefusal() throws {
    try withTemporaryRoot { root in
        let directory = root.appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let socketURL = directory.appendingPathComponent("bridge.sock")

        let staleDescriptor = try bindRawSocket(
            path: socketURL.path,
            listening: false
        )
        Darwin.close(staleDescriptor)

        let replacement = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { _, completion in
            completion(.success(.null))
        }
        try replacement.start()
        try replacement.stop()

        let liveDescriptor = try bindRawSocket(
            path: socketURL.path,
            listening: true
        )
        defer {
            Darwin.close(liveDescriptor)
            unlink(socketURL.path)
        }
        var liveStatus = stat()
        try require(
            lstat(socketURL.path, &liveStatus) == 0,
            "live socket was not present before refusal test"
        )

        let contender = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { _, completion in
            completion(.success(.null))
        }
        do {
            try contender.start()
            try? contender.stop()
            throw TestFailure.message("server replaced a live listener")
        } catch let error as PeelLocalAgentServerError {
            guard case .addressInUse = error else {
                throw TestFailure.message("unexpected live-listener error: \(error)")
            }
        }

        var afterStatus = stat()
        try require(
            lstat(socketURL.path, &afterStatus) == 0 &&
                liveStatus.st_dev == afterStatus.st_dev &&
                liveStatus.st_ino == afterStatus.st_ino,
            "live listener inode was replaced or removed"
        )
    }
}

private func testMissingNewlineDeadline() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let server = PeelLocalAgentServer(
            configuration: .init(
                socketURL: socketURL,
                readTimeout: 0.15,
                handlerTimeout: 1,
                writeTimeout: 1
            )
        ) { _, completion in
            completion(.success(.null))
        }
        try server.start()
        defer { try? server.stop() }

        let descriptor = try connectSocket(path: socketURL.path)
        var request = try requestData()
        request.removeLast()
        try sendBytes(request, to: descriptor)
        let response = try readUntilNewlineOrClose(from: descriptor)
        Darwin.close(descriptor)
        try require(response.isEmpty, "unterminated request received a response")
    }
}

private func testUnsafePathIsRefused() throws {
    try withTemporaryRoot { root in
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let linkedDirectory = root.appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )

        let server = PeelLocalAgentServer(
            configuration: .init(
                socketURL: linkedDirectory.appendingPathComponent("bridge.sock")
            )
        ) { _, completion in
            completion(.success(.null))
        }

        do {
            try server.start()
            try? server.stop()
            throw TestFailure.message("server started through a symlink")
        } catch let error as PeelLocalAgentServerError {
            guard case .unsafePath = error else {
                throw TestFailure.message("unexpected unsafe-path error: \(error)")
            }
        }
    }
}

private func testStopAndRestart() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let server = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { request, completion in
            completion(.success(.object([
                "method": .string(request.method.rawValue),
            ])))
            completion(.failure(.init(
                code: "duplicate",
                message: "This second completion must be ignored."
            )))
        }

        for _ in 0..<2 {
            try server.start()
            let id = UUID()
            let response = try roundTrip(
                socketPath: socketURL.path,
                request: requestData(id: id)
            )
            try require(
                response["id"] as? String == id.uuidString,
                "response id did not match request"
            )
            let result = response["result"] as? [String: Any]
            try require(
                result?["method"] as? String == "listDevices",
                "first completion did not win"
            )
            try server.stop()

            var status = stat()
            try require(
                lstat(socketURL.path, &status) != 0 && errno == ENOENT,
                "socket path remained after clean stop"
            )
        }
    }
}

private func testBlockedHandlerIsSkippedAfterTimeout() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let handlerQueue = DispatchQueue(label: "peel.local-agent.tests.blocked-timeout")
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        handlerQueue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        try require(
            blockerStarted.wait(timeout: .now() + 1) == .success,
            "timeout fixture did not block its handler queue"
        )
        defer { releaseBlocker.signal() }

        let invocations = LockedBox(0)
        let server = PeelLocalAgentServer(
            configuration: .init(
                socketURL: socketURL,
                readTimeout: 1,
                handlerTimeout: 0.15,
                writeTimeout: 1
            ),
            handlerQueue: handlerQueue
        ) { _, completion in
            invocations.withValue { $0 += 1 }
            completion(.success(.null))
        }
        try server.start()
        defer { try? server.stop() }

        let descriptor = try connectSocket(path: socketURL.path)
        try sendBytes(requestData(), to: descriptor)
        try waitUntil(
            message: "timed-out handler was not submitted"
        ) {
            server.testingHandlerInvocationsInFlight == 1
        }

        let response = try responseObject(
            readUntilNewlineOrClose(from: descriptor)
        )
        Darwin.close(descriptor)
        let error = response["error"] as? [String: Any]
        try require(
            error?["code"] as? String == "timeout",
            "blocked handler did not reach its transport timeout"
        )

        releaseBlocker.signal()
        let queueDrained = DispatchSemaphore(value: 0)
        handlerQueue.async {
            queueDrained.signal()
        }
        try require(
            queueDrained.wait(timeout: .now() + 1) == .success,
            "timeout fixture handler queue did not drain"
        )
        try waitUntil(
            message: "skipped timed-out handler did not decrement in-flight state"
        ) {
            server.testingHandlerInvocationsInFlight == 0
        }
        try require(
            invocations.withValue { $0 } == 0,
            "timed-out queued handler was invoked after queue release"
        )
    }
}

private func testBlockedOldHandlerIsSkippedAfterStopAndRestart() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let handlerQueue = DispatchQueue(label: "peel.local-agent.tests.blocked-restart")
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        handlerQueue.async {
            blockerStarted.signal()
            releaseBlocker.wait()
        }
        try require(
            blockerStarted.wait(timeout: .now() + 1) == .success,
            "restart fixture did not block its handler queue"
        )
        defer { releaseBlocker.signal() }

        let invokedMarkers = LockedBox<[String]>([])
        let server = PeelLocalAgentServer(
            configuration: .init(
                socketURL: socketURL,
                readTimeout: 1,
                handlerTimeout: 5,
                writeTimeout: 1
            ),
            handlerQueue: handlerQueue
        ) { request, completion in
            guard let markerValue = request.params["marker"],
                  case .string(let marker) = markerValue else {
                completion(.failure(.init(
                    code: "invalid_test_marker",
                    message: "Missing fixture marker."
                )))
                return
            }
            invokedMarkers.withValue { $0.append(marker) }
            completion(.success(.string(marker)))
        }

        try server.start()
        defer { try? server.stop() }

        let oldClient = try connectSocket(path: socketURL.path)
        try sendBytes(
            requestData(params: ["marker": "old"]),
            to: oldClient
        )
        try waitUntil(
            message: "old-generation handler was not submitted"
        ) {
            server.testingHandlerInvocationsInFlight == 1
        }

        try server.stop()
        Darwin.close(oldClient)
        try server.start()

        let newClient = try connectSocket(path: socketURL.path)
        try sendBytes(
            requestData(params: ["marker": "new"]),
            to: newClient
        )
        try waitUntil(
            message: "new-generation handler was not submitted"
        ) {
            server.testingHandlerInvocationsInFlight == 2
        }

        releaseBlocker.signal()
        let response = try responseObject(
            readUntilNewlineOrClose(from: newClient)
        )
        Darwin.close(newClient)
        try require(
            response["result"] as? String == "new",
            "current-generation handler did not complete after queue release"
        )

        let queueDrained = DispatchSemaphore(value: 0)
        handlerQueue.async {
            queueDrained.signal()
        }
        try require(
            queueDrained.wait(timeout: .now() + 1) == .success,
            "restart fixture handler queue did not drain"
        )
        try waitUntil(
            message: "restart fixture did not decrement in-flight state"
        ) {
            server.testingHandlerInvocationsInFlight == 0
        }
        try require(
            invokedMarkers.withValue { $0 } == ["new"],
            "stopped-generation handler was invoked after restart"
        )
    }
}

private func testCompletionAfterTimeoutIsSuppressed() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let completionBox = LockedBox<PeelLocalAgentServer.Completion?>(nil)
        let handlerCalled = DispatchSemaphore(value: 0)
        let server = PeelLocalAgentServer(
            configuration: .init(
                socketURL: socketURL,
                readTimeout: 1,
                handlerTimeout: 0.15,
                writeTimeout: 1
            )
        ) { _, completion in
            completionBox.withValue { $0 = completion }
            handlerCalled.signal()
        }
        try server.start()
        defer { try? server.stop() }

        let descriptor = try connectSocket(path: socketURL.path)
        try sendBytes(requestData(), to: descriptor)
        try require(
            handlerCalled.wait(timeout: .now() + 1) == .success,
            "handler was not called"
        )

        let responseData = try readUntilNewlineOrClose(from: descriptor)
        let response = try responseObject(responseData)
        let error = response["error"] as? [String: Any]
        try require(error?["code"] as? String == "timeout", "handler timeout was not returned")

        completionBox.withValue {
            $0?(.success(.string("late")))
            $0?(.success(.string("duplicate")))
        }
        let trailing = try readUntilNewlineOrClose(from: descriptor)
        Darwin.close(descriptor)
        try require(trailing.isEmpty, "late completion produced another response")
    }
}

private func testCompletionAfterStopAndRestartIsSuppressed() throws {
    try withTemporaryRoot { root in
        let socketURL = root
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("bridge.sock")
        let completions = LockedBox<[PeelLocalAgentServer.Completion]>([])
        let handlerCalled = DispatchSemaphore(value: 0)
        let server = PeelLocalAgentServer(
            configuration: .init(socketURL: socketURL)
        ) { _, completion in
            completions.withValue { $0.append(completion) }
            handlerCalled.signal()
        }

        try server.start()
        let oldClient = try connectSocket(path: socketURL.path)
        try sendBytes(requestData(), to: oldClient)
        try require(
            handlerCalled.wait(timeout: .now() + 1) == .success,
            "first handler was not called"
        )
        try server.stop()
        let oldCompletion = completions.withValue { $0[0] }
        oldCompletion(.success(.string("late-after-stop")))
        let oldTrailing = try readUntilNewlineOrClose(from: oldClient)
        Darwin.close(oldClient)
        try require(oldTrailing.isEmpty, "completion after stop wrote a response")

        try server.start()
        let newClient = try connectSocket(path: socketURL.path)
        try sendBytes(requestData(), to: newClient)
        try require(
            handlerCalled.wait(timeout: .now() + 1) == .success,
            "second handler was not called"
        )
        let newCompletion = completions.withValue { $0[1] }
        newCompletion(.success(.string("current")))
        let response = try responseObject(
            readUntilNewlineOrClose(from: newClient)
        )
        Darwin.close(newClient)
        try require(response["result"] as? String == "current", "restart response was incorrect")

        oldCompletion(.success(.string("late-again")))
        try server.stop()
    }
}

@main
private struct PeelLocalAgentServerTestMain {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("malformed and oversized requests", testMalformedAndOversizedRequests),
            ("response size accounting", testResponseSizeAccounting),
            ("lowercase id exact echo", testLowercaseIDIsEchoedExactly),
            ("stale cleanup and live refusal", testStaleSocketCleanupAndLiveSocketRefusal),
            ("missing newline deadline", testMissingNewlineDeadline),
            ("unsafe path refusal", testUnsafePathIsRefused),
            ("stop and restart", testStopAndRestart),
            ("blocked handler skipped after timeout", testBlockedHandlerIsSkippedAfterTimeout),
            ("blocked old handler skipped after restart", testBlockedOldHandlerIsSkippedAfterStopAndRestart),
            ("completion after timeout", testCompletionAfterTimeoutIsSuppressed),
            ("completion after stop and restart", testCompletionAfterStopAndRestartIsSuppressed),
        ]

        for (name, test) in tests {
            try test()
            print("PASS: \(name)")
        }
    }
}
