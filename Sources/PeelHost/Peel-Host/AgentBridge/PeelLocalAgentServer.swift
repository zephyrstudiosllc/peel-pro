import Foundation
import Darwin

nonisolated enum PeelLocalAgentJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([PeelLocalAgentJSONValue])
    case object([String: PeelLocalAgentJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PeelLocalAgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PeelLocalAgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON numbers must be finite"
                    )
                )
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

nonisolated enum PeelLocalAgentMethod: String, Codable, CaseIterable, Sendable {
    case listDevices
    case listWindows
    case listApps
    case launchApp
    case presentWindow
    case notify
    case getStreamDiagnostics
    case inspectWindow
    case controlWindow
}

/// The write direction distinguishes a supported request half-close from a
/// vanished client. Zero-byte send probes no payload; accepted descriptors are
/// nonblocking with SO_NOSIGPIPE. Invalidation precedes descriptor close/reuse.
nonisolated final class PeelLocalAgentRequestLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?
    private var active = true
    init(descriptor: Int32? = nil) { self.descriptor = descriptor }
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        guard let descriptor else { return true }
        return Darwin.send(descriptor, nil, 0, MSG_DONTWAIT) >= 0
    }
    func invalidate() { lock.lock(); active = false; descriptor = nil; lock.unlock() }
}

nonisolated struct PeelLocalAgentRequest: Equatable, Sendable {
    let version: Int
    let id: UUID
    let method: PeelLocalAgentMethod
    let params: [String: PeelLocalAgentJSONValue]
    let deadlineUptimeNanoseconds: UInt64
    let lifetime: PeelLocalAgentRequestLifetime
    init(version: Int, id: UUID, method: PeelLocalAgentMethod, params: [String: PeelLocalAgentJSONValue],
         deadlineUptimeNanoseconds: UInt64, lifetime: PeelLocalAgentRequestLifetime = .init()) {
        self.version = version; self.id = id; self.method = method; self.params = params
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds; self.lifetime = lifetime
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.id == rhs.id && lhs.method == rhs.method &&
            lhs.params == rhs.params && lhs.deadlineUptimeNanoseconds == rhs.deadlineUptimeNanoseconds
    }
}

nonisolated struct PeelLocalAgentResponseError: Equatable, Sendable {
    let code: String
    let message: String

    init(code: String, message: String) {
        self.code = Self.safeCode(code)
        self.message = Self.safeMessage(message)
    }

    private static func safeCode(_ value: String) -> String {
        var count = 0
        for scalar in value.unicodeScalars {
            guard count < 64 else { return "internal_error" }
            switch scalar.value {
            case 45, 48...57, 95, 97...122:
                count += 1
            default:
                return "internal_error"
            }
        }
        return count > 0 ? value : "internal_error"
    }

    private static func safeMessage(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(min(value.unicodeScalars.count, 512))

        for scalar in value.unicodeScalars.prefix(512) {
            if scalar.value < 0x20 || scalar.value == 0x7f {
                output.append(" ")
            } else {
                output.append(scalar)
            }
        }

        let message = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Request failed." : message
    }
}

nonisolated enum PeelLocalAgentHandlerResult: Equatable, Sendable {
    case success(PeelLocalAgentJSONValue)
    case failure(PeelLocalAgentResponseError)
}

nonisolated enum PeelLocalAgentServerError: Error, LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case invalidConfiguration(String)
    case unsafePath(String)
    case addressInUse
    case systemCall(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The local agent server is already running."
        case .invalidConfiguration(let message):
            return "Invalid local agent server configuration: \(message)"
        case .unsafePath(let message):
            return "Unsafe local agent server path: \(message)"
        case .addressInUse:
            return "Another listener is using the local agent socket."
        case .systemCall(let operation, let code):
            return "\(operation) failed with POSIX error \(code)."
        }
    }
}

nonisolated final class PeelLocalAgentServer: @unchecked Sendable {
    struct Configuration: Sendable {
        var socketURL: URL
        var readTimeout: TimeInterval
        var handlerTimeout: TimeInterval
        var writeTimeout: TimeInterval

        init(
            socketURL: URL = PeelLocalAgentServer.defaultSocketURL,
            readTimeout: TimeInterval = 5,
            handlerTimeout: TimeInterval = 30,
            writeTimeout: TimeInterval = 5
        ) {
            self.socketURL = socketURL
            self.readTimeout = readTimeout
            self.handlerTimeout = handlerTimeout
            self.writeTimeout = writeTimeout
        }
    }

    typealias Completion = @Sendable (PeelLocalAgentHandlerResult) -> Void
    typealias Handler = @Sendable (PeelLocalAgentRequest, @escaping Completion) -> Void

    static let protocolVersion = 1
    static let maximumMessageBytes = 256 * 1024
    static let maximumClients = 4
    static let maximumDeadline: TimeInterval = 300

    static var defaultSocketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Peel", isDirectory: true)
            .appendingPathComponent("AgentBridge", isDirectory: true)
            .appendingPathComponent("bridge.sock", isDirectory: false)
    }

    private enum ClientPhase: Sendable {
        case reading
        case handling
        case writing
        case closed
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let owner: uid_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            mode = status.st_mode
            owner = status.st_uid
        }

        var fileType: mode_t {
            mode & mode_t(S_IFMT)
        }

        var permissions: mode_t {
            mode & mode_t(0o7777)
        }

        func isSameInode(as other: FileIdentity) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    private struct ReadSourceHandle {
        let source: DispatchSourceRead
        let cancelled: DispatchSemaphore
    }

    private struct WriteSourceHandle {
        let source: DispatchSourceWrite
        let cancelled: DispatchSemaphore
    }

    private struct TimerSourceHandle {
        let source: DispatchSourceTimer
        let cancelled: DispatchSemaphore
    }

    private final class EventGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false
        private var requestedWhilePending = false

        func enqueue(
            on queue: DispatchQueue,
            action: @escaping @Sendable () -> Bool
        ) {
            lock.lock()
            if pending {
                requestedWhilePending = true
                lock.unlock()
                return
            }
            pending = true
            lock.unlock()

            queue.async { [self] in
                run(on: queue, action: action)
            }
        }

        private func run(
            on queue: DispatchQueue,
            action: @escaping @Sendable () -> Bool
        ) {
            let shouldRepeat = action()

            lock.lock()
            if shouldRepeat || requestedWhilePending {
                requestedWhilePending = false
                lock.unlock()
                queue.async { [self] in
                    run(on: queue, action: action)
                }
            } else {
                pending = false
                lock.unlock()
            }
        }
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private final class Client {
        let identifier: UInt64
        let serverGeneration: UInt64
        let fileDescriptor: Int32
        var phase: ClientPhase = .reading
        var input = Data()
        var output = Data()
        var outputOffset = 0
        var responseID: String?
        var handlerDeadlineUptimeNanoseconds: UInt64?
        var readSource: ReadSourceHandle?
        var writeSource: WriteSourceHandle?
        var deadline: TimerSourceHandle?
        let lifetime: PeelLocalAgentRequestLifetime

        init(identifier: UInt64, serverGeneration: UInt64, fileDescriptor: Int32) {
            self.identifier = identifier
            self.serverGeneration = serverGeneration
            self.fileDescriptor = fileDescriptor
            self.lifetime = PeelLocalAgentRequestLifetime(descriptor: fileDescriptor)
        }
    }

    private struct WireRequest: Decodable {
        let version: Int
        let id: String
        let method: String
        let params: PeelLocalAgentJSONValue
    }

    private struct SuccessResponse: Encodable {
        let version: Int
        let id: String
        let result: PeelLocalAgentJSONValue
    }

    private struct FailureResponse: Encodable {
        struct WireError: Encodable {
            let code: String
            let message: String
        }

        let version: Int
        let id: String
        let error: WireError
    }

    private enum ProbeResult {
        case stale
        case live
        case ambiguous(Int32)
    }

    private let configuration: Configuration
    private let handlerQueue: DispatchQueue
    private let handler: Handler
    private let stateQueue = DispatchQueue(label: "com.peel.agentbridge.local-server.state")
    private let eventQueue = DispatchQueue(label: "com.peel.agentbridge.local-server.events")
    private let stateQueueKey = DispatchSpecificKey<UInt8>()

    private var running = false
    private var generation: UInt64 = 0
    private var nextClientIdentifier: UInt64 = 1
    private var clients: [UInt64: Client] = [:]
    private var handlerInvocationsInFlight = 0

    private var directoryFileDescriptor: Int32 = -1
    private var lockFileDescriptor: Int32 = -1
    private var listenerFileDescriptor: Int32 = -1
    private var listenerSource: ReadSourceHandle?
    private var socketIdentity: FileIdentity?
    private var directoryPath = ""
    private var socketName = ""
    private var socketPath = ""

    init(
        configuration: Configuration = Configuration(),
        handlerQueue: DispatchQueue = DispatchQueue(
            label: "com.peel.agentbridge.local-server.handler",
            qos: .userInitiated
        ),
        handler: @escaping Handler
    ) {
        self.configuration = configuration
        self.handlerQueue = handlerQueue
        self.handler = handler
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            try? stopLocked()
        } else {
            try? stop()
        }
    }

    var isRunning: Bool {
        stateQueue.sync { running }
    }

#if PEEL_LOCAL_AGENT_SERVER_TESTING
    var testingHandlerInvocationsInFlight: Int {
        stateQueue.sync { handlerInvocationsInFlight }
    }
#endif

    func start() throws {
        try stateQueue.sync {
            try startLocked()
        }
    }

    func stop() throws {
        try stateQueue.sync {
            try stopLocked()
        }
    }

    private func startLocked() throws {
        guard !running else {
            throw PeelLocalAgentServerError.alreadyRunning
        }
        let deadlines = [
            configuration.readTimeout,
            configuration.handlerTimeout,
            configuration.writeTimeout,
        ]
        guard deadlines.allSatisfy({
            $0.isFinite && $0 > 0 && $0 <= Self.maximumDeadline
        }) else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "deadlines must be finite and between 0 and 300 seconds"
            )
        }

        let path = configuration.socketURL.path
        let parsed = try Self.parseSocketPath(path)
        socketPath = path
        directoryPath = parsed.directoryPath
        socketName = parsed.socketName

        generation &+= 1
        var boundIdentity: FileIdentity?

        do {
            directoryFileDescriptor = try Self.openSecureDirectory(at: directoryPath)
            lockFileDescriptor = try acquireLockLocked()
            try removeStaleSocketIfNeededLocked()

            let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else {
                throw Self.posixError("socket")
            }
            listenerFileDescriptor = listener

            try Self.configureDescriptor(listener, nonBlocking: true)
            let address = try Self.makeSocketAddress(path: socketPath)
            var mutableAddress = address.value
            let bindResult = withUnsafePointer(to: &mutableAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, address.length)
                }
            }
            guard bindResult == 0 else {
                throw Self.posixError("bind")
            }

            let identityBeforePermissions = try checkedSocketIdentityLocked()
            boundIdentity = identityBeforePermissions
            guard identityBeforePermissions.fileType == mode_t(S_IFSOCK),
                  identityBeforePermissions.owner == geteuid() else {
                throw PeelLocalAgentServerError.unsafePath(
                    "new socket identity or owner changed before setting permissions"
                )
            }
            // Darwin does not support fchmod on a socket descriptor. The
            // owner-only directory and the identity checks on both sides of
            // this descriptor-relative call keep it scoped to the new socket.
            guard fchmodat(
                directoryFileDescriptor,
                socketName,
                mode_t(0o600),
                0
            ) == 0 else {
                throw Self.posixError("fchmodat(socket)")
            }

            let identity = try checkedSocketIdentityLocked()
            guard identity.isSameInode(as: identityBeforePermissions),
                  identity.permissions == mode_t(0o600) else {
                throw PeelLocalAgentServerError.unsafePath(
                    "socket identity changed while setting permissions"
                )
            }
            boundIdentity = identity
            socketIdentity = identity

            guard Darwin.listen(listener, Int32(Self.maximumClients)) == 0 else {
                throw Self.posixError("listen")
            }

            running = true
            let listenerGeneration = generation
            let source = makeReadSource(fileDescriptor: listener) { [weak self] in
                guard let self,
                      self.running,
                      self.generation == listenerGeneration else {
                    return false
                }
                return self.acceptPendingClientsLocked()
            }
            listenerSource = source
            source.source.resume()
        } catch {
            running = false

            if let source = listenerSource {
                cancel(source)
                listenerSource = nil
            }
            if listenerFileDescriptor >= 0 {
                Darwin.close(listenerFileDescriptor)
                listenerFileDescriptor = -1
            }
            if let identity = boundIdentity ?? socketIdentity {
                _ = try? removeSocketLocked(expected: identity)
            }
            socketIdentity = nil

            releaseLockLocked()
            closeDirectoryLocked()
            throw error
        }
    }

    private func stopLocked() throws {
        guard running || listenerFileDescriptor >= 0 || directoryFileDescriptor >= 0 else {
            return
        }

        running = false
        generation &+= 1

        if let source = listenerSource {
            cancel(source)
            listenerSource = nil
        }
        if listenerFileDescriptor >= 0 {
            Darwin.close(listenerFileDescriptor)
            listenerFileDescriptor = -1
        }

        let activeClients = Array(clients.values)
        clients.removeAll(keepingCapacity: false)
        for client in activeClients {
            closeClientResourcesLocked(client)
        }

        var removalError: Error?
        if let identity = socketIdentity {
            do {
                try removeSocketLocked(expected: identity)
            } catch {
                removalError = error
            }
        }
        socketIdentity = nil

        releaseLockLocked()
        closeDirectoryLocked()

        if let removalError {
            throw removalError
        }
    }

    private func acceptPendingClientsLocked() -> Bool {
        var acceptedInThisBatch = 0
        while running && acceptedInThisBatch < 16 {
            acceptedInThisBatch += 1
            let descriptor = Darwin.accept(listenerFileDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return false
                }
                try? stopLocked()
                return false
            }

            do {
                try Self.configureDescriptor(descriptor, nonBlocking: true)
            } catch {
                Darwin.close(descriptor)
                continue
            }

            var peerUserID: uid_t = 0
            var peerGroupID: gid_t = 0
            guard getpeereid(descriptor, &peerUserID, &peerGroupID) == 0,
                  peerUserID == geteuid(),
                  clients.count < Self.maximumClients else {
                Darwin.close(descriptor)
                continue
            }

            let identifier = nextClientIdentifier
            nextClientIdentifier &+= 1
            let client = Client(
                identifier: identifier,
                serverGeneration: generation,
                fileDescriptor: descriptor
            )
            clients[identifier] = client

            let source = makeReadSource(fileDescriptor: descriptor) { [weak self] in
                self?.readClientLocked(identifier: identifier)
                return false
            }
            client.readSource = source
            source.source.resume()
            scheduleDeadlineLocked(
                for: client,
                phase: .reading,
                interval: configuration.readTimeout
            )
        }
        return running && acceptedInThisBatch == 16
    }

    private func readClientLocked(identifier: UInt64) {
        guard let client = currentClientLocked(identifier: identifier, phase: .reading) else {
            return
        }

        while true {
            let remainingCapacity = Self.maximumMessageBytes + 1 - client.input.count
            guard remainingCapacity > 0 else {
                closeClientLocked(client)
                return
            }

            let readSize = min(16 * 1024, remainingCapacity)
            var bytes = [UInt8](repeating: 0, count: readSize)
            let count = Darwin.recv(client.fileDescriptor, &bytes, readSize, 0)

            if count > 0 {
                client.input.append(contentsOf: bytes.prefix(Int(count)))

                if let newline = client.input.firstIndex(of: 0x0a) {
                    let messageLength = client.input.distance(
                        from: client.input.startIndex,
                        to: newline
                    )
                    guard messageLength <= Self.maximumMessageBytes else {
                        closeClientLocked(client)
                        return
                    }

                    let message = Data(client.input.prefix(messageLength))
                    stopReadingLocked(client)
                    processRequestLocked(message, client: client)
                    return
                }

                if client.input.count > Self.maximumMessageBytes {
                    closeClientLocked(client)
                    return
                }
                continue
            }

            if count == 0 {
                closeClientLocked(client)
                return
            }

            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }

            closeClientLocked(client)
            return
        }
    }

    private func processRequestLocked(_ data: Data, client: Client) {
        guard !data.isEmpty else {
            closeClientLocked(client)
            return
        }

        let decoder = JSONDecoder()
        let wireRequest: WireRequest
        do {
            wireRequest = try decoder.decode(WireRequest.self, from: data)
        } catch {
            if let responseID = Self.extractValidatedRequestIDString(from: data) {
                client.responseID = responseID
                beginErrorResponseLocked(
                    client,
                    error: PeelLocalAgentResponseError(
                        code: "invalid_request",
                        message: "The request envelope is malformed."
                    )
                )
            } else {
                closeClientLocked(client)
            }
            return
        }

        guard let requestID = UUID(uuidString: wireRequest.id) else {
            closeClientLocked(client)
            return
        }
        client.responseID = wireRequest.id

        guard wireRequest.version == Self.protocolVersion else {
            beginErrorResponseLocked(
                client,
                error: PeelLocalAgentResponseError(
                    code: "unsupported_version",
                    message: "Only local agent protocol version 1 is supported."
                )
            )
            return
        }
        guard let method = PeelLocalAgentMethod(rawValue: wireRequest.method) else {
            beginErrorResponseLocked(
                client,
                error: PeelLocalAgentResponseError(
                    code: "unsupported_method",
                    message: "The requested method is not supported."
                )
            )
            return
        }
        guard case .object(let params) = wireRequest.params else {
            beginErrorResponseLocked(
                client,
                error: PeelLocalAgentResponseError(
                    code: "invalid_params",
                    message: "The params value must be a JSON object."
                )
            )
            return
        }

        guard handlerInvocationsInFlight < Self.maximumClients else {
            beginErrorResponseLocked(
                client,
                error: PeelLocalAgentResponseError(
                    code: "server_busy",
                    message: "The local agent handler is busy."
                )
            )
            return
        }

        client.phase = .handling
        client.input.removeAll(keepingCapacity: false)
        client.handlerDeadlineUptimeNanoseconds = scheduleDeadlineLocked(
            for: client,
            phase: .handling,
            interval: configuration.handlerTimeout
        )

        let clientIdentifier = client.identifier
        let clientGeneration = client.serverGeneration
        let clientIdentity = ObjectIdentifier(client)
        guard let handlerDeadline = client.handlerDeadlineUptimeNanoseconds else {
            closeClientLocked(client)
            return
        }
        let request = PeelLocalAgentRequest(
            version: wireRequest.version,
            id: requestID,
            method: method,
            params: params,
            deadlineUptimeNanoseconds: handlerDeadline,
            lifetime: client.lifetime
        )
        let completionGate = CompletionGate()
        handlerInvocationsInFlight += 1
        handlerQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateQueue.async { [weak self] in
                    guard let self else { return }
                    self.handlerInvocationsInFlight = max(
                        0,
                        self.handlerInvocationsInFlight - 1
                    )
                }
            }
            let mayInvoke = self.stateQueue.sync {
                self.mayInvokeHandlerLocked(
                    clientIdentifier: clientIdentifier,
                    clientGeneration: clientGeneration,
                    clientIdentity: clientIdentity,
                    handlerDeadline: handlerDeadline
                )
            }
            guard mayInvoke,
                  DispatchTime.now().uptimeNanoseconds < handlerDeadline else {
                return
            }
            self.handler(request) { [weak self] result in
                guard completionGate.claim() else { return }
                self?.stateQueue.async { [weak self] in
                    self?.completeRequestLocked(
                        clientIdentifier: clientIdentifier,
                        clientGeneration: clientGeneration,
                        result: result
                    )
                }
            }
        }
    }

    private func mayInvokeHandlerLocked(
        clientIdentifier: UInt64,
        clientGeneration: UInt64,
        clientIdentity: ObjectIdentifier,
        handlerDeadline: UInt64
    ) -> Bool {
        guard running,
              generation == clientGeneration,
              let client = clients[clientIdentifier],
              ObjectIdentifier(client) == clientIdentity,
              client.serverGeneration == clientGeneration,
              client.phase == .handling,
              client.handlerDeadlineUptimeNanoseconds == handlerDeadline,
              DispatchTime.now().uptimeNanoseconds < handlerDeadline else {
            return false
        }
        return true
    }

    private func completeRequestLocked(
        clientIdentifier: UInt64,
        clientGeneration: UInt64,
        result: PeelLocalAgentHandlerResult
    ) {
        guard let client = currentClientLocked(
            identifier: clientIdentifier,
            phase: .handling
        ), client.serverGeneration == clientGeneration else {
            return
        }

        guard let deadline = client.handlerDeadlineUptimeNanoseconds,
              DispatchTime.now().uptimeNanoseconds < deadline else {
            beginErrorResponseLocked(client, error: .init(
                code: "handler_timeout", message: "The local agent handler timed out."
            ))
            return
        }

        switch result {
        case .success(let value):
            beginSuccessResponseLocked(client, result: value)
        case .failure(let error):
            beginErrorResponseLocked(client, error: error)
        }
    }

    private func beginSuccessResponseLocked(
        _ client: Client,
        result: PeelLocalAgentJSONValue
    ) {
        guard let responseID = client.responseID else {
            closeClientLocked(client)
            return
        }

        do {
            try Self.validateResponseValue(result)
            let response = SuccessResponse(
                version: Self.protocolVersion,
                id: responseID,
                result: result
            )
            let data = try Self.encodeResponse(response)
            beginWritingLocked(client, data: data)
        } catch {
            beginErrorResponseLocked(
                client,
                error: PeelLocalAgentResponseError(
                    code: "response_too_large",
                    message: "The response exceeded the transport limit."
                )
            )
        }
    }

    private func beginErrorResponseLocked(
        _ client: Client,
        error: PeelLocalAgentResponseError
    ) {
        guard let responseID = client.responseID else {
            closeClientLocked(client)
            return
        }

        let response = FailureResponse(
            version: Self.protocolVersion,
            id: responseID,
            error: FailureResponse.WireError(
                code: error.code,
                message: error.message
            )
        )

        guard let data = try? Self.encodeResponse(response) else {
            closeClientLocked(client)
            return
        }
        beginWritingLocked(client, data: data)
    }

    private func beginWritingLocked(_ client: Client, data: Data) {
        guard clients[client.identifier] === client,
              client.serverGeneration == generation else {
            return
        }

        cancelDeadlineLocked(client)
        client.handlerDeadlineUptimeNanoseconds = nil
        client.phase = .writing
        client.output = data
        client.outputOffset = 0
        scheduleDeadlineLocked(
            for: client,
            phase: .writing,
            interval: configuration.writeTimeout
        )
        flushClientLocked(client)
    }

    private func flushClientLocked(_ client: Client) {
        guard clients[client.identifier] === client,
              client.phase == .writing else {
            return
        }

        while client.outputOffset < client.output.count {
            let sent: Int = client.output.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                let start = baseAddress.advanced(by: client.outputOffset)
                return Darwin.send(
                    client.fileDescriptor,
                    start,
                    client.output.count - client.outputOffset,
                    0
                )
            }

            if sent > 0 {
                client.outputOffset += sent
                continue
            }
            if sent == 0 {
                closeClientLocked(client)
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if client.writeSource == nil {
                    let identifier = client.identifier
                    let source = makeWriteSource(
                        fileDescriptor: client.fileDescriptor
                    ) { [weak self] in
                        guard let self,
                              let current = self.currentClientLocked(
                                identifier: identifier,
                                phase: .writing
                              ) else {
                            return false
                        }
                        self.flushClientLocked(current)
                        return false
                    }
                    client.writeSource = source
                    source.source.resume()
                }
                return
            }

            closeClientLocked(client)
            return
        }

        closeClientLocked(client)
    }

    @discardableResult
    private func scheduleDeadlineLocked(
        for client: Client,
        phase: ClientPhase,
        interval: TimeInterval
    ) -> UInt64 {
        cancelDeadlineLocked(client)
        let identifier = client.identifier
        let clientGeneration = client.serverGeneration
        let deadline = DispatchTime.now() + interval
        let timer = makeTimerSource(deadline: deadline) { [weak self] in
            guard let self,
                  let current = self.currentClientLocked(
                    identifier: identifier,
                    phase: phase
                  ),
                  current.serverGeneration == clientGeneration else {
                return false
            }

            if phase == .handling {
                self.beginErrorResponseLocked(
                    current,
                    error: PeelLocalAgentResponseError(
                        code: "timeout",
                        message: "The request handler did not complete before its deadline."
                    )
                )
            } else {
                self.closeClientLocked(current)
            }
            return false
        }
        client.deadline = timer
        timer.source.resume()
        return deadline.uptimeNanoseconds
    }

    private func cancelDeadlineLocked(_ client: Client) {
        guard let deadline = client.deadline else { return }
        cancel(deadline)
        client.deadline = nil
    }

    private func currentClientLocked(
        identifier: UInt64,
        phase: ClientPhase
    ) -> Client? {
        guard running,
              let client = clients[identifier],
              client.serverGeneration == generation,
              client.phase == phase else {
            return nil
        }
        return client
    }

    private func stopReadingLocked(_ client: Client) {
        if let source = client.readSource {
            cancel(source)
            client.readSource = nil
        }
        cancelDeadlineLocked(client)
    }

    private func closeClientLocked(_ client: Client) {
        guard clients[client.identifier] === client else {
            return
        }
        clients.removeValue(forKey: client.identifier)
        closeClientResourcesLocked(client)
    }

    private func closeClientResourcesLocked(_ client: Client) {
        client.lifetime.invalidate()
        client.phase = .closed
        client.handlerDeadlineUptimeNanoseconds = nil
        cancelDeadlineLocked(client)

        if let source = client.readSource {
            cancel(source)
            client.readSource = nil
        }
        if let source = client.writeSource {
            cancel(source)
            client.writeSource = nil
        }

        Darwin.close(client.fileDescriptor)
        client.input.removeAll(keepingCapacity: false)
        client.output.removeAll(keepingCapacity: false)
    }

    private func makeReadSource(
        fileDescriptor: Int32,
        stateHandler: @escaping @Sendable () -> Bool
    ) -> ReadSourceHandle {
        let cancelled = DispatchSemaphore(value: 0)
        let gate = EventGate()
        let stateQueue = self.stateQueue
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: eventQueue
        )
        source.setEventHandler {
            gate.enqueue(on: stateQueue, action: stateHandler)
        }
        source.setCancelHandler {
            cancelled.signal()
        }
        return ReadSourceHandle(source: source, cancelled: cancelled)
    }

    private func makeWriteSource(
        fileDescriptor: Int32,
        stateHandler: @escaping @Sendable () -> Bool
    ) -> WriteSourceHandle {
        let cancelled = DispatchSemaphore(value: 0)
        let gate = EventGate()
        let stateQueue = self.stateQueue
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: fileDescriptor,
            queue: eventQueue
        )
        source.setEventHandler {
            gate.enqueue(on: stateQueue, action: stateHandler)
        }
        source.setCancelHandler {
            cancelled.signal()
        }
        return WriteSourceHandle(source: source, cancelled: cancelled)
    }

    private func makeTimerSource(
        deadline: DispatchTime,
        stateHandler: @escaping @Sendable () -> Bool
    ) -> TimerSourceHandle {
        let cancelled = DispatchSemaphore(value: 0)
        let gate = EventGate()
        let stateQueue = self.stateQueue
        let source = DispatchSource.makeTimerSource(queue: eventQueue)
        source.schedule(
            deadline: deadline,
            leeway: .milliseconds(10)
        )
        source.setEventHandler {
            gate.enqueue(on: stateQueue, action: stateHandler)
        }
        source.setCancelHandler {
            cancelled.signal()
        }
        return TimerSourceHandle(source: source, cancelled: cancelled)
    }

    private func cancel(_ handle: ReadSourceHandle) {
        handle.source.cancel()
        handle.cancelled.wait()
    }

    private func cancel(_ handle: WriteSourceHandle) {
        handle.source.cancel()
        handle.cancelled.wait()
    }

    private func cancel(_ handle: TimerSourceHandle) {
        handle.source.cancel()
        handle.cancelled.wait()
    }

    private func acquireLockLocked() throws -> Int32 {
        let lockName = "bridge.sock.lock"
        var created = false
        var descriptor = openat(
            directoryFileDescriptor,
            lockName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )

        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = openat(
                directoryFileDescriptor,
                lockName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw Self.posixError("openat(lock)")
        }

        do {
            if created, fchmod(descriptor, mode_t(0o600)) != 0 {
                throw Self.posixError("fchmod(lock)")
            }

            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw Self.posixError("fstat(lock)")
            }
            let descriptorIdentity = FileIdentity(descriptorStatus)
            guard descriptorIdentity.fileType == mode_t(S_IFREG),
                  descriptorIdentity.owner == geteuid(),
                  descriptorIdentity.permissions == mode_t(0o600) else {
                throw PeelLocalAgentServerError.unsafePath(
                    "lock file must be an owner-only regular file"
                )
            }

            let pathIdentity = try Self.entryIdentity(
                directoryFileDescriptor: directoryFileDescriptor,
                name: lockName
            )
            guard descriptorIdentity.isSameInode(as: pathIdentity) else {
                throw PeelLocalAgentServerError.unsafePath(
                    "lock file identity changed while opening"
                )
            }

            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK {
                    throw PeelLocalAgentServerError.addressInUse
                }
                throw Self.posixError("flock")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func releaseLockLocked() {
        guard lockFileDescriptor >= 0 else { return }
        _ = flock(lockFileDescriptor, LOCK_UN)
        Darwin.close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func closeDirectoryLocked() {
        guard directoryFileDescriptor >= 0 else { return }
        Darwin.close(directoryFileDescriptor)
        directoryFileDescriptor = -1
    }

    private func removeStaleSocketIfNeededLocked() throws {
        let existing: FileIdentity
        do {
            existing = try checkedSocketIdentityLocked()
        } catch let error as PeelLocalAgentServerError {
            if case .systemCall(_, let code) = error, code == ENOENT {
                return
            }
            throw error
        }

        guard existing.owner == geteuid(),
              existing.fileType == mode_t(S_IFSOCK),
              existing.permissions == mode_t(0o600) else {
            throw PeelLocalAgentServerError.unsafePath(
                "existing socket has an unsafe owner, type, or permissions"
            )
        }

        switch Self.probeSocket(path: socketPath) {
        case .live:
            throw PeelLocalAgentServerError.addressInUse
        case .ambiguous:
            throw PeelLocalAgentServerError.unsafePath(
                "existing socket state is ambiguous"
            )
        case .stale:
            break
        }

        try removeSocketLocked(expected: existing)
    }

    @discardableResult
    private func removeSocketLocked(expected: FileIdentity) throws -> Bool {
        let before = try checkedSocketIdentityLocked()
        guard before.isSameInode(as: expected),
              before.fileType == mode_t(S_IFSOCK),
              before.owner == geteuid() else {
            throw PeelLocalAgentServerError.unsafePath(
                "socket identity changed before removal"
            )
        }

        let quarantineName = ".s.\(UUID().uuidString.prefix(8))"
        guard renameatx_np(
            directoryFileDescriptor,
            socketName,
            directoryFileDescriptor,
            quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw Self.posixError("renameatx_np(socket)")
        }

        do {
            let quarantined = try Self.entryIdentity(
                directoryFileDescriptor: directoryFileDescriptor,
                name: quarantineName
            )
            guard quarantined.isSameInode(as: expected),
                  quarantined.fileType == mode_t(S_IFSOCK),
                  quarantined.owner == geteuid() else {
                throw PeelLocalAgentServerError.unsafePath(
                    "socket identity changed during removal"
                )
            }

            let quarantinePath = directoryPath + "/" + quarantineName
            switch Self.probeSocket(path: quarantinePath) {
            case .live:
                throw PeelLocalAgentServerError.addressInUse
            case .ambiguous:
                throw PeelLocalAgentServerError.unsafePath(
                    "quarantined socket state is ambiguous"
                )
            case .stale:
                break
            }

            let immediatelyBeforeUnlink = try Self.entryIdentity(
                directoryFileDescriptor: directoryFileDescriptor,
                name: quarantineName
            )
            guard immediatelyBeforeUnlink.isSameInode(as: expected) else {
                throw PeelLocalAgentServerError.unsafePath(
                    "quarantined socket identity changed before unlink"
                )
            }
            guard unlinkat(directoryFileDescriptor, quarantineName, 0) == 0 else {
                throw Self.posixError("unlinkat(socket)")
            }
            return true
        } catch {
            do {
                try restoreQuarantinedSocketLocked(name: quarantineName)
            } catch {
                throw PeelLocalAgentServerError.unsafePath(
                    "could not safely restore a quarantined socket"
                )
            }
            throw error
        }
    }

    private func restoreQuarantinedSocketLocked(name: String) throws {
        guard renameatx_np(
            directoryFileDescriptor,
            name,
            directoryFileDescriptor,
            socketName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw PeelLocalAgentServerError.unsafePath(
                "could not safely restore a quarantined socket"
            )
        }
    }

    private func checkedSocketIdentityLocked() throws -> FileIdentity {
        let relative = try Self.entryIdentity(
            directoryFileDescriptor: directoryFileDescriptor,
            name: socketName
        )
        let absolute = try Self.lstatIdentity(path: socketPath)
        guard relative.isSameInode(as: absolute),
              relative.mode == absolute.mode,
              relative.owner == absolute.owner else {
            throw PeelLocalAgentServerError.unsafePath(
                "absolute and directory-relative socket identities differ"
            )
        }
        return relative
    }

    private static func parseSocketPath(
        _ path: String
    ) throws -> (directoryPath: String, socketName: String) {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "socket path must be absolute and contain no NUL bytes"
            )
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2,
              !components.contains("."),
              !components.contains("..") else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "socket path must not contain dot components"
            )
        }

        let socketName = String(components.last!)
        guard socketName == "bridge.sock" else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "socket filename must be bridge.sock"
            )
        }

        let directoryPath = "/" + components.dropLast().joined(separator: "/")
        _ = try makeSocketAddress(path: path)
        return (directoryPath, socketName)
    }

    private static func openSecureDirectory(at path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard current >= 0 else {
            throw posixError("open(root)")
        }

        do {
            for (index, componentValue) in components.enumerated() {
                let component = String(componentValue)
                let isFinal = index == components.count - 1
                var created = false
                var status = stat()

                if fstatat(current, component, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else {
                        throw posixError("fstatat(directory)")
                    }
                    if mkdirat(current, component, mode_t(0o700)) == 0 {
                        created = true
                    } else {
                        if errno != EEXIST {
                            throw posixError("mkdirat")
                        }
                    }
                    if fstatat(current, component, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                        throw posixError("fstatat(directory)")
                    }
                }

                let beforeOpen = FileIdentity(status)
                guard beforeOpen.fileType == mode_t(S_IFDIR) else {
                    throw PeelLocalAgentServerError.unsafePath(
                        "a path component is not a real directory"
                    )
                }
                guard beforeOpen.owner == 0 || beforeOpen.owner == geteuid() else {
                    throw PeelLocalAgentServerError.unsafePath(
                        "a path component has an untrusted owner"
                    )
                }

                let writableByOthers = beforeOpen.permissions &
                    mode_t(S_IWGRP | S_IWOTH) != 0
                let sticky = beforeOpen.mode & mode_t(S_ISVTX) != 0
                guard !writableByOthers || sticky else {
                    throw PeelLocalAgentServerError.unsafePath(
                        "a path component is writable by another user"
                    )
                }

                let next = openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else {
                    throw posixError("openat(directory)")
                }

                var openedStatus = stat()
                guard fstat(next, &openedStatus) == 0 else {
                    Darwin.close(next)
                    throw posixError("fstat(directory)")
                }
                let opened = FileIdentity(openedStatus)
                guard opened.isSameInode(as: beforeOpen) else {
                    Darwin.close(next)
                    throw PeelLocalAgentServerError.unsafePath(
                        "a directory identity changed while opening"
                    )
                }

                if created {
                    guard fchmod(next, mode_t(0o700)) == 0 else {
                        Darwin.close(next)
                        throw posixError("fchmod(directory)")
                    }
                    guard fstat(next, &openedStatus) == 0 else {
                        Darwin.close(next)
                        throw posixError("fstat(directory)")
                    }
                }

                if isFinal {
                    let finalIdentity = FileIdentity(openedStatus)
                    guard finalIdentity.owner == geteuid(),
                          finalIdentity.permissions == mode_t(0o700) else {
                        Darwin.close(next)
                        throw PeelLocalAgentServerError.unsafePath(
                            "socket directory must be owned by the effective user with mode 0700"
                        )
                    }
                }

                Darwin.close(current)
                current = next
            }

            var descriptorStatus = stat()
            guard fstat(current, &descriptorStatus) == 0 else {
                throw posixError("fstat(socket directory)")
            }
            let descriptorIdentity = FileIdentity(descriptorStatus)
            let pathIdentity = try lstatIdentity(path: path)
            guard descriptorIdentity.isSameInode(as: pathIdentity) else {
                throw PeelLocalAgentServerError.unsafePath(
                    "socket directory identity changed during traversal"
                )
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func entryIdentity(
        directoryFileDescriptor: Int32,
        name: String
    ) throws -> FileIdentity {
        var status = stat()
        guard fstatat(
            directoryFileDescriptor,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw posixError("fstatat(\(name))")
        }
        return FileIdentity(status)
    }

    private static func lstatIdentity(path: String) throws -> FileIdentity {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw posixError("lstat")
        }
        return FileIdentity(status)
    }

    private static func configureDescriptor(
        _ descriptor: Int32,
        nonBlocking: Bool
    ) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw posixError("fcntl(FD_CLOEXEC)")
        }

        if nonBlocking {
            let statusFlags = fcntl(descriptor, F_GETFL)
            guard statusFlags >= 0,
                  fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
                throw posixError("fcntl(O_NONBLOCK)")
            }
        }

        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw posixError("setsockopt(SO_NOSIGPIPE)")
        }
    }

    private static func makeSocketAddress(
        path: String
    ) throws -> (value: sockaddr_un, length: socklen_t) {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count + 1 <= pathCapacity else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "socket path exceeds Darwin's AF_UNIX limit"
            )
        }

        address.sun_family = sa_family_t(AF_UNIX)
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        let length = pathOffset + pathBytes.count + 1
        guard length <= Int(UInt8.max) else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "socket address length is invalid"
            )
        }
        address.sun_len = UInt8(length)

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                destination[index] = byte
            }
        }
        return (address, socklen_t(length))
    }

    private static func probeSocket(path: String) -> ProbeResult {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .ambiguous(errno)
        }
        defer { Darwin.close(descriptor) }

        do {
            try configureDescriptor(descriptor, nonBlocking: true)
            let address = try makeSocketAddress(path: path)
            var mutableAddress = address.value
            let result = withUnsafePointer(to: &mutableAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, address.length)
                }
            }
            if result == 0 {
                return .live
            }

            switch errno {
            case EINPROGRESS, EALREADY, EISCONN:
                return .live
            case ECONNREFUSED:
                return .stale
            default:
                return .ambiguous(errno)
            }
        } catch let error as PeelLocalAgentServerError {
            if case .systemCall(_, let code) = error {
                return .ambiguous(code)
            }
            return .ambiguous(EINVAL)
        } catch {
            return .ambiguous(EINVAL)
        }
    }

    private static func extractValidatedRequestIDString(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let value = dictionary["id"] as? String,
              UUID(uuidString: value) != nil else {
            return nil
        }
        return value
    }

    private static func encodeResponse<T: Encodable>(_ response: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(response)
        guard data.count <= maximumMessageBytes else {
            throw PeelLocalAgentServerError.invalidConfiguration(
                "encoded response exceeds the transport limit"
            )
        }
        data.append(0x0a)
        return data
    }

    private static func validateResponseValue(
        _ value: PeelLocalAgentJSONValue
    ) throws {
        var remaining = maximumMessageBytes - 512

        func consume(_ count: Int) throws {
            guard count >= 0, count <= remaining else {
                throw PeelLocalAgentServerError.invalidConfiguration(
                    "encoded response exceeds the transport limit"
                )
            }
            remaining -= count
        }

        /// An upper bound of the string's JSON encoding, stopping as soon as
        /// the budget is spent: printable ASCII is one byte, a quote or
        /// backslash two, a control character at most a six-byte `\u` escape,
        /// and any other scalar at most a `\u` escape per UTF-16 unit, which
        /// also covers its raw UTF-8 bytes.
        func consumeString(_ string: String) throws {
            try consume(2)
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 0..<0x20: try consume(6)
                case 0x22, 0x5C: try consume(2)
                case 0x20..<0x80: try consume(1)
                case 0x80...0xFFFF: try consume(6)
                default: try consume(12)
                }
            }
        }

        func visit(_ current: PeelLocalAgentJSONValue, depth: Int) throws {
            guard depth <= 64 else {
                throw PeelLocalAgentServerError.invalidConfiguration(
                    "encoded response exceeds the nesting limit"
                )
            }

            switch current {
            case .null:
                try consume(4)
            case .bool:
                try consume(5)
            case .integer:
                try consume(21)
            case .number:
                try consume(32)
            case .string(let string):
                try consumeString(string)
            case .array(let values):
                guard values.count <= remaining / 2 else {
                    throw PeelLocalAgentServerError.invalidConfiguration(
                        "encoded response exceeds the transport limit"
                    )
                }
                try consume(2 + max(0, values.count - 1))
                for element in values {
                    try visit(element, depth: depth + 1)
                }
            case .object(let object):
                guard object.count <= remaining / 4 else {
                    throw PeelLocalAgentServerError.invalidConfiguration(
                        "encoded response exceeds the transport limit"
                    )
                }
                try consume(2 + max(0, object.count - 1))
                for (key, element) in object {
                    try consumeString(key)
                    try consume(1)
                    try visit(element, depth: depth + 1)
                }
            }
        }

        try visit(value, depth: 0)
    }

    private static func posixError(_ operation: String) -> PeelLocalAgentServerError {
        .systemCall(operation: operation, code: errno)
    }
}
