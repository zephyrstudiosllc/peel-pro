import Foundation

@MainActor
private final class FakeProfiles: PeelAppleProfileStorage {
    var profile: PeelAppleAccountProfile?
    var saves = 0
    var removals = 0
    func load() throws -> PeelAppleAccountProfile? { profile }
    func save(_ profile: PeelAppleAccountProfile) throws { self.profile = profile; saves += 1 }
    func remove() throws { profile = nil; removals += 1 }
}

@MainActor
private final class FakeCredentials: PeelAppleCredentialChecking {
    var authorized = true
    var hold = false
    var pending: CheckedContinuation<Bool, Error>?
    var checks = 0
    func isAuthorized(userID: String) async throws -> Bool {
        checks += 1
        if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
        return authorized
    }
}

@MainActor
private final class FakeCloud: PeelCloudMetadataTransport {
    var account = "fixture-private-account-A"
    var records: [PeelCloudDeviceMetadata] = []
    var writes: [PeelCloudDeviceMetadata] = []
    var holdNextRead = false
    var pending: CheckedContinuation<[PeelCloudDeviceMetadata], Error>?
    var holdNextAccount = false
    var pendingAccount: CheckedContinuation<String, Error>?
    var reads = 0
    var accountChecks = 0
    func availableAccountID() async throws -> String {
        accountChecks += 1
        if holdNextAccount {
            holdNextAccount = false
            return try await withCheckedThrowingContinuation { pendingAccount = $0 }
        }
        return account
    }
    func fetchDevices(now: Date) async throws -> [PeelCloudDeviceMetadata] {
        reads += 1
        if holdNextRead {
            holdNextRead = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return records
    }
    func saveDevice(_ device: PeelCloudDeviceMetadata, allowingTombstoneRestore: Bool) async throws -> PeelCloudDeviceMetadata {
        writes.append(device)
        if let existing = records.first(where: { $0.id == device.id }),
           PeelCloudDeviceMetadata.publicationWinner(existing, device,
               allowingTombstoneRestore: allowingTombstoneRestore) == existing { return existing }
        records.removeAll { $0.id == device.id }
        records.append(device)
        return device
    }
}

@main
enum PeelAccountChecks {
    @MainActor
    static func main() async throws {
        try metadataChecks()
        try await serviceChecks()
        await tombstoneLifecycleChecks()
        await automaticLifecycleChecks()
        await expiredTombstoneChecks()
        print("Optional account checks passed: whitelist/bounds/expiry/LWW/tombstones, consent/rates/revocation, automatic launch/foreground/background/single-loop/off/logout, and stale completions; fakes only")
    }

    private static func device(id: String = UUID().uuidString, revision: Int64 = 1,
                               deleted: Bool = false, now: Date = .now,
                               agents: [PeelCloudAgentDigest] = []) -> PeelCloudDeviceMetadata {
        PeelCloudDeviceMetadata(schema: 1, id: id, writerID: UUID().uuidString, revision: revision,
            displayName: "Fixture Mac", platform: .mac, discoveryID: UUID().uuidString,
            updatedAt: now, expiresAt: now.addingTimeInterval(3600), isDeleted: deleted, agents: agents)
    }

    private static func metadataChecks() throws {
        let now = Date.now
        let id = UUID().uuidString
        let old = device(id: id, revision: 1, now: now)
        let next = device(id: id, revision: 2, now: now)
        let tombstone = device(id: id, revision: 2, deleted: true, now: now)
        let merged = PeelCloudDeviceMetadata.merge([next, old, tombstone, next], at: now)
        precondition(merged.count == 1 && merged[0].isDeleted, "Tombstones must win equal revisions")
        precondition(PeelCloudDeviceMetadata.winner(old, next) == next)
        precondition(PeelCloudDeviceMetadata.publicationWinner(tombstone, device(id: id, revision: 3, now: now),
            allowingTombstoneRestore: false) == tombstone)
        precondition(!PeelCloudDeviceMetadata.publicationWinner(tombstone, device(id: id, revision: 3, now: now),
            allowingTombstoneRestore: true).isDeleted)
        precondition(PeelCloudDeviceMetadata.merge([device(now: now.addingTimeInterval(-7200))], at: now).isEmpty)

        let secret = "private prompt /Users/example/work PIN1234 KEY_abcd"
        let digest = PeelCloudAgentDigest.snapshot(localID: secret, deviceID: id, provider: "codex", state: "working", updatedAt: now)
        let safe = device(now: now, agents: [digest])
        let data = try safe.encoded()
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains(secret) && !text.contains("/Users/") && !text.contains("KEY_abcd"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let expected: Set<String> = ["schema", "id", "writerID", "revision", "displayName", "platform", "discoveryID", "updatedAt", "expiresAt", "isDeleted", "agents"]
        precondition(Set(json.keys) == expected, "Only explicit metadata keys may leave the device")
        let agentJSON = (json["agents"] as! [[String: Any]])[0]
        precondition(Set(agentJSON.keys) == Set(["id", "provider", "state", "updatedAt"]))
        precondition(PeelCloudDeviceMetadata.decoded(data, at: now) == safe)
        precondition(PeelCloudDeviceMetadata.decoded(Data(repeating: 0, count: 16_385), at: now) == nil)
        let tooManyAgents = (0..<25).map {
            PeelCloudAgentDigest.snapshot(localID: "\($0)", deviceID: id, provider: "codex", state: "working", updatedAt: now)
        }
        precondition(!device(now: now, agents: tooManyAgents).isValid(at: now))
        let manyDevices = (0..<300).map { _ in device(now: now) }
        precondition(PeelCloudDeviceMetadata.merge(manyDevices, at: now).count == 128)
        var bad = json
        bad["schema"] = 999
        let invalidSchema = try JSONSerialization.data(withJSONObject: bad)
        precondition(PeelCloudDeviceMetadata.decoded(invalidSchema, at: now) == nil)
    }

    @MainActor
    private static func serviceChecks() async throws {
        let suite = "local.peel.optional-account-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = FakeProfiles()
        let credentials = FakeCredentials()
        let cloud = FakeCloud()
        let model = PeelAccountController(defaults: defaults, storage: profiles,
            credentialChecker: credentials, cloud: cloud, observesAccountChanges: false)
        precondition(!model.syncEnabled && cloud.writes.isEmpty && model.devices.isEmpty)
        let now = Date.now
        cloud.records = [device(now: now)]
        model.agentSnapshotProvider = {
            (0..<50).map { PeelCloudAgentDigest.snapshot(localID: "local-private-\($0)", deviceID: model.deviceID,
                provider: "grok_bot", state: "working", updatedAt: now) }
        }
        await model.setSyncEnabled(true)
        precondition(model.syncEnabled && model.devices.count == 2 && cloud.writes.count == 1)
        precondition(cloud.writes[0].agents.count == 24 && cloud.writes[0].agents[0].provider == "grok_bot")
        await model.refreshCloud(now: now.addingTimeInterval(16))
        precondition(cloud.writes.count == 1, "Manual refresh must not bypass write rate limits")
        await model.refreshCloud(now: now.addingTimeInterval(61))
        precondition(cloud.writes.count == 2)

        await model.acceptAppleCredential(userID: "fixture-apple-user", email: "fixture@privaterelay.appleid.com")
        precondition(model.profile?.usesPrivateRelay == true && profiles.saves == 1)
        await model.acceptAppleCredential(userID: "fixture-apple-user", email: nil)
        precondition(model.profile?.email == "fixture@privaterelay.appleid.com", "Apple may omit email after first authorization")
        credentials.authorized = false
        await model.checkAppleCredential()
        precondition(model.profile == nil && profiles.profile == nil && !model.syncEnabled && model.devices.isEmpty)

        credentials.authorized = true
        await model.setSyncEnabled(true)
        cloud.holdNextRead = true
        let read = Task { await model.refreshCloud(now: now.addingTimeInterval(120)) }
        for _ in 0..<100 where cloud.pending == nil { await Task.yield() }
        precondition(cloud.pending != nil)
        let writesBeforeLogout = cloud.writes.count
        model.signOut()
        cloud.pending?.resume(returning: cloud.records)
        cloud.pending = nil
        await read.value
        precondition(model.devices.isEmpty && !model.syncEnabled && !model.isBusy)
        precondition(cloud.writes.count == writesBeforeLogout, "An old cloud read must not write after logout")

        await model.setSyncEnabled(true)
        let writesBeforeSwitch = cloud.writes.count
        cloud.account = "fixture-private-account-B"
        await model.refreshCloud(now: now.addingTimeInterval(180))
        precondition(!model.syncEnabled && model.devices.isEmpty && cloud.writes.count == writesBeforeSwitch)
        await model.setSyncEnabled(true)
        precondition(model.syncEnabled, "The new iCloud account needs explicit opt-in")
        await model.removeThisDeviceFromCloud()
        precondition(!model.syncEnabled && model.devices.isEmpty && cloud.writes.last?.isDeleted == true)

        credentials.hold = true
        let lateCredential = Task { await model.acceptAppleCredential(userID: "late-fixture-user", email: nil) }
        for _ in 0..<100 where credentials.pending == nil { await Task.yield() }
        precondition(credentials.pending != nil)
        let savesBeforeLogout = profiles.saves
        model.signOut()
        credentials.pending?.resume(returning: true)
        credentials.pending = nil
        _ = await lateCredential.value
        precondition(model.profile == nil && profiles.saves == savesBeforeLogout)

        let notConfigured = PeelAccountController(defaults: defaults, storage: profiles,
            credentialChecker: FakeCredentials(), observesAccountChanges: false)
        await notConfigured.setSyncEnabled(true)
        precondition(!notConfigured.cloudConfigured && !notConfigured.syncEnabled && notConfigured.devices.isEmpty)
    }

    @MainActor
    private static func tombstoneLifecycleChecks() async {
        let suite = "local.peel.tombstone-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = FakeCloud()
        let model = PeelAccountController(defaults: defaults, storage: FakeProfiles(),
            credentialChecker: FakeCredentials(), cloud: cloud, observesAccountChanges: false)
        let now = Date.now
        await model.setSyncEnabled(true)
        let first = cloud.writes[0]
        cloud.records = [device(id: first.id, revision: first.revision + 1, deleted: true, now: now)]
        await model.refreshCloud(now: now.addingTimeInterval(16))
        precondition(!model.syncEnabled && model.devices.isEmpty && cloud.writes.count == 1,
                     "A remote tombstone must stop automatic republication")
        await model.setSyncEnabled(true)
        precondition(cloud.writes.count == 1, "Rapid toggling must not bypass write pacing")
        await model.refreshCloud(now: now.addingTimeInterval(61))
        precondition(model.syncEnabled && cloud.writes.count == 2 && cloud.writes.last?.isDeleted == false,
                     "Only explicit renewed consent can restore a removed device")
    }

    @MainActor
    private static func automaticLifecycleChecks() async {
        let suite = "local.peel.lifecycle-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = FakeCloud()
        defaults.set(true, forKey: PeelAccountController.syncKey)
        defaults.set(cloud.account, forKey: "peel.account.consentedCloudAccount.v1")
        let model = PeelAccountController(defaults: defaults, storage: FakeProfiles(),
            credentialChecker: FakeCredentials(), cloud: cloud, observesAccountChanges: false)
        defer { model.stopAutomaticSync() }
        precondition(model.syncEnabled && cloud.writes.isEmpty)
        model.startAutomaticSync(isForeground: true)
        await spinUntil { cloud.writes.count == 1 && !model.isBusy }
        precondition(cloud.writes.count == 1, "Persisted consent must publish at app launch without opening Settings")
        let firstLoop = model.automaticLoopID
        precondition(firstLoop != nil)
        for _ in 0..<20 { model.startAutomaticSync(isForeground: true) }
        precondition(model.automaticLoopID == firstLoop, "Multiple scene setup calls must keep one loop")

        model.setApplicationForeground(false)
        let pausedReads = cloud.reads
        precondition(model.automaticLoopID == nil && model.syncEnabled && !model.isBusy)
        await model.refreshCloud(now: Date.now.addingTimeInterval(120))
        precondition(cloud.reads == pausedReads, "Mobile background must not admit refreshes")

        cloud.holdNextRead = true
        model.setApplicationForeground(true)
        await spinUntil { cloud.pending != nil }
        precondition(cloud.pending != nil && model.automaticLoopID != firstLoop)
        let oldRead = cloud.pending!
        cloud.pending = nil
        model.setApplicationForeground(false)
        model.setApplicationForeground(true)
        await spinUntil { cloud.reads >= pausedReads + 2 && !model.isBusy }
        let currentDevices = model.devices
        oldRead.resume(returning: [device()])
        for _ in 0..<20 { await Task.yield() }
        precondition(model.devices == currentDevices && !model.isBusy,
                     "A canceled pre-background read must not replace a resumed loop's cache/busy state")
        precondition(cloud.writes.count == 1, "Rapid pause/resume must preserve write pacing")

        await model.setSyncEnabled(false)
        precondition(model.automaticLoopID == nil && !model.syncEnabled)
        model.setApplicationForeground(false)
        model.setApplicationForeground(true)
        precondition(model.automaticLoopID == nil, "Foregrounding must not revive disabled sync")
        await model.setSyncEnabled(true)
        await spinUntil { model.automaticLoopID != nil }
        model.signOut()
        precondition(model.automaticLoopID == nil && model.devices.isEmpty && !model.syncEnabled)

        let pendingCloud = FakeCloud()
        pendingCloud.holdNextAccount = true
        let pendingModel = PeelAccountController(defaults: defaults, storage: FakeProfiles(),
            credentialChecker: FakeCredentials(), cloud: pendingCloud, observesAccountChanges: false)
        let enabling = Task { await pendingModel.setSyncEnabled(true) }
        await spinUntil { pendingCloud.pendingAccount != nil }
        precondition(pendingModel.isEnablingSync && pendingModel.isBusy)
        await pendingModel.setSyncEnabled(false)
        pendingCloud.pendingAccount?.resume(returning: pendingCloud.account)
        pendingCloud.pendingAccount = nil
        await enabling.value
        precondition(!pendingModel.syncEnabled && !pendingModel.isEnablingSync && pendingCloud.writes.isEmpty,
                     "Turning off must cancel even an unfinished consent/account lookup")

        defaults.set(true, forKey: PeelAccountController.syncKey)
        defaults.set(cloud.account, forKey: "peel.account.consentedCloudAccount.v1")
        let backgroundCloud = FakeCloud()
        let backgroundModel = PeelAccountController(defaults: defaults, storage: FakeProfiles(),
            credentialChecker: FakeCredentials(), cloud: backgroundCloud, observesAccountChanges: false)
        defer { backgroundModel.stopAutomaticSync() }
        backgroundModel.startAutomaticSync(isForeground: false)
        for _ in 0..<10 { await Task.yield() }
        precondition(backgroundCloud.accountChecks == 0 && backgroundModel.automaticLoopID == nil,
                     "A background launch must not start iCloud work")
        backgroundModel.setApplicationForeground(true)
        await spinUntil { backgroundCloud.writes.count == 1 }
        precondition(backgroundCloud.writes.count == 1)

        let revokedProfiles = FakeProfiles()
        revokedProfiles.profile = PeelAppleAccountProfile(userID: "revoked-fixture", email: nil)
        // Seed a fresh independent identity fixture after the earlier sign-out.
        defaults.removeObject(forKey: "peel.account.localAppleProfileDiscarded.v1")
        let revokedCredentials = FakeCredentials()
        revokedCredentials.authorized = false
        let revokedCloud = FakeCloud()
        let revokedModel = PeelAccountController(defaults: defaults, storage: revokedProfiles,
            credentialChecker: revokedCredentials, cloud: revokedCloud, observesAccountChanges: false)
        defer { revokedModel.stopAutomaticSync() }
        revokedModel.startAutomaticSync(isForeground: true)
        await spinUntil { !revokedModel.syncEnabled }
        precondition(revokedModel.profile == nil && revokedProfiles.profile == nil
            && revokedModel.automaticLoopID == nil && revokedCloud.writes.isEmpty,
            "Revoked credentials must stop persisted startup sync before publishing")

        defaults.set(false, forKey: PeelAccountController.syncKey)
        let localProfiles = FakeProfiles()
        localProfiles.profile = PeelAppleAccountProfile(userID: "local-only-fixture", email: nil)
        defaults.removeObject(forKey: "peel.account.localAppleProfileDiscarded.v1")
        let localCredentials = FakeCredentials()
        localCredentials.hold = true
        let localCloud = FakeCloud()
        let localModel = PeelAccountController(defaults: defaults, storage: localProfiles,
            credentialChecker: localCredentials, cloud: localCloud, observesAccountChanges: false)
        defer { localModel.stopAutomaticSync() }
        localModel.startAutomaticSync(isForeground: true)
        await spinUntil { localCredentials.pending != nil }
        for _ in 0..<20 { localModel.startAutomaticSync(isForeground: true) }
        precondition(localCredentials.checks == 1 && localCloud.accountChecks == 0,
                     "Stored identity must be checked once at launch even with sync off, without cloud work")
        await localModel.setSyncEnabled(false)
        localCredentials.pending?.resume(returning: false)
        localCredentials.pending = nil
        await spinUntil { localModel.profile == nil }
        precondition(localModel.profile == nil && localProfiles.profile == nil && localCloud.writes.isEmpty,
                     "Turning sync off must not discard an independent stored-identity revocation result")
    }

    @MainActor
    private static func expiredTombstoneChecks() async {
        let suite = "local.peel.expired-tombstone-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = FakeCloud()
        let id = UUID().uuidString
        let now = Date.now
        let expired = device(id: id, deleted: true, now: now.addingTimeInterval(-8 * 24 * 60 * 60))
        cloud.records = [expired]
        precondition(PeelCloudDeviceMetadata.merge(cloud.records, at: now).isEmpty)
        precondition(PeelCloudDeviceMetadata.decoded(try! expired.encoded(), at: now) == expired,
                     "Expired metadata remains readable for server-side conflict and removal checks")
        defaults.set(id, forKey: "peel.account.localCloudDeviceID.v1")
        defaults.set(true, forKey: PeelAccountController.syncKey)
        defaults.set(cloud.account, forKey: "peel.account.consentedCloudAccount.v1")
        let model = PeelAccountController(defaults: defaults, storage: FakeProfiles(),
            credentialChecker: FakeCredentials(), cloud: cloud, observesAccountChanges: false)
        defer { model.stopAutomaticSync() }
        model.startAutomaticSync(isForeground: true)
        await spinUntil { !model.syncEnabled }
        precondition(!model.syncEnabled && model.devices.isEmpty && cloud.records == [expired],
                     "A returning installation must not overwrite a query-expired server tombstone without renewed consent")
        await model.setSyncEnabled(true)
        await spinUntil { !model.isBusy }
        await model.refreshCloud(now: now.addingTimeInterval(61))
        precondition(model.syncEnabled && cloud.records.count == 1 && !cloud.records[0].isDeleted,
                     "An explicit new opt-in can restore the expired tombstone, with normal write pacing")
    }

    @MainActor
    private static func spinUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
    }
}
