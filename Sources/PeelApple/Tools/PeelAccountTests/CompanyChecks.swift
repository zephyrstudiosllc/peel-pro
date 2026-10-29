import Foundation

@MainActor private final class CompanyStore: PeelCompanySessionStorage {
    var session: PeelCompanySession?
    var intent: PeelCompanyDeletionIntent?
    var loads = 0, saves = 0
    var failSave = false, failRemove = false, failIntentSave = false, failIntentRemove = false
    func load() throws -> PeelCompanySession? { loads += 1; return session }
    func save(_ session: PeelCompanySession) throws { if failSave { throw PeelCompanyAccountError.secureStorage }; self.session = session; saves += 1 }
    func remove() throws { if failRemove { throw PeelCompanyAccountError.secureStorage }; session = nil }
    func loadDeletionIntent() throws -> PeelCompanyDeletionIntent? { intent }
    func saveDeletionIntent(_ intent: PeelCompanyDeletionIntent) throws { if failIntentSave { throw PeelCompanyAccountError.secureStorage }; self.intent = intent }
    func removeDeletionIntent() throws { if failIntentRemove { throw PeelCompanyAccountError.secureStorage }; intent = nil }
}
@MainActor private final class CompanyClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
@MainActor private final class CompanyAPI: PeelCompanyAccountAPI {
    let configuration = PeelCompanyAccountConfiguration(origin: "https://account-fixture.peel-tests.net", privacyURL: "https://account-fixture.peel-tests.net/privacy")!
    var challenges = 0, signIns = 0, gets = 0, withdrawals = 0, deletes = 0
    var signedOut: [String] = []
    var consent: Bool?
    var error: PeelCompanyAccountError?
    var deletionResult: PeelCompanyDeletionOutcome = .complete
    var holdSignIn = false
    var pending: CheckedContinuation<PeelCompanySignInResponse, any Error>?
    var deleteArguments: (String?, String?, String?)?
    var savedEmail = false
    static let token = String(repeating: "A", count: 43)
    func profile(_ collect: Bool) -> PeelCompanyAccountProfile {
        PeelCompanyAccountProfile(account_id: "fixture-account", email: collect ? "fixture@privaterelay.appleid.com" : nil,
            email_collection_consent: collect, marketing_consent: false,
            consent_version: PeelCompanyAccountConfiguration.consentVersion, marketing_delivery_configured: false)
    }
    func response(_ collect: Bool) -> PeelCompanySignInResponse {
        PeelCompanySignInResponse(account: profile(collect), session_token: Self.token, expires_in: 3600)
    }
    func challenge() async throws -> PeelCompanyChallenge {
        challenges += 1
        return PeelCompanyChallenge(challenge_id: "fixture-challenge", apple_nonce: "EXACT_server_nonce", expires_in: 300,
            client_id: PeelCompanyAccountConfiguration.clientID, consent_version: PeelCompanyAccountConfiguration.consentVersion)
    }
    func signIn(challenge: String, identityToken: String, code: String, collectEmail: Bool, consentVersion: String) async throws -> PeelCompanySignInResponse {
        signIns += 1; consent = collectEmail
        precondition(challenge == "fixture-challenge" && identityToken == "header.payload.signature" && code == "one-use-code")
        if let error { throw error }
        if holdSignIn { return try await withCheckedThrowingContinuation { pending = $0 } }
        savedEmail = collectEmail
        return response(collectEmail)
    }
    func account(bearer: String) async throws -> PeelCompanyAccountProfile { gets += 1; if let error { throw error }; return profile(savedEmail) }
    func withdrawEmail(bearer: String) async throws -> PeelCompanyAccountProfile { withdrawals += 1; if let error { throw error }; savedEmail = false; return profile(false) }
    func signOut(bearer: String) async throws { signedOut.append(bearer); if let error { throw error } }
    func delete(bearer: String?, challenge: String?, identityToken: String?) async throws -> PeelCompanyDeletionOutcome {
        deletes += 1; deleteArguments = (bearer, challenge, identityToken)
        if let error { throw error }; return deletionResult
    }
}
@MainActor private final class CompanyAuth: PeelCompanyAppleAuthorizing {
    var user = "fixture-apple-user", badState = false, cancelled = false
    var error: PeelCompanyAccountError?
    var nonce: String?, state: String?, requestedEmail: Bool?
    var afterAuthorization: (() -> Void)?
    func authorize(nonce: String, state: String, requestEmail: Bool) async throws -> PeelCompanyAppleAuthorization {
        self.nonce = nonce; self.state = state; requestedEmail = requestEmail
        if let error { throw error }
        afterAuthorization?()
        return PeelCompanyAppleAuthorization(userID: user, state: badState ? "different" : state,
            identityToken: "header.payload.signature", authorizationCode: requestEmail ? "one-use-code" : nil,
            localEmail: "local-only@privaterelay.appleid.com")
    }
    func cancel() { cancelled = true }
}
@MainActor private final class CompanyProfiles: PeelAppleProfileStorage {
    var profile: PeelAppleAccountProfile?, failSave = false
    func load() throws -> PeelAppleAccountProfile? { profile }
    func save(_ profile: PeelAppleAccountProfile) throws { if failSave { throw PeelCompanyAccountError.secureStorage }; self.profile = profile }
    func remove() throws { profile = nil }
}
@MainActor private final class CompanyCredentials: PeelAppleCredentialChecking {
    var authorized = true
    func isAuthorized(userID: String) async throws -> Bool { authorized }
}
@MainActor private final class CompanyCloud: PeelCloudMetadataTransport {
    func availableAccountID() async throws -> String { "fixture-cloud" }
    func fetchDevices(now: Date) async throws -> [PeelCloudDeviceMetadata] { [] }
    func saveDevice(_ device: PeelCloudDeviceMetadata, allowingTombstoneRestore: Bool) async throws -> PeelCloudDeviceMetadata { device }
}
@MainActor private final class RecordingHTTP: PeelCompanyHTTPExecuting {
    var requests: [URLRequest] = []
    var response = PeelCompanyHTTPResponse(status: 200, data: Data())
    func execute(_ request: URLRequest) async throws -> PeelCompanyHTTPResponse { requests.append(request); return response }
}

@main enum PeelCompanyChecks {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); assertions += 1
    }
    @MainActor private static func controller(_ api: CompanyAPI, _ store: CompanyStore, _ clock: CompanyClock,
                                      fence: PeelCompanyMemorySessionFence? = nil) -> PeelCompanyAccountController {
        PeelCompanyAccountController(api: api, storage: store, fence: fence, now: { clock.date }, randomState: { "independent_random_state" })
    }
    @MainActor static func spin(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "fixture continuation not reached")
    }
    @MainActor static func main() async throws {
        try await networkDTOChecks()
        await authorizationChecks()
        await sessionChecks()
        await deletionChecks()
        await bridgeChecks()
        print("Company account checks passed: \(assertions) assertions; deterministic fakes only, no sockets/real Keychain/standard defaults")
    }
    @MainActor static func networkDTOChecks() async throws {
        for origin in ["http://account-fixture.peel-tests.net", "https://example.com", "https://api.invalid", "https://127.0.0.1", "https://name.local", "https://user:pass@real.peel-tests.net", "https://real.peel-tests.net/path", "https://real.peel-tests.net?token=x"] {
            check(PeelCompanyAccountConfiguration(origin: origin, privacyURL: "https://account-fixture.peel-tests.net/privacy") == nil, "Reject insecure/placeholder/non-origin configuration")
        }
        check(!PeelCompanyValidation.identityToken("x..y") && !PeelCompanyValidation.identityToken("x.y."), "Reject empty JWT components")
        let api = CompanyAPI(), executor = RecordingHTTP()
        let client = PeelCompanyHTTPSAccountAPI(configuration: api.configuration, executor: executor)
        executor.response = PeelCompanyHTTPResponse(status: 200, data: try JSONEncoder().encode(SignInFixture(account: api.profile(true), session_token: CompanyAPI.token, expires_in: 3600)))
        _ = try await client.signIn(challenge: "fixture-challenge", identityToken: "header.payload.signature", code: "one-use-code", collectEmail: true, consentVersion: PeelCompanyAccountConfiguration.consentVersion)
        let request = executor.requests.last!
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(Set(body.keys) == Set(["challenge_id", "identity_token", "authorization_code", "email_collection_consent", "marketing_consent", "consent_version"]), "Network credential DTO is explicitly whitelisted")
        check(body["marketing_consent"] as? Bool == false && body["email_collection_consent"] as? Bool == true, "Marketing is always false and save-email consent explicit")
        check(request.url?.path == "/v1/apple/sign-in" && request.url?.query == nil && request.httpMethod == "POST" && !request.httpShouldHandleCookies, "Credentials are POST JSON only with no cookies/query")
        for (code, expected) in [("apple_revocation_pending", PeelCompanyAccountError.pendingRevocation), ("account_grant_capacity_reached", .grantCapacity), ("fresh_apple_sign_in_required", .freshAppleProofRequired), ("verified_email_unavailable", .verifiedEmailUnavailable)] {
            executor.response = PeelCompanyHTTPResponse(status: 409, data: try JSONSerialization.data(withJSONObject: ["error": code]))
            do { _ = try await client.challenge(); preconditionFailure("409 accepted") } catch { check(error as? PeelCompanyAccountError == expected, "409 maps exact stable code without automatic retry") }
        }
        executor.response = PeelCompanyHTTPResponse(status: 200, data: Data(repeating: 32, count: 65_537))
        do { _ = try await client.challenge(); preconditionFailure("Oversize accepted") } catch { check(error as? PeelCompanyAccountError == .invalidResponse, "Bound decoded JSON before parsing") }
        executor.response = PeelCompanyHTTPResponse(status: 202, data: Data("{\"account_deleted\":true,\"apple_revocation_complete\":false,\"apple_revocation_pending\":true}".utf8))
        _ = try await client.delete(bearer: nil, challenge: "fresh", identityToken: "header.payload.signature")
        let deletionBody = try JSONSerialization.jsonObject(with: executor.requests.last!.httpBody!) as! [String: Any]
        check(Set(deletionBody.keys) == Set(["challenge_id", "identity_token"]) && executor.requests.last!.value(forHTTPHeaderField: "Authorization") == nil, "Fresh deletion sends no authorization code/bearer/email")
        let flags = [(200, true, false, false, PeelCompanyDeletionOutcome.complete), (202, false, true, false, .pending), (200, false, false, true, .manualRevocation)]
        for (status, complete, pending, manual, result) in flags {
            let actual = try PeelCompanyDeletionResponse(account_deleted: true, apple_revocation_complete: complete, apple_revocation_pending: pending, manual_apple_revocation_required: manual).outcome(status: status)
            check(actual == result, "Deletion flags determine truthful result")
        }
        do { _ = try PeelCompanyDeletionResponse(account_deleted: true, apple_revocation_complete: true, apple_revocation_pending: true, manual_apple_revocation_required: nil).outcome(status: 200); preconditionFailure("Contradictory flags") }
        catch { check(error as? PeelCompanyAccountError == .invalidResponse, "Contradictory deletion rejected") }
    }
    private struct SignInFixture: Encodable { let account: PeelCompanyAccountProfile; let session_token: String; let expires_in: Int }

    @MainActor static func authorizationChecks() async {
        let clock = CompanyClock()
        for collect in [true, false] {
            let api = CompanyAPI(), auth = CompanyAuth(), model = controller(api, CompanyStore(), clock)
            let identity = await model.signIn(using: auth, collectEmail: collect, expectedUserID: nil)
            check(identity != nil && model.hasSession && model.account?.email_collection_consent == collect, "Only verified success adopts consent-bound company session")
            check(auth.nonce == "EXACT_server_nonce" && auth.state == "independent_random_state" && auth.nonce != auth.state, "Exact server nonce and independent state")
            check(identity?.email == "local-only@privaterelay.appleid.com" && api.consent == collect, "Apple callback email stays local, not network API input")
        }
        for failure in 0..<4 {
            let api = CompanyAPI(), store = CompanyStore(), auth = CompanyAuth(), model = controller(api, store, clock)
            if failure == 0 { auth.badState = true }
            if failure == 1 { auth.user = "other-user" }
            if failure == 2 { auth.error = .cancelled }
            if failure == 3 { auth.afterAuthorization = { clock.date.addTimeInterval(301) } }
            _ = await model.signIn(using: auth, collectEmail: false, expectedUserID: "fixture-apple-user")
            check(!model.hasSession && store.saves == 0 && api.signIns == 0, "State/user/cancel/expired proof cannot create session")
        }
        for interruption in 0..<3 {
            let api = CompanyAPI(), store = CompanyStore(), auth = CompanyAuth(), model = controller(api, store, clock)
            api.holdSignIn = true; model.startLifecycle(isForeground: true)
            let task = Task { await model.signIn(using: auth, collectEmail: false, expectedUserID: nil) }
            await spin { api.pending != nil }
            if interruption == 0 { model.signOut() }
            if interruption == 1 { model.setForeground(false) }
            if interruption == 2 { model.cancelPendingOperations() }
            api.pending?.resume(returning: api.response(false)); api.pending = nil
            let result = await task.value
            await spin { !api.signedOut.isEmpty }
            check(result == nil && !model.hasSession && store.saves == 0 && api.signedOut.count == 1, "Late successful backend cannot restore after signout/background/account change; revoke partial success")
            model.stopLifecycle()
        }
        let store = CompanyStore(), disabled = PeelCompanyAccountController(storage: store)
        check(!disabled.isConfigured && store.loads == 0, "Default-off performs no secure credential reads")
    }
    @MainActor static func sessionChecks() async {
        let clock = CompanyClock(), api = CompanyAPI(), store = CompanyStore(), fence = PeelCompanyMemorySessionFence()
        let model = controller(api, store, clock, fence: fence)
        _ = await model.signIn(using: CompanyAuth(), collectEmail: true, expectedUserID: nil)
        await model.withdrawEmail()
        check(model.account?.email == nil && model.account?.email_collection_consent == false && api.withdrawals == 1, "Email withdrawal persists no-email profile")
        api.error = .unavailable; await model.refreshSession()
        check(model.hasSession && store.session != nil, "503/offline retains valid session")
        api.error = .unauthorized; await model.refreshSession()
        check(!model.hasSession && store.session == nil && fence.isDiscarded, "401 clears only company session immediately")
        api.error = nil; _ = await model.signIn(using: CompanyAuth(), collectEmail: false, expectedUserID: nil)
        clock.date.addTimeInterval(3601); await model.refreshSession()
        check(!model.hasSession, "Expired session cannot authorize refresh")
        _ = await model.signIn(using: CompanyAuth(), collectEmail: false, expectedUserID: nil)
        store.failRemove = true; api.error = .unavailable; model.signOut()
        check(!model.hasSession && model.storageWarning != nil && fence.isDiscarded, "Offline signout remains local even if Keychain erase fails")
        let reload = controller(api, store, clock, fence: fence)
        check(!reload.hasSession && reload.storageWarning != nil, "Discard fence prevents old bearer resurrection")
    }
    @MainActor static func deletionChecks() async {
        let clock = CompanyClock()
        for outcome in [PeelCompanyDeletionOutcome.complete, .pending, .manualRevocation] {
            let api = CompanyAPI(), store = CompanyStore(), fence = PeelCompanyMemorySessionFence()
            api.deletionResult = outcome
            let model = controller(api, store, clock, fence: fence)
            _ = await model.signIn(using: CompanyAuth(), collectEmail: true, expectedUserID: nil)
            await model.deleteRecentSession()
            check(!model.hasSession && model.deletion == outcome && store.intent?.result == outcome && fence.isDiscarded, "Confirmed deletion clears credential and persists exact flags")
            let reload = controller(api, store, clock, fence: fence)
            check(reload.deletion == outcome && !reload.hasSession && reload.authorizationUserID == "fixture-apple-user", "Receipt preserves original identity independent of bearer")
            reload.requestDeletionVerification()
            check(reload.needsFreshDeletionProof, "Pending/manual receipt exposes explicit fresh deletion proof")
            let wrong = CompanyAuth(); wrong.user = "wrong-user"
            let before = api.deletes
            await reload.deleteWithApple(using: wrong, expectedUserID: "wrong-user")
            check(api.deletes == before, "Fresh deletion rejects switched Apple subject despite caller identity")
            store.failIntentRemove = true; reload.allowNewAccountAfterConfirmedDeletion()
            check(reload.deletion == outcome, "New enrollment cannot discard receipt if secure erase fails")
            store.failIntentRemove = false; reload.allowNewAccountAfterConfirmedDeletion()
            check(reload.deletion == nil && store.intent == nil && !reload.hasSession && fence.isDiscarded && api.signIns == 1, "Explicit re-enrollment only reveals fresh form, preserves old-session fence, never creates account")
        }
        let api = CompanyAPI(), store = CompanyStore(), fence = PeelCompanyMemorySessionFence()
        let model = controller(api, store, clock, fence: fence)
        api.error = .unavailable
        await model.deleteWithApple(using: CompanyAuth(), expectedUserID: "fixture-apple-user")
        check(model.deletion == .unconfirmed && store.intent?.result == .unconfirmed && api.deletes == 1, "No-bearer ambiguous DELETE has durable intent")
        let reload = controller(api, store, clock, fence: fence)
        check(reload.deletion == .unconfirmed && reload.authorizationUserID == "fixture-apple-user", "Ambiguous deletion survives restart without bearer")
        reload.allowNewAccountAfterConfirmedDeletion()
        check(reload.deletion == .unconfirmed && store.intent != nil, "Unconfirmed deletion cannot acknowledge new enrollment")
        let auth = CompanyAuth(); _ = await reload.signIn(using: auth, collectEmail: true, expectedUserID: nil)
        check(api.signIns == 0 && auth.nonce == nil, "Never sign in to infer deletion state")
        api.error = nil; api.deletionResult = .manualRevocation
        await reload.deleteWithApple(using: CompanyAuth(), expectedUserID: "different-caller")
        check(reload.deletion == .manualRevocation && api.deleteArguments?.0 == nil && api.deleteArguments?.1 == "fixture-challenge", "Original-user proof retries deletion without bearer/code or automatic account recreation")
        let failStore = CompanyStore(); failStore.failIntentSave = true
        let failModel = controller(api, failStore, clock)
        let before = api.deletes
        await failModel.deleteWithApple(using: CompanyAuth(), expectedUserID: "fixture-apple-user")
        check(api.deletes == before && failModel.deletion == nil, "Abort before destructive request if durable intent cannot save")
        let invalid = CompanyStore()
        invalid.intent = PeelCompanyDeletionIntent(appleUserID: "fixture-apple-user", origin: "https://wrong.peel-tests.net", createdAt: clock.date, outcome: "unconfirmed")
        let invalidModel = controller(api, invalid, clock)
        _ = await invalidModel.signIn(using: CompanyAuth(), collectEmail: false, expectedUserID: nil)
        check(invalidModel.storageRecoveryRequired && !invalidModel.hasSession, "Present invalid deletion receipt fails closed")
    }
    @MainActor static func bridgeChecks() async {
        let suite = "local.peel.company-bridge-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Use only this private suite, never standard preferences.
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = CompanyAPI(), store = CompanyStore(), clock = CompanyClock(), profiles = CompanyProfiles(), credentials = CompanyCredentials()
        let company = controller(api, store, clock)
        let root = PeelAccountController(defaults: defaults, storage: profiles, credentialChecker: credentials,
            cloud: CompanyCloud(), company: company, observesAccountChanges: false)
        defer { root.stopAutomaticSync(); defaults.removePersistentDomain(forName: suite) }
        await root.signInToCompany(using: CompanyAuth(), collectEmail: false)
        await root.setSyncEnabled(true)
        check(company.hasSession && root.profile != nil && root.syncEnabled, "Successful company adoption retains separate local Apple profile")
        root.cloudAccountChanged()
        await spin { !company.isBusy }
        check(company.hasSession && root.profile != nil && !root.syncEnabled && root.devices.isEmpty, "CloudKit account change preserves authorized identity/bearer and requires metadata reconsent")
        credentials.authorized = false; await root.checkAppleCredential()
        check(!company.hasSession && root.profile == nil && profiles.profile == nil, "Actual native revocation clears both optional identities")
        credentials.authorized = true; profiles.failSave = true
        await root.signInToCompany(using: CompanyAuth(), collectEmail: false)
        check(!company.hasSession && store.session == nil, "Native profile persistence failure compensates successful backend session")
        profiles.failSave = false; root.startAutomaticSync(isForeground: true)
        api.holdSignIn = true
        let task = Task { await root.signInToCompany(using: CompanyAuth(), collectEmail: false) }
        await spin { api.pending != nil }
        root.setApplicationForeground(false) // system sheet inactivity
        api.pending?.resume(returning: api.response(false)); api.pending = nil
        await task.value
        check(company.hasSession && root.profile != nil, "Benign inactive auth sheet does not cancel its own authorization")
        root.signOut(); root.setApplicationForeground(true)
        let background = Task { await root.signInToCompany(using: CompanyAuth(), collectEmail: false) }
        await spin { api.pending != nil }
        root.setApplicationBackground(true)
        api.pending?.resume(returning: api.response(false)); api.pending = nil
        await background.value
        check(!company.hasSession && root.profile == nil && store.session == nil, "Actual background cancels late authorization adoption")
    }
}
