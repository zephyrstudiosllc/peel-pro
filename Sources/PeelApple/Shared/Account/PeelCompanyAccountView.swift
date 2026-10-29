import SwiftUI
import AuthenticationServices
#if os(iOS) || os(visionOS)
import UIKit
#endif

@MainActor
struct PeelCompanyAccountView: View {
    @ObservedObject private var local: PeelAccountController
    @ObservedObject private var company: PeelCompanyAccountController
    @State private var saveEmail = false
    @State private var showsEmailChoice = false
    @State private var confirmsDeletion = false
    @State private var confirmsNewAccount = false
    @State private var confirmsRepeatDeletion = false

    init(local: PeelAccountController) { self.local = local; self.company = local.company }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional Peel Pro account").font(.headline)
            if company.isConfigured {
                if let profile = company.account, company.deletion == nil {
                    Label("Company account verified", systemImage: "checkmark.shield")
                    if let email = profile.email {
                        Text(email).font(.caption).textSelection(.enabled)
                        Text("Email saved with Zephyr Studios.").font(.caption2).foregroundStyle(.secondary)
                        Button("Remove my saved company email", role: .destructive) {
                            Task { await company.withdrawEmail() }
                        }.disabled(company.isBusy)
                    } else {
                        Text("Zephyr Studios has not saved your email.").font(.caption).foregroundStyle(.secondary)
                        Button("Choose whether to save my Apple email") { saveEmail = false; showsEmailChoice = true }
                            .disabled(company.isBusy)
                    }
                    Button("Refresh company account") { Task { await company.refreshSession() } }.disabled(company.isBusy)
                }
                if company.deletion == nil && (company.account == nil || showsEmailChoice) { signInForm }
                deletionSection
                if local.profile == nil && company.hasSession { Button("Sign Out on This Device") { local.signOut() } }
                if let privacy = company.configuration?.privacyURL { Link("Privacy and account deletion policy", destination: privacy) }
            } else {
                Text("Company accounts are not available in this build yet. Your Apple profile and private iCloud sync are separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(company.status).font(.caption).foregroundStyle(.secondary)
            if let warning = company.storageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if company.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("Cancel account request") { company.cancelAuthorization() }
                }
            }
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Save my Apple-provided email with Zephyr Studios", isOn: $saveEmail)
                .disabled(company.isBusy || company.storageRecoveryRequired)
            Text("Apple may provide your real email or a private relay address in the identity token we process to verify sign-in. We save your email only if you choose. Apple's sheet controls Share My Email and Hide My Email.")
                .font(.caption).foregroundStyle(.secondary)
#if os(iOS) || os(visionOS)
            PeelCompanyNativeAppleButton(type: .signIn, enabled: !company.isBusy && !company.storageRecoveryRequired) { window in
                let consent = saveEmail
                Task {
                    await local.signInToCompany(using: PeelCompanyNativeAuthorizer(anchor: window), collectEmail: consent)
                    saveEmail = false; showsEmailChoice = false
                }
            }.frame(maxWidth: 320).frame(height: 44)
#endif
        }
    }

    private var deletionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let outcome = company.deletion {
                switch outcome {
                case .complete:
                    Text("Company account deleted. Known Apple authorizations were revoked.")
                case .pending:
                    Text("Company account deleted. Apple authorization revocation is pending.")
                case .manualRevocation:
                    Text("Company deletion confirmed. Apple authorization needs manual revocation.")
                case .unconfirmed:
                    Text("Company deletion is not confirmed. A fresh Apple authorization can request deletion again.")
                }
                if outcome == .pending || outcome == .manualRevocation {
                    Link("Apple's manual revocation instructions", destination: URL(string: "https://support.apple.com/102571")!)
                    Button("Confirm deletion again with Apple", role: .destructive) { confirmsRepeatDeletion = true }
                        .disabled(company.isBusy || company.storageRecoveryRequired)
                }
                if outcome != .unconfirmed {
                    Button("Create a new optional company account") { confirmsNewAccount = true }
                        .disabled(company.isBusy || company.storageRecoveryRequired)
                }
            }
            if (company.deletion == nil || company.deletion == .unconfirmed),
               company.authorizationUserID != nil || local.profile != nil {
                Button("Delete company account", role: .destructive) { confirmsDeletion = true }
                    .disabled(company.isBusy || company.storageRecoveryRequired)
            }
            if company.needsFreshDeletionProof {
                    Text("Continue with Apple to request deletion again for the original account. This can delete a company profile recreated on another device. It does not sign in or create an account.")
                        .font(.caption).foregroundStyle(.secondary)
#if os(iOS) || os(visionOS)
                    PeelCompanyNativeAppleButton(type: .continue, enabled: !company.isBusy && !company.storageRecoveryRequired) { window in
                        Task { await company.deleteWithApple(using: PeelCompanyNativeAuthorizer(anchor: window), expectedUserID: local.profile?.userID) }
                    }.frame(maxWidth: 320).frame(height: 44)
#endif
            }
            if company.account != nil || company.deletion != nil || local.profile != nil {
                Text("Company deletion does not unpair devices or erase private iCloud metadata. The separate Remove This Device from iCloud control stops updates and hides this device; some private iCloud data may remain. Deleting the company account does not cancel App Store subscriptions.")
                    .font(.caption2).foregroundStyle(.secondary)
                Link("Manage App Store subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
        }
        .alert("Delete company account?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete company account", role: .destructive) { Task { await company.deleteRecentSession() } }
        } message: {
            Text("Delete your company account and saved email, and request Apple authorization revocation. Pairings and private iCloud metadata remain separate. App Store subscriptions are not canceled; deletion can proceed immediately.")
        }
        .alert("Create a new optional account?", isPresented: $confirmsNewAccount) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                company.allowNewAccountAfterConfirmedDeletion()
                saveEmail = false; showsEmailChoice = true
            }
        } message: {
            Text("Your previous company deletion was confirmed. This starts a separate, fresh Apple sign-in only if you choose. If Apple revocation is still pending, the service may require it to finish first. This does not check deletion status or restore an old session.")
        }
        .alert("Confirm deletion again?", isPresented: $confirmsRepeatDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Continue with Apple", role: .destructive) { company.requestDeletionVerification() }
        } message: {
            Text("A fresh Apple authorization will request deletion again for the original Apple account. This can delete a company profile recreated on another device. It does not sign in or create an account.")
        }
    }
}

#if os(iOS) || os(visionOS)
@MainActor
struct PeelCompanyNativeAppleButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let type: ASAuthorizationAppleIDButton.ButtonType
    let enabled: Bool
    let action: (UIWindow) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: type, style: colorScheme == .dark ? .white : .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate(_:)), for: .touchUpInside)
        button.isEnabled = enabled
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action; button.isEnabled = enabled
    }
    @MainActor final class Coordinator: NSObject {
        var action: (UIWindow) -> Void
        init(action: @escaping (UIWindow) -> Void) { self.action = action }
        @objc func activate(_ button: ASAuthorizationAppleIDButton) {
            guard let window = button.window else { return }
            action(window)
        }
    }
}

@MainActor
final class PeelCompanyNativeAuthorizer: NSObject, PeelCompanyAppleAuthorizing,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<PeelCompanyAppleAuthorization, any Error>?
    private var requestsEmail = false
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func authorize(nonce: String, state: String, requestEmail: Bool) async throws -> PeelCompanyAppleAuthorization {
        guard controller == nil else { throw PeelCompanyAccountError.invalidAuthorization }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: PeelCompanyAccountError.cancelled); return }
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = requestEmail ? [.email] : []
                request.nonce = nonce // Exact backend apple_nonce; never hash it again.
                request.state = state
                requestsEmail = requestEmail
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self; controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() {
        controller?.cancel()
        finish(.failure(PeelCompanyAccountError.cancelled))
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken, tokenData.count <= 16_384,
              let token = String(data: tokenData, encoding: .utf8) else {
            finish(.failure(PeelCompanyAccountError.invalidAuthorization)); return
        }
        let code: String?
        if requestsEmail, let data = credential.authorizationCode, data.count <= 4096 {
            code = String(data: data, encoding: .utf8)
        } else { code = nil }
        finish(.success(PeelCompanyAppleAuthorization(userID: credential.user, state: credential.state,
            identityToken: token, authorizationCode: code, localEmail: requestsEmail ? credential.email : nil)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        guard self.controller === controller else { return }
        finish(.failure((error as? ASAuthorizationError)?.code == .canceled
            ? PeelCompanyAccountError.cancelled : .invalidAuthorization))
    }
    private func finish(_ result: Result<PeelCompanyAppleAuthorization, any Error>) {
        let continuation = continuation; self.continuation = nil; controller = nil
        continuation?.resume(with: result)
    }
}
#endif
