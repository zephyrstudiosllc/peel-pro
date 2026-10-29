import Foundation
import Network
import Darwin

nonisolated private enum Mode: String { case success, fragmented, wrongNonce, oversized, unframed, silent, wrongKey }

nonisolated private func fixtureDiagnostic(_ message: String) {
    fputs("TLS-FIXTURE \(message)\n", stderr)
}

private func privateInterfaceAddress() -> String? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return nil }
    defer { freeifaddrs(first) }
    var cursor = first
    while let item = cursor {
        defer { cursor = item.pointee.ifa_next }
        guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
            let host = String(cString: text)
            if PeelICloudPairingValidation.endpointHost(host) != nil { return host }
        }
    }
    return nil
}

nonisolated private final class TLSFixture: @unchecked Sendable {
    let mode: Mode
    let hostID = UUID().uuidString
    let enrollmentID = UUID().uuidString
    let secret = Data(repeating: 0x69, count: 32)
    let queue = DispatchQueue(label: "peel.icloud.fixture")
    var listener: NWListener!
    var connections = [NWConnection]()
    var record: PeelICloudHostRecord!
    var sawLF = false

    init(mode: Mode, host: String) throws {
        self.mode = mode
        let identity = "peel-icloud-v1-\(hostID)-\(enrollmentID)"
        let parameters = PeelTLS.makeSinglePSKHostParameters(identity: identity,
            psk: mode == .wrongKey ? Data(repeating: 0x70, count: 32) : secret)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            fixtureDiagnostic("\(mode.rawValue) listener=\(state)")
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            fixtureDiagnostic("\(self.mode.rawValue) accepted connection")
            self.connections.append(connection)
            var started = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                fixtureDiagnostic("\(self.mode.rawValue) server connection=\(state)")
                if case .ready = state, !started {
                    started = true
                    self.receive(connection, buffer: Data())
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            throw NSError(domain: "Fixture", code: 1)
        }
        record = try PeelICloudHostRecord(hostID: hostID, enrollmentID: enrollmentID,
            displayName: "Disposable TLS Fixture", endpointHost: host,
            controlPort: port.rawValue == 49706 ? 49705 : 49706,
            pairingPort: port.rawValue, bootstrapSecret: secret)
        fixtureDiagnostic("\(mode.rawValue) host=\(host) port=\(port.rawValue)")
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var updated = buffer
            if let data { updated.append(data) }
            fixtureDiagnostic("\(self.mode.rawValue) receive bytes=\(data?.count ?? 0) complete=\(complete) error=\(String(describing: error))")
            switch PeelICloudPairRequestFrameDecoder.decode(updated, isComplete: complete || error != nil) {
            case .request(let request):
                self.sawLF = true
                guard request.isValid(for: self.record) else { connection.cancel(); return }
                if self.mode == .silent { return }
                let response = PeelICloudPairResponse(hostID: self.hostID, enrollmentID: self.enrollmentID,
                    requestID: self.mode == .wrongNonce ? UUID().uuidString : request.requestID,
                    hostName: self.record.displayName, accepted: true,
                    pairingID: UUID().uuidString, psk: Data(repeating: 0x53, count: 32))
                var bytes = (try? JSONEncoder().encode(response)) ?? Data()
                if self.mode == .oversized { bytes = Data(repeating: 0x78, count: 9000) }
                if self.mode != .unframed { bytes.append(0x0a) }
                if self.mode == .fragmented {
                    let split = bytes.count / 2
                    connection.send(content: bytes.prefix(split), completion: .contentProcessed { _ in
                        self.queue.asyncAfter(deadline: .now() + 0.02) {
                            connection.send(content: bytes.suffix(from: split), completion: .contentProcessed { _ in })
                        }
                    })
                } else {
                    connection.send(content: bytes, completion: .contentProcessed { _ in
                        if self.mode == .unframed { connection.cancel() }
                    })
                }
            case .incomplete:
                self.receive(connection, buffer: updated)
            case .invalid: connection.cancel()
            }
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

@main struct TransportChecks {
    static func main() throws {
        guard let host = privateInterfaceAddress() else {
            throw NSError(domain: "Fixture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A private IPv4 interface is required for the disposable TLS test."])
        }
        fixtureDiagnostic("selected interface address=\(host)")
        var checks = 0
        for mode in [Mode.success, .fragmented, .wrongNonce, .oversized, .unframed, .silent, .wrongKey] {
            let fixture = try TLSFixture(mode: mode, host: host)
            defer { fixture.stop() }
            let request = PeelICloudPairRequest(hostID: fixture.hostID, enrollmentID: fixture.enrollmentID,
                clientDeviceID: UUID().uuidString, clientName: "Disposable Client")
            let line = try PeelICloudEnrollmentTransport.requestLine(request)
            guard line.last == 0x0a else { fatalError("request omitted LF") }
            // Positive handshakes use the production deadline. The deliberate
            // timeout and wrong-key cases keep a shorter bounded deadline.
            let timeout: TimeInterval = mode == .silent || mode == .wrongKey ? 1.5 : 8
            let transport = PeelICloudEnrollmentTransport(record: fixture.record, request: request,
                timeout: timeout, callbackQueue: .global())
            let startedAt = ProcessInfo.processInfo.systemUptime
            let finished = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result: Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>?
            var completions = 0
            transport.start { value in
                lock.lock(); result = value; completions += 1; lock.unlock()
                finished.signal()
            }
            guard finished.wait(timeout: .now() + timeout + 4) == .success else {
                fatalError("transport never completed in \(mode.rawValue)")
            }
            lock.lock(); let received = result; let count = completions; lock.unlock()
            let resultLabel = received.map { value -> String in
                switch value {
                case .success: return "success"
                case .failure(let error): return String(describing: error)
                }
            } ?? "missing"
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            fixtureDiagnostic("\(mode.rawValue) result=\(resultLabel) completions=\(count) elapsed=\(String(format: "%.3f", elapsed))s")
            guard count == 1 else { fatalError("completion delivered more than once") }
            switch (mode, received) {
            case (.success, .success(let response)), (.fragmented, .success(let response)):
                guard response.isValid(for: request), fixture.sawLF else { fatalError("wire framing or identity failed") }
            case (.wrongNonce, .failure(.invalidResponse)), (.oversized, .failure(.invalidResponse)),
                 (.unframed, .failure), (.silent, .failure(.timedOut)), (.wrongKey, .failure): break
            default: fatalError("unexpected TLS fixture result in \(mode.rawValue): \(String(describing: received))")
            }
            transport.cancel()
            guard finished.wait(timeout: .now() + 0.05) == .timedOut else {
                fatalError("cancellation produced a second completion in \(mode.rawValue)")
            }
            checks += 1
        }
        let fixture = try TLSFixture(mode: .silent, host: host)
        defer { fixture.stop() }
        let request = PeelICloudPairRequest(hostID: fixture.hostID, enrollmentID: fixture.enrollmentID,
            clientDeviceID: UUID().uuidString, clientName: "Disposable Client")
        let transport = PeelICloudEnrollmentTransport(record: fixture.record, request: request,
            timeout: 2, callbackQueue: .global())
        let cancelled = DispatchSemaphore(value: 0)
        transport.start { result in
            guard case .failure(.cancelled) = result else { fatalError("cancel not fenced") }
            cancelled.signal()
        }
        transport.cancel()
        guard cancelled.wait(timeout: .now() + 3) == .success else { fatalError("cancel did not finish") }
        checks += 1
        print("PASS \(checks) real TLS enrollment fixtures (framing, fragmentation, request binding, bounds, timeout, wrong key, cancellation). No real pairing or iCloud access.")
    }
}
