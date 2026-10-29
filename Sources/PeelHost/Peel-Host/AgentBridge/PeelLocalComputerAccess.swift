import Combine
import Foundation

/// Runtime-only consent and identity for the explicit local-computer agent
/// target (`targetPairingId: "local"`). Only Peel's own UI can grant it; the
/// bridge can read readiness but has no setter. It starts off at every launch,
/// is never persisted, and every revocation rotates the generation so listed
/// windows, app IDs, inspections and queued input from before become invalid.
@MainActor
final class PeelLocalComputerAccess: ObservableObject {
    /// Reserved bridge target. Paired IDs are UUIDs, so this cannot name a peer.
    nonisolated static let targetID = "local"

    @Published private(set) var isAllowed = false
    @Published private(set) var status = "Off"
    /// Short plain-text activity shown in the Host's visible Stop surfaces.
    @Published private(set) var activity: String?

    private(set) var generation: UInt64 = 1
    /// Inspections are bound to this grant, as paired inspections are bound to
    /// a receiver renderer. A new grant never accepts an old inspection.
    private(set) var evidence = UUID()
    private var authorityOwners: Set<UUID> = []
    private var advertisedAppIDs: Set<String> = []

    /// Called after every revocation, before any later request is admitted.
    var onRevoked: (String) -> Void = { _ in }

    var scope: PeelAgentPresentationScope {
        PeelAgentPresentationScope(pairingID: Self.targetID, generation: generation)
    }

    /// The exact InputSynthesizer generation owned by this grant.
    var inputGeneration: UInt64 { InputSynthesizer.localControlGenerationFlag | generation }

    nonisolated static func isLocalTarget(_ targetID: String) -> Bool { targetID == Self.targetID }

    /// UI-only consent change. Turning it on starts a fresh generation.
    func setAllowed(_ allowed: Bool) {
        if allowed {
            guard !isAllowed else { return }
            rotate()
            isAllowed = true
            status = "On — AI can use apps on this Mac"
            activity = nil
        } else {
            revoke(reason: "Stopped")
        }
    }

    /// Stop, lock, bridge shutdown or permission loss. Always rotates.
    func revoke(reason: String) {
        let wasAllowed = isAllowed
        rotate()
        isAllowed = false
        activity = nil
        status = wasAllowed ? "Off — \(reason)" : "Off"
        onRevoked(reason)
    }

    func isCurrent(scope candidate: PeelAgentPresentationScope) -> Bool {
        isAllowed && candidate == scope
    }

    func isCurrentInputGeneration(_ candidate: UInt64) -> Bool {
        isAllowed && candidate == inputGeneration
    }

    // MARK: Request-scoped authority

    /// Each local request that can focus, inspect or control holds its own
    /// owner. Effects check that exact owner; no request lends authority to
    /// another request or to any paired-client path.
    func beginAuthority() -> UUID {
        let owner = UUID()
        authorityOwners.insert(owner)
        return owner
    }

    func endAuthority(_ owner: UUID) { authorityOwners.remove(owner) }

    func isAuthorityCurrent(_ owner: UUID) -> Bool { isAllowed && authorityOwners.contains(owner) }

    var hasActiveAuthority: Bool { isAllowed && !authorityOwners.isEmpty }

    /// A person used the keyboard or mouse: every pending local request loses
    /// its authority. Consent and the person's own input are unaffected.
    func interruptRequests() {
        authorityOwners.removeAll()
        evidence = UUID()
    }

    // MARK: App catalog scoping

    func replaceAdvertisedApps(_ ids: [String]) { advertisedAppIDs = Set(ids) }
    func isAdvertisedApp(_ id: String) -> Bool { isAllowed && advertisedAppIDs.contains(id) }

    func noteActivity(_ text: String?) {
        guard isAllowed else { return }
        activity = text.map { String($0.prefix(160)) }
    }

    private func rotate() {
        generation &+= 1
        if generation == 0 || generation & InputSynthesizer.localControlGenerationFlag != 0 { generation = 1 }
        evidence = UUID()
        authorityOwners.removeAll()
        advertisedAppIDs.removeAll()
    }
}

/// One local request completes exactly once, even if a focus attempt is
/// superseded without calling back and the request deadline fires instead.
@MainActor
final class PeelLocalRequestCompletion {
    private var completed = false
    var isCompleted: Bool { completed }
    func claim() -> Bool {
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// Pure eligibility rules for the local target. Peel's own windows and
/// authentication/system agents are never inspectable or controllable, and
/// whole desktops are not local targets.
nonisolated enum PeelLocalComputerWindowPolicy {
    static let deniedBundleIdentifiers: Set<String> = [
        "com.apple.SecurityAgent", "com.apple.loginwindow",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.ScreenSaver.Engine"
    ]

    static func isEligible(_ fingerprint: PeelAgentWindowInstanceFingerprint,
                           ownProcessID: Int32, ownBundleIdentifier: String?) -> Bool {
        guard !fingerprint.isDisplay, fingerprint.hasDurableIdentity,
              let pid = fingerprint.ownerProcessID, pid != ownProcessID,
              let bundle = fingerprint.appBundleIdentifier,
              !deniedBundleIdentifiers.contains(bundle) else { return false }
        return ownBundleIdentifier.map { $0 != bundle } ?? true
    }

    static func isEligibleApplication(bundleIdentifier: String, ownBundleIdentifier: String?) -> Bool {
        !deniedBundleIdentifiers.contains(bundleIdentifier) && ownBundleIdentifier != bundleIdentifier
    }

    /// Written to `eventSourceUserData` on every event Peel posts. Metadata only.
    static let postedEventMarker: Int64 = 0x5045_454C_4C43

    /// Only events carrying Peel's posted-event marker are Peel's own. Anything
    /// else (hardware, another app, or a person using Peel's own UI) interrupts.
    static func isExternalInput(sourceUserData: Int64) -> Bool {
        sourceUserData != postedEventMarker
    }
}
