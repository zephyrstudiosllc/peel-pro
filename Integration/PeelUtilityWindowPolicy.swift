import AppKit

/// Peel Pro's manager is a compact utility window. This policy only acts on the
/// window registered as `peel.computers.hub`; stream, notch, popover and quit
/// confirmation windows never pass through it.
///
/// The scene disables restoration, so each launch opens at `defaultSize`.
/// Registration only caps the content size once; it never resizes, because the
/// window is still mid-layout then. The first normalization waits until the
/// window is key after layout (one deferred main-actor check, or the first
/// key notification), and explicit Show/Open normalizes again. It only shrinks
/// a frame that is full screen, zoomed or larger than `defaultSize`; the user
/// may enlarge it up to `maximumSize` while open, and a size at or below the
/// default is kept. Manual resizing is never fought.
@MainActor
enum PeelUtilityWindowPolicy {
    static let identifier = NSUserInterfaceItemIdentifier("peel.computers.hub")
    static let defaultSize = CGSize(width: 720, height: 600)
    static let minimumSize = CGSize(width: 640, height: 520)
    static let maximumSize = CGSize(width: 1100, height: 900)

    private static let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private static var firstKeyObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private static var fullScreenExitObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func attach(_ window: NSWindow) {
        guard window.identifier == identifier, !attachedWindows.contains(window) else { return }
        attachedWindows.add(window)
        // SwiftUI owns the minimum (.contentMinSize); the maximum lives here
        // rather than as a finite SwiftUI frame around the split view.
        window.contentMaxSize = maximumSize
        let id = ObjectIdentifier(window)
        firstKeyObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak window] _ in
            Task { @MainActor [weak window] in
                if let window { firstKeyAfterLayout(window) }
            }
        }
        // Already key by the next main-actor turn: normalize once then.
        Task { @MainActor [weak window] in
            if let window, window.isKeyWindow { firstKeyAfterLayout(window) }
        }
    }

    /// Runs at most once per window: whichever of the deferred check or the
    /// first key notification arrives first removes the observer and normalizes.
    private static func firstKeyAfterLayout(_ window: NSWindow) {
        guard let token = firstKeyObservers.removeValue(forKey: ObjectIdentifier(window)) else { return }
        NotificationCenter.default.removeObserver(token)
        normalize(window)
    }

    /// Returns a full-screen, zoomed or larger-than-default manager to the
    /// compact utility frame on its current screen. Anything else is left alone.
    static func normalize(_ window: NSWindow) {
        guard window.identifier == identifier else { return }
        if window.styleMask.contains(.fullScreen) {
            leaveFullScreen(window)
            return
        }
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
        let content = window.contentRect(forFrameRect: window.frame).size
        guard window.isZoomed
                || content.width > defaultSize.width + 1
                || content.height > defaultSize.height + 1 else { return }
        window.setFrame(compactFrame(for: window), display: true)
    }

    private static func leaveFullScreen(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard fullScreenExitObservers[id] == nil else { return }
        fullScreenExitObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak window] _ in
            Task { @MainActor [weak window] in
                if let token = fullScreenExitObservers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(token)
                }
                if let window { normalize(window) }
            }
        }
        window.toggleFullScreen(nil)
    }

    /// The default utility size, centred where the window was and kept on screen.
    private static func compactFrame(for window: NSWindow) -> NSRect {
        let current = window.frame
        var size = window.frameRect(forContentRect: NSRect(origin: .zero, size: defaultSize)).size
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return NSRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)
        let x = min(max(current.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(current.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
