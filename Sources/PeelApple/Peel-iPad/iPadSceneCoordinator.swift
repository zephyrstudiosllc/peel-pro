//
//  SceneCoordinator.swift
//  Peel
//
//  Created by Zach on 1/19/26.
//
//  iPad/iPhone parity update: peeled scene tracking from Vision normal files.
//

import SwiftUI
import UIKit
import Combine

enum PeeledWindowPlacementMode: Equatable {
    case trailingCascade
    case balancedSlots
}

@MainActor
final class SceneCoordinator: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    private weak var commerceStore: PeelStore?

    func configureCommerce(_ store: PeelStore) {
        commerceStore = store
    }

    private var phoneWorkspaceWindowsByOwner: [UUID: Set<String>] = [:]

    @discardableResult
    func reservePhoneWorkspace(owner: UUID, windows: [HostedPeelWindow]) -> Bool {
        pruneClosedPeeledWindowScenes()
        let previous = phoneWorkspaceWindowsByOwner[owner] ?? []
        var others = Set(peeledWindowSceneIDsByKey.keys).union(pendingPeeledWindowKeys)
            .union(mountedPeeledWindowKeysByOwner.values)
        for (otherOwner, keys) in phoneWorkspaceWindowsByOwner where otherOwner != owner {
            others.formUnion(keys)
        }
        let requested = Set(windows.map(\.id))
        guard PeelWindowAdmissionPolicy.allowsUpdate(
            otherWindows: others, previousWindows: previous, requestedWindows: requested,
            freeLimit: commerceStore?.freeWindowLimit ?? 1,
            hasProAccess: commerceStore?.hasProAccess ?? false,
            resourceLimit: maxPeeledWindowSceneCount,
            allowsWindowReplacement: true
        ) else { return false }
        if previous != requested {
            objectWillChange.send()
            phoneWorkspaceWindowsByOwner[owner] = requested.isEmpty ? nil : requested
        }
        return true
    }

    func releasePhoneWorkspace(owner: UUID) {
        guard phoneWorkspaceWindowsByOwner[owner] != nil else { return }
        objectWillChange.send()
        phoneWorkspaceWindowsByOwner.removeValue(forKey: owner)
    }

    private var mountedPeeledWindowKeysByOwner: [UUID: String] = [:]

    @discardableResult
    func mountPeeledWindow(owner: UUID, for hostedWindow: HostedPeelWindow) -> Bool {
        guard reservePeeledWindowScene(for: hostedWindow) else { return false }
        mountedPeeledWindowKeysByOwner[owner] = peeledWindowKey(for: hostedWindow)
        return true
    }

    func unmountPeeledWindow(owner: UUID, for hostedWindow: HostedPeelWindow) {
        mountedPeeledWindowKeysByOwner.removeValue(forKey: owner)
        cancelPendingPeeledWindowSceneReservation(for: hostedWindow)
        objectWillChange.send()
    }

    private var mainPersistentID: String?
    private weak var mainScene: UIWindowScene?

    private var isOpeningMainScene = false
    private var peeledWindowSceneIDsByKey: [String: String] = [:]
    private var pendingPeeledWindowKeys: Set<String> = []
    private var pendingPeeledWindowRequestDatesByKey: [String: Date] = [:]
    private var peeledWindowsByKey: [String: PeelWindow] = [:]
    private var peeledWindowSlotsByKey: [String: Int] = [:]
    private var peeledWindowKeysBySlot: [Int: String] = [:]
    private var pendingPeeledWindowPlacementSlots: [Int] = []

    var peeledWindowPlacementMode: PeeledWindowPlacementMode = .balancedSlots {
        didSet {
            guard oldValue != peeledWindowPlacementMode else { return }
            objectWillChange.send()
        }
    }

    private var lastMainOpenRequestDate: Date?
    private let duplicateMainOpenSuppressionInterval: TimeInterval = 0.75
    private let staleMainOpenRequestInterval: TimeInterval = 4.0
    private let minimumPeeledWindowCountBeforeMainMayStayClosed = 2
    let maxPeeledWindowSceneCount = 12
    private var didRunInitialAuxiliarySceneMainRestore = false

    // iPad Home singleton (P2-012). Only scenes that called registerMainScene
    // from the "main" WindowGroup are ever candidates for duplicate destruction.
    private var registeredMainSceneIDs: Set<String> = []
    private var mainDestructionAttemptsByID: [String: Int] = [:]
    private var pendingMainDestructionIDs: Set<String> = []
    private var isMainReconcileScheduled = false
    private let maxMainDestructionAttempts = 3
    private let mainReconcileDelayNanoseconds: UInt64 = 500_000_000

    private var enforcesSingleMainScene: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    func registerMainScene(_ scene: UIWindowScene) {
        let id = scene.session.persistentIdentifier
        guard enforcesSingleMainScene else {
            mainScene = scene
            mainPersistentID = id
            isOpeningMainScene = false
            return
        }

        registeredMainSceneIDs.insert(id)
        isOpeningMainScene = false

        // Keep a still-connected keeper so repeated updateUIView callbacks cannot
        // reverse the choice. The one-way exception promotes a foreground Home over
        // a keeper that is not in the foreground (e.g. restored in the background).
        if let keeper = resolveMainScene(), keeper.session.persistentIdentifier != id {
            let keeperIsForeground = keeper.activationState == .foregroundActive
                || keeper.activationState == .foregroundInactive
            if !keeperIsForeground, scene.activationState == .foregroundActive,
               !pendingMainDestructionIDs.contains(id) {
                mainScene = scene
                mainPersistentID = id
            }
        } else {
            mainScene = scene
            mainPersistentID = id
        }

        scheduleMainSceneReconcile()
    }

    func markMainSceneClosed(_ scene: UIWindowScene? = nil) {
        if let scene {
            let id = scene.session.persistentIdentifier
            registeredMainSceneIDs.remove(id)
            pendingMainDestructionIDs.remove(id)
            mainDestructionAttemptsByID[id] = nil
            // A discarded duplicate must not clear the keeper.
            guard mainPersistentID == id else { return }
        }

        mainScene = nil
        mainPersistentID = nil
        isOpeningMainScene = false
    }

    /// Coalesces bursts of registrations (restoration connects many scenes at once)
    /// into one reconcile pass. Triggered only by main-scene registration, never by
    /// scene-phase changes, so it cannot form a restore loop.
    private func scheduleMainSceneReconcile() {
        guard !isMainReconcileScheduled else { return }
        isMainReconcileScheduled = true
        let delay = mainReconcileDelayNanoseconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            self.isMainReconcileScheduled = false
            self.reconcileDuplicateMainScenes()
        }
    }

    private func reconcileDuplicateMainScenes() {
        guard enforcesSingleMainScene else { return }

        let connected = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let connectedIDs = Set(connected.map(\.session.persistentIdentifier))
        registeredMainSceneIDs.formIntersection(connectedIDs)
        pendingMainDestructionIDs.formIntersection(connectedIDs)
        mainDestructionAttemptsByID = mainDestructionAttemptsByID.filter { connectedIDs.contains($0.key) }

        guard let keeper = resolveMainScene() else { return }
        let keeperID = keeper.session.persistentIdentifier
        let peeledIDs = Set(peeledWindowSceneIDsByKey.values)

        for scene in connected {
            let id = scene.session.persistentIdentifier
            guard id != keeperID,
                  registeredMainSceneIDs.contains(id),
                  !peeledIDs.contains(id),
                  !pendingMainDestructionIDs.contains(id),
                  mainDestructionAttemptsByID[id, default: 0] < maxMainDestructionAttempts
            else { continue }

            pendingMainDestructionIDs.insert(id)
            mainDestructionAttemptsByID[id, default: 0] += 1
            UIApplication.shared.requestSceneSessionDestruction(
                scene.session,
                options: nil,
                errorHandler: { [weak self] _ in
                    Task { @MainActor in
                        // Allow a bounded retry on the next registration.
                        self?.pendingMainDestructionIDs.remove(id)
                    }
                }
            )
        }
    }

    /// Deterministic fallback keeper among positively registered Home scenes:
    /// foreground first, then by persistent identifier.
    private func connectedRegisteredMainSceneCandidate() -> UIWindowScene? {
        func rank(_ scene: UIWindowScene) -> Int {
            switch scene.activationState {
            case .foregroundActive: return 0
            case .foregroundInactive: return 1
            case .background: return 2
            default: return 3
            }
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                let id = $0.session.persistentIdentifier
                return registeredMainSceneIDs.contains(id) && !pendingMainDestructionIDs.contains(id)
            }
            .min {
                let (l, r) = (rank($0), rank($1))
                return l != r ? l < r : $0.session.persistentIdentifier < $1.session.persistentIdentifier
            }
    }

    func canBeginPeeledWindowTransition() -> Bool {
        true
    }

    func finishPeeledWindowTransition() {
        // Admission is checked atomically when reserving each window.
        // This method remains as a compatibility hook for callers that still
        // bracket an open-window request with begin/finish calls.
    }

    func peeledWindowKey(for window: PeelWindow) -> String {
        "legacy::windowId:\(window.windowId)"
    }

    func peeledWindowKey(for hostedWindow: HostedPeelWindow) -> String {
        hostedWindow.id
    }

    @discardableResult
    func reservePeeledWindowScene(for window: PeelWindow) -> Bool {
        guard admittedWindowKeys().contains(peeledWindowKey(for: window)) || canOpenAnotherPeeledWindow() else { return false }

        let key = peeledWindowKey(for: window)
        peeledWindowsByKey[key] = window
        let slot = assignPeeledWindowSlotIfNeeded(forKey: key)
        if !pendingPeeledWindowPlacementSlots.contains(slot) { pendingPeeledWindowPlacementSlots.append(slot) }
        guard pendingPeeledWindowKeys.insert(key).inserted else { return true }
        pendingPeeledWindowRequestDatesByKey[key] = Date()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func reservePeeledWindowScene(for hostedWindow: HostedPeelWindow) -> Bool {
        guard admittedWindowKeys().contains(peeledWindowKey(for: hostedWindow)) || canOpenAnotherPeeledWindow() else { return false }

        let key = peeledWindowKey(for: hostedWindow)
        peeledWindowsByKey[key] = hostedWindow.window
        let slot = assignPeeledWindowSlotIfNeeded(forKey: key)
        if !pendingPeeledWindowPlacementSlots.contains(slot) { pendingPeeledWindowPlacementSlots.append(slot) }
        guard pendingPeeledWindowKeys.insert(key).inserted else { return true }
        pendingPeeledWindowRequestDatesByKey[key] = Date()
        objectWillChange.send()
        return true
    }

    func registerPeeledWindowScene(_ scene: UIWindowScene, for window: PeelWindow) {
        objectWillChange.send()

        let key = peeledWindowKey(for: window)
        removeSupersededSceneRegistration(sceneID: scene.session.persistentIdentifier, keeping: key)
        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        peeledWindowSceneIDsByKey[key] = scene.session.persistentIdentifier
        peeledWindowsByKey[key] = window
        assignPeeledWindowSlotIfNeeded(forKey: key)
    }

    func registerPeeledWindowScene(_ scene: UIWindowScene, for hostedWindow: HostedPeelWindow) {
        objectWillChange.send()

        let key = peeledWindowKey(for: hostedWindow)
        removeSupersededSceneRegistration(sceneID: scene.session.persistentIdentifier, keeping: key)
        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        peeledWindowSceneIDsByKey[key] = scene.session.persistentIdentifier
        peeledWindowsByKey[key] = hostedWindow.window
        assignPeeledWindowSlotIfNeeded(forKey: key)
    }

    private func removeSupersededSceneRegistration(sceneID: String, keeping key: String) {
        // A launcher successor replaces the represented app in the same UI
        // scene. Its old identity must not keep spending a second slot.
        let oldKeys = peeledWindowSceneIDsByKey.compactMap { oldKey, identifier in
            identifier == sceneID && oldKey != key ? oldKey : nil
        }
        for oldKey in oldKeys {
            for (owner, mountedKey) in mountedPeeledWindowKeysByOwner where mountedKey == oldKey {
                mountedPeeledWindowKeysByOwner[owner] = key
            }
            peeledWindowSceneIDsByKey[oldKey] = nil
            pendingPeeledWindowKeys.remove(oldKey)
            pendingPeeledWindowRequestDatesByKey[oldKey] = nil
            peeledWindowsByKey[oldKey] = nil
            releasePeeledWindowSlot(forKey: oldKey)
        }
    }

    func isPeeledWindowOpen(_ window: PeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: window)

        if pendingPeeledWindowKeys.contains(key) {
            return true
        }

        guard let persistentID = peeledWindowSceneIDsByKey[key] else {
            return false
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.session.persistentIdentifier == persistentID }
    }

    func isPeeledWindowOpen(_ hostedWindow: HostedPeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)

        if pendingPeeledWindowKeys.contains(key) {
            return true
        }

        guard let persistentID = peeledWindowSceneIDsByKey[key] else {
            return false
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.session.persistentIdentifier == persistentID }
    }

    func isPeeledWindowSceneForegroundActive(_ hostedWindow: HostedPeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)

        if let existingWindow = peeledWindowsByKey[key],
           !isSameWindowInstance(existingWindow, hostedWindow.window) {
            return false
        }

        guard let persistentID = peeledWindowSceneIDsByKey[key] else {
            return false
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains {
                $0.session.persistentIdentifier == persistentID &&
                    $0.activationState == .foregroundActive
            }
    }

    func cancelPendingPeeledWindowSceneReservation(for hostedWindow: HostedPeelWindow) {
        let key = peeledWindowKey(for: hostedWindow)

        guard pendingPeeledWindowKeys.contains(key),
              peeledWindowSceneIDsByKey[key] == nil,
              let reservedWindow = peeledWindowsByKey[key],
              isSameWindowInstance(reservedWindow, hostedWindow.window) else {
            return
        }

        objectWillChange.send()
        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        peeledWindowsByKey[key] = nil
        releasePeeledWindowSlot(forKey: key)
    }

    func markPeeledWindowSceneClosed(_ scene: UIWindowScene? = nil, for window: PeelWindow) {
        let key = peeledWindowKey(for: window)

        if let scene,
           peeledWindowSceneIDsByKey[key] != scene.session.persistentIdentifier {
            return
        }

        objectWillChange.send()
        let hadPendingReplacement = pendingPeeledWindowKeys.contains(key)
        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        peeledWindowSceneIDsByKey[key] = nil
        if !hadPendingReplacement {
            peeledWindowsByKey[key] = nil
            releasePeeledWindowSlot(forKey: key)
        }
    }

    func markPeeledWindowSceneClosed(_ scene: UIWindowScene? = nil, for hostedWindow: HostedPeelWindow) {
        let key = peeledWindowKey(for: hostedWindow)

        if let scene,
           peeledWindowSceneIDsByKey[key] != scene.session.persistentIdentifier {
            return
        }

        objectWillChange.send()
        let hadPendingReplacement = pendingPeeledWindowKeys.contains(key)
        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        peeledWindowSceneIDsByKey[key] = nil
        if !hadPendingReplacement {
            peeledWindowsByKey[key] = nil
            releasePeeledWindowSlot(forKey: key)
        }
    }

    func hasOpenPeeledWindows() -> Bool {
        openPeeledWindowSceneCount() > 0
    }

    func canOpenAnotherPeeledWindow() -> Bool {
        let count = openPeeledWindowSceneCount()
        return count < maxPeeledWindowSceneCount &&
            (commerceStore?.canOpenAdditionalWindow(openWindowCount: count) ?? (count < 1))
    }

    private func admittedWindowKeys() -> Set<String> {
        pruneClosedPeeledWindowScenes()
        return Set(peeledWindowSceneIDsByKey.keys)
            .union(pendingPeeledWindowKeys)
            .union(mountedPeeledWindowKeysByOwner.values)
            .union(phoneWorkspaceWindowsByOwner.values.reduce(into: Set<String>()) { $0.formUnion($1) })
    }

    func openPeeledWindowSceneCount() -> Int {
        admittedWindowKeys().count
    }

    func openPeeledWindows() -> [PeelWindow] {
        pruneClosedPeeledWindowScenes()

        let keys = Set(peeledWindowSceneIDsByKey.keys)
            .union(pendingPeeledWindowKeys)

        let windows = keys.compactMap { peeledWindowsByKey[$0] }
        return uniqueWindowsById(windows)
            .sorted { $0.windowId < $1.windowId }
    }

    func peeledWindowPlacementSlot(for window: PeelWindow) -> Int {
        let key = peeledWindowKey(for: window)
        return assignPeeledWindowSlotIfNeeded(forKey: key)
    }

    func peeledWindowPlacementSlot(for hostedWindow: HostedPeelWindow) -> Int {
        let key = peeledWindowKey(for: hostedWindow)
        return assignPeeledWindowSlotIfNeeded(forKey: key)
    }

    func consumeNextPendingPeeledWindowPlacementSlot() -> Int? {
        guard !pendingPeeledWindowPlacementSlots.isEmpty else { return nil }
        return pendingPeeledWindowPlacementSlots.removeFirst()
    }

    func registeredPeeledWindowPlacementSlots() -> [Int] {
        pruneClosedPeeledWindowScenes()

        return peeledWindowSceneIDsByKey.keys
            .compactMap { peeledWindowSlotsByKey[$0] }
            .sorted()
    }

    func anchorSlotForPeeledWindowPlacementSlot(_ slot: Int) -> Int? {
        switch slot {
        case 1, 2, 5:
            return 0
        case 3:
            return 1
        case 4:
            return 2
        case 6...:
            let columnCenter = 5 + (((slot - 6) / 3) * 3)
            return columnCenter
        default:
            return nil
        }
    }

    func shouldPlacePeeledWindowSlotTrailing(_ slot: Int) -> Bool {
        slot == 0 || slot == 5 || (slot >= 8 && (slot - 8) % 3 == 0)
    }

    func shouldPlacePeeledWindowSlotLeading(_ slot: Int) -> Bool {
        slot == 3 || slot == 4
    }

    func shouldPlacePeeledWindowSlotAbove(_ slot: Int) -> Bool {
        slot == 1 || (slot >= 6 && (slot - 6) % 3 == 0)
    }

    func shouldPlacePeeledWindowSlotBelow(_ slot: Int) -> Bool {
        slot == 2 || (slot >= 7 && (slot - 7) % 3 == 0)
    }

    private func uniqueWindowsById(_ windows: [PeelWindow]) -> [PeelWindow] {
        var seen = Set<UInt32>()
        var result: [PeelWindow] = []

        for window in windows where seen.insert(window.windowId).inserted {
            result.append(window)
        }

        return result
    }

    @discardableResult
    private func assignPeeledWindowSlotIfNeeded(forKey key: String) -> Int {
        if let existingSlot = peeledWindowSlotsByKey[key] {
            return existingSlot
        }

        var slot = 0
        while peeledWindowKeysBySlot[slot] != nil {
            slot += 1
        }

        peeledWindowSlotsByKey[key] = slot
        peeledWindowKeysBySlot[slot] = key
        return slot
    }

    private func releasePeeledWindowSlot(forKey key: String) {
        guard let slot = peeledWindowSlotsByKey[key] else { return }

        peeledWindowSlotsByKey[key] = nil

        if peeledWindowKeysBySlot[slot] == key {
            peeledWindowKeysBySlot[slot] = nil
        }

        pendingPeeledWindowPlacementSlots.removeAll { $0 == slot }
    }

    private func pruneStalePendingPeeledWindowRequests() {
        let now = Date()
        let mountedKeys = Set(mountedPeeledWindowKeysByOwner.values)
        let stalePending = pendingPeeledWindowRequestDatesByKey.compactMap { key, date in
            peeledWindowSceneIDsByKey[key] == nil && !mountedKeys.contains(key) &&
                now.timeIntervalSince(date) >= 4 ? key : nil
        }
        for key in stalePending {
            pendingPeeledWindowKeys.remove(key)
            pendingPeeledWindowRequestDatesByKey[key] = nil
            peeledWindowsByKey[key] = nil
            releasePeeledWindowSlot(forKey: key)
        }
        if !stalePending.isEmpty { objectWillChange.send() }
    }

    private func pruneClosedPeeledWindowScenes() {
        pruneStalePendingPeeledWindowRequests()
        let liveSceneIDs = Set(
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.session.persistentIdentifier }
        )

        let staleKeys = peeledWindowSceneIDsByKey.compactMap { key, sceneID in
            liveSceneIDs.contains(sceneID) ? nil : key
        }

        guard !staleKeys.isEmpty else { return }

        objectWillChange.send()

        for key in staleKeys {
            peeledWindowSceneIDsByKey[key] = nil

            if !pendingPeeledWindowKeys.contains(key) {
                peeledWindowsByKey[key] = nil
                releasePeeledWindowSlot(forKey: key)
            }
        }
    }

    func shouldRestoreMainAfterPeeledWindowClosed() -> Bool {
        guard openPeeledWindowSceneCount() < minimumPeeledWindowCountBeforeMainMayStayClosed else {
            return false
        }

        return canRequestMainSceneRestore()
    }

    func shouldRestoreMainAfterMainSceneClosed() -> Bool {
        // Temporarily allow users to close ContentView without immediately restoring it.
        // Re-enable the previous behavior by restoring the peeled-window count gate below.
        /*
        guard openPeeledWindowSceneCount() < minimumPeeledWindowCountBeforeMainMayStayClosed else {
            return false
        }

        return canRequestMainSceneRestore()
        */
        return false
    }

    func shouldRestoreMainWhenAppBecomesActive() -> Bool {
        // Do not resurrect ContentView while the user is actively working in peeled windows.
        // This keeps the launcher from popping back into focus over the user's current gaze target.
        guard !hasOpenPeeledWindows() else { return false }

        return canRequestMainSceneRestore()
    }

    func noteAppScenePhaseChanged(_ phase: ScenePhase) {
        guard phase != .active else { return }

        // A pending openWindow request while the app is backgrounding can get dropped.
        // Clear the gate so foreground/relaunch can request main again.
        isOpeningMainScene = false
        lastMainOpenRequestDate = nil

        // This should be one-shot per activation, not one-shot for the entire process.
        didRunInitialAuxiliarySceneMainRestore = false
    }

    func shouldPresentMainSceneFromUserAction() -> Bool {
        pruneClosedPeeledWindowScenes()

        // The iPad main scene is a WindowGroup, so opening it while a registered
        // main scene already exists can create a duplicate ContentView.
        if resolveMainScene() != nil {
            isOpeningMainScene = false
            return false
        }

        return canRequestMainSceneRestore()
    }

    func shouldRestoreMainAfterInitialAuxiliarySceneAppears() -> Bool {
        guard !didRunInitialAuxiliarySceneMainRestore else { return false }
        didRunInitialAuxiliarySceneMainRestore = true

        // Auxiliary scenes include peeled windows. If the user intentionally has a peeled
        // window open, do not bring the launcher back unless there are no peeled windows left.
        guard !hasOpenPeeledWindows() else { return false }

        return canRequestMainSceneRestore()
    }

    func activatePeeledWindowIfPossible(for window: PeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: window)

        if pendingPeeledWindowKeys.contains(key) {
            return true
        }

        guard let persistentID = peeledWindowSceneIDsByKey[key] else {
            return false
        }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            objectWillChange.send()
            peeledWindowSceneIDsByKey[key] = nil
            releasePeeledWindowSlot(forKey: key)
            return false
        }

        UIApplication.shared.requestSceneSessionActivation(
            windowScene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.markPeeledWindowSceneClosed(for: window)
                }
            }
        )
        return true
    }

    func activatePeeledWindowIfPossible(
        for hostedWindow: HostedPeelWindow,
        onFailure: ((Error) -> Void)? = nil
    ) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)

        if let existingWindow = peeledWindowsByKey[key],
           !isSameWindowInstance(existingWindow, hostedWindow.window) {
            return false
        }

        if pendingPeeledWindowKeys.contains(key) {
            return true
        }

        guard let persistentID = peeledWindowSceneIDsByKey[key] else {
            return false
        }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            objectWillChange.send()
            peeledWindowSceneIDsByKey[key] = nil
            releasePeeledWindowSlot(forKey: key)
            return false
        }

        UIApplication.shared.requestSceneSessionActivation(
            windowScene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.markPeeledWindowSceneClosed(for: hostedWindow)
                    onFailure?(error)
                }
            }
        )
        return true
    }

    private func isSameWindowInstance(_ expected: PeelWindow, _ current: PeelWindow) -> Bool {
        guard expected.appName == current.appName,
              expected.title == current.title else { return false }

        switch (expected.appLaunchTimeIntervalSince1970, current.appLaunchTimeIntervalSince1970) {
        case let (expectedLaunch?, currentLaunch?):
            return abs(expectedLaunch - currentLaunch) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    func canRequestMainSceneRestore() -> Bool {
        pruneClosedPeeledWindowScenes()

        if resolveMainScene() != nil {
            isOpeningMainScene = false
            return false
        }

        let now = Date()

        if isOpeningMainScene {
            guard let lastMainOpenRequestDate else {
                return false
            }

            // Do not issue another Window(id: "main") request while SwiftUI may still
            // be connecting the previous one. Re-requesting the same scene id during
            // that window can trigger SwiftUI's fatal duplicate-window assertion.
            guard now.timeIntervalSince(lastMainOpenRequestDate) >= staleMainOpenRequestInterval else {
                return false
            }

            // The pending request appears stale. Clear it, but only after the longer
            // stale interval and after checking for an already-connected main scene.
            isOpeningMainScene = false
        }

        if let lastMainOpenRequestDate,
           now.timeIntervalSince(lastMainOpenRequestDate) < duplicateMainOpenSuppressionInterval {
            return false
        }

        isOpeningMainScene = true
        lastMainOpenRequestDate = now
        return true
    }

    func markMainSceneOpenRequested() {
        isOpeningMainScene = true
        lastMainOpenRequestDate = Date()
    }

    func cancelPendingMainSceneOpen() {
        isOpeningMainScene = false
    }

    func activateMainIfPossible() -> Bool {
        guard let windowScene = resolveMainScene() else {
            mainScene = nil
            mainPersistentID = nil
            return false
        }

        mainScene = windowScene
        mainPersistentID = windowScene.session.persistentIdentifier
        isOpeningMainScene = false

        UIApplication.shared.requestSceneSessionActivation(
            windowScene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.cancelPendingMainSceneOpen()
                }
            }
        )
        return true
    }

    private func resolveMainScene() -> UIWindowScene? {
        if let mainScene,
           UIApplication.shared.connectedScenes.contains(where: { $0.session.persistentIdentifier == mainScene.session.persistentIdentifier }) {
            return mainScene
        }

        guard let id = mainPersistentID else {
            // Reuse a positively registered connected Home instead of spawning another.
            guard enforcesSingleMainScene,
                  let candidate = connectedRegisteredMainSceneCandidate() else { return nil }
            mainScene = candidate
            mainPersistentID = candidate.session.persistentIdentifier
            return candidate
        }

        let resolvedScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.session.persistentIdentifier == id })

        if resolvedScene == nil {
            mainScene = nil
            mainPersistentID = nil
            registeredMainSceneIDs.remove(id)
            // The keeper disconnected; fall back to another registered Home, if any.
            return enforcesSingleMainScene ? resolveMainScene() : nil
        }

        return resolvedScene
    }
    
    @discardableResult
    func closePeeledWindowScene(for window: PeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: window)

        guard let persistentID = peeledWindowSceneIDsByKey[key],
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            markPeeledWindowSceneClosed(for: window)
            return false
        }

        markPeeledWindowSceneClosed(windowScene, for: window)

        UIApplication.shared.requestSceneSessionDestruction(
            windowScene.session,
            options: nil,
            errorHandler: { error in
    #if DEBUG
                print("Failed to close peeled window scene for \(window.windowId): \(error)")
    #endif
            }
        )

        return true
    }

    @discardableResult
    func closePeeledWindowScene(for hostedWindow: HostedPeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)

        guard let persistentID = peeledWindowSceneIDsByKey[key],
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            markPeeledWindowSceneClosed(for: hostedWindow)
            return false
        }

        markPeeledWindowSceneClosed(windowScene, for: hostedWindow)

        UIApplication.shared.requestSceneSessionDestruction(
            windowScene.session,
            options: nil,
            errorHandler: { error in
    #if DEBUG
                print("Failed to close peeled window scene for \(hostedWindow.window.windowId): \(error)")
    #endif
            }
        )

        return true
    }

    // (resolveConnectedMainSceneCandidate removed)
}

struct MainWindowActivationRestorer: View {
    @ObservedObject var scenes: SceneCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                restoreMainAfterInitialAuxiliarySceneAppearsIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                scenes.noteAppScenePhaseChanged(newPhase)

                guard newPhase == .active else { return }
                restoreMainAfterActivationIfNeeded()
            }
    }

    private func restoreMainAfterActivationIfNeeded() {
#if os(visionOS)
        Task { @MainActor in
            await Task.yield()
            if scenes.shouldRestoreMainWhenAppBecomesActive() {
                openWindow(id: "main")
            }
        }
#endif
    }

    private func restoreMainAfterInitialAuxiliarySceneAppearsIfNeeded() {
#if os(visionOS)
        Task { @MainActor in
            await Task.yield()
            if scenes.shouldRestoreMainAfterInitialAuxiliarySceneAppears() {
                openWindow(id: "main")
            }
        }
#endif
    }
}

struct WindowSceneReader: UIViewRepresentable {
    let onResolve: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Defer one runloop so uiView.window is populated.
        DispatchQueue.main.async {
            if let scene = uiView.window?.windowScene {
                onResolve(scene)
            }
        }
    }
}
