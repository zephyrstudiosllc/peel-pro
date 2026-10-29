import Foundation
import Combine
import Security
import LocalAuthentication

@MainActor
final class PeelSecureCompanySessionStorage: PeelCompanySessionStorage {
    private let service = (Bundle.main.bundleIdentifier ?? "local.peel") + ".company-account-session.v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "companySession", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> PeelCompanySession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data, data.count <= 16_384,
              let value = try? JSONDecoder().decode(PeelCompanySession.self, from: data)
        else { throw PeelCompanyAccountError.secureStorage }
        return value
    }
    func save(_ session: PeelCompanySession) throws {
        let data = try JSONEncoder().encode(session)
        guard data.count <= 16_384 else { throw PeelCompanyAccountError.secureStorage }
        var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw PeelCompanyAccountError.secureStorage }
    }
    func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw PeelCompanyAccountError.secureStorage }
    }
    func loadDeletionIntent() throws -> PeelCompanyDeletionIntent? {
        var request = query; request[kSecAttrAccount as String] = "companyDeletionIntent"
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data, data.count <= 16_384,
              let intent = try? JSONDecoder().decode(PeelCompanyDeletionIntent.self, from: data)
        else { throw PeelCompanyAccountError.secureStorage }
        return intent
    }
    func saveDeletionIntent(_ intent: PeelCompanyDeletionIntent) throws {
        let data = try JSONEncoder().encode(intent)
        guard data.count <= 16_384 else { throw PeelCompanyAccountError.secureStorage }
        var key = query; key[kSecAttrAccount as String] = "companyDeletionIntent"
        var result = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            key[kSecValueData as String] = data
            key[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(key as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw PeelCompanyAccountError.secureStorage }
    }
    func removeDeletionIntent() throws {
        var key = query; key[kSecAttrAccount as String] = "companyDeletionIntent"
        let result = SecItemDelete(key as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw PeelCompanyAccountError.secureStorage }
    }
}

@MainActor
final class PeelCompanyAccountController: ObservableObject {
    @Published private(set) var account: PeelCompanyAccountProfile?
    @Published private(set) var status = "A company account is optional."
    @Published private(set) var isBusy = false
    @Published private(set) var deletion: PeelCompanyDeletionOutcome?
    @Published private(set) var needsFreshDeletionProof = false
    @Published private(set) var storageWarning: String?
    @Published private(set) var storageRecoveryRequired = false
    private(set) var sessionID: UUID?
    var onDeletionConfirmed: (() -> Void)?
    let configuration: PeelCompanyAccountConfiguration?
    var isConfigured: Bool { api != nil }
    var authorizationUserID: String? { session?.appleUserID ?? deletionIntent?.appleUserID ?? lastKnownAppleUserID }
    var hasSession: Bool { session != nil }

    private let api: (any PeelCompanyAccountAPI)?
    private let storage: any PeelCompanySessionStorage
    private let fence: any PeelCompanySessionFencing
    private let now: () -> Date
    private let randomState: () throws -> String
    private var session: PeelCompanySession?
    private var lastKnownAppleUserID: String?
    private var deletionIntent: PeelCompanyDeletionIntent?
    private var generation = 0
    private var operationID: UUID?
    private var authorizer: (any PeelCompanyAppleAuthorizing)?
    private var started = false
    private var foreground = true
    private var lifecycleTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var lastCheckedAt: Date?

    init(api: (any PeelCompanyAccountAPI)? = nil, storage: (any PeelCompanySessionStorage)? = nil,
         fence: (any PeelCompanySessionFencing)? = nil,
         configuration bundle: Bundle = .main, now: @escaping () -> Date = Date.init,
         randomState: (() throws -> String)? = nil) {
        let configuration = api?.configuration ?? PeelCompanyAccountConfiguration(bundle: bundle)
        self.configuration = configuration
        self.api = api ?? configuration.map { PeelCompanyHTTPSAccountAPI(configuration: $0) }
        self.storage = storage ?? PeelSecureCompanySessionStorage()
        self.fence = fence ?? (storage == nil ? PeelCompanyDefaultsSessionFence() : PeelCompanyMemorySessionFence())
        self.now = now
        self.randomState = randomState ?? {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PeelCompanyAccountError.invalidAuthorization }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        // Disabled builds do not load or mutate a real company Keychain item.
        guard let configuration else { status = PeelCompanyAccountError.notConfigured.localizedDescription; return }
        do {
            if let intent = try self.storage.loadDeletionIntent() {
                guard intent.isValid(at: now(), origin: configuration.origin) else { throw PeelCompanyAccountError.secureStorage }
                deletionIntent = intent; deletion = intent.result; lastKnownAppleUserID = intent.appleUserID
                needsFreshDeletionProof = intent.result == .unconfirmed
                status = "A company deletion receipt is saved on this device."
                if intent.result != .unconfirmed {
                    self.fence.discard()
                    do { try self.storage.remove() }
                    catch { storageWarning = "Secure erasure could not finish. This device will not reuse the discarded company session." }
                    return
                }
            }
        } catch {
            storageWarning = "The company deletion receipt could not be read securely. Unlock this device and reopen Peel Pro."
            storageRecoveryRequired = true
            return
        }
        guard !self.fence.isDiscarded else {
            status = "This device's company session was discarded. Sign in again only if you choose."
            do { try self.storage.remove() }
            catch { storageWarning = "Secure erasure could not finish. This device will not reuse the discarded company session." }
            return
        }
        do {
            if let stored = try self.storage.load() {
                lastKnownAppleUserID = stored.appleUserID
                if stored.isValid(at: now(), origin: configuration.origin) {
                    session = stored; account = stored.profile; sessionID = UUID()
                    status = deletion == .unconfirmed ? "Company deletion is not confirmed. Verify it with Apple." : "Company session saved on this device."
                } else { self.fence.discard(); try self.storage.remove(); status = PeelCompanyAccountError.unauthorized.localizedDescription }
            }
        } catch { storageRecoveryRequired = true; status = PeelCompanyAccountError.secureStorage.localizedDescription }
    }

    isolated deinit { lifecycleTask?.cancel(); refreshTask?.cancel() }

    func startLifecycle(isForeground: Bool) {
        guard !started else { return }
        started = true; foreground = isForeground
        reconcileLifecycle()
    }
    func setForeground(_ active: Bool) {
        guard started, foreground != active else { return }
        foreground = active
        if !active { invalidateOperation() }
        reconcileLifecycle()
    }
    func stopLifecycle() {
        started = false; foreground = false
        invalidateOperation()
        lifecycleTask?.cancel(); lifecycleTask = nil
    }
    private func reconcileLifecycle() {
        guard started, foreground, session != nil else { lifecycleTask?.cancel(); lifecycleTask = nil; return }
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.expireSessionIfNeeded()
                if self?.session == nil { return }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
    func requestSessionRefresh() {
        expireSessionIfNeeded()
        guard session != nil, (!started || foreground), refreshTask == nil,
              lastCheckedAt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        let id = UUID(); refreshID = id
        refreshTask = Task { @MainActor [weak self] in
            await self?.refreshSession()
            guard let self, self.refreshID == id else { return }
            self.refreshTask = nil; self.refreshID = nil
        }
    }
    func isCurrentSession(_ id: UUID) -> Bool {
        sessionID == id && session != nil && (!started || foreground)
    }

    private func begin() -> (UUID, Int)? {
        guard !isBusy, !storageRecoveryRequired, api != nil, !started || foreground else { return nil }
        generation += 1
        let id = UUID(); operationID = id; isBusy = true
        return (id, generation)
    }
    private func current(_ id: UUID, _ expected: Int) -> Bool {
        operationID == id && generation == expected && !Task.isCancelled && (!started || foreground)
    }
    private func end(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; authorizer = nil; isBusy = false
    }
    func cancelAuthorization() {
        invalidateOperation()
        status = PeelCompanyAccountError.cancelled.localizedDescription
    }
    func cancelPendingOperations() { invalidateOperation() }

    func discardSessionIfCurrent(_ id: UUID) {
        guard sessionID == id else { return }
        signOut()
        status = "Company sign-in did not finish on this device. A company account may have been created; use account deletion if needed."
    }

    func requestDeletionVerification() {
        guard deletion != nil, authorizationUserID != nil else { return }
        needsFreshDeletionProof = true
    }

    /// An explicit new enrollment is distinct from checking an old deletion.
    /// A server-confirmed deletion receipt must be durably removed first.
    func allowNewAccountAfterConfirmedDeletion() {
        guard let deletion, deletion != .unconfirmed, !storageRecoveryRequired, !isBusy else { return }
        do { try storage.removeDeletionIntent() }
        catch { storageWarning = "The deletion receipt could not be removed. New account enrollment has not started."; return }
        deletionIntent = nil; self.deletion = nil; needsFreshDeletionProof = false
        lastKnownAppleUserID = nil
        status = "Choose a fresh Apple sign-in only if you want a new optional company account."
    }
    private func invalidateOperation() {
        generation += 1; operationID = nil; isBusy = false
        authorizer?.cancel(); authorizer = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshID = nil
    }
    private func expireSessionIfNeeded() {
        guard let session, let configuration else { return }
        guard session.isValid(at: now(), origin: configuration.origin) else {
            clearSession(); status = PeelCompanyAccountError.unauthorized.localizedDescription; return
        }
    }
    private func clearSession() {
        if let session { lastKnownAppleUserID = session.appleUserID }
        session = nil; account = nil; sessionID = nil
        lifecycleTask?.cancel(); lifecycleTask = nil
        guard isConfigured else { return }
        fence.discard()
        do { try storage.remove(); storageWarning = nil }
        catch { storageWarning = "Secure erasure could not finish. This device will not reuse the discarded company session." }
    }
    private func describe(_ error: any Error) -> String {
        (error as? PeelCompanyAccountError ?? .unavailable).localizedDescription
    }
    private func discardServerSession(_ bearer: String) {
        guard let api, PeelCompanyValidation.bearer(bearer) else { return }
        Task { @MainActor in try? await api.signOut(bearer: bearer) }
    }

    func signOut() {
        let bearer = session?.bearer
        invalidateOperation()
        clearSession()
        lastKnownAppleUserID = nil
        lastCheckedAt = nil
        if deletion == nil { status = "Signed out of the company account on this device." }
        if let bearer { discardServerSession(bearer) }
    }

    /// Called from a user gesture. The native authorizer obtains Apple's sheet
    /// only after the one-use server challenge is ready, with its exact nonce.
    func signIn(using authorizer: any PeelCompanyAppleAuthorizing, collectEmail: Bool,
                expectedUserID: String?) async -> PeelCompanyLocalIdentity? {
        guard deletion == nil, let api, let (id, expected) = begin() else { return nil }
        let expectedAccount = session?.profile.account_id
        let intendedUser = session?.appleUserID ?? expectedUserID
        self.authorizer = authorizer
        defer { end(id) }
        do {
            let issuedAt = now()
            let challenge = try await api.challenge()
            guard current(id, expected), challenge.isValid else { return nil }
            let state = try randomState()
            guard PeelCompanyValidation.opaque(state, maximum: 128), state != challenge.apple_nonce else { throw PeelCompanyAccountError.invalidAuthorization }
            let credential = try await authorizer.authorize(nonce: challenge.apple_nonce, state: state, requestEmail: true)
            guard current(id, expected) else { return nil }
            guard now() < issuedAt.addingTimeInterval(TimeInterval(challenge.expires_in)) else { throw PeelCompanyAccountError.expiredChallenge }
            guard credential.state == state, PeelCompanyValidation.text(credential.userID, maximum: 1024),
                  intendedUser == nil || intendedUser == credential.userID,
                  PeelCompanyValidation.identityToken(credential.identityToken),
                  let code = credential.authorizationCode, PeelCompanyValidation.text(code, maximum: 4096) else { throw PeelCompanyAccountError.invalidAuthorization }
            lastKnownAppleUserID = credential.userID
            let result = try await api.signIn(challenge: challenge.challenge_id, identityToken: credential.identityToken,
                code: code, collectEmail: collectEmail, consentVersion: challenge.consent_version)
            guard current(id, expected) else { discardServerSession(result.session_token); return nil }
            guard result.account.isValid, result.account.email_collection_consent == collectEmail,
                  expectedAccount == nil || result.account.account_id == expectedAccount,
                  PeelCompanyValidation.bearer(result.session_token), (1...(30 * 86_400)).contains(result.expires_in),
                  let configuration else { discardServerSession(result.session_token); throw PeelCompanyAccountError.invalidResponse }
            let next = PeelCompanySession(profile: result.account, bearer: result.session_token,
                appleUserID: credential.userID, origin: configuration.origin.absoluteString,
                issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(TimeInterval(result.expires_in)))
            guard next.isValid(at: now(), origin: configuration.origin) else { discardServerSession(result.session_token); throw PeelCompanyAccountError.invalidResponse }
            do { try storage.save(next) }
            catch { discardServerSession(result.session_token); throw PeelCompanyAccountError.secureStorage }
            let previous = session?.bearer
            session = next; account = next.profile; sessionID = UUID(); lastCheckedAt = now()
            fence.acceptVerifiedSession(); storageWarning = nil
            status = collectEmail ? "Company account verified. Your Apple-provided email is saved with Zephyr Studios." : "Company account verified. Zephyr Studios has not saved your email."
            reconcileLifecycle()
            if let previous, previous != next.bearer { discardServerSession(previous) }
            return PeelCompanyLocalIdentity(userID: credential.userID, email: credential.localEmail, sessionID: sessionID!)
        } catch {
            if current(id, expected) { status = describe(error) }
            return nil
        }
    }

    func refreshSession() async {
        expireSessionIfNeeded()
        guard let stored = session, let api, let (id, expected) = begin() else { return }
        defer { end(id) }
        do {
            let profile = try await api.account(bearer: stored.bearer)
            guard current(id, expected), session?.bearer == stored.bearer else { return }
            guard profile.isValid, profile.account_id == stored.profile.account_id else { throw PeelCompanyAccountError.invalidResponse }
            let updated = PeelCompanySession(profile: profile, bearer: stored.bearer,
                appleUserID: stored.appleUserID, origin: stored.origin, issuedAt: stored.issuedAt,
                expiresAt: stored.expiresAt)
            do { try storage.save(updated) } catch { throw PeelCompanyAccountError.secureStorage }
            session = updated; account = profile; lastCheckedAt = now()
            if deletion == nil { status = "Company account checked." }
        } catch {
            guard current(id, expected) else { return }
            lastCheckedAt = now()
            if (error as? PeelCompanyAccountError) == .unauthorized { clearSession() }
            status = describe(error) // 503/offline retains the still-valid secure session.
        }
    }

    func withdrawEmail() async {
        expireSessionIfNeeded()
        guard let stored = session, let api, let (id, expected) = begin() else { return }
        defer { end(id) }
        do {
            let profile = try await api.withdrawEmail(bearer: stored.bearer)
            guard current(id, expected), session?.bearer == stored.bearer else { return }
            guard profile.isValid, profile.account_id == stored.profile.account_id,
                  !profile.email_collection_consent, profile.email == nil else { throw PeelCompanyAccountError.invalidResponse }
            let updated = PeelCompanySession(profile: profile, bearer: stored.bearer, appleUserID: stored.appleUserID,
                origin: stored.origin, issuedAt: stored.issuedAt, expiresAt: stored.expiresAt)
            do { try storage.save(updated) } catch { throw PeelCompanyAccountError.secureStorage }
            session = updated; account = profile
            status = "Your saved company email was removed. Saving it again requires a fresh Apple flow."
        } catch {
            guard current(id, expected) else { return }
            if (error as? PeelCompanyAccountError) == .unauthorized { clearSession() }
            status = describe(error)
        }
    }

    /// Confirmation is owned by the view. A conservative 240s window avoids
    /// extending the backend's five-minute bearer freshness during transit.
    func deleteRecentSession() async {
        expireSessionIfNeeded()
        guard let stored = session else { needsFreshDeletionProof = true; return }
        guard now().timeIntervalSince(stored.issuedAt) >= 0, now().timeIntervalSince(stored.issuedAt) <= 240 else {
            needsFreshDeletionProof = true; status = "Confirm deletion with a fresh Apple authorization."; return
        }
        await performDeletion(bearer: stored.bearer, challenge: nil, token: nil, intendedUser: stored.appleUserID)
    }

    func deleteWithApple(using authorizer: any PeelCompanyAppleAuthorizing, expectedUserID: String?) async {
        guard let api, let intendedUser = authorizationUserID ?? expectedUserID,
              let (id, expected) = begin() else { return }
        self.authorizer = authorizer
        defer { end(id) }
        var submitted = false
        do {
            let issuedAt = now()
            let challenge = try await api.challenge()
            guard current(id, expected), challenge.isValid else { return }
            let state = try randomState()
            guard PeelCompanyValidation.opaque(state, maximum: 128), state != challenge.apple_nonce else { throw PeelCompanyAccountError.invalidAuthorization }
            let credential = try await authorizer.authorize(nonce: challenge.apple_nonce, state: state, requestEmail: false)
            guard current(id, expected) else { return }
            guard now() < issuedAt.addingTimeInterval(TimeInterval(challenge.expires_in)) else { throw PeelCompanyAccountError.expiredChallenge }
            guard credential.state == state, credential.userID == intendedUser,
                  PeelCompanyValidation.identityToken(credential.identityToken) else { throw PeelCompanyAccountError.invalidAuthorization }
            try markDeletionPending(userID: intendedUser)
            submitted = true
            let result = try await api.delete(bearer: nil, challenge: challenge.challenge_id, identityToken: credential.identityToken)
            guard current(id, expected) else { return }
            confirmedDeletion(result)
        } catch {
            guard current(id, expected) else { return }
            if submitted { await deletionFailed(error, id: id, generation: expected) }
            else { status = describe(error) }
        }
    }

    private func markDeletionPending(userID: String) throws {
        guard let configuration else { throw PeelCompanyAccountError.notConfigured }
        let intent = PeelCompanyDeletionIntent(appleUserID: userID, origin: configuration.origin.absoluteString,
            createdAt: now(), outcome: PeelCompanyDeletionOutcome.unconfirmed.rawValue)
        do { try storage.saveDeletionIntent(intent) }
        catch { throw PeelCompanyAccountError.secureStorage }
        deletionIntent = intent
        deletion = .unconfirmed; needsFreshDeletionProof = true
    }
    private func performDeletion(bearer: String?, challenge: String?, token: String?, intendedUser: String) async {
        guard let api, let (id, expected) = begin() else { return }
        lastKnownAppleUserID = intendedUser
        defer { end(id) }
        var submitted = false
        do {
            try markDeletionPending(userID: intendedUser)
            submitted = true
            let result = try await api.delete(bearer: bearer, challenge: challenge, identityToken: token)
            guard current(id, expected) else { return }
            confirmedDeletion(result)
        } catch {
            guard current(id, expected) else { return }
            if submitted { await deletionFailed(error, id: id, generation: expected) }
            else { status = describe(error) }
        }
    }
    private func confirmedDeletion(_ result: PeelCompanyDeletionOutcome) {
        guard result != .unconfirmed else { return }
        clearSession(); deletion = result; needsFreshDeletionProof = false
        if let intent = deletionIntent {
            let updated = PeelCompanyDeletionIntent(appleUserID: intent.appleUserID, origin: intent.origin,
                createdAt: intent.createdAt, outcome: result.rawValue)
            do { try storage.saveDeletionIntent(updated); deletionIntent = updated }
            catch { storageWarning = "The deletion response was received, but its updated receipt could not be saved. Verify deletion again after reopening Peel." }
        }
        switch result {
        case .complete: status = "Company account and saved email deleted. Known Apple authorizations were revoked."
        case .pending: status = "Company account and saved email deleted. Apple authorization revocation is pending."
        case .manualRevocation: status = "Company deletion confirmed. Revoke Apple's authorization manually using the instructions below."
        case .unconfirmed: break
        }
        onDeletionConfirmed?()
    }
    private func deletionFailed(_ error: any Error, id: UUID, generation expected: Int) async {
        if let stored = session, let api,
           (error as? PeelCompanyAccountError) == .unavailable {
            // Check the existing bearer once; never sign in/create an account
            // to discover whether an ambiguous delete reached the server.
            do {
                let profile = try await api.account(bearer: stored.bearer)
                guard current(id, expected) else { return }
                guard profile.isValid, profile.account_id == stored.profile.account_id else { throw PeelCompanyAccountError.invalidResponse }
            } catch {
                guard current(id, expected) else { return }
                if (error as? PeelCompanyAccountError) == .unauthorized { clearSession() }
            }
        } else if (error as? PeelCompanyAccountError) == .unauthorized { clearSession() }
        guard current(id, expected) else { return }
        deletion = .unconfirmed; needsFreshDeletionProof = true
        status = "Company deletion is not confirmed. Use a fresh Apple authorization to verify deletion. " + describe(error)
    }
}
