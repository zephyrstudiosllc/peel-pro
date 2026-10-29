import Foundation
import Combine
import AuthenticationServices
import CloudKit
import Security
import LocalAuthentication

@MainActor
final class PeelSecureAppleProfileStorage: PeelAppleProfileStorage {
    private let service = (Bundle.main.bundleIdentifier ?? "local.peel") + ".apple-account-profile"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "nativeAppleProfile.v1", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> PeelAppleAccountProfile? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PeelAccountError.secureStorage(status) }
        guard let data = item as? Data, data.count <= 16_384 else { throw PeelAccountError.invalidMetadata }
        return try JSONDecoder().decode(PeelAppleAccountProfile.self, from: data)
    }
    func save(_ profile: PeelAppleAccountProfile) throws {
        let data = try JSONEncoder().encode(profile)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PeelAccountError.secureStorage(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PeelAccountError.secureStorage(status)
        }
    }
}

@MainActor
final class PeelNativeAppleCredentialChecker: PeelAppleCredentialChecking {
    func isAuthorized(userID: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state == .authorized) }
            }
        }
    }
}

@MainActor
final class PeelPrivateCloudKitTransport: PeelCloudMetadataTransport {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private static let recordType = "PeelDeviceMetadataV1"

    init(identifier: String) { container = CKContainer(identifier: identifier) }

    func availableAccountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw PeelAccountError.iCloudUnavailable }
        let recordID = try await container.userRecordID()
        // A local namespace marker, never an Apple identity token or trust key.
        return recordID.recordName
    }

    func fetchDevices(now: Date) async throws -> [PeelCloudDeviceMetadata] {
        let query = CKQuery(recordType: Self.recordType,
                            predicate: NSPredicate(format: "expiresAt > %@", now as NSDate))
        let result = try await database.records(matching: query, desiredKeys: ["payload"],
                                                resultsLimit: PeelCloudDeviceMetadata.maximumDevices)
        return result.matchResults.compactMap { id, result in
            guard case .success(let record) = result, let data = record["payload"] as? Data,
                  let metadata = PeelCloudDeviceMetadata.decoded(data, at: now), metadata.id == id.recordName
            else { return nil }
            return metadata
        }
    }

    func saveDevice(_ device: PeelCloudDeviceMetadata, allowingTombstoneRestore: Bool) async throws -> PeelCloudDeviceMetadata {
        guard device.isValid(at: .now) else { throw PeelAccountError.invalidMetadata }
        let id = CKRecord.ID(recordName: device.id)
        // Read the server change tag and use compare-and-save. A concurrent
        // writer is reconciled once; never overwrite an unknown server version.
        for attempt in 0..<2 {
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: Self.recordType, recordID: id)
            }
            if record.allKeys().contains("payload") {
                guard let data = record["payload"] as? Data,
                      let existing = PeelCloudDeviceMetadata.decoded(data, at: .now), existing.id == device.id
                else { throw PeelAccountError.invalidMetadata }
                if PeelCloudDeviceMetadata.publicationWinner(existing, device,
                    allowingTombstoneRestore: allowingTombstoneRestore) == existing { return existing }
            }
            record["payload"] = try device.encoded() as CKRecordValue
            record["expiresAt"] = device.expiresAt as CKRecordValue
            do { _ = try await database.save(record); return device }
            catch let error as CKError where error.code == .serverRecordChanged && attempt == 0 { continue }
        }
        throw PeelAccountError.invalidMetadata
    }
}

@MainActor
final class PeelAccountController: ObservableObject {
    static let shared = PeelAccountController()
    static let syncKey = "peel.account.metadataSyncEnabled.v1"
    private static let deviceKey = "peel.account.localCloudDeviceID.v1"
    private static let accountKey = "peel.account.consentedCloudAccount.v1"
    private static let discardedAppleProfileKey = "peel.account.localAppleProfileDiscarded.v1"
    let company: PeelCompanyAccountController

    @Published private(set) var profile: PeelAppleAccountProfile?
    @Published private(set) var identityStatus = "Apple sign-in is optional."
    @Published private(set) var cloudStatus = "Device sync is off."
    @Published private(set) var syncEnabled: Bool
    @Published private(set) var devices: [PeelCloudDeviceMetadata] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isEnablingSync = false
    @Published private(set) var lastSyncedAt: Date?
    let nativeAppleSignInConfigured: Bool
    let cloudConfigured: Bool
    let deviceID: String
    var agentSnapshotProvider: (() -> [PeelCloudAgentDigest])?
    var localDeviceName = "Peel device"
    var localPlatform: PeelCloudDeviceMetadata.Platform = .mac
    var localDiscoveryID: String?

    private let defaults: UserDefaults
    private let storage: any PeelAppleProfileStorage
    private let credentialChecker: any PeelAppleCredentialChecking
    private let cloud: (any PeelCloudMetadataTransport)?
    private let writerID = UUID().uuidString
    private var generation = 0
    private var lastReadAt: Date?
    private var lastWriteAt: Date?
    private var localRevision: Int64 = 0
    private var mayRestoreTombstone = false
    private var observers: [NSObjectProtocol] = []
    private var lifecycleStarted = false
    private var applicationForeground = false
    private var automaticTask: Task<Void, Never>?
    private(set) var automaticLoopID: UUID?
    private var cloudOperationID: UUID?
    private var identityGeneration = 0
    private var profileCheckTask: Task<Void, Never>?
    private var profileCheckID: UUID?
    private var applicationInBackground = false
    private var localAuthorizationID: UUID?
    private var localAuthorizer: (any PeelCompanyAppleAuthorizing)?

    init(defaults: UserDefaults = .standard,
         storage: (any PeelAppleProfileStorage)? = nil,
         credentialChecker: (any PeelAppleCredentialChecking)? = nil,
         cloud: (any PeelCloudMetadataTransport)? = nil,
         company: PeelCompanyAccountController? = nil,
         configuration: Bundle = .main, observesAccountChanges: Bool = true) {
        self.defaults = defaults
        self.storage = storage ?? PeelSecureAppleProfileStorage()
        self.credentialChecker = credentialChecker ?? PeelNativeAppleCredentialChecker()
        self.company = company ?? PeelCompanyAccountController(configuration: configuration)
        deviceID = defaults.string(forKey: Self.deviceKey).flatMap { UUID(uuidString: $0)?.uuidString }
            ?? UUID().uuidString
#if os(macOS)
        // The current product is Developer ID distributed. Native SIWA's
        // restricted entitlement is not supported in that distribution.
        nativeAppleSignInConfigured = false
#else
        nativeAppleSignInConfigured = configuration.object(forInfoDictionaryKey: "PeelNativeAppleSignInEnabled") as? Bool == true
#endif
        let identifier = configuration.object(forInfoDictionaryKey: "PeelCloudKitContainerIdentifier") as? String
        let enabled = configuration.object(forInfoDictionaryKey: "PeelCloudKitEnabled") as? Bool == true
        cloudConfigured = cloud != nil || (enabled && identifier?.hasPrefix("iCloud.") == true)
        self.cloud = cloud ?? (cloudConfigured ? PeelPrivateCloudKitTransport(identifier: identifier!) : nil)
        syncEnabled = defaults.bool(forKey: Self.syncKey) && cloudConfigured
        do { if !defaults.bool(forKey: Self.discardedAppleProfileKey) { profile = try self.storage.load() } }
        catch { identityStatus = error.localizedDescription }
        if !cloudConfigured { cloudStatus = PeelAccountError.setupRequired.localizedDescription }
        if observesAccountChanges {
            observers.append(NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.cloudAccountChanged() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.profile != nil || self.company.authorizationUserID != nil else { return }
                    self.signOut(revoked: true)
                }
            })
        }
        self.company.onDeletionConfirmed = { [weak self] in self?.discardLocalAppleIdentity(revoked: false) }
        if let deletion = self.company.deletion, deletion != .unconfirmed { discardLocalAppleIdentity(revoked: false) }
    }

    isolated deinit {
        automaticTask?.cancel()
        profileCheckTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// One process-owned loop. Repeated scene/app setup cannot create workers.
    /// Mac keeps this active while running; mobile app lifecycle pauses it.
    func startAutomaticSync(isForeground: Bool) {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        applicationForeground = isForeground
        company.startLifecycle(isForeground: !applicationInBackground)
        if isForeground { requestStoredCredentialCheck() }
        reconcileAutomaticLoop()
    }

    func setApplicationForeground(_ active: Bool) {
        guard lifecycleStarted, applicationForeground != active else { return }
        applicationForeground = active
        if !active {
            stopAutomaticLoop()
            stopStoredCredentialCheck()
            invalidateCloudOperation()
        } else {
            lastReadAt = nil
            requestStoredCredentialCheck()
            reconcileAutomaticLoop()
        }
    }

    func stopAutomaticSync() {
        lifecycleStarted = false
        applicationForeground = false
        stopAutomaticLoop()
        stopStoredCredentialCheck()
        invalidateCloudOperation()
        company.stopLifecycle()
        cancelLocalAuthorization()
    }

    /// System auth panels may make UIKit inactive. Only actual backgrounding
    /// invalidates native authorization; metadata still pauses on inactivity.
    func setApplicationBackground(_ background: Bool) {
        guard applicationInBackground != background else { return }
        applicationInBackground = background
        company.setForeground(!background)
        if background {
            generation += 1; identityGeneration += 1
            cancelLocalAuthorization()
            stopStoredCredentialCheck()
        }
    }

    /// Stored identity is revalidated even when private metadata sync is off.
    /// Scene setup and sync share this check rather than making duplicate calls.
    @discardableResult
    private func requestStoredCredentialCheck() -> Task<Void, Never>? {
        guard profile != nil || company.hasSession else { return nil }
        if let profileCheckTask { return profileCheckTask }
        let id = UUID()
        profileCheckID = id
        let task = Task { @MainActor [weak self] in
            await self?.checkAppleCredential()
            guard let self, self.profileCheckID == id else { return }
            self.profileCheckID = nil
            self.profileCheckTask = nil
        }
        profileCheckTask = task
        return task
    }

    private func stopStoredCredentialCheck() {
        profileCheckID = nil
        profileCheckTask?.cancel()
        profileCheckTask = nil
    }

    private func stopAutomaticLoop() {
        automaticLoopID = nil
        automaticTask?.cancel()
        automaticTask = nil
    }

    private func invalidateCloudOperation() {
        cloudOperationID = nil
        isBusy = false
        isEnablingSync = false
    }

    private func reconcileAutomaticLoop() {
        guard lifecycleStarted, applicationForeground, syncEnabled, cloudConfigured else {
            stopAutomaticLoop(); return
        }
        guard automaticTask == nil else { return }
        let id = UUID()
        automaticLoopID = id
        automaticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.automaticRefresh(loopID: id)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func automaticRefresh(loopID: UUID) async {
        guard automaticLoopID == loopID, applicationForeground, syncEnabled else { return }
        await requestStoredCredentialCheck()?.value
        guard automaticLoopID == loopID, applicationForeground, syncEnabled else { return }
        await refreshCloud()
    }

    private func isCurrentCloudOperation(_ id: UUID, generation expected: Int) -> Bool {
        generation == expected && cloudOperationID == id && !Task.isCancelled
            && (!lifecycleStarted || applicationForeground)
    }

    @discardableResult
    func acceptAppleCredential(userID: String, email: String?, validityCheck: (() -> Bool)? = nil) async -> Bool {
        let originalGeneration = generation
        do {
            guard !userID.isEmpty, userID.utf8.count <= 1024,
                  email.map({ $0.utf8.count <= 254 && $0.contains("@") }) ?? true
            else { throw PeelAccountError.credentialUnavailable }
            let authorized = try await credentialChecker.isAuthorized(userID: userID)
            guard generation == originalGeneration, !Task.isCancelled, !applicationInBackground,
                  validityCheck?() ?? true else { return false }
            guard authorized else { signOut(revoked: true); return false }
            let retainedEmail = profile?.userID == userID ? profile?.email : nil
            let next = PeelAppleAccountProfile(userID: userID, email: email ?? retainedEmail)
            try storage.save(next)
            defaults.removeObject(forKey: Self.discardedAppleProfileKey)
            identityGeneration += 1
            stopStoredCredentialCheck()
            profile = next
            identityStatus = "Signed in with Apple."
            return true
        } catch { identityStatus = "The Apple profile could not be saved securely."; return false }
    }

    func checkAppleCredential() async {
        guard let userID = profile?.userID ?? company.authorizationUserID else { return }
        if let profile, company.hasSession, company.authorizationUserID != profile.userID {
            signOut(revoked: true); return
        }
        let originalGeneration = identityGeneration
        do {
            let authorized = try await credentialChecker.isAuthorized(userID: userID)
            guard identityGeneration == originalGeneration, (profile?.userID ?? company.authorizationUserID) == userID,
                  !Task.isCancelled else { return }
            if !authorized { signOut(revoked: true) }
            else { company.requestSessionRefresh() }
        } catch {
            guard identityGeneration == originalGeneration, !Task.isCancelled else { return }
            identityStatus = "Could not check Apple sign-in. Try again later."
        }
    }

    func authorizationFailed(_ error: Error) {
        if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
            identityStatus = "Sign-in canceled. You can keep using Peel without an account."
        } else {
            identityStatus = "Apple sign-in could not finish. Try a fresh Apple flow if you choose."
        }
    }

    func signOut(revoked: Bool = false) {
        company.signOut()
        discardLocalAppleIdentity(revoked: revoked)
    }

    private func discardLocalAppleIdentity(revoked: Bool) {
        generation += 1
        identityGeneration += 1
        stopStoredCredentialCheck()
        cancelLocalAuthorization()
        setSyncOff()
        profile = nil
        defaults.set(true, forKey: Self.discardedAppleProfileKey)
        do {
            try storage.remove()
            identityStatus = revoked ? "Apple sign-in was revoked. Local pairing is still available." : "Signed out on this device. Local pairing is unchanged."
        } catch { identityStatus = "Sign-out could not remove the secure profile: \(error.localizedDescription)" }
    }

    func cloudAccountChanged() {
        generation += 1; identityGeneration += 1
        setSyncOff()
        stopStoredCredentialCheck()
        cancelLocalAuthorization()
        company.cancelPendingOperations()
        defaults.removeObject(forKey: Self.accountKey)
        lastWriteAt = nil
        cloudStatus = PeelAccountError.accountChanged.localizedDescription
        if !applicationInBackground { requestStoredCredentialCheck() }
    }

    private func cancelLocalAuthorization() {
        localAuthorizationID = nil
        localAuthorizer?.cancel(); localAuthorizer = nil
    }

    func signInToCompany(using authorizer: any PeelCompanyAppleAuthorizing, collectEmail: Bool) async {
        guard let identity = await company.signIn(using: authorizer, collectEmail: collectEmail,
                                                  expectedUserID: profile?.userID) else { return }
        let adopted = await acceptAppleCredential(userID: identity.userID, email: identity.email,
            validityCheck: { [weak company] in company?.isCurrentSession(identity.sessionID) == true })
        if !adopted { company.discardSessionIfCurrent(identity.sessionID) }
    }

    func signInLocallyWithApple(using authorizer: any PeelCompanyAppleAuthorizing) async {
        guard nativeAppleSignInConfigured, !applicationInBackground, localAuthorizationID == nil else { return }
        let id = UUID(); let expected = generation
        localAuthorizationID = id; localAuthorizer = authorizer
        defer { if localAuthorizationID == id { localAuthorizationID = nil; localAuthorizer = nil } }
        do {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PeelCompanyAccountError.invalidAuthorization }
            let state = Data(bytes).base64EncodedString()
            let credential = try await authorizer.authorize(nonce: UUID().uuidString, state: state, requestEmail: true)
            guard localAuthorizationID == id, expected == generation, credential.state == state,
                  !applicationInBackground else { return }
            await acceptAppleCredential(userID: credential.userID, email: credential.localEmail,
                validityCheck: { [weak self] in self?.localAuthorizationID == id })
        } catch {
            guard localAuthorizationID == id, expected == generation else { return }
            identityStatus = (error as? PeelCompanyAccountError) == .cancelled
                ? "Sign-in canceled. You can keep using Peel without an account."
                : "Apple sign-in could not finish. Try a fresh Apple flow if you choose."
        }
    }

    private func setSyncOff() {
        syncEnabled = false
        defaults.set(false, forKey: Self.syncKey)
        devices = []
        stopAutomaticLoop()
        invalidateCloudOperation()
        lastReadAt = nil
        lastSyncedAt = nil
        mayRestoreTombstone = false
    }

    func setSyncEnabled(_ enabled: Bool) async {
        if enabled && (syncEnabled || isEnablingSync) { reconcileAutomaticLoop(); return }
        generation += 1
        if !enabled { setSyncOff(); cloudStatus = "Device sync is off. Existing entries stop appearing after their expiry date."; return }
        guard let cloud else { cloudStatus = PeelAccountError.setupRequired.localizedDescription; return }
        let originalGeneration = generation
        let operation = UUID()
        cloudOperationID = operation
        isBusy = true
        isEnablingSync = true
        cloudStatus = "Checking the system iCloud account…"
        defer { if cloudOperationID == operation { invalidateCloudOperation() } }
        do {
            let account = try await cloud.availableAccountID()
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            defaults.set(account, forKey: Self.accountKey)
            defaults.set(deviceID, forKey: Self.deviceKey)
            defaults.set(true, forKey: Self.syncKey)
            syncEnabled = true
            mayRestoreTombstone = true
            cloudStatus = "Sync enabled. Checking iCloud…"
            invalidateCloudOperation()
            reconcileAutomaticLoop()
            if !lifecycleStarted { await refreshCloud() }
        } catch {
            if isCurrentCloudOperation(operation, generation: originalGeneration) { cloudStatus = error.localizedDescription }
        }
    }

    func refreshCloud(now: Date = .now) async {
        guard syncEnabled, let cloud, !isBusy else { return }
        guard !lifecycleStarted || applicationForeground else { return }
        guard lastReadAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        let originalGeneration = generation
        let operation = UUID()
        cloudOperationID = operation
        isBusy = true
        defer { if cloudOperationID == operation { invalidateCloudOperation() } }
        do {
            let account = try await cloud.availableAccountID()
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            guard account == defaults.string(forKey: Self.accountKey) else {
                cloudAccountChanged(); return
            }
            let fetched = try await cloud.fetchDevices(now: now)
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            var merged = PeelCloudDeviceMetadata.merge(fetched, at: now)
            if let own = merged.first(where: { $0.id == deviceID }) {
                localRevision = max(localRevision, own.revision)
                if own.isDeleted && !mayRestoreTombstone {
                    generation += 1
                    setSyncOff()
                    cloudStatus = "This device's cloud entry was removed. Enable sync again to resume."
                    return
                }
            }
            if lastWriteAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                // Reserve the interval before awaiting the network so a rapid
                // background/resume cannot start a second concurrent write.
                lastWriteAt = now
                let saved = try await cloud.saveDevice(localMetadata(at: now),
                                                       allowingTombstoneRestore: mayRestoreTombstone)
                guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
                localRevision = max(localRevision, saved.revision)
                if saved.isDeleted {
                    generation += 1
                    setSyncOff()
                    cloudStatus = "This device's cloud entry was removed. Enable sync again to resume."
                    return
                }
                merged = PeelCloudDeviceMetadata.merge(merged + [saved], at: now)
                mayRestoreTombstone = false
            }
            devices = merged.filter { !$0.isDeleted }
            lastReadAt = now
            lastSyncedAt = now
            cloudStatus = "Synced privately through the system iCloud account."
        } catch {
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            devices = []
            lastReadAt = now
            cloudStatus = error.localizedDescription
        }
    }

    func removeThisDeviceFromCloud() async {
        guard syncEnabled, let cloud, !isBusy else { return }
        guard !lifecycleStarted || applicationForeground else { return }
        let originalGeneration = generation
        let operation = UUID()
        cloudOperationID = operation
        isBusy = true
        defer { if cloudOperationID == operation { invalidateCloudOperation() } }
        do {
            let account = try await cloud.availableAccountID()
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            guard account == defaults.string(forKey: Self.accountKey) else { cloudAccountChanged(); return }
            var retired = try await cloud.saveDevice(localMetadata(at: .now, deleted: true), allowingTombstoneRestore: false)
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            if !retired.isDeleted {
                localRevision = max(localRevision, retired.revision)
                retired = try await cloud.saveDevice(localMetadata(at: .now, deleted: true), allowingTombstoneRestore: false)
            }
            guard isCurrentCloudOperation(operation, generation: originalGeneration) else { return }
            guard retired.id == deviceID, retired.isDeleted else { throw PeelAccountError.invalidMetadata }
            generation += 1
            setSyncOff()
            cloudStatus = "This device was removed from iCloud metadata. Local pairings are unchanged."
        } catch {
            if isCurrentCloudOperation(operation, generation: originalGeneration) { cloudStatus = error.localizedDescription }
        }
    }

    private func localMetadata(at now: Date, deleted: Bool = false) -> PeelCloudDeviceMetadata {
        localRevision = max(localRevision + 1, Int64(now.timeIntervalSince1970 * 1000))
        let name = String(localDeviceName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }.prefix(64))
        let safeName = name.utf8.count <= 128 ? name : "Peel device"
        let snapshots = deleted ? [] : (agentSnapshotProvider?() ?? [])
        var seen = Set<String>()
        let agents = snapshots.filter { $0.isValid && $0.updatedAt <= now.addingTimeInterval(300) && seen.insert($0.id).inserted }
            .prefix(PeelCloudDeviceMetadata.maximumAgents).map { $0 }
        return PeelCloudDeviceMetadata(schema: 1, id: deviceID, writerID: writerID, revision: localRevision,
            displayName: safeName.isEmpty ? "Peel device" : safeName, platform: localPlatform,
            discoveryID: localDiscoveryID.flatMap { UUID(uuidString: $0)?.uuidString }, updatedAt: now,
            expiresAt: now.addingTimeInterval(deleted ? PeelCloudDeviceMetadata.tombstoneLifetime : PeelCloudDeviceMetadata.lifetime),
            isDeleted: deleted, agents: agents)
    }
}
