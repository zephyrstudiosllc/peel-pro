// Derived from Conductor KnownHostsStore; adds machine binding and explicit persistence failures.
import Foundation

public nonisolated enum SSHTrustEvaluation: Equatable, Sendable {
    case unknown
    case known
    case changed(previous: SSHHostKey)
}
public nonisolated protocol SSHTrustStoreProtocol: Sendable {
    func evaluate(target: PeelShellTarget, key: SSHHostKey) async throws -> SSHTrustEvaluation
    func record(target: PeelShellTarget, key: SSHHostKey) async throws
}
public nonisolated enum SSHTrustStoreError: Error, LocalizedError {
    case corrupt, tooManyEntries
    public var errorDescription: String? {
        switch self {
        case .corrupt: return "The SSH trust store could not be read. Repair it before connecting."
        case .tooManyEntries: return "The SSH trust store is full. Remove an unused association before saving another."
        }
    }
}

public actor FileSSHTrustStore: SSHTrustStoreProtocol {
    @MainActor private static var sharedDefaultStore: FileSSHTrustStore?
    private struct Entry: Codable {
        let hostID: UUID
        let endpoint: SSHEndpoint
        let key: SSHHostKey
    }
    private let fileURL: URL
    private var entries: [Entry]
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL), data.count <= 1_048_576,
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data), decoded.count <= 128,
                  decoded.allSatisfy({ $0.endpoint.isValid && !$0.key.keyBlob.isEmpty && $0.key.keyBlob.count <= 16_384 }) else {
                throw SSHTrustStoreError.corrupt
            }
            entries = decoded
        } else { entries = [] }
    }
    /// All app scenes share one actor so concurrent previews cannot overwrite or use stale trust entries.
    @MainActor public static func defaultStore() throws -> FileSSHTrustStore {
        if let store = sharedDefaultStore { return store }
        let directory = URL.applicationSupportDirectory.appending(path: "Peel/ManualShell", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try FileSSHTrustStore(fileURL: directory.appending(path: "host-trust-v1.json"))
        sharedDefaultStore = store
        return store
    }
    public func evaluate(target: PeelShellTarget, key: SSHHostKey) -> SSHTrustEvaluation {
        guard let record = entries.first(where: { $0.hostID == target.hostID && $0.endpoint == target.endpoint }) else { return .unknown }
        return record.key == key ? .known : .changed(previous: record.key)
    }
    public func record(target: PeelShellTarget, key: SSHHostKey) throws {
        guard target.endpoint.isValid, !key.keyBlob.isEmpty, key.keyBlob.count <= 16_384 else { throw SSHTrustStoreError.corrupt }
        var next = entries.filter { !($0.hostID == target.hostID && $0.endpoint == target.endpoint) }
        guard next.count < 128 else { throw SSHTrustStoreError.tooManyEntries }
        next.append(Entry(hostID: target.hostID, endpoint: target.endpoint, key: key))
        let data = try JSONEncoder().encode(next)
        try data.write(to: fileURL, options: .atomic)
        entries = next // Never claim persistence when the write failed.
    }
}
