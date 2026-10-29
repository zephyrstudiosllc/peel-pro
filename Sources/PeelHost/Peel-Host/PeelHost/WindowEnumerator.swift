//
//  WindowEnumerator.swift
//  Peel-Host
//
//  Created by Zach on 4/14/26.
//


import Foundation
import AppKit
import ApplicationServices
import os

/// Content-free stage counts for diagnosing an empty app-window list. Logging
/// is bounded across concurrent enumerations and never includes titles or pixels.
private nonisolated final class PeelWindowEnumerationDiagnostics: @unchecked Sendable {
    static let shared = PeelWindowEnumerationDiagnostics()
    private let lock = NSLock()
    private var lastLoggedAt: TimeInterval?
    private let logger = Logger(subsystem: "com.zephyrstudiosllc.Peel-Host", category: "WindowEnumeration")

    func record(scope: String, counts: [String: Int]) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard lastLoggedAt.map({ now - $0 >= 5 }) ?? true else { lock.unlock(); return }
        lastLoggedAt = now
        lock.unlock()
        let summary = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
        logger.notice("scope=\(scope, privacy: .public) \(summary, privacy: .public)")
    }
}

#if os(macOS)
// AX constant isn't always visible from Swift headers, define it explicitly.
let kAXWindowNumberAttribute = "AXWindowNumber" as CFString

#endif

enum WindowEnumerationScope: String, CaseIterable, Identifiable {
    case currentSpaceOnly
    case allSpaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentSpaceOnly:
            return "This Space Only"
        case .allSpaces:
            return "All Spaces"
        }
    }

    var helpText: String {
        switch self {
        case .currentSpaceOnly:
            return "Only show windows visible in the current macOS Space."
        case .allSpaces:
            return "Show eligible windows across all macOS Spaces."
        }
    }

    var cgWindowListOptions: CGWindowListOption {
        switch self {
        case .currentSpaceOnly:
            return [.optionOnScreenOnly, .excludeDesktopElements]
        case .allSpaces:
            return [.excludeDesktopElements]
        }
    }
}

#if os(macOS)
enum PeelDisplayCaptureSource {
    static let appName = "Peel Display"
    static let singleDisplayTitle = "Peel Display"

    private static let syntheticBase: UInt32 = 0xFFF0_0000
    private static let maxSyntheticDisplays: UInt32 = 64

    struct Descriptor {
        let syntheticWindowId: UInt32
        let displayId: CGDirectDisplayID
        let bounds: CGRect
        let title: String
        let isMain: Bool
    }

    static func isDisplayWindowId(_ windowId: UInt32) -> Bool {
        windowId >= syntheticBase && windowId < syntheticBase + maxSyntheticDisplays
    }

    static func descriptor(forWindowId windowId: UInt32) -> Descriptor? {
        guard isDisplayWindowId(windowId) else { return nil }
        return descriptors().first { $0.syntheticWindowId == windowId }
    }

    static func displayId(forWindowId windowId: UInt32) -> CGDirectDisplayID? {
        descriptor(forWindowId: windowId)?.displayId
    }

    static func descriptors() -> [Descriptor] {
        let maxDisplays = maxSyntheticDisplays
        var displayIds = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(maxDisplays, &displayIds, &displayCount)
        guard err == .success, displayCount > 0 else {
            return []
        }

        let mainDisplayId = CGMainDisplayID()
        let ids = Array(displayIds.prefix(Int(displayCount)))

        let sortedIds = ids.sorted { lhs, rhs in
            if lhs == mainDisplayId { return true }
            if rhs == mainDisplayId { return false }

            let l = CGDisplayBounds(lhs)
            let r = CGDisplayBounds(rhs)

            if l.minX != r.minX { return l.minX < r.minX }
            if l.minY != r.minY { return l.minY < r.minY }

            return lhs < rhs
        }

        return sortedIds.enumerated().compactMap { index, displayId in
            guard index < Int(maxSyntheticDisplays) else { return nil }

            let bounds = CGDisplayBounds(displayId)
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            let title: String
            if sortedIds.count == 1 {
                title = singleDisplayTitle
            } else if displayId == mainDisplayId {
                title = "Peel Display Main"
            } else {
                title = "Peel Display \(index + 1)"
            }

            return Descriptor(
                syntheticWindowId: syntheticBase + UInt32(index),
                displayId: displayId,
                bounds: bounds,
                title: title,
                isMain: displayId == mainDisplayId
            )
        }
    }

    static func peelWindows() -> [PeelWindow] {
        descriptors().map { descriptor in
            let width = max(1, Int(descriptor.bounds.width.rounded(.toNearestOrAwayFromZero)))
            let height = max(1, Int(descriptor.bounds.height.rounded(.toNearestOrAwayFromZero)))

            return PeelWindow(
                windowId: descriptor.syntheticWindowId,
                appName: appName,
                title: descriptor.title,
                width: width,
                height: height,
                statusSummary: "\(descriptor.title) — full display stream",
                appIconPNGBase64: nil,
                appLaunchTimeIntervalSince1970: nil
            )
        }
    }
}
#endif

enum WindowEnumerator {
    struct InputGeometry {
        let streamBounds: CGRect
        let capturedBounds: CGRect

        func screenPoint(normX: Double, normY: Double) -> CGPoint? {
            guard normX.isFinite, normY.isFinite else { return nil }
            guard streamBounds.width > 0, streamBounds.height > 0,
                  capturedBounds.width > 0, capturedBounds.height > 0 else {
                return nil
            }

            let clampedX = CGFloat(min(1.0, max(0.0, normX)))
            let clampedY = CGFloat(min(1.0, max(0.0, normY)))
            let streamAspect = streamBounds.width / streamBounds.height
            let capturedAspect = capturedBounds.width / capturedBounds.height

            let fittedSize: CGSize
            if streamAspect > capturedAspect {
                fittedSize = CGSize(
                    width: streamBounds.height * capturedAspect,
                    height: streamBounds.height
                )
            } else {
                fittedSize = CGSize(
                    width: streamBounds.width,
                    height: streamBounds.width / capturedAspect
                )
            }

            guard fittedSize.width > 0, fittedSize.height > 0 else { return nil }

            // ScreenCaptureKit anchors independent-window content at the output
            // surface's top-left when child chrome changes the captured aspect.
            let fittedX = min(clampedX * streamBounds.width, fittedSize.width)
            let fittedY = min(clampedY * streamBounds.height, fittedSize.height)

            return CGPoint(
                x: capturedBounds.minX + ((fittedX / fittedSize.width) * capturedBounds.width),
                y: capturedBounds.minY + ((fittedY / fittedSize.height) * capturedBounds.height)
            )
        }
    }

    static let enumerationScopeDefaultsKey = "PeelHost.windowEnumerationScope"

    private static let minimumWindowWidth = 160
    private static let minimumWindowHeight = 120
    private static let fullscreenGeometryTolerance: CGFloat = 1
    private static let maximumFullscreenChromeHeight: CGFloat = 160

    private static func accessibilityWindowIdsByPID(
        for pids: Set<pid_t>, diagnostics: (([String: Int]) -> Void)? = nil
    ) -> [pid_t: Set<UInt32>] {
        var result: [pid_t: Set<UInt32>] = [:]
        var copiedWindowLists = 0
        var eligibleWindows = 0
        var unresolvedWindowIDs = 0
        var incompleteApplications = 0

        for pid in pids {
            let appElement = AXUIElementCreateApplication(pid)

            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement]
            else {
                continue
            }
            copiedWindowLists += 1

            var ids = Set<UInt32>()
            var hasUnresolvedEligibleWindow = false

            for window in windows {
                if axBoolAttribute(kAXMinimizedAttribute as CFString, element: window) == true {
                    continue
                }
                eligibleWindows += 1

                if let windowId = axWindowNumber(for: window) {
                    ids.insert(windowId)
                } else {
                    hasUnresolvedEligibleWindow = true
                    unresolvedWindowIDs += 1
                }
            }

            // AXWindowNumber is not provided by every application/OS. A partial
            // map is unknown, not proof that the remaining CG windows are absent.
            // Preserve the existing unknown-map fallback to all other filters;
            // a known empty or minimized-only AX list still yields an empty set.
            if hasUnresolvedEligibleWindow {
                incompleteApplications += 1
            } else {
                result[pid] = ids
            }
        }

        diagnostics?(["axAppsWithWindowLists": copiedWindowLists,
                      "axEligibleWindows": eligibleWindows,
                      "axUnresolvedWindowIDs": unresolvedWindowIDs,
                      "axAppsWithIncompleteIDMap": incompleteApplications])
        return result
    }

    private static func axBoolAttribute(_ attribute: CFString, element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? Bool
    }

    private static func axWindowNumber(for window: AXUIElement) -> UInt32? {
        // Use the same existing CG identity resolver as exact input focus.
        // AXWindowNumber is only a fallback; many apps do not expose it.
        if let windowID = AccessibilityManager.cgWindowID(of: window) { return windowID }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXWindowNumberAttribute, &value) == .success,
              let number = value as? NSNumber
        else {
            return nil
        }

        let rawValue = number.uint64Value
        guard rawValue > 0, rawValue <= UInt64(UInt32.max) else { return nil }

        return UInt32(rawValue)
    }

    private static func passesAccessibilityWindowFilter(
        windowId: UInt32,
        pid: pid_t,
        axWindowIdsByPID: [pid_t: Set<UInt32>]
    ) -> Bool {
        guard let axWindowIds = axWindowIdsByPID[pid] else {
            return true
        }

        return axWindowIds.contains(windowId)
    }

    private static func windowHasVisiblePixels(windowId: UInt32, counts: inout [String: Int]) -> Bool {
        guard let image = CGWindowListCreateImageShim(
            .null,
            .optionIncludingWindow,
            CGWindowID(windowId),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            counts["missingPixelImages", default: 0] += 1
            return false
        }

        guard image.width > 1, image.height > 1 else {
            counts["invalidPixelImageSizes", default: 0] += 1
            return false
        }

        let hasPixels = imageContainsNonZeroPixels(image)
        if !hasPixels { counts["emptyPixelImages", default: 0] += 1 }
        return hasPixels
    }

    private static func imageContainsNonZeroPixels(_ image: CGImage) -> Bool {
        let sampleWidth = min(32, image.width)
        let sampleHeight = min(32, image.height)

        guard sampleWidth > 0, sampleHeight > 0 else {
            return false
        }

        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        let byteCount = bytesPerRow * sampleHeight

        let data = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { data.deallocate() }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: data,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return true
        }

        let sampleRect = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sampleWidth),
            height: CGFloat(sampleHeight)
        )

        context.interpolationQuality = .low
        context.draw(image, in: sampleRect)

        let pixels = data.bindMemory(to: UInt8.self, capacity: byteCount)

        for index in 0..<byteCount {
            if pixels[index] != 0 {
                return true
            }
        }

        return false
    }

    static var enumerationScope: WindowEnumerationScope {
        get {
            guard
                let rawValue = UserDefaults.standard.string(forKey: enumerationScopeDefaultsKey),
                let scope = WindowEnumerationScope(rawValue: rawValue)
            else {
                return .allSpaces
            }

            return scope
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: enumerationScopeDefaultsKey)
        }
    }

    static func enumerateWindows(scope: WindowEnumerationScope = WindowEnumerator.enumerationScope) -> [PeelWindow] {
        let options = scope.cgWindowListOptions
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        let regularAppsByPID: [pid_t: NSRunningApplication] = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications
                .filter { app in
                    app.activationPolicy == .regular &&
                    app.bundleIdentifier != nil &&
                    !app.isTerminated &&
                    !app.isHidden
                }
                .map { app in
                    (app.processIdentifier, app)
                }
        )
        
        let regularAppPIDs = Set(regularAppsByPID.keys)

        var counts = ["windowServerRows": windowListInfo.count, "regularApps": regularAppsByPID.count,
                      "accessibilityTrusted": AXIsProcessTrusted() ? 1 : 0,
                      "screenCapturePreflight": CGPreflightScreenCaptureAccess() ? 1 : 0]
        let axWindowIdsByPID = accessibilityWindowIdsByPID(for: regularAppPIDs) {
            counts.merge($0) { _, new in new }
        }
        counts["axAppsWithCompleteIDMap"] = axWindowIdsByPID.count
        counts["axAppsWithEmptyIDSet"] = axWindowIdsByPID.values.filter(\.isEmpty).count
        counts["axMappedWindowIDs"] = axWindowIdsByPID.values.reduce(0) { $0 + $1.count }

        var result: [PeelWindow] = []

        for info in windowListInfo {
            guard
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let windowId = info[kCGWindowNumber as String] as? UInt32,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                regularAppPIDs.contains(pid)
            else {
                continue
            }
            counts["normalLayerAppCandidates", default: 0] += 1

            if scope == .currentSpaceOnly {
                let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
                guard isOnscreen else { counts["offscreenRejected", default: 0] += 1; continue }
            }

            if let sharingState = info[kCGWindowSharingState as String] as? Int,
               sharingState == 0 {
                counts["sharingRejected", default: 0] += 1
                continue
            }

            if let alpha = info[kCGWindowAlpha as String] as? Double,
               alpha <= 0 {
                counts["alphaRejected", default: 0] += 1
                continue
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else {
                counts["boundsRejected", default: 0] += 1
                continue
            }

            let width = Int(bounds.width)
            let height = Int(bounds.height)

            guard width >= minimumWindowWidth, height >= minimumWindowHeight else {
                counts["sizeRejected", default: 0] += 1
                continue
            }

            guard passesAccessibilityWindowFilter(
                windowId: windowId,
                pid: pid,
                axWindowIdsByPID: axWindowIdsByPID
            ) else {
                counts["axRejected", default: 0] += 1
                continue
            }

            guard windowHasVisiblePixels(windowId: windowId, counts: &counts) else {
                counts["pixelsRejected", default: 0] += 1
                continue
            }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "Unknown App"
            let rawTitle = info[kCGWindowName as String] as? String ?? ""
            let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = trimmedTitle.isEmpty ? "Window" : trimmedTitle
            if trimmedTitle.isEmpty { counts["acceptedWithPlaceholderTitle", default: 0] += 1 }

            let statusSummary = trimmedTitle.isEmpty
                ? "\(ownerName) window"
                : "\(ownerName): \(displayTitle)"

            result.append(
                PeelWindow(
                    windowId: windowId,
                    appName: ownerName,
                    title: displayTitle,
                    width: width,
                    height: height,
                    statusSummary: statusSummary,
                    appIconPNGBase64: HostAppIconProvider.iconPNGBase64(for: pid),
                    appLaunchTimeIntervalSince1970: regularAppsByPID[pid]?.launchDate?.timeIntervalSince1970
                )
            )
        }

        counts["appWindowsAccepted"] = result.count
        let displays = PeelDisplayCaptureSource.peelWindows()
        counts["displayWindows"] = displays.count
        PeelWindowEnumerationDiagnostics.shared.record(scope: scope.rawValue, counts: counts)
        result.append(contentsOf: displays)
        return result
    }

    static func isDisplayCaptureWindowId(_ windowId: UInt32) -> Bool {
        PeelDisplayCaptureSource.isDisplayWindowId(windowId)
    }

    static func displayCaptureDisplayId(for windowId: UInt32) -> CGDirectDisplayID? {
        PeelDisplayCaptureSource.displayId(forWindowId: windowId)
    }

    static func ownerPID(for windowId: UInt32) -> pid_t? {
        let options = enumerationScope.cgWindowListOptions
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        for info in windowListInfo {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowId else { continue }

            if let pid = info[kCGWindowOwnerPID as String] as? pid_t {
                return pid
            }
        }

        return nil
    }

    static func bounds(for windowId: UInt32) -> CGRect? {
        if let display = PeelDisplayCaptureSource.descriptor(forWindowId: windowId) {
            return display.bounds
        }

        let options = enumerationScope.cgWindowListOptions
        let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        for info in windowListInfo {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  id == windowId else { continue }

            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict) {
                return bounds
            }
        }

        return nil
    }

    static func inputGeometry(for windowId: UInt32) -> InputGeometry? {
        guard let streamBounds = bounds(for: windowId) else { return nil }

        if isDisplayCaptureWindowId(windowId) {
            return InputGeometry(streamBounds: streamBounds, capturedBounds: streamBounds)
        }

        let capturedBounds = fullscreenCapturedBounds(for: streamBounds) ?? streamBounds
        return InputGeometry(streamBounds: streamBounds, capturedBounds: capturedBounds)
    }

    private static func fullscreenCapturedBounds(for windowBounds: CGRect) -> CGRect? {
        guard let display = PeelDisplayCaptureSource.descriptors().first(where: {
            $0.bounds.contains(CGPoint(x: windowBounds.midX, y: windowBounds.midY))
        }) else {
            return nil
        }

        let displayBounds = display.bounds
        let tolerance = fullscreenGeometryTolerance
        let spansDisplayWidth = abs(windowBounds.minX - displayBounds.minX) <= tolerance &&
            abs(windowBounds.maxX - displayBounds.maxX) <= tolerance
        let reachesDisplayBottom = abs(windowBounds.maxY - displayBounds.maxY) <= tolerance

        guard spansDisplayWidth, reachesDisplayBottom else { return nil }

        let topSystemInset = screen(for: display.displayId).map {
            max(0, $0.frame.maxY - $0.visibleFrame.maxY)
        } ?? 0
        let fullscreenBounds = CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY + topSystemInset,
            width: displayBounds.width,
            height: max(0, displayBounds.height - topSystemInset)
        )

        let topChromeHeight = windowBounds.minY - fullscreenBounds.minY
        guard topChromeHeight >= -tolerance,
              topChromeHeight <= maximumFullscreenChromeHeight,
              windowBounds.height >= fullscreenBounds.height * 0.7 else {
            return nil
        }

        return fullscreenBounds
    }

    private static func screen(for displayId: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return false }
            return number.uint32Value == displayId
        }
    }
}

@_silgen_name("CGWindowListCreateImage")
nonisolated func CGWindowListCreateImageShim(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> CGImage?
