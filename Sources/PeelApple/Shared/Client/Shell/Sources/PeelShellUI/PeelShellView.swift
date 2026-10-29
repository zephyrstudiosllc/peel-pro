import SwiftUI
import PeelShellCore
import PeelShellTransport

/// Manual-only entry. The caller supplies the selected machine; the person supplies and verifies SSH access.
/// Tier policy and app entry routing belong to Peel's central policy, not to this reusable view.
@MainActor
public struct PeelShellView: View {
    private let selected: PeelShellTarget
    private let title: String
    private let credentials: any SSHCredentialStoreProtocol
    @StateObject private var controller: PeelShellSessionController
    @Environment(\.scenePhase) private var scenePhase
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var privateKey = ""
    @State private var loadedCredential: SSHBoundCredential?
    @State private var usePrivateKey = false
    @State private var saveCredential = false
    @State private var formError: String?

    public init(target: PeelShellTarget, trustStore: any SSHTrustStoreProtocol,
                credentialStore: any SSHCredentialStoreProtocol = KeychainCredentialStore(), title: String = "Shell") {
        self.selected = target; self.credentials = credentialStore
        self.title = title
        _host = State(initialValue: target.endpoint.host)
        _port = State(initialValue: String(target.endpoint.port))
        _username = State(initialValue: target.endpoint.username)
        _controller = StateObject(wrappedValue: PeelShellSessionController(client: NIOSSHClient(), trustStore: trustStore))
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(selected.displayName, systemImage: "terminal")
                    Spacer()
                    if isBusy { Button("Disconnect") { controller.disconnect() } }
                }
                Text("Machine: \(selected.hostID.uuidString)").font(.caption2).textSelection(.enabled)
                if let target = controller.target, isBusy {
                    Text(target.endpoint.label).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if let fingerprint = controller.acceptedFingerprint {
                    Text(fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                }
                if let requested = selected.requestedWorkingDirectory, !requested.isEmpty {
                    Text("Requested folder (unverified): \(requested)").font(.caption).lineLimit(3)
                }
                Text("Independent shell · current folder is not verified by Peel").font(.caption2).foregroundStyle(.secondary)
            }.padding()
            Divider()
            if let prompt = controller.trustPrompt {
                trustDecision(prompt)
            } else if let session = controller.session, let id = controller.sessionID {
                LiveTerminalView(sessionID: id, session: session) { error in
                    controller.terminalEnded(sessionID: id, error: error)
                }
            } else if isBusy {
                VStack { ProgressView(); Text(statusText) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                connectionForm
            }
        }
        .navigationTitle(title)
        .onDisappear { controller.disconnect(); clearSecrets() }
        .onChange(of: selected) { _, target in
            controller.disconnect()
            clearSecrets()
            host = target.endpoint.host
            port = String(target.endpoint.port)
            username = target.endpoint.username
            formError = nil
        }
        .onChange(of: scenePhase) { _, phase in
            // No implied background continuity. Reconnect always opens a fresh independent shell.
            if phase == .background { controller.disconnect(); clearSecrets() }
        }
    }

    private var connectionForm: some View {
        Form {
            Section("SSH endpoint for this machine") {
                TextField("Host or private-network address", text: Binding(get: { host }, set: { clearSecrets(); host = $0 })).textContentType(.URL)
#if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
#endif
                TextField("Port", text: Binding(get: { port }, set: { clearSecrets(); port = $0 }))
                TextField("Username", text: Binding(get: { username }, set: { clearSecrets(); username = $0 })).textContentType(.username)
#if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
#endif
            }
            Section("Credential") {
                Toggle("Use an unencrypted private key", isOn: Binding(get: { usePrivateKey }, set: { clearSecrets(); usePrivateKey = $0 }))
                if loadedCredential != nil {
                    Text("Saved credential loaded for this exact machine and SSH endpoint.").font(.caption)
                }
                if usePrivateKey {
                    Text("OpenSSH Ed25519 or PEM P-256/P-384/P-521. Encrypted keys are not supported.").font(.caption)
                    TextEditor(text: Binding(get: { privateKey }, set: { loadedCredential = nil; privateKey = $0 })).font(.caption.monospaced()).frame(minHeight: 100)
                        .accessibilityLabel("Private key")
                } else {
                    SecureField("Password", text: Binding(get: { password }, set: { loadedCredential = nil; password = $0 })).textContentType(.password)
                }
                Toggle("Save credential in this device's Keychain", isOn: $saveCredential)
                Button("Load saved credential") { loadCredential() }
                Button("Forget saved credential", role: .destructive) { forgetCredential() }
            }
            if let error = formError { Text(error).foregroundStyle(.red) }
            if case .failed(let reason) = controller.state { Text(reason).foregroundStyle(.red) }
            Button("Open independent shell") { connect() }
        }
    }

    private func trustDecision(_ prompt: PeelShellTrustPrompt) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(prompt.evaluation.isChanged ? "SSH host key changed" : "Verify this SSH host")
                    .font(.headline)
                Text("Confirm that this endpoint belongs to \(prompt.target.displayName) by checking its fingerprint.")
                Text(prompt.target.endpoint.label).font(.body.monospaced()).textSelection(.enabled)
                Text(prompt.key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                if case .changed(let previous) = prompt.evaluation {
                    Text("Previously trusted: \(previous.fingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Continue only after independently verifying why this machine's key changed.").foregroundStyle(.red)
                }
                Button(prompt.evaluation.isChanged ? "Replace association and trust" : "Save association and trust") {
                    controller.decideHostKey(promptID: prompt.id, decision: .trust)
                }.buttonStyle(.borderedProminent)
                Button("Trust for this connection only") { controller.decideHostKey(promptID: prompt.id, decision: .trustOnce) }
                Button("Cancel", role: .cancel) { controller.decideHostKey(promptID: prompt.id, decision: .reject) }
            }.padding()
        }
    }

    private var isBusy: Bool {
        switch controller.state { case .connecting, .verifyingHost, .connected: return true; default: return false }
    }
    private var statusText: String {
        switch controller.state {
        case .idle: return "Ready to open a new SSH connection"
        case .connecting: return "Connecting and requesting an interactive shell…"
        case .verifyingHost: return "Waiting for your fingerprint decision"
        case .connected: return "Connected · interactive PTY accepted"
        case .disconnected: return "Disconnected · reconnect opens a new shell"
        case .failed: return "Connection unavailable"
        }
    }
    private func formTarget() -> PeelShellTarget? {
        guard let number = UInt16(port) else { formError = "Use a port from 1 to 65535."; return nil }
        let endpoint = SSHEndpoint(host: host, port: number, username: username)
        guard endpoint.isValid else { formError = SSHClientError.invalidEndpoint.localizedDescription; return nil }
        return PeelShellTarget(hostID: selected.hostID, displayName: selected.displayName, endpoint: endpoint,
                               requestedWorkingDirectory: selected.requestedWorkingDirectory)
    }
    private func connect() {
        formError = nil
        guard let target = formTarget() else { return }
        let stored: SSHStoredCredential
        if let loadedCredential {
            guard let bound = loadedCredential.credential(for: target) else {
                clearSecrets()
                formError = "The endpoint changed. Enter or load a credential for this machine and endpoint."
                return
            }
            stored = bound
        } else {
            guard (usePrivateKey ? !privateKey.isEmpty : !password.isEmpty) else { formError = "Enter or load a credential."; return }
            stored = usePrivateKey ? .privateKey(pem: privateKey, passphrase: nil) : .password(password)
        }
        if saveCredential {
            do { try credentials.save(stored, for: target.credentialKey) }
            catch { formError = "The credential could not be saved in Keychain. Nothing was connected."; return }
        }
        controller.connect(to: target, authentication: stored.authMethod)
        clearSecrets()
    }
    private func loadCredential() {
        clearSecrets()
        formError = nil
        guard let target = formTarget() else { return }
        do {
            guard let saved = try credentials.load(for: target.credentialKey) else { formError = "No saved credential for this exact machine and endpoint."; return }
            switch saved {
            case .password: usePrivateKey = false
            case .privateKey(_, let passphrase):
                guard passphrase == nil else { formError = "Encrypted private keys are not supported."; return }
                usePrivateKey = true
            }
            loadedCredential = SSHBoundCredential(saved, for: target)
        } catch { formError = "The saved credential could not be read." }
    }
    private func forgetCredential() {
        guard let target = formTarget() else { return }
        do { try credentials.delete(for: target.credentialKey); clearSecrets(); formError = nil }
        catch { formError = "The saved credential could not be removed." }
    }
    private func clearSecrets() { password = ""; privateKey = ""; loadedCredential = nil }
}

private extension SSHTrustEvaluation {
    var isChanged: Bool { if case .changed = self { return true }; return false }
}
