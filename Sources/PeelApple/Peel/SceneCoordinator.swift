//
//  SceneCoordinator.swift
//  Peel
//
//  Created by Zach on 1/19/26.
//

import SwiftUI
import UIKit
import Combine

enum PeeledWindowPlacementMode: Equatable {
    case trailingCascade
    case balancedSlots
}

enum PeeledWindowSceneMode: Hashable {
    case locked
    case resizable
}

enum PeelImmersiveLaunchContext: Equatable {
    case hudEnvironment
    case regular
}

@MainActor
final class SceneCoordinator: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    private weak var commerceStore: PeelStore?

    func configureCommerce(_ store: PeelStore) {
        commerceStore = store
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
    private var peeledWindowSceneIDsByKeyAndMode: [String: [PeeledWindowSceneMode: String]] = [:]
    private var pendingPeeledWindowKeys: Set<String> = []
    private var peeledWindowsByKey: [String: HostedPeelWindow] = [:]
    private var peeledWindowSlotsByKey: [String: Int] = [:]
    private var peeledWindowKeysBySlot: [Int: String] = [:]
    private var pendingPeeledWindowPlacementSlots: [Int] = []
    private var pendingPeeledWindowRequestDatesByKey: [String: Date] = [:]
    private var explicitlyClosedPeeledWindowKeys: Set<String> = []
    private let stalePeeledWindowOpenRequestInterval: TimeInterval = 4.0

    var peeledWindowPlacementMode: PeeledWindowPlacementMode = .balancedSlots {
        didSet {
            guard oldValue != peeledWindowPlacementMode else { return }
            objectWillChange.send()
        }
    }

    private(set) var peelImmersiveWindows: [PeelWindow] = []
    private(set) var peelImmersivePrimaryWindowId: UInt32? = nil
    private(set) var peelImmersiveHostedWindows: [HostedPeelWindow] = []
    private(set) var peelImmersivePrimaryWindowInstanceID: PeelWindowInstanceID? = nil
    private(set) var isPeelImmersiveSpaceOpen: Bool = false
    private(set) var peelImmersiveLaunchContext: PeelImmersiveLaunchContext? = nil
    private(set) var immersiveFieldOffsetX: Float = 0
    private(set) var immersiveFieldOffsetY: Float = 0
    private(set) var immersiveFieldScale: Float = 1.0
    private(set) var immersiveFieldDistance: Float = 1.65
    private(set) var immersiveFieldArc: Float = 0.0
    private(set) var immersiveFieldOpacity: Float = 1.0
    private var lastMainOpenRequestDate: Date?
    private let duplicateMainOpenSuppressionInterval: TimeInterval = 0.75
    private let staleMainOpenRequestInterval: TimeInterval = 4.0
    private let minimumPeeledWindowCountBeforeMainMayStayClosed = 2
    let maxPeeledWindowSceneCount = 12
    private var didRunInitialAuxiliarySceneMainRestore = false

    func registerMainScene(_ scene: UIWindowScene) {
        mainScene = scene
        mainPersistentID = scene.session.persistentIdentifier
        isOpeningMainScene = false
    }

    func markMainSceneClosed(_ scene: UIWindowScene? = nil) {
        if let scene {
            guard mainPersistentID == scene.session.persistentIdentifier else { return }
        }

        mainScene = nil
        mainPersistentID = nil
        isOpeningMainScene = false
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

    func peeledWindowKey(hostKey: PeelHostKey, windowId: UInt32) -> String {
        PeelWindowInstanceID(hostKey: hostKey, windowId: windowId).id
    }

    private func legacyHostedWindow(for window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: PeelHostKey(rawValue: "legacy"),
            hostName: "Mac",
            window: window
        )
    }

    @discardableResult
    func reservePeeledWindowScene(for window: PeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        guard admittedWindowKeys().contains(peeledWindowKey(for: window)) || canOpenAnotherPeeledWindow() else { return false }

        let key = peeledWindowKey(for: window)
        let slot = assignPeeledWindowSlotIfNeeded(forKey: key)

        explicitlyClosedPeeledWindowKeys.remove(key)
        peeledWindowsByKey[key] = legacyHostedWindow(for: window)

        if !pendingPeeledWindowPlacementSlots.contains(slot) {
            pendingPeeledWindowPlacementSlots.append(slot)
        }

        pendingPeeledWindowKeys.insert(key)
        pendingPeeledWindowRequestDatesByKey[key] = Date()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func reservePeeledWindowScene(for hostedWindow: HostedPeelWindow) -> Bool {
        reservePeeledWindowScene(for: hostedWindow, mode: .locked)
    }

    @discardableResult
    func reservePeeledWindowScene(for hostedWindow: HostedPeelWindow, mode: PeeledWindowSceneMode) -> Bool {
        pruneClosedPeeledWindowScenes()

        guard admittedWindowKeys().contains(peeledWindowKey(for: hostedWindow)) || canOpenAnotherPeeledWindow() else { return false }

        let key = peeledWindowKey(for: hostedWindow)
        let slot = assignPeeledWindowSlotIfNeeded(forKey: key)

        explicitlyClosedPeeledWindowKeys.remove(key)
        peeledWindowsByKey[key] = hostedWindow

        if !pendingPeeledWindowPlacementSlots.contains(slot) {
            pendingPeeledWindowPlacementSlots.append(slot)
        }

        pendingPeeledWindowKeys.insert(key)
        pendingPeeledWindowRequestDatesByKey[key] = Date()
        objectWillChange.send()
        return true
    }

    func cancelPendingPeeledWindowSceneReservation(for hostedWindow: HostedPeelWindow) {
        let key = peeledWindowKey(for: hostedWindow)
        guard pendingPeeledWindowKeys.contains(key), peeledWindowSceneIDsByKey[key] == nil,
              let reserved = peeledWindowsByKey[key],
              reserved.window == hostedWindow.window else { return }
        forgetPeeledWindow(forKey: key)
        objectWillChange.send()
    }

    func registerPeeledWindowScene(_ scene: UIWindowScene, for window: PeelWindow) {
        let key = peeledWindowKey(for: window)
        removeSupersededSceneRegistration(sceneID: scene.session.persistentIdentifier, keeping: key)

        guard !explicitlyClosedPeeledWindowKeys.contains(key) else {
            forgetPeeledWindow(forKey: key)
            requestPeeledWindowSceneDestruction(scene, windowID: window.windowId)
            objectWillChange.send()
            return
        }

        let slot = assignPeeledWindowSlotIfNeeded(forKey: key)

        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        pendingPeeledWindowPlacementSlots.removeAll { $0 == slot }
        peeledWindowSceneIDsByKey[key] = scene.session.persistentIdentifier
        peeledWindowsByKey[key] = legacyHostedWindow(for: window)
        objectWillChange.send()
    }

    func registerPeeledWindowScene(_ scene: UIWindowScene, for hostedWindow: HostedPeelWindow) {
        registerPeeledWindowScene(scene, for: hostedWindow, mode: .locked)
    }

    func registerPeeledWindowScene(_ scene: UIWindowScene, for hostedWindow: HostedPeelWindow, mode: PeeledWindowSceneMode) {
        let key = peeledWindowKey(for: hostedWindow)
        removeSupersededSceneRegistration(sceneID: scene.session.persistentIdentifier, keeping: key)

        guard !explicitlyClosedPeeledWindowKeys.contains(key) else {
            forgetPeeledWindow(forKey: key)
            requestPeeledWindowSceneDestruction(scene, windowID: hostedWindow.window.windowId)
            objectWillChange.send()
            return
        }

        let slot = assignPeeledWindowSlotIfNeeded(forKey: key)

        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        pendingPeeledWindowPlacementSlots.removeAll { $0 == slot }
        peeledWindowSceneIDsByKey[key] = scene.session.persistentIdentifier
        var sceneIDsByMode = peeledWindowSceneIDsByKeyAndMode[key] ?? [:]
        sceneIDsByMode[mode] = scene.session.persistentIdentifier
        peeledWindowSceneIDsByKeyAndMode[key] = sceneIDsByMode
        peeledWindowsByKey[key] = hostedWindow
        objectWillChange.send()
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
            forgetPeeledWindow(forKey: oldKey)
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
        isPeeledWindowOpen(hostedWindow, mode: .locked)
    }

    func isPeeledWindowOpen(_ hostedWindow: HostedPeelWindow, mode: PeeledWindowSceneMode) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)

        if pendingPeeledWindowKeys.contains(key) {
            return true
        }

        guard let persistentID = peeledWindowSceneIDsByKeyAndMode[key]?[mode] ?? peeledWindowSceneIDsByKey[key] else {
            return false
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.session.persistentIdentifier == persistentID }
    }

    func markPeeledWindowSceneClosed(_ scene: UIWindowScene? = nil, for window: PeelWindow) {
        let key = peeledWindowKey(for: window)

        if let scene,
           peeledWindowSceneIDsByKey[key] != scene.session.persistentIdentifier {
            return
        }

        let hadPendingReplacement = pendingPeeledWindowKeys.contains(key)

        if hadPendingReplacement {
            pendingPeeledWindowKeys.remove(key)
            pendingPeeledWindowRequestDatesByKey[key] = nil
            peeledWindowSceneIDsByKey[key] = nil
        } else {
            explicitlyClosedPeeledWindowKeys.insert(key)
            forgetPeeledWindow(forKey: key)
        }

        objectWillChange.send()
    }

    func markPeeledWindowSceneClosed(_ scene: UIWindowScene? = nil, for hostedWindow: HostedPeelWindow) {
        let key = peeledWindowKey(for: hostedWindow)

        if let scene,
           peeledWindowSceneIDsByKey[key] != scene.session.persistentIdentifier {
            return
        }

        let hadPendingReplacement = pendingPeeledWindowKeys.contains(key)

        if hadPendingReplacement {
            pendingPeeledWindowKeys.remove(key)
            pendingPeeledWindowRequestDatesByKey[key] = nil
            peeledWindowSceneIDsByKey[key] = nil
        } else {
            explicitlyClosedPeeledWindowKeys.insert(key)
            forgetPeeledWindow(forKey: key)
        }

        objectWillChange.send()
    }

    func hasOpenPeeledWindows() -> Bool {
        openPeeledWindowSceneCount() > 0
    }

    func canOpenAnotherPeeledWindow() -> Bool {
        let count = openPeeledWindowSceneCount()
        return count < maxPeeledWindowSceneCount &&
            (commerceStore?.canOpenAdditionalWindow(openWindowCount: count) ?? (count < 2))
    }

    private func admittedWindowKeys() -> Set<String> {
        pruneClosedPeeledWindowScenes()
        return Set(peeledWindowSceneIDsByKey.keys)
            .union(pendingPeeledWindowKeys)
            .union(mountedPeeledWindowKeysByOwner.values)
            .union(peelImmersiveHostedWindows.map(\.id))
    }

    func openPeeledWindowSceneCount() -> Int {
        admittedWindowKeys().count
    }

    func openPeeledWindows() -> [PeelWindow] {
        openHostedPeeledWindows().map(\.window)
    }

    func openHostedPeeledWindows() -> [HostedPeelWindow] {
        pruneClosedPeeledWindowScenes()

        let keys = Set(peeledWindowSceneIDsByKey.keys)
            .union(pendingPeeledWindowKeys)

        let hostedWindows = keys.compactMap { peeledWindowsByKey[$0] }
        return uniqueHostedWindowsByInstanceId(hostedWindows)
            .sorted {
                if $0.hostName != $1.hostName {
                    return $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending
                }

                return $0.window.windowId < $1.window.windowId
            }
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

    func setImmersiveFieldOffsetX(_ value: Float) {
        let clamped = min(1.0, max(-1.0, value))
        guard immersiveFieldOffsetX != clamped else { return }
        immersiveFieldOffsetX = clamped
        objectWillChange.send()
    }

    func setImmersiveFieldOffsetY(_ value: Float) {
        let clamped = min(1.0, max(-1.0, value))
        guard immersiveFieldOffsetY != clamped else { return }
        immersiveFieldOffsetY = clamped
        objectWillChange.send()
    }

    func setImmersiveFieldScale(_ value: Float) {
        let clamped = min(3.0, max(0.5, value))
        guard immersiveFieldScale != clamped else { return }
        immersiveFieldScale = clamped
        objectWillChange.send()
    }

    func setImmersiveFieldDistance(_ value: Float) {
        let clamped = min(3.0, max(1.0, value))
        guard immersiveFieldDistance != clamped else { return }
        immersiveFieldDistance = clamped
        objectWillChange.send()
    }

    func setImmersiveFieldArc(_ value: Float) {
        let clamped = min(1.0, max(0.0, value))
        guard immersiveFieldArc != clamped else { return }
        immersiveFieldArc = clamped
        objectWillChange.send()
    }

    func setImmersiveFieldOpacity(_ value: Float) {
        let clamped = min(1.0, max(0.2, value))
        guard immersiveFieldOpacity != clamped else { return }
        immersiveFieldOpacity = clamped
        objectWillChange.send()
    }

    func resetImmersiveFieldControls() {
        immersiveFieldOffsetX = 0
        immersiveFieldOffsetY = 0
        immersiveFieldScale = 1.0
        immersiveFieldDistance = 1.65
        immersiveFieldArc = 0.0
        immersiveFieldOpacity = 1.0
        objectWillChange.send()
    }

    @discardableResult
    func preparePeelImmersiveSpace(primary: PeelWindow, windows: [PeelWindow]) -> Bool {
        objectWillChange.send()

        let merged = uniqueWindowsById([primary] + windows + openPeeledWindows())
        let openHostedWindows = openHostedPeeledWindows()
        let primaryHostedWindow = openHostedWindows.first { $0.window.windowId == primary.windowId } ?? legacyHostedWindow(for: primary)
        let hostedMerged = uniqueHostedWindowsByInstanceId(
            merged.map { window in
                openHostedWindows.first { $0.window.windowId == window.windowId } ?? legacyHostedWindow(for: window)
            }
        )

        guard canAdmitImmersiveWindows(hostedMerged) else { return false }
        peelImmersivePrimaryWindowId = primary.windowId
        peelImmersivePrimaryWindowInstanceID = primaryHostedWindow.instanceID
        peelImmersiveWindows = merged
        peelImmersiveHostedWindows = hostedMerged
        return true
    }

    @discardableResult
    func preparePeelImmersiveSpace(primary: HostedPeelWindow, windows: [HostedPeelWindow]) -> Bool {
        objectWillChange.send()

        let merged = uniqueHostedWindowsByInstanceId([primary] + windows + openHostedPeeledWindows())

        guard canAdmitImmersiveWindows(merged) else { return false }
        peelImmersivePrimaryWindowId = primary.window.windowId
        peelImmersivePrimaryWindowInstanceID = primary.instanceID
        peelImmersiveWindows = merged.map(\.window)
        peelImmersiveHostedWindows = merged
        return true
    }

    private func canAdmitImmersiveWindows(_ windows: [HostedPeelWindow]) -> Bool {
        pruneClosedPeeledWindowScenes()
        return PeelWindowAdmissionPolicy.allowsUpdate(
            otherWindows: Set(peeledWindowSceneIDsByKey.keys).union(pendingPeeledWindowKeys)
                .union(mountedPeeledWindowKeysByOwner.values),
            previousWindows: Set(peelImmersiveHostedWindows.map(\.id)),
            requestedWindows: Set(windows.map(\.id)),
            freeLimit: commerceStore?.freeWindowLimit ?? 2,
            hasProAccess: commerceStore?.hasProAccess ?? false,
            resourceLimit: maxPeeledWindowSceneCount
        )
    }

    func setPeelImmersivePrimaryWindow(_ window: PeelWindow) {
        objectWillChange.send()
        let hostedWindow = openHostedPeeledWindows().first { $0.window.windowId == window.windowId } ?? legacyHostedWindow(for: window)

        guard admittedWindowKeys().contains(hostedWindow.id) || canOpenAnotherPeeledWindow() else { return }
        peelImmersivePrimaryWindowId = window.windowId
        peelImmersivePrimaryWindowInstanceID = hostedWindow.instanceID

        if !peelImmersiveWindows.contains(where: { $0.windowId == window.windowId }) {
            peelImmersiveWindows.insert(window, at: 0)
        }

        if !peelImmersiveHostedWindows.contains(where: { $0.id == hostedWindow.id }) {
            peelImmersiveHostedWindows.insert(hostedWindow, at: 0)
        }
    }

    func setPeelImmersivePrimaryWindow(_ hostedWindow: HostedPeelWindow) {
        guard admittedWindowKeys().contains(hostedWindow.id) || canOpenAnotherPeeledWindow() else { return }
        objectWillChange.send()
        peelImmersivePrimaryWindowId = hostedWindow.window.windowId
        peelImmersivePrimaryWindowInstanceID = hostedWindow.instanceID

        if !peelImmersiveHostedWindows.contains(where: { $0.id == hostedWindow.id }) {
            peelImmersiveHostedWindows.insert(hostedWindow, at: 0)
        }

        if !peelImmersiveWindows.contains(where: { $0.windowId == hostedWindow.window.windowId }) {
            peelImmersiveWindows.insert(hostedWindow.window, at: 0)
        }
    }

    func markPeelImmersiveSpaceOpen() {
        objectWillChange.send()
        isPeelImmersiveSpaceOpen = true
    }

    func preparePeelImmersiveLaunch(context: PeelImmersiveLaunchContext) {
        peelImmersiveLaunchContext = context
    }

    func markPeelImmersiveSpaceClosed() {
        objectWillChange.send()
        isPeelImmersiveSpaceOpen = false
        peelImmersiveLaunchContext = nil
        peelImmersiveWindows.removeAll()
        peelImmersiveHostedWindows.removeAll()
        peelImmersivePrimaryWindowId = nil
        peelImmersivePrimaryWindowInstanceID = nil
    }

    private func uniqueWindowsById(_ windows: [PeelWindow]) -> [PeelWindow] {
        var seen = Set<UInt32>()
        var result: [PeelWindow] = []

        for window in windows where seen.insert(window.windowId).inserted {
            result.append(window)
        }

        return result
    }

    private func uniqueHostedWindowsByInstanceId(_ hostedWindows: [HostedPeelWindow]) -> [HostedPeelWindow] {
        var seen = Set<String>()
        var result: [HostedPeelWindow] = []

        for hostedWindow in hostedWindows where seen.insert(hostedWindow.id).inserted {
            result.append(hostedWindow)
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

    private func forgetPeeledWindow(forKey key: String) {
        pendingPeeledWindowKeys.remove(key)
        pendingPeeledWindowRequestDatesByKey[key] = nil
        peeledWindowSceneIDsByKey[key] = nil
        peeledWindowSceneIDsByKeyAndMode[key] = nil
        peeledWindowsByKey[key] = nil
        releasePeeledWindowSlot(forKey: key)
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
        var staleKeys: [String] = []

        for (key, requestDate) in pendingPeeledWindowRequestDatesByKey {
            guard peeledWindowSceneIDsByKey[key] == nil,
                  !mountedPeeledWindowKeysByOwner.values.contains(key) else {
                continue
            }

            if now.timeIntervalSince(requestDate) >= stalePeeledWindowOpenRequestInterval {
                staleKeys.append(key)
            }
        }

        guard !staleKeys.isEmpty else { return }

        for key in staleKeys {
            forgetPeeledWindow(forKey: key)
        }

        objectWillChange.send()
    }

    private func requestPeeledWindowSceneDestruction(_ scene: UIWindowScene, windowID: UInt32) {
        UIApplication.shared.requestSceneSessionDestruction(
            scene.session,
            options: nil,
            errorHandler: { error in
    #if DEBUG
                print("Failed to close peeled window scene for \(windowID): \(error)")
    #endif
            }
        )
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
            peeledWindowSceneIDsByKeyAndMode[key] = nil

            if !pendingPeeledWindowKeys.contains(key) {
                peeledWindowsByKey[key] = nil
                releasePeeledWindowSlot(forKey: key)
            }
        }
    }

    func shouldRestoreMainAfterPeeledWindowClosed() -> Bool {
        // Launch-safe policy: closing a peeled window should never passively summon
        // the main Peel menu. Users can always bring it back with the Peel button
        // or by relaunching Peel from the system.
        return false
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
        // Launch-safe policy: scene activation is passive. Do not resurrect the
        // main Peel menu just because an auxiliary scene became active again.
        return false
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

        // For explicit user action, allow openWindow(id: "main") even if the
        // coordinator already knows main exists. On visionOS this is more reliable
        // than relying only on requestSceneSessionActivation.
        if resolveMainScene() != nil {
            isOpeningMainScene = false
            return true
        }

        return canRequestMainSceneRestore()
    }

    func shouldRestoreMainAfterInitialAuxiliarySceneAppears() -> Bool {
        // Launch-safe policy: auxiliary scenes, including peeled windows and trackpad,
        // must not passively summon the main Peel menu. Explicit user action still
        // uses shouldPresentMainSceneFromUserAction().
        didRunInitialAuxiliarySceneMainRestore = true
        return false
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
            forgetPeeledWindow(forKey: key)
            objectWillChange.send()
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

    func activatePeeledWindowIfPossible(for hostedWindow: HostedPeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)

        if pendingPeeledWindowKeys.contains(key) {
            return true
        }

        guard let persistentID = peeledWindowSceneIDsByKey[key] else {
            return false
        }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            forgetPeeledWindow(forKey: key)
            objectWillChange.send()
            return false
        }

        UIApplication.shared.requestSceneSessionActivation(
            windowScene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.markPeeledWindowSceneClosed(for: hostedWindow)
                }
            }
        )
        return true
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

        guard let id = mainPersistentID else { return nil }

        let resolvedScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.session.persistentIdentifier == id })

        if resolvedScene == nil {
            mainScene = nil
            mainPersistentID = nil
        }

        return resolvedScene
    }
    
    @discardableResult
    func closePeeledWindowScene(for window: PeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: window)
        explicitlyClosedPeeledWindowKeys.insert(key)

        guard let persistentID = peeledWindowSceneIDsByKey[key],
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            forgetPeeledWindow(forKey: key)
            objectWillChange.send()
            return false
        }

        forgetPeeledWindow(forKey: key)
        objectWillChange.send()
        requestPeeledWindowSceneDestruction(windowScene, windowID: window.windowId)

        return true
    }

    @discardableResult
    func closePeeledWindowScene(for hostedWindow: HostedPeelWindow) -> Bool {
        pruneClosedPeeledWindowScenes()

        let key = peeledWindowKey(for: hostedWindow)
        explicitlyClosedPeeledWindowKeys.insert(key)

        guard let persistentID = peeledWindowSceneIDsByKey[key],
              let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.session.persistentIdentifier == persistentID }) else {
            forgetPeeledWindow(forKey: key)
            objectWillChange.send()
            return false
        }

        forgetPeeledWindow(forKey: key)
        objectWillChange.send()
        requestPeeledWindowSceneDestruction(windowScene, windowID: hostedWindow.window.windowId)

        return true
    }

    // (resolveConnectedMainSceneCandidate removed)
}

struct MainWindowActivationRestorer: View {
    @ObservedObject var scenes: SceneCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: scenePhase) { _, newPhase in
                scenes.noteAppScenePhaseChanged(newPhase)
            }
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
