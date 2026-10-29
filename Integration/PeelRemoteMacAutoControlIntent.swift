import Foundation

/// Per-stream default control intent for the Mac receiver. Only an explicit user
/// window selection arms it. It opens control at most once, for that same stream,
/// after video arrives while its window is key in the active app. Explicit
/// Off/Escape/Stop, disconnect and stream changes cancel it, so routine view or
/// format updates never re-enable control. Host Allow Control, Accessibility,
/// lock and revocation remain enforced by the Host and the controller gates.
struct PeelRemoteMacAutoControlIntent: Sendable {
    struct Gates: Sendable {
        var stream: String?
        var isConnected: Bool
        var hasVideo: Bool
        var isPaused: Bool
        var windowIsKey: Bool
        var appIsActive: Bool
        var controlEnabled: Bool
    }

    private(set) var armedStream: String?

    mutating func armForExplicitSelection(stream: String) {
        armedStream = stream
    }

    mutating func cancel() {
        armedStream = nil
    }

    /// Returns true once per arming. Focus/foreground gates leave the intent armed
    /// for a later fresh focus; a different stream or existing control consumes it.
    mutating func consume(_ gates: Gates) -> Bool {
        guard let armed = armedStream else { return false }
        guard gates.stream == armed, !gates.controlEnabled else {
            armedStream = nil
            return false
        }
        guard gates.isConnected, gates.hasVideo, !gates.isPaused,
              gates.windowIsKey, gates.appIsActive else { return false }
        armedStream = nil
        return true
    }
}
