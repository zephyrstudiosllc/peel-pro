import Combine
import Foundation

public nonisolated struct PeelShellTrustPrompt: Identifiable, Sendable {
    public let id: UUID
    public let target: PeelShellTarget
    public let key: SSHHostKey
    public let evaluation: SSHTrustEvaluation
}

private nonisolated struct ControllerVerifier: SSHHostKeyVerifier {
    let decide: @Sendable (SSHHostKey, SSHEndpoint) async -> SSHHostKeyDecision
    func decision(for hostKey: SSHHostKey, endpoint: SSHEndpoint) async -> SSHHostKeyDecision { await decide(hostKey, endpoint) }
}

@MainActor
public final class PeelShellSessionController: ObservableObject {
    public enum State: Equatable { case idle, connecting, verifyingHost, connected, disconnected, failed(String) }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var target: PeelShellTarget?
    @Published public private(set) var sessionID: UUID?
    @Published public private(set) var trustPrompt: PeelShellTrustPrompt?
    @Published public private(set) var acceptedFingerprint: String?
    public private(set) var session: (any SSHShellSessionProtocol)?
    private let client: any SSHClientProtocol
    private let trustStore: any SSHTrustStoreProtocol
    private var generation = UUID()
    private var connection: (any SSHConnectionProtocol)?
    private var connectTask: Task<Void, Never>?
    private var promptDeadline: Task<Void, Never>?
    private var pendingDecision: CheckedContinuation<SSHHostKeyDecision, Never>?

    public init(client: any SSHClientProtocol, trustStore: any SSHTrustStoreProtocol) {
        self.client = client; self.trustStore = trustStore
    }

    /// Always creates a fresh PTY. No saved command, tmux attach or old session input is used.
    public func connect(to selected: PeelShellTarget, authentication: SSHAuthMethod) {
        disconnect()
        guard selected.endpoint.isValid else { state = .failed(SSHClientError.invalidEndpoint.localizedDescription); return }
        let attempt = UUID()
        generation = attempt
        target = selected
        acceptedFingerprint = nil
        state = .connecting
        connectTask = Task { [weak self, client] in
            var candidate: (any SSHConnectionProtocol)?
            do {
                let verifier = ControllerVerifier { [weak self] key, endpoint in
                    guard endpoint == selected.endpoint else { return .reject }
                    return await self?.verify(key: key, target: selected, attempt: attempt) ?? .reject
                }
                let connected = try await client.connect(to: selected.endpoint, authentication: authentication, hostKeyVerifier: verifier)
                candidate = connected
                guard let self, self.isCurrent(attempt) else { await connected.disconnect(); return }
                self.connection = connected // Cancel can close this while authentication/openShell is pending.
                let shell = try await connected.openShell(initialSize: .fallback)
                guard self.isCurrent(attempt) else { await shell.close(); await connected.disconnect(); return }
                self.session = shell
                self.sessionID = UUID()
                self.state = .connected
                self.connectTask = nil
            } catch {
                await candidate?.disconnect()
                guard let self, self.generation == attempt else { return }
                self.finishPrompt(.reject)
                self.connection = nil
                self.session = nil
                self.sessionID = nil
                self.state = .failed(Self.safeMessage(error))
                self.connectTask = nil
            }
        }
    }

    public func disconnect() {
        generation = UUID()
        connectTask?.cancel(); connectTask = nil
        finishPrompt(.reject)
        let oldSession = session
        let oldConnection = connection
        session = nil; sessionID = nil; connection = nil
        acceptedFingerprint = nil
        state = .disconnected
        Task { await oldSession?.close(); await oldConnection?.disconnect() }
    }

    /// A callback from an obsolete view cannot close or update the new shell.
    public func terminalEnded(sessionID endedID: UUID, error: Error?) {
        guard sessionID == endedID else { return }
        disconnect()
        if let error { state = .failed(Self.safeMessage(error)) }
    }

    public func decideHostKey(promptID: UUID, decision: SSHHostKeyDecision) {
        guard trustPrompt?.id == promptID else { return }
        finishPrompt(decision)
    }

    private func isCurrent(_ attempt: UUID) -> Bool { generation == attempt && !Task.isCancelled }

    private func verify(key: SSHHostKey, target: PeelShellTarget, attempt: UUID) async -> SSHHostKeyDecision {
        guard isCurrent(attempt) else { return .reject }
        do {
            let evaluation = try await trustStore.evaluate(target: target, key: key)
            guard isCurrent(attempt) else { return .reject }
            if evaluation == .known { acceptedFingerprint = key.fingerprint; return .trustOnce }
            let promptID = UUID()
            trustPrompt = PeelShellTrustPrompt(id: promptID, target: target, key: key, evaluation: evaluation)
            state = .verifyingHost
            // Bound the suspended trust decision even if the presenting view disappears.
            promptDeadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard self?.trustPrompt?.id == promptID else { return }
                self?.finishPrompt(.reject)
            }
            let decision = await withCheckedContinuation { pendingDecision = $0 }
            guard isCurrent(attempt) else { return .reject }
            if decision == .trust { try await trustStore.record(target: target, key: key) }
            guard isCurrent(attempt) else { return .reject }
            if decision != .reject { acceptedFingerprint = key.fingerprint; state = .connecting }
            return decision
        } catch {
            guard isCurrent(attempt) else { return .reject }
            state = .failed("SSH host trust could not be verified or saved. No connection was authorized.")
            return .reject
        }
    }

    private func finishPrompt(_ decision: SSHHostKeyDecision) {
        promptDeadline?.cancel(); promptDeadline = nil
        let continuation = pendingDecision
        pendingDecision = nil; trustPrompt = nil
        continuation?.resume(returning: decision)
    }

    private static func safeMessage(_ error: Error) -> String {
        if let error = error as? SSHClientError { return error.localizedDescription }
        if error is CancellationError { return SSHClientError.cancelled.localizedDescription }
        return "The SSH connection ended unexpectedly. Reconnect to open a new shell."
    }
}
