import Foundation
import Testing
@testable import PeelShellCore

private actor MemoryTrust: SSHTrustStoreProtocol {
    var saved: [String: SSHHostKey] = [:]
    func evaluate(target: PeelShellTarget, key: SSHHostKey) -> SSHTrustEvaluation {
        guard let prior = saved[target.credentialKey] else { return .unknown }
        return prior == key ? .known : .changed(previous: prior)
    }
    func record(target: PeelShellTarget, key: SSHHostKey) { saved[target.credentialKey] = key }
}
private actor MockShell: SSHShellSessionProtocol {
    nonisolated let output = AsyncThrowingStream<Data, Error> { _ in }
    var closes = 0
    func send(_ input: Data) {}
    func resize(to size: SSHTerminalSize) {}
    func close() { closes += 1 }
}
private actor MockConnection: SSHConnectionProtocol {
    let shell = MockShell()
    let delay: UInt64
    var closes = 0
    init(delay: UInt64 = 0) { self.delay = delay }
    func openShell(initialSize: SSHTerminalSize) async -> any SSHShellSessionProtocol {
        // Deliberately ignores cancellation: tests prove the controller closes late completions.
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return shell
    }
    func disconnect() { closes += 1 }
}
private actor VerifyingClient: SSHClientProtocol {
    let connection = MockConnection()
    let key = SSHHostKey(keyType: "ssh-ed25519", keyBlob: Data("synthetic-key".utf8))
    func connect(to endpoint: SSHEndpoint, authentication: SSHAuthMethod,
                 hostKeyVerifier: any SSHHostKeyVerifier) async throws -> any SSHConnectionProtocol {
        guard await hostKeyVerifier.decision(for: key, endpoint: endpoint) != .reject else {
            throw SSHClientError.hostKeyRejected(fingerprint: key.fingerprint)
        }
        return connection
    }
}
private actor CrossedClient: SSHClientProtocol {
    let slow = MockConnection()
    let fast = MockConnection()
    func connect(to endpoint: SSHEndpoint, authentication: SSHAuthMethod,
                 hostKeyVerifier: any SSHHostKeyVerifier) async -> any SSHConnectionProtocol {
        if endpoint.host == "slow.test" {
            // A continuation simulates a transport that returns even after its caller was cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
            return slow
        }
        return fast
    }
}
private struct OneConnectionClient: SSHClientProtocol {
    let connection: MockConnection
    func connect(to endpoint: SSHEndpoint, authentication: SSHAuthMethod,
                 hostKeyVerifier: any SSHHostKeyVerifier) async -> any SSHConnectionProtocol { connection }
}

private func target(_ host: String = "machine.test", id: UUID = UUID()) -> PeelShellTarget {
    PeelShellTarget(hostID: id, displayName: "Same name", endpoint: SSHEndpoint(host: host, username: "tester"))
}
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

struct CoreTests {
    @Test func credentialsAndTrustIncludeMachineAndEndpoint() {
        let id = UUID()
        let a = target(id: id)
        #expect(a.credentialKey == target(id: id).credentialKey)
        #expect(a.credentialKey != target().credentialKey)
        #expect(a.credentialKey != target("different.test", id: id).credentialKey)
        let changedName = PeelShellTarget(hostID: id, displayName: "Renamed", endpoint: a.endpoint)
        #expect(a.credentialKey == changedName.credentialKey)
        #expect(!String(describing: SSHAuthMethod.password("hidden-fixture")).contains("hidden-fixture"))
    }
    @Test func inputBoundsAndEndpointValidation() {
        #expect(!SSHEndpoint(host: "bad\nhost", username: "user").isValid)
        #expect(!SSHEndpoint(host: "host", port: 0, username: "user").isValid)
        #expect(!SSHEndpoint(host: "host", username: "user\u{0}").isValid)
        #expect(SSHTerminalSize(columns: Int.max, rows: -1) == SSHTerminalSize(columns: 1_000, rows: 1))
    }
    @Test func persistedTrustNeverTransfersToAnotherMachine() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("trust.json")
        let store = try FileSSHTrustStore(fileURL: file)
        let machine = target()
        let key = SSHHostKey(keyType: "ssh-ed25519", keyBlob: Data([1, 2, 3]))
        #expect(await store.evaluate(target: machine, key: key) == .unknown)
        try await store.record(target: machine, key: key)
        let reloaded = try FileSSHTrustStore(fileURL: file)
        #expect(await reloaded.evaluate(target: machine, key: key) == .known)
        #expect(await reloaded.evaluate(target: target(), key: key) == .unknown)
        #expect(await reloaded.evaluate(target: machine, key: SSHHostKey(keyType: "ssh-ed25519", keyBlob: Data([4]))) == .changed(previous: key))
    }
    @Test func corruptTrustIsAnErrorRatherThanFirstUse() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("broken".utf8).write(to: file)
        #expect(throws: SSHTrustStoreError.self) { try FileSSHTrustStore(fileURL: file) }
    }
    @Test func failedTrustWriteDoesNotBecomeTrusted() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/trust.json")
        let store = try FileSSHTrustStore(fileURL: missing)
        let machine = target()
        let key = SSHHostKey(keyType: "ssh-ed25519", keyBlob: Data([1]))
        do { try await store.record(target: machine, key: key); Issue.record("Expected failed write") } catch {}
        #expect(await store.evaluate(target: machine, key: key) == .unknown)
    }
    @Test @MainActor func unknownKeyWaitsForExplicitDecisionAndCancelRejects() async {
        let client = VerifyingClient()
        let controller = PeelShellSessionController(client: client, trustStore: MemoryTrust())
        controller.connect(to: target(), authentication: .password("fixture"))
        #expect(await eventually { controller.trustPrompt != nil })
        #expect(controller.state == .verifyingHost)
        #expect(controller.session == nil)
        controller.disconnect()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(controller.state == .disconnected)
        #expect(controller.trustPrompt == nil)
        #expect(controller.session == nil)
    }
    @Test @MainActor func knownKeySkipsPromptButChangedKeyDoesNot() async throws {
        let client = VerifyingClient()
        let store = MemoryTrust()
        let machine = target()
        await store.record(target: machine, key: client.key)
        let controller = PeelShellSessionController(client: client, trustStore: store)
        controller.connect(to: machine, authentication: .password("fixture"))
        #expect(await eventually { controller.state == .connected })
        #expect(controller.trustPrompt == nil)
        controller.disconnect()
        await store.record(target: machine, key: SSHHostKey(keyType: "ssh-ed25519", keyBlob: Data([9])))
        controller.connect(to: machine, authentication: .password("fixture"))
        #expect(await eventually { controller.trustPrompt != nil })
        if case .changed = controller.trustPrompt?.evaluation {} else { Issue.record("Changed-key prompt missing") }
        controller.disconnect()
    }
    @Test @MainActor func obsoletePromptCannotAuthorizeNewAttempt() async {
        let controller = PeelShellSessionController(client: VerifyingClient(), trustStore: MemoryTrust())
        controller.connect(to: target(), authentication: .password("fixture"))
        #expect(await eventually { controller.trustPrompt != nil })
        let oldID = controller.trustPrompt!.id
        controller.connect(to: target("second.test"), authentication: .password("fixture"))
        #expect(await eventually { controller.trustPrompt != nil })
        controller.decideHostKey(promptID: oldID, decision: .trust)
        #expect(controller.state == .verifyingHost)
        #expect(controller.session == nil)
        controller.disconnect()
    }
    @Test @MainActor func lateConnectCannotReplaceNewMachine() async {
        let client = CrossedClient()
        let controller = PeelShellSessionController(client: client, trustStore: MemoryTrust())
        controller.connect(to: target("slow.test"), authentication: .password("fixture"))
        try? await Task.sleep(nanoseconds: 5_000_000)
        let second = target("fast.test")
        controller.connect(to: second, authentication: .password("fixture"))
        #expect(await eventually { controller.state == .connected })
        let id = controller.sessionID
        try? await Task.sleep(nanoseconds: 70_000_000)
        #expect(controller.target == second)
        #expect(controller.sessionID == id)
        #expect(await client.slow.closes > 0)
        controller.terminalEnded(sessionID: UUID(), error: SSHClientError.cancelled)
        #expect(controller.state == .connected)
        controller.disconnect()
    }
    @Test @MainActor func disconnectWhileOpeningShellClosesLateResult() async {
        let connection = MockConnection(delay: 50_000_000)
        let controller = PeelShellSessionController(client: OneConnectionClient(connection: connection), trustStore: MemoryTrust())
        controller.connect(to: target(), authentication: .password("fixture"))
        try? await Task.sleep(nanoseconds: 5_000_000)
        controller.disconnect()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(controller.state == .disconnected)
        #expect(controller.sessionID == nil)
        #expect(await connection.closes > 0)
        #expect(await connection.shell.closes > 0)
    }
}

@Test func loadedCredentialCannotFollowEndpointOrMachineEdits() {
    let id = UUID()
    let original = PeelShellTarget(hostID: id, displayName: "Original", endpoint: SSHEndpoint(host: "one.test", port: 22, username: "alice"))
    let secret = SSHStoredCredential.password("synthetic-only")
    let loaded = SSHBoundCredential(secret, for: original)
    #expect(loaded.credential(for: original) == secret)
    let renamed = PeelShellTarget(hostID: id, displayName: "Renamed", endpoint: original.endpoint)
    #expect(loaded.credential(for: renamed) == secret)
    let changed = [
        PeelShellTarget(hostID: UUID(), displayName: original.displayName, endpoint: original.endpoint),
        PeelShellTarget(hostID: id, displayName: original.displayName, endpoint: SSHEndpoint(host: "two.test", username: "alice")),
        PeelShellTarget(hostID: id, displayName: original.displayName, endpoint: SSHEndpoint(host: "one.test", port: 2222, username: "alice")),
        PeelShellTarget(hostID: id, displayName: original.displayName, endpoint: SSHEndpoint(host: "one.test", username: "bob"))
    ]
    for target in changed { #expect(loaded.credential(for: target) == nil) }
    #expect(!String(describing: loaded).contains("synthetic-only"))
}
