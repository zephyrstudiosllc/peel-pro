import Foundation

/// Transport support only. This result must never grant paid access. The Host's
/// current-session commerce admission must also allow every target-bound action.
nonisolated enum PeelConnectedAgentAvailability {
    static let unavailableMessage = "Connected-device agent actions are unavailable in this build."

    static func allows(_ method: PeelLocalAgentMethod) -> Bool {
        switch method {
        case .launchApp, .presentWindow, .notify,
             .listDevices, .listWindows, .listApps, .getStreamDiagnostics, .inspectWindow, .controlWindow:
            return true
        }
    }
}
