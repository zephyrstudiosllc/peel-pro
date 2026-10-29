import Foundation

private let AVAudioSessionInterruptionTypeKey = "interruption-type"
private let AVAudioSessionRouteChangeReasonKey = "route-change"
private final class AVAudioSession: NSObject {
    static let interruptionNotification = Notification.Name("fixture.audio.interruption")
    static let routeChangeNotification = Notification.Name("fixture.audio.route")
    enum InterruptionType: UInt { case ended = 0, began = 1 }
    enum RouteChangeReason: UInt { case unknown = 0, newDeviceAvailable = 1, oldDeviceUnavailable = 2, noSuitableRouteForCategory = 7 }
}
private enum Failure { case interrupted, routeLost, audioSessionDeactivationFailed }
private final class ObserverBag {
    var tokens: [NSObjectProtocol] = []
    func append(_ token: NSObjectProtocol) { tokens.append(token) }
    func removeAll() { for token in tokens { NotificationCenter.default.removeObserver(token) }; tokens.removeAll() }
    deinit { removeAll() }
}
