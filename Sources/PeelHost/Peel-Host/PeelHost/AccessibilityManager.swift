//
//  AccessibilityManager.swift
//  Peel-Host
//
//  Created by Zach on 4/14/26.
//


import Foundation
import AppKit
import ApplicationServices
import OSLog

// Private HIServices API: returns the true CGWindowID backing an AX window element,
// independent of whether the app exposes the "AXWindowNumber" attribute. This is the
// reliable way to match a streamed window (identified by CGWindowID) to its AXUIElement.
// The app is directly distributed (Sparkle updater + self-relaunch), not Mac App Store,
// and already relies on a private symbol via @_silgen_name in WindowEnumerator.swift.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// BEGIN PeelLocalPointerHitTestPolicy (extracted verbatim by Tests/LocalPointerHitTest)
/// One on-screen CGWindowList row, front-to-back, as seen by the local agent pointer gate.
struct PeelLocalPointerWindowRow: Equatable {
    let windowID: UInt32
    let ownerPID: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect

    static func parse(_ row: [String: Any]) -> PeelLocalPointerWindowRow? {
        guard let raw = row[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw),
              let windowID = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let layer = row[kCGWindowLayer as String] as? Int else { return nil }
        return PeelLocalPointerWindowRow(windowID: windowID, ownerPID: pid, layer: layer,
                                         alpha: row[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
    }
}

/// The real Accessibility hit-test result at the event point: the owning process
/// and the CGWindowID of the containing AX window (nil if unresolved).
struct PeelLocalPointerAXHit: Equatable {
    let ownerPID: pid_t
    let windowID: UInt32?
}

/// Owner identity of a CG row's process, resolved only for the Dock exception.
struct PeelLocalPointerOwnerIdentity: Equatable {
    let bundleIdentifier: String?
    let executablePath: String?
}

/// Local-only exact pointer hit-test. The cheap CG answer wins when the exact
/// target is the first containing row. The only discountable row is the system
/// Dock's full-display row at the Dock window level exactly covering a display
/// containing the point, and only when the real AX hit-test resolves the exact
/// target window and owner. Anything else covering the point blocks.
enum PeelLocalPointerHitTestPolicy {
    static let dockBundleIdentifier = "com.apple.dock"
    static let dockExecutablePath = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

    static func allows(rawRows: [[String: Any]], targetWindowID: UInt32, targetPID: pid_t, point: CGPoint,
                       dockLayer: Int, displayBounds: [CGRect],
                       ownerIdentity: (pid_t) -> PeelLocalPointerOwnerIdentity?,
                       axHit: () -> PeelLocalPointerAXHit?) -> Bool {
        guard point.x.isFinite, point.y.isFinite, targetWindowID != 0, targetPID > 0 else { return false }
        var discountedDockRow = false
        for raw in rawRows {
            // Same containment filter as the paired gate; a containing row without
            // a complete identity blocks.
            guard (raw[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let rawBounds = raw[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds), bounds.contains(point) else { continue }
            guard let row = PeelLocalPointerWindowRow.parse(raw) else { return false }
            if row.windowID == targetWindowID {
                guard row.ownerPID == targetPID else { return false }
                guard discountedDockRow else { return true }
                guard let hit = axHit() else { return false }
                return hit.ownerPID == targetPID && hit.windowID == targetWindowID
            }
            guard !discountedDockRow, isSystemDockCoveringRow(row, dockLayer: dockLayer, displayBounds: displayBounds,
                                                              identity: ownerIdentity(row.ownerPID)) else { return false }
            discountedDockRow = true
        }
        return false
    }

    static func isSystemDockCoveringRow(_ row: PeelLocalPointerWindowRow, dockLayer: Int, displayBounds: [CGRect],
                                        identity: PeelLocalPointerOwnerIdentity?) -> Bool {
        guard row.ownerPID > 0, row.layer == dockLayer, !row.bounds.isEmpty, !row.bounds.isInfinite,
              displayBounds.contains(where: { !$0.isEmpty && $0 == row.bounds }),
              let identity, identity.bundleIdentifier == dockBundleIdentifier,
              let path = identity.executablePath,
              URL(fileURLWithPath: path).standardizedFileURL.path == dockExecutablePath else { return false }
        return true
    }
}
// END PeelLocalPointerHitTestPolicy

final class AccessibilityManager {
    private let log = Logger(subsystem: "com.zephyrstudiosllc.Peel-Host", category: "Accessibility")

    private struct FocusAttemptState {
        let generation: UInt64
        var completions: [() -> Void]
    }

    var isRemoteControlAllowed: () -> Bool = { false }
    var sendInputRejected: ((UInt32, String) -> Void)?

    private let focusStateQueue = DispatchQueue(label: "peel.host.focusState")
    private var lastFocusedWindowId: UInt32?
    private var lastFocusAt: CFAbsoluteTime = 0
    private var latestFocusGeneration: UInt64 = 0
    private var focusAttemptsByWindowId: [UInt32: FocusAttemptState] = [:]
    private let focusThrottleInterval: CFTimeInterval = 0.20
    private let focusRetryDelays: [CFTimeInterval] = [0.0, 0.04, 0.10]
    private let clickFocusSettleDelay: CFTimeInterval = 0.03

    init() {
        let systemWideElement = AXUIElementCreateSystemWide()
        let result = AXUIElementSetMessagingTimeout(systemWideElement, 0.25)
        if result != .success {
            print("PeelHost: failed to set global AX messaging timeout result=\(result.rawValue)")
        }
    }

    func hostMayDriveMacUI() -> Bool { true }

    func focusAuthoritativeWindowIfNeeded(windowId: UInt32, force: Bool = false, activateApp: Bool = false) {
        guard !WindowEnumerator.isDisplayCaptureWindowId(windowId) else { return }
        guard isRemoteControlAllowed() else { return }
        _ = activateApp

        DispatchQueue.main.async {
            let point = self.authoritativePointFallback(for: windowId)
            self.bringWindowToFront(
                windowId: windowId,
                interactionPoint: point,
                force: force
            )
        }
    }

    func bringWindowToFront(
        windowId: UInt32,
        interactionPoint: CGPoint? = nil,
        force: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.bringWindowToFront(
                    windowId: windowId,
                    interactionPoint: interactionPoint,
                    force: force,
                    completion: completion
                )
            }
            return
        }

        if WindowEnumerator.isDisplayCaptureWindowId(windowId) {
            completion?()
            return
        }
        guard isRemoteControlAllowed() else {
            completion?()
            return
        }
        guard AXIsProcessTrustedWithOptions(nil) else {
            print("PeelHost: bringWindowToFront – AX not trusted")
            completion?()
            return
        }
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else {
            print("PeelHost: bringWindowToFront – no PID for window \(windowId)")
            completion?()
            return
        }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            print("PeelHost: bringWindowToFront – no running app for pid \(pid)")
            completion?()
            return
        }

        let point = interactionPoint ?? authoritativePointFallback(for: windowId)

        if !force {
            let recentFocusCacheHit = focusStateQueue.sync { () -> Bool in
                guard lastFocusedWindowId == windowId else { return false }
                return (CFAbsoluteTimeGetCurrent() - lastFocusAt) < focusThrottleInterval
            }

            if recentFocusCacheHit, isWindowReadyForInput(windowId: windowId, interactionPoint: point) {
                completion?()
                return
            }

            if isWindowReadyForInput(windowId: windowId, interactionPoint: point) {
                markWindowFocusVerified(windowId)
                completion?()
                return
            }
        }

        let focusGeneration = focusStateQueue.sync { () -> UInt64? in
            if var existingAttempt = focusAttemptsByWindowId[windowId],
               existingAttempt.generation == latestFocusGeneration {
                if let completion {
                    existingAttempt.completions.append(completion)
                    focusAttemptsByWindowId[windowId] = existingAttempt
                }
                return nil
            }

            latestFocusGeneration &+= 1

            var completions = focusAttemptsByWindowId[windowId]?.completions ?? []
            if let completion {
                completions.append(completion)
            }

            let generation = latestFocusGeneration
            focusAttemptsByWindowId[windowId] = FocusAttemptState(
                generation: generation,
                completions: completions
            )
            return generation
        }

        guard let focusGeneration else {
            return
        }

        func finish() {
            let isLatestAttempt = self.isFocusAttemptCurrent(
                windowId: windowId,
                generation: focusGeneration
            )
            let didFocus = isLatestAttempt && self.isWindowReadyForInput(
                windowId: windowId,
                interactionPoint: point
            )
            let completions = focusStateQueue.sync { () -> [() -> Void] in
                guard self.focusAttemptsByWindowId[windowId]?.generation == focusGeneration else {
                    return []
                }

                let completions = self.focusAttemptsByWindowId.removeValue(forKey: windowId)?.completions ?? []

                if didFocus {
                    self.lastFocusedWindowId = windowId
                    self.lastFocusAt = CFAbsoluteTimeGetCurrent()
                } else if self.lastFocusedWindowId == windowId {
                    self.lastFocusedWindowId = nil
                    self.lastFocusAt = 0
                }

                return isLatestAttempt ? completions : []
            }

            completions.forEach { $0() }
        }

        runAuthoritativeBringToFrontSequence(
            windowId: windowId,
            point: point,
            diagnosticGeneration: focusGeneration,
            shouldContinue: { [weak self] in
                self?.isFocusAttemptCurrent(
                    windowId: windowId,
                    generation: focusGeneration
                ) ?? false
            }
        ) {
            finish()
        }
    }

    /// Local-computer route only. The exact request's authority is the sole
    /// gate for every staged effect: it is checked at entry, before activation,
    /// before each AX raise and before each later stage. It is never merged into
    /// the paired focus attempt table and never messages a paired client.
    func bringWindowToFrontForLocalAgent(windowId: UInt32, authorized: @escaping () -> Bool,
                                         completion: @escaping (Bool) -> Void) {
        guard Thread.isMainThread, !WindowEnumerator.isDisplayCaptureWindowId(windowId), authorized(),
              AXIsProcessTrustedWithOptions(nil), let pid = WindowEnumerator.ownerPID(for: windowId),
              NSRunningApplication(processIdentifier: pid) != nil else {
            completion(false)
            return
        }
        runAuthoritativeBringToFrontSequence(
            windowId: windowId,
            point: authoritativePointFallback(for: windowId),
            diagnosticGeneration: 0,
            shouldContinue: authorized,
            authorized: authorized
        ) { [weak self] in
            completion(self?.isExactWindowFocusedForAgentInput(windowId: windowId, authorized: authorized) ?? false)
        }
    }

    private func isFocusAttemptCurrent(windowId: UInt32, generation: UInt64) -> Bool {
        focusStateQueue.sync {
            latestFocusGeneration == generation &&
            focusAttemptsByWindowId[windowId]?.generation == generation
        }
    }

    private func markWindowFocusVerified(_ windowId: UInt32) {
        let now = CFAbsoluteTimeGetCurrent()
        focusStateQueue.async {
            self.lastFocusedWindowId = windowId
            self.lastFocusAt = now
        }
    }

    func closeWindow(windowId: UInt32) {
        guard isRemoteControlAllowed() else {
            print("PeelHost: closeWindow blocked; remote control not allowed")
            return
        }
        guard AXIsProcessTrustedWithOptions(nil) else {
            print("PeelHost: closeWindow blocked; AX not trusted")
            return
        }

        prepareAppForWindowAction(windowId: windowId)

        guard let targetWindow = axWindowElement(for: windowId) else {
            print("PeelHost: closeWindow could not resolve AX window for \(windowId)")
            return
        }

        let closeResult = performAXClose(on: targetWindow)
        print("PeelHost: closeWindow windowId=\(windowId) result=\(closeResult.rawValue)")
    }

    func minimizeWindow(windowId: UInt32) {
        guard isRemoteControlAllowed() else {
            print("PeelHost: minimizeWindow blocked; remote control not allowed")
            return
        }
        guard AXIsProcessTrustedWithOptions(nil) else {
            print("PeelHost: minimizeWindow blocked; AX not trusted")
            return
        }

        prepareAppForWindowAction(windowId: windowId)

        guard let targetWindow = axWindowElement(for: windowId) else {
            print("PeelHost: minimizeWindow could not resolve AX window for \(windowId)")
            return
        }

        let minimizedValue = kCFBooleanTrue!
        let setResult = AXUIElementSetAttributeValue(
            targetWindow,
            kAXMinimizedAttribute as CFString,
            minimizedValue
        )

        print("PeelHost: minimizeWindow windowId=\(windowId) result=\(setResult.rawValue)")
    }

    func isTargetWindowTopmost(targetWindowId: UInt32, at point: CGPoint) -> Bool {
        guard let top = topWindowId(at: point) else { return false }
        return top == targetWindowId
    }

    func verifyTargetWindowIsTopmost(targetWindowId: UInt32, at point: CGPoint) -> Bool {
        guard isTargetWindowTopmost(targetWindowId: targetWindowId, at: point) else {
            let topDescription = topWindowId(at: point).map(String.init) ?? "unknown"
            let reason = "Input rejected: top window (\(topDescription)) != target (\(targetWindowId))"
            print("PeelHost:", reason)
            sendInputRejected?(targetWindowId, reason)
            return false
        }
        return true
    }

    func isWindowActuallyFrontmost(windowId: UInt32, authorized: (() -> Bool)? = nil) -> Bool {
        guard (authorized ?? isRemoteControlAllowed)() else { return false }
        guard let targetPID = WindowEnumerator.ownerPID(for: windowId) else { return false }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let appIsFrontmost = (frontmostPID == targetPID)
        guard appIsFrontmost else { return false }

        if let focusedWindow = focusedAXWindowElement(for: targetPID),
           axWindowNumber(focusedWindow) == windowId {
            return true
        }

        if let mainWindow = mainAXWindowElement(for: targetPID),
           axWindowNumber(mainWindow) == windowId {
            return true
        }

        if let point = authoritativePointFallback(for: windowId),
           isTargetWindowTopmost(targetWindowId: windowId, at: point) {
            return true
        }

        return false
    }

    /// Agent input never raises/falls back to a different window of the same app.
    func isExactWindowFocusedForAgentInput(windowId: UInt32) -> Bool {
        isExactWindowFocusedForAgentInput(windowId: windowId, authorized: isRemoteControlAllowed)
    }

    /// Same exact-window check under a caller-supplied authority (the local
    /// computer route passes its exact request owner, never paired consent).
    func isExactWindowFocusedForAgentInput(windowId: UInt32, authorized: () -> Bool) -> Bool {
        guard authorized(), let pid = WindowEnumerator.ownerPID(for: windowId),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = focusedAXWindowElement(for: pid) else { return false }
        return axWindowNumber(focused) == windowId
    }

    /// Unlike the general remote focus helper, overlays/menu windows at other
    /// layers must block an agent pointer action rather than be skipped.
    func isExactWindowTopmostForAgentInput(windowId: UInt32, point: CGPoint) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for row in rows {
            guard (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), bounds.contains(point) else { continue }
            return (row[kCGWindowNumber as String] as? UInt32) == windowId
        }
        return false
    }

    /// Local computer route only: the same exact-topmost gate, except the system
    /// Dock's click-through full-display row may be discounted when the real AX
    /// hit-test at the point resolves the exact target window and owner.
    func isExactWindowHitForLocalAgentPointer(windowId: UInt32, point: CGPoint) -> Bool {
        guard let targetPID = WindowEnumerator.ownerPID(for: windowId) else { return false }
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        let displayBounds = CGGetDisplaysWithPoint(point, UInt32(displays.count), &displays, &displayCount) == .success
            ? displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) } : []
        return PeelLocalPointerHitTestPolicy.allows(
            rawRows: rows, targetWindowID: windowId, targetPID: targetPID, point: point,
            dockLayer: Int(CGWindowLevelForKey(.dockWindow)), displayBounds: displayBounds,
            ownerIdentity: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
                return PeelLocalPointerOwnerIdentity(bundleIdentifier: app.bundleIdentifier,
                                                     executablePath: app.executableURL?.path)
            },
            axHit: { Self.axHit(at: point) })
    }

    private static func axHit(at point: CGPoint) -> PeelLocalPointerAXHit? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        var role: AnyObject?
        var window: AXUIElement?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == kAXWindowRole as String {
            window = element
        } else {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                window = (value as! AXUIElement)
            }
        }
        return PeelLocalPointerAXHit(ownerPID: pid, windowID: window.flatMap { cgWindowID(of: $0) })
    }

    func isWindowReadyForInput(windowId: UInt32, interactionPoint: CGPoint? = nil) -> Bool {
        if WindowEnumerator.isDisplayCaptureWindowId(windowId) {
            return true
        }

        guard isRemoteControlAllowed() else {
            return false
        }

        guard let targetPID = WindowEnumerator.ownerPID(for: windowId),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            return false
        }

        if isWindowActuallyFrontmost(windowId: windowId) {
            return true
        }

        if let interactionPoint {
            return isTargetWindowTopmost(targetWindowId: windowId, at: interactionPoint)
        }

        return false
    }

    func authoritativePointFallback(for windowId: UInt32) -> CGPoint? {
        guard let bounds = WindowEnumerator.bounds(for: windowId) else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func authoritativeActivationClickPoint(for windowId: UInt32) -> CGPoint? {
        guard let bounds = WindowEnumerator.bounds(for: windowId),
              bounds.width > 40,
              bounds.height > 40 else {
            return authoritativePointFallback(for: windowId)
        }

        // Prefer a titlebar/toolbar-ish point so the synthetic click focuses and raises the window
        // without replaying the user's actual content click inside the remote app.
        let x = bounds.midX
        let y = min(max(bounds.minY + 18, bounds.minY + 8), bounds.maxY - 8)
        return CGPoint(x: x, y: y)
    }

    private func topWindowId(at point: CGPoint) -> UInt32? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        for info in windowListInfo {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let id = info[kCGWindowNumber as String] as? UInt32 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            if bounds.contains(point) { return id }
        }
        return nil
    }

    private func topWindowOwnerPID(at point: CGPoint) -> pid_t? {
        guard let topWindowId = topWindowId(at: point) else { return nil }
        return WindowEnumerator.ownerPID(for: topWindowId)
    }

    private func isWindowCurrentlyOnScreen(windowId: UInt32) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        return windowListInfo.contains { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32 else { return false }
            return id == windowId
        }
    }

    @discardableResult
    private func performAXRaiseAttempt(
        windowId: UInt32,
        activateApp: Bool,
        bringAllWindowsForward: Bool = false,
        diagnosticGeneration: UInt64? = nil,
        diagnosticPhase: String = "unspecified",
        authorized: (() -> Bool)? = nil,
        reportsRejections: Bool = true
    ) -> Bool {
        guard (authorized ?? isRemoteControlAllowed)() else { return false }
        guard AXIsProcessTrustedWithOptions(nil) else { return false }
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        let resolutionStarted = DispatchTime.now().uptimeNanoseconds
        var resolutionRoute = "unresolved"
        guard let targetWindow = resolvedAXWindowElement(for: windowId, resolutionRoute: { resolutionRoute = $0 }) else {
            if let diagnosticGeneration {
                let resolutionNS = DispatchTime.now().uptimeNanoseconds - resolutionStarted
                log.notice("Focus diagnostic windowId=\(windowId) focusGeneration=\(diagnosticGeneration) targetPID=\(pid) phase=\(diagnosticPhase, privacy: .public) route=unresolved resolutionNS=\(resolutionNS)")
            }
            if reportsRejections { self.sendInputRejected?(windowId, "Peel could not resolve the requested Mac window") }
            return false
        }
        let resolutionNS = DispatchTime.now().uptimeNanoseconds - resolutionStarted

        let minimizedStarted = DispatchTime.now().uptimeNanoseconds
        let minimizedResult = AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let minimizedNS = DispatchTime.now().uptimeNanoseconds - minimizedStarted

        if activateApp, let app = NSRunningApplication(processIdentifier: pid) {
            if app.isHidden {
                app.unhide()
            }

            _ = bringAllWindowsForward
            app.activate(options: [.activateIgnoringOtherApps])
        }

        let appMainStarted = DispatchTime.now().uptimeNanoseconds
        let appMainResult = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, targetWindow)
        let appMainNS = DispatchTime.now().uptimeNanoseconds - appMainStarted
        let appFocusedStarted = DispatchTime.now().uptimeNanoseconds
        let appFocusedResult = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, targetWindow)
        let appFocusedNS = DispatchTime.now().uptimeNanoseconds - appFocusedStarted
        let windowMainStarted = DispatchTime.now().uptimeNanoseconds
        let windowMainResult = AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        let windowMainNS = DispatchTime.now().uptimeNanoseconds - windowMainStarted
        let windowFocusedStarted = DispatchTime.now().uptimeNanoseconds
        let windowFocusedResult = AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let windowFocusedNS = DispatchTime.now().uptimeNanoseconds - windowFocusedStarted

        let raiseStarted = DispatchTime.now().uptimeNanoseconds
        let raiseResult = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        let raiseNS = DispatchTime.now().uptimeNanoseconds - raiseStarted
        if let diagnosticGeneration {
            log.notice("Focus diagnostic windowId=\(windowId) focusGeneration=\(diagnosticGeneration) targetPID=\(pid) phase=\(diagnosticPhase, privacy: .public) route=\(resolutionRoute, privacy: .public) resolutionNS=\(resolutionNS) minimizedResult=\(minimizedResult.rawValue) minimizedNS=\(minimizedNS) appMainResult=\(appMainResult.rawValue) appMainNS=\(appMainNS) appFocusedResult=\(appFocusedResult.rawValue) appFocusedNS=\(appFocusedNS) windowMainResult=\(windowMainResult.rawValue) windowMainNS=\(windowMainNS) windowFocusedResult=\(windowFocusedResult.rawValue) windowFocusedNS=\(windowFocusedNS) raiseResult=\(raiseResult.rawValue) raiseNS=\(raiseNS)")
        }

        return raiseResult == .success
    }


    private func runAuthoritativeBringToFrontSequence(
        windowId: UInt32,
        point: CGPoint?,
        diagnosticGeneration: UInt64,
        shouldContinue: @escaping () -> Bool,
        authorized: (() -> Bool)? = nil,
        completion: @escaping () -> Void
    ) {
        let reportsRejections = authorized == nil
        func verifyExactWindow() -> Bool {
            if self.isWindowActuallyFrontmost(windowId: windowId, authorized: authorized) {
                return true
            }

            if let point {
                return self.isTargetWindowTopmost(targetWindowId: windowId, at: point)
            }

            return false
        }

        // Phase 0: pre-select the exact target window as the app's main/focused window
        // BEFORE activating the app. Activation surfaces the app's main window, so setting
        // the correct window first means activation raises IT instead of a sibling — this
        // removes the ~0.18s wrong-window flash. Additive: does no harm if it fails on a
        // fully-backgrounded app, since Phase 2/3 still raise the exact window afterward.
        _ = self.performAXRaiseAttempt(
            windowId: windowId,
            activateApp: false,
            bringAllWindowsForward: false,
            diagnosticGeneration: diagnosticGeneration,
            diagnosticPhase: "preselect",
            authorized: authorized,
            reportsRejections: reportsRejections
        )

        // Phase 1: enter the owning app/Space using the same simple PID-based activation
        // strategy that works well in Mac Mechanic. A local request also lends its own
        // authority for the AX frontmost request when macOS refuses that activation.
        if (authorized ?? { true })() {
            _ = self.activateOwningRegularAppMacMechanicStyle(windowId: windowId, diagnosticGeneration: diagnosticGeneration,
                                                              localAuthority: authorized)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard shouldContinue() else {
                completion()
                return
            }

            // Phase 2: now that macOS has had a moment to care about the app,
            // resolve and raise/focus the exact selected AX window.
            _ = self.performAXRaiseAttempt(
                windowId: windowId,
                activateApp: false,
                bringAllWindowsForward: false,
                diagnosticGeneration: diagnosticGeneration,
                diagnosticPhase: "afterActivation",
                authorized: authorized,
                reportsRejections: reportsRejections
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard shouldContinue() else {
                    completion()
                    return
                }

                if verifyExactWindow() {
                    completion()
                    return
                }

                // Phase 3: reinforce exact-window AX focus once, without changing the success
                // condition to app-level focus.
                _ = self.performAXRaiseAttempt(
                    windowId: windowId,
                    activateApp: false,
                    bringAllWindowsForward: false,
                    diagnosticGeneration: diagnosticGeneration,
                    diagnosticPhase: "reinforce",
                    authorized: authorized,
                    reportsRejections: reportsRejections
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    guard shouldContinue() else {
                        completion()
                        return
                    }

                    if verifyExactWindow() {
                        completion()
                        return
                    }

                    let reason = "Focus warning: target window (\(windowId)) did not become exact frontmost after app activation and AX focus"
                    if reportsRejections { self.sendInputRejected?(windowId, reason) }
                    completion()
                }
            }
        }
    }

    private func activateOwningRegularAppMacMechanicStyle(windowId: UInt32, diagnosticGeneration: UInt64? = nil,
                                                          localAuthority: (() -> Bool)? = nil) -> Bool {
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else {
            print("PeelHost: activateOwningRegularAppMacMechanicStyle – no PID for window \(windowId)")
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            print("PeelHost: activateOwningRegularAppMacMechanicStyle – no running app for pid \(pid)")
            return false
        }

        let activationPolicy = app.activationPolicy
        guard activationPolicy == .regular else {
            if let diagnosticGeneration {
                log.notice("Focus diagnostic windowId=\(windowId) focusGeneration=\(diagnosticGeneration) targetPID=\(pid) phase=activate skipped=nonRegular policy=\(activationPolicy.rawValue) finishedLaunching=\(app.isFinishedLaunching) hidden=\(app.isHidden) terminated=\(app.isTerminated) active=\(app.isActive)")
            }
            print("PeelHost: activateOwningRegularAppMacMechanicStyle – app for pid \(pid) is not regular")
            return false
        }

        let wasFinishedLaunching = diagnosticGeneration == nil ? false : app.isFinishedLaunching
        let wasTerminated = diagnosticGeneration == nil ? false : app.isTerminated
        let wasActive = diagnosticGeneration == nil ? false : app.isActive
        let wasHidden = app.isHidden
        var unhideResultCode = -1
        var unhideNS: UInt64 = 0
        if wasHidden {
            let unhideStarted = DispatchTime.now().uptimeNanoseconds
            unhideResultCode = app.unhide() ? 1 : 0
            unhideNS = DispatchTime.now().uptimeNanoseconds - unhideStarted
        }

        let activationStarted = DispatchTime.now().uptimeNanoseconds
        let activationResult = app.activate(options: [.activateIgnoringOtherApps])
        let activationNS = DispatchTime.now().uptimeNanoseconds - activationStarted
        // Since macOS 14 a background Host's activation request is refused
        // (ignoringOtherApps has no effect). For an explicitly authorized local
        // request only, ask the exact owning app to become frontmost through
        // the public AX application attribute, after rechecking the request's
        // own authority and that the window still belongs to this PID.
        var frontmostResultCode = -1
        if !app.isActive, let localAuthority, localAuthority(), AXIsProcessTrustedWithOptions(nil),
           WindowEnumerator.ownerPID(for: windowId) == pid {
            frontmostResultCode = Int(AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue).rawValue)
        }
        if let diagnosticGeneration {
            log.notice("Focus diagnostic windowId=\(windowId) focusGeneration=\(diagnosticGeneration) targetPID=\(pid) phase=activate policy=\(activationPolicy.rawValue) finishedLaunching=\(wasFinishedLaunching) hiddenBefore=\(wasHidden) terminated=\(wasTerminated) activeBefore=\(wasActive) unhideResult=\(unhideResultCode) unhideNS=\(unhideNS) activationResult=\(activationResult) activationNS=\(activationNS) frontmostResult=\(frontmostResultCode) hiddenAfter=\(app.isHidden) activeAfter=\(app.isActive)")
        }
        return activationResult || frontmostResultCode == 0
    }
    private func activateOwningApp(windowId: UInt32, bringAllWindowsForward: Bool = false) -> Bool {
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else {
            print("PeelHost: activateOwningApp – no PID for window \(windowId)")
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid) else {
            print("PeelHost: activateOwningApp – no running app for pid \(pid)")
            return false
        }

        _ = bringAllWindowsForward
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    private func performSyntheticActivationClick(at point: CGPoint) -> Bool {
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            print("PeelHost: failed to create synthetic activation click events")
            return false
        }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func runFocusRetryLoop(windowId: UInt32, activateApp: Bool, completion: (() -> Void)? = nil) {
        func attempt(_ index: Int) {
            guard index < focusRetryDelays.count else {
                completion?()
                return
            }

            let delay = focusRetryDelays[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.performAXRaiseAttempt(windowId: windowId, activateApp: activateApp)

                if index == self.focusRetryDelays.count - 1 {
                    completion?()
                } else {
                    attempt(index + 1)
                }
            }
        }

        attempt(0)
    }

    private func resolvedAXWindowElement(for windowId: UInt32, resolutionRoute: ((String) -> Void)? = nil) -> AXUIElement? {
        if let exactWindow = exactAXWindowElement(for: windowId, resolutionRoute: resolutionRoute) {
            return exactWindow
        }

        let window = geometryMatchedAXWindowElement(for: windowId)
        resolutionRoute?(window == nil ? "unresolved" : "geometry")
        return window
    }

    private func geometryMatchedAXWindowElement(for windowId: UInt32) -> AXUIElement? {
        guard let pid = WindowEnumerator.ownerPID(for: windowId),
              let targetBounds = WindowEnumerator.bounds(for: windowId) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: AnyObject?
        let winResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard winResult == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        var bestWindow: AXUIElement?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for window in windows {
            guard let axBounds = axBounds(for: window) else { continue }

            let centerDistance = hypot(
                targetBounds.midX - axBounds.midX,
                targetBounds.midY - axBounds.midY
            )
            let sizeDelta = abs(targetBounds.width - axBounds.width) + abs(targetBounds.height - axBounds.height)
            let score = centerDistance + sizeDelta

            let centersAreClose = centerDistance < 80
            let sizesAreClose = abs(targetBounds.width - axBounds.width) < 80 &&
                abs(targetBounds.height - axBounds.height) < 80
            let framesOverlap = targetBounds.intersects(axBounds)

            guard (centersAreClose && sizesAreClose) || framesOverlap else { continue }

            if score < bestScore {
                bestScore = score
                bestWindow = window
            }
        }

        return bestWindow
    }

    private func axBounds(for window: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        let positionResult = AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        )

        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        )

        guard positionResult == .success,
              sizeResult == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    /// The true CGWindowID backing an AX window element, via the private
    /// `_AXUIElementGetWindow`. Returns nil if the call fails or yields 0.
    static func cgWindowID(of window: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else {
            return nil
        }
        return windowID
    }

    private func exactAXWindowElement(for windowId: UInt32, resolutionRoute: ((String) -> Void)? = nil) -> AXUIElement? {
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else {
            log.error("exactAXWindowElement could not resolve PID for target \(windowId, privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: AnyObject?
        let winResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard winResult == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            log.error("exactAXWindowElement could not fetch AX windows for target \(windowId, privacy: .public); result=\(winResult.rawValue, privacy: .public)")
            return nil
        }

        // Primary: match the real CGWindowID, which is reliable across all apps.
        for window in windows {
            if Self.cgWindowID(of: window) == windowId {
                resolutionRoute?("cgWindowID")
                return window
            }
        }

        // Secondary: the undocumented "AXWindowNumber" attribute (not all apps expose it).
        for window in windows {
            var numberValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(window, kAXWindowNumberAttribute, &numberValue)

            if result == .success,
               let number = numberValue as? NSNumber,
               number.uint32Value == windowId {
                resolutionRoute?("AXWindowNumber")
                return window
            }
        }

        return nil
    }

    private func mainAXWindowElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        var mainWindowValue: AnyObject?
        let mainResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            &mainWindowValue
        )

        guard mainResult == .success,
              let mainWindowValue,
              CFGetTypeID(mainWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(mainWindowValue, to: AXUIElement.self)
    }

    private func axWindowNumber(_ window: AXUIElement) -> UInt32? {
        // Primary: the real CGWindowID (reliable across all apps).
        if let cgID = Self.cgWindowID(of: window) {
            return cgID
        }

        // Secondary: the undocumented "AXWindowNumber" attribute.
        var numberValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            window,
            kAXWindowNumberAttribute as CFString,
            &numberValue
        )

        guard result == .success,
              let number = numberValue as? NSNumber else {
            return nil
        }

        return number.uint32Value
    }

    private func focusedAXWindowElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
    }

    private func axWindowElement(for windowId: UInt32) -> AXUIElement? {
        guard let pid = WindowEnumerator.ownerPID(for: windowId) else {
            log.error("axWindowElement could not resolve PID for target \(windowId, privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        func axElement(from value: AnyObject?) -> AXUIElement? {
            guard let value else { return nil }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        var windowsValue: AnyObject?
        let winResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard winResult == .success,
              let windows = windowsValue as? [AXUIElement],
              !windows.isEmpty else {
            return nil
        }

        // Primary: match the real CGWindowID (reliable across all apps).
        for window in windows {
            if Self.cgWindowID(of: window) == windowId {
                return window
            }
        }

        // Secondary: the undocumented "AXWindowNumber" attribute.
        for window in windows {
            var numberValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(window, kAXWindowNumberAttribute, &numberValue)

            if result == .success,
               let number = numberValue as? NSNumber,
               number.uint32Value == windowId {
                return window
            }
        }

        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        if focusedResult == .success,
           let focusedWindow = axElement(from: focusedWindowValue) {
            return focusedWindow
        }

        var mainWindowValue: AnyObject?
        let mainResult = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowValue)
        if mainResult == .success,
           let mainWindow = axElement(from: mainWindowValue) {
            return mainWindow
        }

        return windows.first
    }

    private func performAXClose(on window: AXUIElement) -> AXError {
        func axElement(from value: AnyObject?) -> AXUIElement? {
            guard let value else { return nil }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        var closeButtonValue: AnyObject?
        let buttonResult = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonValue)

        if buttonResult == .success,
           let closeButton = axElement(from: closeButtonValue) {
            let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            if pressResult == .success {
                return pressResult
            }
        }

        return .actionUnsupported
    }

    private func prepareAppForWindowAction(windowId: UInt32) {
        guard let pid = WindowEnumerator.ownerPID(for: windowId),
              let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }

        app.activate(options: [.activateIgnoringOtherApps])
        focusAuthoritativeWindowIfNeeded(windowId: windowId, force: true, activateApp: false)
    }
}
