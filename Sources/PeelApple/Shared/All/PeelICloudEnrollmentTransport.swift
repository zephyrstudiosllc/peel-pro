import Foundation
import Network

nonisolated enum PeelICloudEnrollmentTransportError: Error, LocalizedError, Equatable {
    case invalidRequest
    case alreadyStarted
    case connectionFailed
    case timedOut
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The iCloud pairing information is invalid."
        case .alreadyStarted: return "This pairing attempt has already started."
        case .connectionFailed: return "The Mac could not be reached for pairing."
        case .timedOut: return "The Mac did not finish pairing in time."
        case .invalidResponse: return "The Mac's pairing response could not be verified."
        case .cancelled: return "Pairing was cancelled."
        }
    }
}

/// One temporary TLS-PSK connection. The caller retains this object until its
/// completion, validates its own consent generation, and owns all persistence.
/// There is no keychain, pairing-store, UI, or control-session access here.
// Mutable state is confined to queue; callbacks receive copied results.
nonisolated final class PeelICloudEnrollmentTransport: @unchecked Sendable {
    static let maximumFrameBytes = 8 * 1024

    private let record: PeelICloudHostRecord
    private let request: PeelICloudPairRequest
    private let timeoutSeconds: TimeInterval
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "peel.icloud.enrollment.transport")
    private var connection: NWConnection?
    private var completion: ((Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var received = Data()
    private var didStart = false
    private var didSend = false
    private var didFinish = false

    init(record: PeelICloudHostRecord, request: PeelICloudPairRequest,
         timeout: TimeInterval = 8, callbackQueue: DispatchQueue = .main) {
        self.record = record
        self.request = request
        self.timeoutSeconds = timeout.isFinite ? max(1, min(timeout, 30)) : 8
        self.callbackQueue = callbackQueue
    }

    deinit {
        timeoutWork?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    /// The host's enrollment listener consumes one LF-terminated JSON frame.
    static func requestLine(_ request: PeelICloudPairRequest) throws -> Data {
        var line = try JSONEncoder().encode(request)
        guard line.count < maximumFrameBytes else {
            throw PeelICloudEnrollmentTransportError.invalidRequest
        }
        line.append(0x0a)
        return line
    }

    func start(completion: @escaping (Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>) -> Void) {
        queue.async { [self] in
            guard !didStart, !didFinish else {
                let error: PeelICloudEnrollmentTransportError = didFinish ? .cancelled : .alreadyStarted
                callbackQueue.async { completion(.failure(error)) }
                return
            }
            didStart = true
            self.completion = completion
            guard record.isValid, request.isValid(for: record),
                  let port = NWEndpoint.Port(rawValue: record.pairingPort),
                  let payload = try? Self.requestLine(request) else {
                finish(.failure(.invalidRequest))
                return
            }
            let parameters = PeelTLS.makeClientParameters(
                pairingID: record.tlsIdentity, psk: record.bootstrapSecret, pskOrder: .standard
            )
            let connection = NWConnection(host: NWEndpoint.Host(record.endpointHost), port: port, using: parameters)
            self.connection = connection
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut)) }
            timeoutWork = timeout
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.didFinish else { return }
                switch state {
                case .ready:
                    guard !self.didSend else { return }
                    self.didSend = true
                    self.connection?.send(content: payload, completion: .contentProcessed { [weak self] error in
                        guard let self, error != nil else { return }
                        self.finish(.failure(.connectionFailed))
                    })
                    self.receive()
                case .failed:
                    self.finish(.failure(.connectionFailed))
                case .cancelled:
                    self.finish(.failure(.cancelled))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [self] in finish(.failure(.cancelled)) }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.didFinish else { return }
            if let data { self.received.append(data) }
            if let newline = self.received.firstIndex(of: 0x0a) {
                let frame = Data(self.received[..<newline])
                let trailing = self.received[self.received.index(after: newline)...]
                guard frame.count <= Self.maximumFrameBytes,
                      trailing.allSatisfy({ [UInt8(0x20), 0x09, 0x0a, 0x0d].contains($0) }),
                      let response = try? JSONDecoder().decode(PeelICloudPairResponse.self, from: frame),
                      response.isValid(for: self.request) else {
                    self.finish(.failure(.invalidResponse))
                    return
                }
                self.finish(.success(response))
                return
            }
            guard self.received.count <= Self.maximumFrameBytes else {
                self.finish(.failure(.invalidResponse))
                return
            }
            if complete || error != nil {
                self.finish(.failure(.connectionFailed))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<PeelICloudPairResponse, PeelICloudEnrollmentTransportError>) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()
        timeoutWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        received = Data()
        let callback = completion
        completion = nil
        if let callback { callbackQueue.async { callback(result) } }
    }
}
