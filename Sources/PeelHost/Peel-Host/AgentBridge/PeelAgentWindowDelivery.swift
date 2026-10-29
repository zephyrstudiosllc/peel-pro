import Foundation

/// A windowList replaces the client's authoritative inventory. MCP display
/// labels may be shortened, but wire identities and the full list must survive.
enum PeelAgentWindowDelivery {
    enum DeliveryError: Error {
        case payloadTooLarge
    }

    static func window(_ source: PeelWindow) -> PeelWindow {
        PeelWindow(
            windowId: source.windowId,
            appName: source.appName,
            title: source.title,
            width: source.width,
            height: source.height,
            statusSummary: source.statusSummary,
            appIconPNGBase64: nil,
            appLaunchTimeIntervalSince1970: source.appLaunchTimeIntervalSince1970
        )
    }

    static func currentList(_ windows: [PeelWindow]) throws -> WindowListMessage {
        let message = WindowListMessage(windows: windows.map(window))
        guard try JSONEncoder().encode(message).count < 256 * 1024 else {
            throw DeliveryError.payloadTooLarge
        }
        return message
    }
}
