// Adapted from OrcheSSHtra (Conductor) 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
// See ORIGIN.md. Shell access is independent of Peel's streaming transport.
import CryptoKit
import Foundation

public nonisolated struct SSHEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public init(host: String, port: UInt16 = 22, username: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username
    }
    public var isValid: Bool {
        !host.isEmpty && host.utf8.count <= 253 && port > 0 &&
        !username.isEmpty && username.utf8.count <= 128 &&
        !host.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) } &&
        !username.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public var label: String { "\(username)@\(host):\(port)" }
}

public nonisolated enum SSHAuthMethod: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
    public var description: String {
        switch self {
        case .password: return "password(<redacted>)"
        case .privateKey: return "privateKey(<redacted>)"
        }
    }
    public var debugDescription: String { description }
}

public nonisolated struct SSHHostKey: Codable, Equatable, Sendable {
    public let keyType: String
    public let keyBlob: Data
    public init(keyType: String, keyBlob: Data) { self.keyType = keyType; self.keyBlob = keyBlob }
    public var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: keyBlob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

public nonisolated struct SSHTerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int, rows: Int) {
        self.columns = max(1, min(1_000, columns))
        self.rows = max(1, min(1_000, rows))
    }
    public static let fallback = Self(columns: 80, rows: 24)
}

/// The owner supplies the selected Peel machine ID; the user explicitly verifies its SSH association.
/// A display name never selects an endpoint or grants trust.
public nonisolated struct PeelShellTarget: Equatable, Sendable, Identifiable {
    public let hostID: UUID
    public let displayName: String
    public let endpoint: SSHEndpoint
    public let requestedWorkingDirectory: String?
    public var id: String { hostID.uuidString + ":" + endpoint.label }
    public init(hostID: UUID, displayName: String, endpoint: SSHEndpoint, requestedWorkingDirectory: String? = nil) {
        self.hostID = hostID
        self.displayName = String(displayName.prefix(120))
        self.endpoint = endpoint
        self.requestedWorkingDirectory = requestedWorkingDirectory.map { String($0.prefix(4_096)) }
    }
    /// A credential for one machine/profile must never be reused by a similarly named endpoint.
    public var credentialKey: String {
        let fields = [hostID.uuidString, endpoint.host, String(endpoint.port), endpoint.username]
        let bytes = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return Data(SHA256.hash(data: Data(bytes.utf8))).base64EncodedString()
    }
}

public nonisolated enum SSHClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case hostKeyRejected(fingerprint: String)
    case authenticationFailed
    case privateKeyUnsupported(reason: String)
    case channelFailure(reason: String)
    case timedOut
    case outputLimitExceeded
    case inputLimitExceeded
    case requestRejected
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter a valid SSH endpoint and username."
        case .hostKeyRejected: return "The SSH host key was not accepted."
        case .authenticationFailed: return "SSH authentication failed."
        case .privateKeyUnsupported(let reason): return reason
        case .channelFailure: return "The SSH connection failed. Reconnect to open a new shell."
        case .timedOut: return "The SSH request timed out."
        case .outputLimitExceeded: return "The shell produced more output than the terminal could receive. The connection was closed."
        case .inputLimitExceeded: return "The input exceeded the shell's bounded input buffer. The connection was closed."
        case .requestRejected: return "The server refused an interactive PTY or shell."
        case .cancelled: return "The shell connection was cancelled."
        }
    }
}

public nonisolated enum SSHHostKeyDecision: Equatable, Sendable { case trust, trustOnce, reject }
public nonisolated protocol SSHHostKeyVerifier: Sendable {
    func decision(for hostKey: SSHHostKey, endpoint: SSHEndpoint) async -> SSHHostKeyDecision
}
public nonisolated protocol SSHShellSessionProtocol: Sendable {
    var output: AsyncThrowingStream<Data, Error> { get }
    func send(_ input: Data) async throws
    func resize(to size: SSHTerminalSize) async throws
    func close() async
}
public nonisolated protocol SSHConnectionProtocol: Sendable {
    func openShell(initialSize: SSHTerminalSize) async throws -> any SSHShellSessionProtocol
    func disconnect() async
}
public nonisolated protocol SSHClientProtocol: Sendable {
    func connect(to endpoint: SSHEndpoint, authentication: SSHAuthMethod,
                 hostKeyVerifier: any SSHHostKeyVerifier) async throws -> any SSHConnectionProtocol
}
