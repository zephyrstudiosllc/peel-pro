import Foundation
#if os(iOS) || os(visionOS)
import UIKit

/// Application notifications represent aggregate foreground state across scenes.
/// Install once at App initialization, independently of Settings presentation.
@MainActor
enum PeelAccountClientLifecycle {
    private static var installed = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard !installed, !ProcessInfo.processInfo.arguments.contains("--peel-preview") else { return }
        installed = true
        let account = PeelAccountController.shared
#if os(visionOS)
        account.localPlatform = .vision
        account.localDeviceName = "Peel Pro on Vision Pro"
#else
        account.localPlatform = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        account.localDeviceName = account.localPlatform == .iPad ? "Peel Pro on iPad" : "Peel Pro on iPhone"
#endif
        account.setApplicationBackground(UIApplication.shared.applicationState == .background)
        account.startAutomaticSync(isForeground: UIApplication.shared.applicationState == .active)
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PeelAccountController.shared.setApplicationBackground(UIApplication.shared.applicationState == .background)
                PeelAccountController.shared.setApplicationForeground(UIApplication.shared.applicationState == .active)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PeelAccountController.shared.setApplicationForeground(UIApplication.shared.applicationState == .active)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                PeelAccountController.shared.setApplicationBackground(UIApplication.shared.applicationState == .background)
                PeelAccountController.shared.setApplicationForeground(UIApplication.shared.applicationState == .active)
            }
        })
    }
}
#endif
