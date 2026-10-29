//
//  WindowHandoff.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


import Foundation
import Combine
import Network
import ImageIO
import AVFoundation
import VideoToolbox

#if canImport(UIKit)
import UIKit
#endif

extension PeelClientBrowser {
    // MARK: - Host command helpers
    
    func openLauncherFolder() {
        let baselineWindows = windows.isEmpty ? Array(lastWindowListById.values) : windows
        pendingLauncherExistingFinderWindowIds = Set(
            baselineWindows
                .filter { isFinderWindow($0) }
                .map(\.windowId)
        )
        pendingLauncherCommandIssuedAt = Date()
        pendingHostCommandAutoOpenWindow = nil
        pendingLauncherSuccessorWindow = nil
        pendingLauncherTrackedFinderWindowId = nil
        pendingLauncherSuccessorIssuedAt = nil
        sendHostCommand(.openLauncherFolder)
    }
    
    var pendingLauncherSuccessorWindow: PeelWindow? {
        get { _pendingLauncherSuccessorWindow }
        set { _pendingLauncherSuccessorWindow = newValue }
    }
    
    var pendingLauncherTrackedFinderWindowId: UInt32? {
        get { _pendingLauncherTrackedFinderWindowId }
        set { _pendingLauncherTrackedFinderWindowId = newValue }
    }
    
    var pendingLauncherSuccessorIssuedAt: Date? {
        get { _pendingLauncherSuccessorIssuedAt }
        set { _pendingLauncherSuccessorIssuedAt = newValue }
    }
    
    func clearPendingLauncherSuccessorTracking() {
        pendingLauncherSuccessorWindow = nil
        pendingLauncherTrackedFinderWindowId = nil
        pendingLauncherSuccessorIssuedAt = nil
    }
    
    func consumePendingLauncherSuccessor(for sourceWindowId: UInt32) -> PeelWindow? {
        guard pendingLauncherTrackedFinderWindowId == sourceWindowId else {
            return nil
        }
        
        let window = pendingLauncherSuccessorWindow
        clearPendingLauncherSuccessorTracking()
        return window
    }
    
    func sendHostCommand(_ command: HostCommandKind,
                         path: String? = nil,
                         windowId: UInt32? = nil) {
        let message = HostCommandMessage(command: command, path: path, windowId: windowId)
        sendJSONMessage(message)
    }

    func supportsHostCapability(_ capability: PeelCapability) -> Bool {
        hostCapabilities.contains(capability.rawValue)
    }

    func switchSpaceLeft() {
        guard supportsHostCapability(.spaceSwitching) else { return }
        sendHostCommand(.switchSpaceLeft)
    }

    func switchSpaceRight() {
        guard supportsHostCapability(.spaceSwitching) else { return }
        sendHostCommand(.switchSpaceRight)
    }
    
    func consumePendingHostCommandAutoOpenWindow() -> PeelWindow? {
        let window = pendingHostCommandAutoOpenWindow
        pendingHostCommandAutoOpenWindow = nil
        
        if let window {
            pendingLauncherTrackedFinderWindowId = window.windowId
            pendingLauncherSuccessorIssuedAt = Date()
            pendingLauncherSuccessorWindow = nil
        }
        
        return window
    }
    
    func processWindowListForPendingHostCommandAutoOpen(_ newWindows: [PeelWindow]) {
        guard let issuedAt = pendingLauncherCommandIssuedAt else { return }
        
        if Date().timeIntervalSince(issuedAt) > launcherCommandAutoOpenTimeout {
            pendingLauncherCommandIssuedAt = nil
            pendingLauncherExistingFinderWindowIds.removeAll()
            pendingHostCommandAutoOpenWindow = nil
            return
        }
        
        guard pendingHostCommandAutoOpenWindow == nil else { return }
        
        let newFinderWindows = newWindows.filter {
            isFinderWindow($0) &&
            !pendingLauncherExistingFinderWindowIds.contains($0.windowId)
        }
        
        let candidate =
        newFinderWindows.first(where: { isLikelyLauncherFolderWindow($0) }) ??
        newFinderWindows.sorted(by: { windowArea($0) > windowArea($1) }).first ??
        newWindows.first(where: { isLikelyLauncherFolderWindow($0) })
        
        guard let candidate else { return }
        
        pendingHostCommandAutoOpenWindow = candidate
        pendingLauncherCommandIssuedAt = nil
        pendingLauncherExistingFinderWindowIds.removeAll()
        
        print("HOSTCOMMAND auto-open queued window=\(candidate.windowId) app=\(candidate.appName) title=\(candidate.title)")
    }
    
    func processWindowListForPendingLauncherSuccessor(_ newWindows: [PeelWindow]) {
        guard let trackedFinderWindowId = pendingLauncherTrackedFinderWindowId,
              let issuedAt = pendingLauncherSuccessorIssuedAt else {
            return
        }
        
        if Date().timeIntervalSince(issuedAt) > launcherCommandAutoOpenTimeout {
            clearPendingLauncherSuccessorTracking()
            return
        }
        
        guard pendingLauncherSuccessorWindow == nil else { return }
        
        let previousIds = Set(lastWindowListById.keys)
        let trackedFinderStillExists = newWindows.contains { $0.windowId == trackedFinderWindowId }
        
        let candidate = newWindows
            .filter { window in
                !previousIds.contains(window.windowId) &&
                !isFinderWindow(window)
            }
            .sorted { lhs, rhs in
                let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if lhsTitle.isEmpty != rhsTitle.isEmpty {
                    return !lhsTitle.isEmpty
                }
                
                return windowArea(lhs) > windowArea(rhs)
            }
            .first
        
        guard let candidate else {
            if !trackedFinderStillExists {
                clearPendingLauncherSuccessorTracking()
            }
            return
        }
        
        pendingLauncherSuccessorWindow = candidate
        
        print("LAUNCHER successor queued source=\(trackedFinderWindowId) child=\(candidate.windowId) app=\(candidate.appName) title=\(candidate.title)")
    }
    
    func isFinderWindow(_ window: PeelWindow) -> Bool {
        normalizedWindowAppName(window.appName) == "finder"
    }
    
    func isLikelyLauncherFolderWindow(_ window: PeelWindow) -> Bool {
        guard isFinderWindow(window) else { return false }
        
        let normalizedTitle = window.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        
        return normalizedTitle == "applications" ||
        normalizedTitle.contains("applications")
    }

    // MARK: - Popup handoff helpers

    var enableAutoPopupParentFallback: Bool {
        false
    }

    var enableAutoPopupHandoff: Bool {
        false
    }
    
    func recordUserInteraction(windowId: UInt32?) {
        guard let windowId else { return }
        lastUserInteractionWindowId = windowId
        lastUserInteractionAt = Date()
    }
    
    func consumeAutoPopupHandoff(from sourceWindowId: UInt32) -> PeelWindow? {
        guard enableAutoPopupHandoff else {
            return nil
        }
        
        guard let popup = pendingAutoPopupBySource.removeValue(forKey: sourceWindowId) else {
            return nil
        }
        
        autoPopupParentByChild[popup.windowId] = sourceWindowId
        print("AUTOPOPUP consume source=\(sourceWindowId) child=\(popup.windowId) app=\(popup.appName) title=\(popup.title)")
        return popup
    }
    
    func isAutoPopupWindow(_ windowId: UInt32) -> Bool {
        autoPopupParentByChild[windowId] != nil
    }
    
    func returnParentWindow(forAutoPopup childWindowId: UInt32) -> PeelWindow? {
        guard enableAutoPopupParentFallback else {
            return nil
        }

        guard let parentId = autoPopupParentByChild[childWindowId] else {
            return nil
        }
        
        return windows.first(where: { $0.windowId == parentId })
        ?? lastWindowListById[parentId]
    }
    
    func clearAutoPopupTracking(for childWindowId: UInt32) {
        if let parentId = autoPopupParentByChild[childWindowId] {
            print("AUTOPOPUP clear child=\(childWindowId) parent=\(parentId)")
        }
        autoPopupParentByChild.removeValue(forKey: childWindowId)
    }
    
    func normalizedWindowAppName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
    
    func windowArea(_ window: PeelWindow) -> Int {
        max(1, window.width) * max(1, window.height)
    }

    func isExternallyGeneratedSCKSurface(_ window: PeelWindow) -> Bool {
        let normalizedTitle = window.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        
        // StreamCaptureKit can expose implementation surfaces titled only "window".
        // Keep them available to internal tracking code, but do not publish them into
        // the user-facing picker/list because they look broken and are not meaningful targets.
        return normalizedTitle == "window"
    }
    
    func userVisibleWindows(from rawWindows: [PeelWindow]) -> [PeelWindow] {
        rawWindows.filter { !isExternallyGeneratedSCKSurface($0) }
    }
    
    func isLikelyAutoPopupCandidate(_ candidate: PeelWindow, from source: PeelWindow) -> Bool {
        guard candidate.windowId != source.windowId else { return false }
        
        let sourceApp = normalizedWindowAppName(source.appName)
        let candidateApp = normalizedWindowAppName(candidate.appName)
        guard !sourceApp.isEmpty, sourceApp == candidateApp else { return false }
        
        guard candidate.width >= minAutoPopupWidth,
              candidate.height >= minAutoPopupHeight else {
            return false
        }
        
        let sourceWidth = max(1, source.width)
        let sourceHeight = max(1, source.height)
        
        let candidateWidthRatio = Double(candidate.width) / Double(sourceWidth)
        let candidateHeightRatio = Double(candidate.height) / Double(sourceHeight)
        let candidateAreaRatio = Double(windowArea(candidate)) / Double(windowArea(source))
        
        if candidateWidthRatio > maxAutoPopupDimensionRatio { return false }
        if candidateHeightRatio > maxAutoPopupDimensionRatio { return false }
        if candidateAreaRatio > maxAutoPopupAreaRatio { return false }
        
        let sameTitle = candidate.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(source.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        
        if sameTitle,
           abs(candidate.width - source.width) < 24,
           abs(candidate.height - source.height) < 24 {
            return false
        }
        
        return true
    }
    
    func processWindowListForAutoPopup(_ newWindows: [PeelWindow]) {
        guard enableAutoPopupHandoff else {
            lastWindowListById = Dictionary(uniqueKeysWithValues: newWindows.map { ($0.windowId, $0) })
            pendingAutoPopupBySource.removeAll()
            autoPopupParentByChild.removeAll()
            return
        }
        
        let now = Date()
        let newById = Dictionary(uniqueKeysWithValues: newWindows.map { ($0.windowId, $0) })
        
        defer {
            lastWindowListById = newById
        }
        
        pendingAutoPopupBySource = pendingAutoPopupBySource.filter { sourceId, popup in
            let keep = newById[sourceId] != nil && newById[popup.windowId] != nil
            if !keep {
                print("AUTOPOPUP drop-pending source=\(sourceId) child=\(popup.windowId)")
            }
            return keep
        }
        
        guard let sourceWindowId = lastUserInteractionWindowId else {
            return
        }
        
        guard now.timeIntervalSince(lastUserInteractionAt) <= autoPopupInteractionWindow else {
            return
        }
        
        guard autoPopupParentByChild[sourceWindowId] == nil else {
            return
        }
        
        guard !autoPopupParentByChild.values.contains(sourceWindowId) else {
            return
        }
        
        guard pendingAutoPopupBySource[sourceWindowId] == nil else {
            return
        }
        
        if let lastAutoPopupAt = lastAutoPopupAtBySource[sourceWindowId],
           now.timeIntervalSince(lastAutoPopupAt) < autoPopupCooldown {
            return
        }
        
        guard let sourceWindow = newById[sourceWindowId] ?? lastWindowListById[sourceWindowId] else {
            print("AUTOPOPUP no-source source=\(sourceWindowId)")
            return
        }
        
        let previousIds = Set(lastWindowListById.keys)
        
        let newCandidates = newWindows.filter { window in
            !previousIds.contains(window.windowId) &&
            !isExternallyGeneratedSCKSurface(window) &&
            isLikelyAutoPopupCandidate(window, from: sourceWindow)
        }
        
        if !newCandidates.isEmpty {
            let candidateSummary = newCandidates
                .map { "\($0.windowId):\($0.appName):\($0.title)" }
                .joined(separator: " | ")
            
            print("AUTOPOPUP detect source=\(sourceWindow.windowId) app=\(sourceWindow.appName) title=\(sourceWindow.title) candidates=\(candidateSummary)")
        }
        
        guard !newCandidates.isEmpty else { return }
        
        let bestCandidate = newCandidates.sorted { lhs, rhs in
            let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if lhsTitle.isEmpty != rhsTitle.isEmpty {
                return !lhsTitle.isEmpty
            }
            
            return windowArea(lhs) < windowArea(rhs)
        }.first
        
        guard let bestCandidate else { return }
        
        pendingAutoPopupBySource[sourceWindowId] = bestCandidate
        lastAutoPopupAtBySource[sourceWindowId] = now
        
        print("AUTOPOPUP queue source=\(sourceWindowId) child=\(bestCandidate.windowId) app=\(bestCandidate.appName) title=\(bestCandidate.title)")
    }
}


// MARK: - Per-host session window handoff
extension PeelHostSession {
    // MARK: - Host command helpers
    
    func openLauncherFolder() {
        let baselineWindows = windows.isEmpty ? Array(lastWindowListById.values) : windows
        pendingLauncherExistingFinderWindowIds = Set(
            baselineWindows
                .filter { isFinderWindow($0) }
                .map(\.windowId)
        )
        pendingLauncherCommandIssuedAt = Date()
        pendingHostCommandAutoOpenWindow = nil
        pendingLauncherSuccessorWindow = nil
        pendingLauncherTrackedFinderWindowId = nil
        pendingLauncherSuccessorIssuedAt = nil
        sendHostCommand(.openLauncherFolder)
    }
    
    var pendingLauncherSuccessorWindow: PeelWindow? {
        get { _pendingLauncherSuccessorWindow }
        set { _pendingLauncherSuccessorWindow = newValue }
    }
    
    var pendingLauncherTrackedFinderWindowId: UInt32? {
        get { _pendingLauncherTrackedFinderWindowId }
        set { _pendingLauncherTrackedFinderWindowId = newValue }
    }
    
    var pendingLauncherSuccessorIssuedAt: Date? {
        get { _pendingLauncherSuccessorIssuedAt }
        set { _pendingLauncherSuccessorIssuedAt = newValue }
    }
    
    func clearPendingLauncherSuccessorTracking() {
        pendingLauncherSuccessorWindow = nil
        pendingLauncherTrackedFinderWindowId = nil
        pendingLauncherSuccessorIssuedAt = nil
    }
    
    func consumePendingLauncherSuccessor(for sourceWindowId: UInt32) -> PeelWindow? {
        guard pendingLauncherTrackedFinderWindowId == sourceWindowId else {
            return nil
        }
        
        let window = pendingLauncherSuccessorWindow
        clearPendingLauncherSuccessorTracking()
        return window
    }
    
    func sendHostCommand(_ command: HostCommandKind,
                         path: String? = nil,
                         windowId: UInt32? = nil) {
        let message = HostCommandMessage(command: command, path: path, windowId: windowId)
        sendJSONMessage(message)
    }

    func supportsHostCapability(_ capability: PeelCapability) -> Bool {
        hostCapabilities.contains(capability.rawValue)
    }

    func switchSpaceLeft() {
        guard supportsHostCapability(.spaceSwitching) else { return }
        sendHostCommand(.switchSpaceLeft)
    }

    func switchSpaceRight() {
        guard supportsHostCapability(.spaceSwitching) else { return }
        sendHostCommand(.switchSpaceRight)
    }
    
    func consumePendingHostCommandAutoOpenWindow() -> PeelWindow? {
        let window = pendingHostCommandAutoOpenWindow
        pendingHostCommandAutoOpenWindow = nil
        
        if let window {
            pendingLauncherTrackedFinderWindowId = window.windowId
            pendingLauncherSuccessorIssuedAt = Date()
            pendingLauncherSuccessorWindow = nil
        }
        
        return window
    }
    
    func processWindowListForPendingHostCommandAutoOpen(_ newWindows: [PeelWindow]) {
        guard let issuedAt = pendingLauncherCommandIssuedAt else { return }
        
        if Date().timeIntervalSince(issuedAt) > launcherCommandAutoOpenTimeout {
            pendingLauncherCommandIssuedAt = nil
            pendingLauncherExistingFinderWindowIds.removeAll()
            pendingHostCommandAutoOpenWindow = nil
            return
        }
        
        guard pendingHostCommandAutoOpenWindow == nil else { return }
        
        let newFinderWindows = newWindows.filter {
            isFinderWindow($0) &&
            !pendingLauncherExistingFinderWindowIds.contains($0.windowId)
        }
        
        let candidate =
        newFinderWindows.first(where: { isLikelyLauncherFolderWindow($0) }) ??
        newFinderWindows.sorted(by: { windowArea($0) > windowArea($1) }).first ??
        newWindows.first(where: { isLikelyLauncherFolderWindow($0) })
        
        guard let candidate else { return }
        
        pendingHostCommandAutoOpenWindow = candidate
        pendingLauncherCommandIssuedAt = nil
        pendingLauncherExistingFinderWindowIds.removeAll()
        
        print("HOSTCOMMAND auto-open queued window=\(candidate.windowId) app=\(candidate.appName) title=\(candidate.title)")
    }
    
    func processWindowListForPendingLauncherSuccessor(_ newWindows: [PeelWindow]) {
        guard let trackedFinderWindowId = pendingLauncherTrackedFinderWindowId,
              let issuedAt = pendingLauncherSuccessorIssuedAt else {
            return
        }
        
        if Date().timeIntervalSince(issuedAt) > launcherCommandAutoOpenTimeout {
            clearPendingLauncherSuccessorTracking()
            return
        }
        
        guard pendingLauncherSuccessorWindow == nil else { return }
        
        let previousIds = Set(lastWindowListById.keys)
        let trackedFinderStillExists = newWindows.contains { $0.windowId == trackedFinderWindowId }
        
        let candidate = newWindows
            .filter { window in
                !previousIds.contains(window.windowId) &&
                !isFinderWindow(window)
            }
            .sorted { lhs, rhs in
                let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if lhsTitle.isEmpty != rhsTitle.isEmpty {
                    return !lhsTitle.isEmpty
                }
                
                return windowArea(lhs) > windowArea(rhs)
            }
            .first
        
        guard let candidate else {
            if !trackedFinderStillExists {
                clearPendingLauncherSuccessorTracking()
            }
            return
        }
        
        pendingLauncherSuccessorWindow = candidate
        
        print("LAUNCHER successor queued source=\(trackedFinderWindowId) child=\(candidate.windowId) app=\(candidate.appName) title=\(candidate.title)")
    }
    
    func isFinderWindow(_ window: PeelWindow) -> Bool {
        normalizedWindowAppName(window.appName) == "finder"
    }
    
    func isLikelyLauncherFolderWindow(_ window: PeelWindow) -> Bool {
        guard isFinderWindow(window) else { return false }
        
        let normalizedTitle = window.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        
        return normalizedTitle == "applications" ||
        normalizedTitle.contains("applications")
    }

    // MARK: - Popup handoff helpers

    var enableAutoPopupParentFallback: Bool {
        false
    }

    var enableAutoPopupHandoff: Bool {
        false
    }
    
    func recordUserInteraction(windowId: UInt32?) {
        guard let windowId else { return }
        lastUserInteractionWindowId = windowId
        lastUserInteractionAt = Date()
    }
    
    func consumeAutoPopupHandoff(from sourceWindowId: UInt32) -> PeelWindow? {
        guard enableAutoPopupHandoff else {
            return nil
        }
        
        guard let popup = pendingAutoPopupBySource.removeValue(forKey: sourceWindowId) else {
            return nil
        }
        
        autoPopupParentByChild[popup.windowId] = sourceWindowId
        print("AUTOPOPUP consume source=\(sourceWindowId) child=\(popup.windowId) app=\(popup.appName) title=\(popup.title)")
        return popup
    }
    
    func isAutoPopupWindow(_ windowId: UInt32) -> Bool {
        autoPopupParentByChild[windowId] != nil
    }
    
    func returnParentWindow(forAutoPopup childWindowId: UInt32) -> PeelWindow? {
        guard enableAutoPopupParentFallback else {
            return nil
        }

        guard let parentId = autoPopupParentByChild[childWindowId] else {
            return nil
        }
        
        return windows.first(where: { $0.windowId == parentId })
        ?? lastWindowListById[parentId]
    }
    
    func clearAutoPopupTracking(for childWindowId: UInt32) {
        if let parentId = autoPopupParentByChild[childWindowId] {
            print("AUTOPOPUP clear child=\(childWindowId) parent=\(parentId)")
        }
        autoPopupParentByChild.removeValue(forKey: childWindowId)
    }
    
    func normalizedWindowAppName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
    
    func windowArea(_ window: PeelWindow) -> Int {
        max(1, window.width) * max(1, window.height)
    }

    func isExternallyGeneratedSCKSurface(_ window: PeelWindow) -> Bool {
        let normalizedTitle = window.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        
        // StreamCaptureKit can expose implementation surfaces titled only "window".
        // Keep them available to internal tracking code, but do not publish them into
        // the user-facing picker/list because they look broken and are not meaningful targets.
        return normalizedTitle == "window"
    }
    
    func userVisibleWindows(from rawWindows: [PeelWindow]) -> [PeelWindow] {
        rawWindows.filter { !isExternallyGeneratedSCKSurface($0) }
    }
    
    func isLikelyAutoPopupCandidate(_ candidate: PeelWindow, from source: PeelWindow) -> Bool {
        guard candidate.windowId != source.windowId else { return false }
        
        let sourceApp = normalizedWindowAppName(source.appName)
        let candidateApp = normalizedWindowAppName(candidate.appName)
        guard !sourceApp.isEmpty, sourceApp == candidateApp else { return false }
        
        guard candidate.width >= minAutoPopupWidth,
              candidate.height >= minAutoPopupHeight else {
            return false
        }
        
        let sourceWidth = max(1, source.width)
        let sourceHeight = max(1, source.height)
        
        let candidateWidthRatio = Double(candidate.width) / Double(sourceWidth)
        let candidateHeightRatio = Double(candidate.height) / Double(sourceHeight)
        let candidateAreaRatio = Double(windowArea(candidate)) / Double(windowArea(source))
        
        if candidateWidthRatio > maxAutoPopupDimensionRatio { return false }
        if candidateHeightRatio > maxAutoPopupDimensionRatio { return false }
        if candidateAreaRatio > maxAutoPopupAreaRatio { return false }
        
        let sameTitle = candidate.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(source.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        
        if sameTitle,
           abs(candidate.width - source.width) < 24,
           abs(candidate.height - source.height) < 24 {
            return false
        }
        
        return true
    }
    
    func processWindowListForAutoPopup(_ newWindows: [PeelWindow]) {
        guard enableAutoPopupHandoff else {
            lastWindowListById = Dictionary(uniqueKeysWithValues: newWindows.map { ($0.windowId, $0) })
            pendingAutoPopupBySource.removeAll()
            autoPopupParentByChild.removeAll()
            return
        }
        
        let now = Date()
        let newById = Dictionary(uniqueKeysWithValues: newWindows.map { ($0.windowId, $0) })
        
        defer {
            lastWindowListById = newById
        }
        
        pendingAutoPopupBySource = pendingAutoPopupBySource.filter { sourceId, popup in
            let keep = newById[sourceId] != nil && newById[popup.windowId] != nil
            if !keep {
                print("AUTOPOPUP drop-pending source=\(sourceId) child=\(popup.windowId)")
            }
            return keep
        }
        
        guard let sourceWindowId = lastUserInteractionWindowId else {
            return
        }
        
        guard now.timeIntervalSince(lastUserInteractionAt) <= autoPopupInteractionWindow else {
            return
        }
        
        guard autoPopupParentByChild[sourceWindowId] == nil else {
            return
        }
        
        guard !autoPopupParentByChild.values.contains(sourceWindowId) else {
            return
        }
        
        guard pendingAutoPopupBySource[sourceWindowId] == nil else {
            return
        }
        
        if let lastAutoPopupAt = lastAutoPopupAtBySource[sourceWindowId],
           now.timeIntervalSince(lastAutoPopupAt) < autoPopupCooldown {
            return
        }
        
        guard let sourceWindow = newById[sourceWindowId] ?? lastWindowListById[sourceWindowId] else {
            print("AUTOPOPUP no-source source=\(sourceWindowId)")
            return
        }
        
        let previousIds = Set(lastWindowListById.keys)
        
        let newCandidates = newWindows.filter { window in
            !previousIds.contains(window.windowId) &&
            !isExternallyGeneratedSCKSurface(window) &&
            isLikelyAutoPopupCandidate(window, from: sourceWindow)
        }
        
        if !newCandidates.isEmpty {
            let candidateSummary = newCandidates
                .map { "\($0.windowId):\($0.appName):\($0.title)" }
                .joined(separator: " | ")
            
            print("AUTOPOPUP detect source=\(sourceWindow.windowId) app=\(sourceWindow.appName) title=\(sourceWindow.title) candidates=\(candidateSummary)")
        }
        
        guard !newCandidates.isEmpty else { return }
        
        let bestCandidate = newCandidates.sorted { lhs, rhs in
            let lhsTitle = lhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsTitle = rhs.title.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if lhsTitle.isEmpty != rhsTitle.isEmpty {
                return !lhsTitle.isEmpty
            }
            
            return windowArea(lhs) < windowArea(rhs)
        }.first
        
        guard let bestCandidate else { return }
        
        pendingAutoPopupBySource[sourceWindowId] = bestCandidate
        lastAutoPopupAtBySource[sourceWindowId] = now
        
        print("AUTOPOPUP queue source=\(sourceWindowId) child=\(bestCandidate.windowId) app=\(bestCandidate.appName) title=\(bestCandidate.title)")
    }
}
