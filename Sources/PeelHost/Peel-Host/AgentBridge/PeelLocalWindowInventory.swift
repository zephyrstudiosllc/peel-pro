import AppKit
import CoreGraphics

/// Window-server metadata parsing for the local agent target. One row is
/// shaped like its remote listing entry, but without the full enumeration's
/// AX, pixel and icon passes, so the local listing stays within the request
/// deadline on a busy desktop and the same parser serves each focus recheck.
enum PeelLocalWindowInventory {
    /// The owning process facts a row is bound to.
    struct Application {
        let bundleIdentifier: String?
        let launchTimeIntervalSince1970: TimeInterval?
        let isRegular: Bool
        let isTerminated: Bool
    }

    typealias Entry = (window: PeelWindow, fingerprint: PeelAgentWindowInstanceFingerprint)

    /// Same size floor as the remote listing.
    static let minimumWidth = 160
    static let minimumHeight = 120

    /// One normal-layer, shareable, visible-alpha window of a running regular app.
    static func entry(_ row: [String: Any], application: (pid_t) -> Application?) -> Entry? {
        guard let windowID = row[kCGWindowNumber as String] as? UInt32,
              (row[kCGWindowLayer as String] as? Int) == 0,
              (row[kCGWindowSharingState as String] as? Int) != 0,
              (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let pid = row[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              let app = application(pid), app.isRegular, !app.isTerminated else { return nil }
        let title = (row[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let window = PeelWindow(windowId: windowID, appName: row[kCGWindowOwnerName as String] as? String ?? "Unknown App",
                                title: title.isEmpty ? "Window" : title, width: Int(bounds.width), height: Int(bounds.height),
                                statusSummary: nil, appIconPNGBase64: nil,
                                appLaunchTimeIntervalSince1970: app.launchTimeIntervalSince1970)
        return (window, PeelAgentWindowInstanceFingerprint(
            windowID: windowID, ownerProcessID: pid, appBundleIdentifier: app.bundleIdentifier,
            appName: window.appName, title: window.title, width: window.width, height: window.height,
            appLaunchTimeIntervalSince1970: window.appLaunchTimeIntervalSince1970,
            isDisplay: false, displayID: nil))
    }

    /// Listable rows in window-server order. Each owning process is looked up
    /// once; eligibility, caps and publishing stay with the caller.
    static func entries(_ rows: [[String: Any]], application: (pid_t) -> Application?) -> [Entry] {
        var applications: [pid_t: Application?] = [:]
        func cached(_ pid: pid_t) -> Application? {
            if let known = applications[pid] { return known }
            let found = application(pid)
            applications.updateValue(found, forKey: pid)
            return found
        }
        var result: [Entry] = []
        for row in rows {
            guard let listed = entry(row, application: cached),
                  listed.window.width >= minimumWidth, listed.window.height >= minimumHeight else { continue }
            result.append(listed)
        }
        return result
    }

    /// The single on-screen window-server metadata read for a local listing.
    static func onScreenRows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// The window-server row of one window, on or off screen.
    static func row(windowID: UInt32) -> [String: Any]? {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]] ?? []
        return rows.first { ($0[kCGWindowNumber as String] as? UInt32) == windowID }
    }

    static func runningApplication(_ pid: pid_t) -> Application? {
        NSRunningApplication(processIdentifier: pid).map {
            Application(bundleIdentifier: $0.bundleIdentifier,
                        launchTimeIntervalSince1970: $0.launchDate?.timeIntervalSince1970,
                        isRegular: $0.activationPolicy == .regular, isTerminated: $0.isTerminated)
        }
    }
}
