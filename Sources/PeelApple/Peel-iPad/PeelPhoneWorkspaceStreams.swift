import Foundation
import Combine

/// UI ownership across phone scenes. The transport still owns streaming; this
/// coordinator only prevents one displayed workspace from releasing another
/// workspace's desired stream on the same authenticated session.
@MainActor
final class PeelPhoneWorkspaceStreams: ObservableObject {
    static let shared = PeelPhoneWorkspaceStreams()
    nonisolated let objectWillChange = ObservableObjectPublisher()

    private struct SessionOwners {
        let session: PeelHostSession
        var windowsByOwner: [UUID: [UInt32: PeelWindow]] = [:]
        var ownedWindows: [UInt32: PeelWindow] = [:]
        var inputEligibleOwners: Set<UUID> = []
        var selectedWindowByOwner: [UUID: UInt32] = [:]
    }

    private var sessions: [ObjectIdentifier: SessionOwners] = [:]
    private var pointerOwners: [ObjectIdentifier: (workspace: UUID, interaction: UUID)] = [:]
    private var inputOwners: [ObjectIdentifier: UUID] = [:]

    func update(
        owner: UUID,
        session: PeelHostSession,
        windows: [UInt32: PeelWindow],
        selectedWindowID: UInt32?,
        canRestoreActiveSelection: Bool
    ) {
        let key = ObjectIdentifier(session)
        var entry = sessions[key] ?? SessionOwners(session: session)
        if windows.isEmpty {
            entry.windowsByOwner.removeValue(forKey: owner)
            entry.inputEligibleOwners.remove(owner)
            entry.selectedWindowByOwner.removeValue(forKey: owner)
        } else {
            entry.windowsByOwner[owner] = windows
            entry.selectedWindowByOwner[owner] = selectedWindowID.flatMap { windows[$0] == nil ? nil : $0 }
            if canRestoreActiveSelection { entry.inputEligibleOwners.insert(owner) }
            else { entry.inputEligibleOwners.remove(owner) }
        }
        let currentOwner = inputOwners[key]
        if currentOwner == nil || entry.windowsByOwner[currentOwner!] == nil {
            let replacement = canRestoreActiveSelection && !windows.isEmpty ? owner :
                entry.inputEligibleOwners.sorted(by: { $0.uuidString < $1.uuidString }).first
            setInputOwner(replacement, session: session)
        } else if !entry.inputEligibleOwners.contains(currentOwner!), canRestoreActiveSelection, !windows.isEmpty {
            setInputOwner(owner, session: session)
        }

        var desired: [UInt32: PeelWindow] = [:]
        for ownerWindows in entry.windowsByOwner.values {
            for saved in ownerWindows.values {
                guard let current = session.windows.first(where: { $0.windowId == saved.windowId }),
                      PeelPhoneWorkspaceWindowIdentity(saved).isSameLifetime(as: PeelPhoneWorkspaceWindowIdentity(current)),
                      session.currentWindowInstanceMatches(current) else { continue }
                desired[current.windowId] = current
            }
        }
        let actualOwned = Set(entry.ownedWindows.keys).intersection(session.desiredPullWindowIds)
        let transition = PeelPhoneWorkspaceLayout.streamTransition(current: actualOwned, desired: Set(desired.keys))
        for id in transition.stop {
            if let window = entry.ownedWindows[id] { session.endPullStream(for: window) }
        }

        if let inputOwner = inputOwners[key], entry.inputEligibleOwners.contains(inputOwner),
           let selectedID = entry.selectedWindowByOwner[inputOwner], desired[selectedID] != nil,
           session.activeWindowId == nil || currentOwner != inputOwner {
            // A remaining scene inherits input when its sibling closes or loses
            // eligibility. Restore that scene's selection before accepting keys.
            session.setActiveWindow(selectedID)
        }
        // A new/recovered scene's key-window callback arrives after mounting.
        // Wait for it before beginPullStream can choose an arbitrary target.
        if session.activeWindowId != nil {
            for id in transition.start.sorted() {
                if let window = desired[id] { session.beginPullStream(for: window) }
            }
        }
        entry.ownedWindows = desired.filter { session.desiredPullWindowIds.contains($0.key) }
        if entry.windowsByOwner.isEmpty {
            sessions.removeValue(forKey: key)
            setInputOwner(nil, session: session)
        } else {
            sessions[key] = entry
        }
    }

    func release(owner: UUID, session: PeelHostSession) {
        let key = ObjectIdentifier(session)
        if pointerOwners[key]?.workspace == owner {
            session.forceMouseUpIfNeeded(reason: "phone workspace closed")
            pointerOwners.removeValue(forKey: key)
        }
        update(owner: owner, session: session, windows: [:], selectedWindowID: nil, canRestoreActiveSelection: false)
    }

    func claimPointer(owner: UUID, interaction: UUID, session: PeelHostSession) {
        pointerOwners[ObjectIdentifier(session)] = (owner, interaction)
    }

    func mayReleasePointer(owner: UUID, interaction: UUID, session: PeelHostSession) -> Bool {
        guard let current = pointerOwners[ObjectIdentifier(session)] else { return false }
        return current.workspace == owner && current.interaction == interaction
    }

    func claimInput(owner: UUID, session: PeelHostSession) {
        guard sessions[ObjectIdentifier(session)]?.windowsByOwner[owner] != nil else { return }
        setInputOwner(owner, session: session)
    }

    func ownsInput(owner: UUID, session: PeelHostSession) -> Bool {
        inputOwners[ObjectIdentifier(session)] == owner
    }

    private func setInputOwner(_ owner: UUID?, session: PeelHostSession) {
        let key = ObjectIdentifier(session)
        guard inputOwners[key] != owner else { return }
        if let pointer = pointerOwners[key], pointer.workspace == inputOwners[key], pointer.workspace != owner {
            session.forceMouseUpIfNeeded(reason: "phone workspace input ownership changed")
            pointerOwners.removeValue(forKey: key)
        }
        objectWillChange.send()
        inputOwners[key] = owner
    }
}
