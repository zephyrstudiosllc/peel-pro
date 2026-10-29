import Foundation
import CoreGraphics

struct PeelRemoteMacWindowInventoryID: Equatable, Sendable {
    let controlEpoch: UUID
    let revision: UInt64
}

/// Only credential-free route metadata and a display hint survive teardown.
/// The old window is NEVER authority to reopen a new window instance.
struct PeelRemoteMacReconnectIntent {
    let pairingID: String
    let stableHostID: String?
    let serviceName: String?
    let tlsOrder: String?
    let address: PeelRemoteMacAddressRecord?
    let window: PeelWindow
    let displaySize: CGSize
    let displayName: String
}

/// Explicit user actions drive reconnect. Inventory arrival can only enable a chooser.
struct PeelRemoteMacReconnectState {
    enum Phase: Equatable { case active, paused, connecting, chooseWindow, closed }
    private(set) var phase: Phase = .active
    private(set) var attempt: UUID?
    private(set) var expectedControlEpoch: UUID?

    mutating func pause() {
        phase = .paused
        attempt = nil
        expectedControlEpoch = nil
    }
    mutating func beginExplicitReconnect() -> UUID? {
        guard phase == .paused else { return nil }
        let token = UUID()
        phase = .connecting
        attempt = token
        expectedControlEpoch = nil
        return token
    }
    @discardableResult
    mutating func bindControlEpoch(_ epoch: UUID, attempt token: UUID) -> Bool {
        guard phase == .connecting, attempt == token else { return false }
        expectedControlEpoch = epoch
        return true
    }
    @discardableResult
    mutating func inventoryArrived(_ inventory: PeelRemoteMacWindowInventoryID) -> Bool {
        guard phase == .connecting, expectedControlEpoch == inventory.controlEpoch else { return false }
        phase = .chooseWindow
        return true
    }
    mutating func currentInventoryIsChoosable(_ inventory: PeelRemoteMacWindowInventoryID) {
        guard phase != .closed else { return }
        phase = .chooseWindow
        attempt = nil
        expectedControlEpoch = inventory.controlEpoch
    }
    mutating func connectionFailed(attempt token: UUID) {
        guard phase == .connecting, attempt == token else { return }
        pause()
    }
    mutating func userSelectedFreshWindow() {
        // Called only after the controller verifies the exact currently rendered inventory ID.
        phase = .active
        attempt = nil
        expectedControlEpoch = nil
    }
    mutating func close() {
        phase = .closed
        attempt = nil
        expectedControlEpoch = nil
    }
}
