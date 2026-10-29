
import SwiftUI

enum PeelAppWindowSortOrder: String, CaseIterable, Identifiable {
    case recentlyUsed
    case leastRecentlyUsed
    case longestRunning
    case shortestRunning
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .recentlyUsed:
            return "Recently Used"
        case .leastRecentlyUsed:
            return "Least Recently Used"
        case .longestRunning:
            return "Longest Running"
        case .shortestRunning:
            return "Shortest Running"
        }
    }
}
struct ContentView: View {
    @EnvironmentObject private var browser: PeelClientBrowser
    @EnvironmentObject private var scenes: SceneCoordinator
    @EnvironmentObject private var store: PeelStore
    @Environment(\.colorScheme) private var colorScheme
    
    @Environment(\.openWindow) private var openWindow
#if os(visionOS)
    @Environment(\.dismissWindow) private var dismissWindow
#endif
    @Environment(\.openURL) private var openURL
    
    @AppStorage("peel.openTopAppsLimit") private var openTopAppsLimit: Int = 5
    @AppStorage("Peel.appWindowSortOrder") private var appWindowSortOrderRawValue: String = PeelAppWindowSortOrder.recentlyUsed.rawValue
    @AppStorage("peel.showHUDTab") private var showHUDTab: Bool = false
    
    @State private var showingPairSheet: Bool = false
    @State private var pairingHost: PeelHostInfo? = nil
    @State private var pairingToken: String = ""
    
    @State private var showingWindowCapacityAlert = false
    @State private var proFeature: PeelProFeature?
    @State private var showingAbout: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingAudio: Bool = false
    @State private var showingMachineStatus: Bool = false
    @State private var locallyPendingHostIDs: Set<PeelHostInfo.ID> = []
    @State private var disconnectCooldownUntil: Date? = nil
    @State private var currentScene: UIWindowScene? = nil
    @State private var openPeeledWindowCountSnapshot: Int = 0
    
    @State private var selectedTab: ContentTab = .macs
    
    @State private var pairingPIN: String = ""
    @State private var showAdvancedToken: Bool = false
    @StateObject private var hostAppearanceStore = PeelHostAppearanceStore()
    @State private var appearanceEditorHost: PeelHostInfo? = nil
    @State private var forgetPairingHost: PeelHostInfo? = nil
    @State private var forgetSavedPairingMac: PeelSavedPairedMac? = nil
    private let peelHostDownloadURL = URL(string: "https://peelpro.app")!

    /// Session changes are forwarded through the browser's objectWillChange.
    private var isComputerAudioPlaying: Bool {
        browser.sessionsByHostKey.values.contains { $0.systemAudioPlaying }
    }

    private enum ContentTab: Hashable {
        case macs
        case apps
        case displays
        case hud
        case more
    }
    
    private func displayNameWithoutPeelPrefix(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let proPrefix = "Peel Pro on "
        let legacyPrefix = "Peel on "
        
        if trimmed.range(of: proPrefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(proPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        if trimmed.range(of: legacyPrefix, options: [.caseInsensitive, .anchored]) != nil {
            return String(trimmed.dropFirst(legacyPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return trimmed
    }
    
    private func hostDisplayName(for host: PeelHostInfo) -> String {
        displayNameWithoutPeelPrefix(host.name)
    }
    
    private func displayWindowTitle(for window: PeelWindow) -> String {
        if isDisplayCaptureWindow(window),
           let connectedHostName = browser.connectedHostName {
            return displayNameWithoutPeelPrefix(connectedHostName)
        }
        
        let cleanedTitle = displayNameWithoutPeelPrefix(window.title)
        
        if !cleanedTitle.isEmpty &&
            cleanedTitle != "Mac Display" &&
            cleanedTitle != "Peel Display" &&
            cleanedTitle != "Peel Pro Display" {
            return cleanedTitle
        }
        
        return "Peel Pro Display"
    }
    
    private func displayWindowTitle(for hostedWindow: HostedPeelWindow) -> String {
        let hostName = displayNameWithoutPeelPrefix(hostedWindow.hostName)
        let cleanedTitle = displayNameWithoutPeelPrefix(hostedWindow.window.title)
        
        guard !cleanedTitle.isEmpty,
              cleanedTitle != "Mac Display",
              cleanedTitle != "Peel Display",
              cleanedTitle != "Peel Pro Display" else {
            return "\(hostName) · Peel Pro Display"
        }
        
        return "\(hostName) · \(cleanedTitle)"
    }
    
    private func openSelectedWindow(_ window: PeelWindow) {
        openSelectedWindow(legacyHostedWindow(for: window))
    }

    @discardableResult
    private func openSelectedWindow(_ hostedWindow: HostedPeelWindow) -> Bool {
        let window = hostedWindow.window
        let session = browser.session(for: hostedWindow.hostKey)
        
        if scenes.activatePeeledWindowIfPossible(for: hostedWindow) {
            session?.recordFocusedWindowId(window.windowId)
            session?.setActiveWindow(window.windowId)
            refreshOpenPeeledWindowCountSnapshot()
            return true
        }

        if scenes.isPeeledWindowOpen(hostedWindow) { return true }
        guard scenes.reservePeeledWindowScene(for: hostedWindow, mode: .resizable) else {
            if !store.hasProAccess { proFeature = .multipleWindows }
            else { showingWindowCapacityAlert = true }
            return false
        }

        session?.recordFocusedWindowId(window.windowId)
        session?.setActiveWindow(window.windowId)
        refreshOpenPeeledWindowCountSnapshot()
        openWindow(id: "peeled-window-resizable", value: PeeledWindowSceneRequest(hostedWindow: hostedWindow))
        return true
    }
    
    private func handleWindowOpenButtonTapped(_ hostedWindow: HostedPeelWindow) {
        openSelectedWindow(hostedWindow)
    }
    
    private func handleWindowOpenButtonTapped(_ window: PeelWindow) {
        openSelectedWindow(window)
    }
    
    private var unopenedAppWindowCount: Int {
        hostedAppWindows.filter { !scenes.isPeeledWindowOpen($0) }.count
    }
    
    private var areAllAvailableAppsOpen: Bool {
        !hostedAppWindows.isEmpty && unopenedAppWindowCount == 0
    }
    private var remainingPeeledWindowSlots: Int {
        max(0, scenes.maxPeeledWindowSceneCount - openPeeledWindowCountSnapshot)
    }
    private var topAppWindows: [HostedPeelWindow] {
        Array(hostedAppWindows.prefix(openTopAppsLimit))
    }
    
    private var unopenedTopAppWindows: [HostedPeelWindow] {
        topAppWindows.filter { !scenes.isPeeledWindowOpen($0) }
    }
    
    private var canOpenTopApps: Bool {
        !topAppWindows.isEmpty && (remainingPeeledWindowSlots > 0 || unopenedTopAppWindows.isEmpty)
    }
    
    private var quickOpenSymbolName: String {
        scenes.peeledWindowPlacementMode == .balancedSlots ? "square.grid.3x3.fill" : "rectangle.split.3x1.fill"
    }
    
    private func openAllAvailableApps() {
        let candidateWindows = unopenedTopAppWindows.isEmpty ? topAppWindows : unopenedTopAppWindows
        let sceneSlots = max(remainingPeeledWindowSlots, unopenedTopAppWindows.isEmpty ? candidateWindows.count : 0)
        let allowedSlots = sceneSlots
        guard allowedSlots > 0 else { return }
        
        let windows = Array(candidateWindows.prefix(allowedSlots))
        
        Task { @MainActor in
            for window in windows {
                // Re-read live reservations after every request: a batch must
                // stop at the first paid addition rather than silently drop it.
                guard openSelectedWindow(window) else { break }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
    
    private func closeAllAvailableApps() {
#if os(visionOS)
        for hostedWindow in scenes.openHostedPeeledWindows() where !isDisplayCaptureWindow(hostedWindow.window) {
            _ = scenes.closePeeledWindowScene(for: hostedWindow)
        }

        // Fallback for any SwiftUI value scene the coordinator did not observe yet.
        dismissWindow(id: "peeled-window")
        dismissWindow(id: "peeled-window-resizable")
        refreshOpenPeeledWindowCountSnapshot()
#endif
    }

    private func closeSelectedWindow(_ window: PeelWindow) {
#if os(visionOS)
        _ = scenes.closePeeledWindowScene(for: window)

        // Fallback only. PeeledWindowSceneRequest now has stable identity,
        // so this value matches the one used by openWindow(id:value:).
        dismissWindow(id: "peeled-window", value: PeeledWindowSceneRequest(window: window))
        dismissWindow(id: "peeled-window-resizable", value: PeeledWindowSceneRequest(window: window))
        refreshOpenPeeledWindowCountSnapshot()
#endif
    }
    
    private func closeSelectedWindow(_ hostedWindow: HostedPeelWindow) {
#if os(visionOS)
        _ = scenes.closePeeledWindowScene(for: hostedWindow)

        // Fallback only. PeeledWindowSceneRequest has stable host-scoped identity,
        // so this value matches the one used by openWindow(id:value:).
        dismissWindow(id: "peeled-window", value: PeeledWindowSceneRequest(hostedWindow: hostedWindow))
        dismissWindow(id: "peeled-window-resizable", value: PeeledWindowSceneRequest(hostedWindow: hostedWindow))
        refreshOpenPeeledWindowCountSnapshot()
#endif
    }
    
    private func isDisplayCaptureWindow(_ window: PeelWindow) -> Bool {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return appName == "Peel Display" || appName == "Peel Pro Display"
    }
    
    private var appWindowSortOrder: PeelAppWindowSortOrder {
        PeelAppWindowSortOrder(rawValue: appWindowSortOrderRawValue) ?? .recentlyUsed
    }
    
    private var appWindowSortOrderBinding: Binding<PeelAppWindowSortOrder> {
        Binding(
            get: { appWindowSortOrder },
            set: { appWindowSortOrderRawValue = $0.rawValue }
        )
    }
    
    private var focusRankByWindowId: [UInt32: Int] {
        var result: [UInt32: Int] = [:]
        
        for (index, windowId) in browser.recentlyFocusedWindowIds.enumerated() {
            if result[windowId] == nil {
                result[windowId] = index
            }
        }
        
        let fallbackStartIndex = result.count
        
        for (index, window) in browser.windows.enumerated() {
            if result[window.windowId] == nil {
                result[window.windowId] = fallbackStartIndex + index
            }
        }
        
        return result
    }
    
    private func appSortName(for window: PeelWindow) -> String {
        let appName = window.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if appName.isEmpty {
            return title.isEmpty ? "(Untitled window)" : title
        }
        
        if title.isEmpty || title == "Window" {
            return appName
        }
        
        return "\(appName) \(title)"
    }
    
    private func isAppWindowTieBreakerOrderedBefore(_ lhs: PeelWindow, _ rhs: PeelWindow) -> Bool {
        let lhsName = appSortName(for: lhs)
        let rhsName = appSortName(for: rhs)
        
        let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        
        return lhs.windowId < rhs.windowId
    }
    
    private func compareLaunchTime(_ lhs: PeelWindow, _ rhs: PeelWindow, newestFirst: Bool) -> Bool? {
        switch (lhs.appLaunchTimeIntervalSince1970, rhs.appLaunchTimeIntervalSince1970) {
        case let (lhsLaunch?, rhsLaunch?):
            if lhsLaunch != rhsLaunch {
                return newestFirst ? lhsLaunch > rhsLaunch : lhsLaunch < rhsLaunch
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        
        return nil
    }
    
    private func compareFocusRank(
        _ lhs: PeelWindow,
        _ rhs: PeelWindow,
        focusRankByWindowId: [UInt32: Int],
        mostRecentFirst: Bool
    ) -> Bool? {
        switch (focusRankByWindowId[lhs.windowId], focusRankByWindowId[rhs.windowId]) {
        case let (lhsRank?, rhsRank?):
            if lhsRank != rhsRank {
                return mostRecentFirst ? lhsRank < rhsRank : lhsRank > rhsRank
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        
        return nil
    }
    
    private func isAppWindow(_ lhs: PeelWindow, orderedBefore rhs: PeelWindow) -> Bool {
        let rankByWindowId = focusRankByWindowId
        
        switch appWindowSortOrder {
        case .recentlyUsed:
            if let focusSort = compareFocusRank(lhs, rhs, focusRankByWindowId: rankByWindowId, mostRecentFirst: true) {
                return focusSort
            }
        case .leastRecentlyUsed:
            if let focusSort = compareFocusRank(lhs, rhs, focusRankByWindowId: rankByWindowId, mostRecentFirst: false) {
                return focusSort
            }
        case .longestRunning:
            if let launchSort = compareLaunchTime(lhs, rhs, newestFirst: false) {
                return launchSort
            }
        case .shortestRunning:
            if let launchSort = compareLaunchTime(lhs, rhs, newestFirst: true) {
                return launchSort
            }
        }
        
        return isAppWindowTieBreakerOrderedBefore(lhs, rhs)
    }
    
    private var appWindows: [PeelWindow] {
        browser.windows
            .filter { !isDisplayCaptureWindow($0) }
            .sorted { lhs, rhs in
                isAppWindow(lhs, orderedBefore: rhs)
            }
    }
    
    private var connectedAppSessions: [PeelHostSession] {
        browser.sessionsByHostKey.values
            .filter { session in
                session.isConnectionReady || session.connection != nil || !session.windows.isEmpty
            }
            .sorted { lhs, rhs in
                displayNameWithoutPeelPrefix(lhs.host.name)
                    .localizedCaseInsensitiveCompare(displayNameWithoutPeelPrefix(rhs.host.name)) == .orderedAscending
            }
    }

    private var connectedMacDisplayName: String {
        var names: [String] = []

        for session in connectedAppSessions where session.isConnectionReady {
            let name = displayNameWithoutPeelPrefix(session.host.name)
            if !names.contains(name) {
                names.append(name)
            }
        }

        if names.count == 1 {
            return names[0]
        }

        if names.count > 1 {
            return "\(names.count) Connected Computers"
        }

        return browser.connectedHostName.map { displayNameWithoutPeelPrefix($0) } ?? "Connected Peel Pro"
    }
    
    private func hostedWindow(for session: PeelHostSession, window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: session.hostKey,
            hostName: displayNameWithoutPeelPrefix(session.host.name),
            window: window
        )
    }
    
    private func legacyHostedWindow(for window: PeelWindow) -> HostedPeelWindow {
        HostedPeelWindow(
            hostKey: browser.selectedHostKey ?? PeelHostKey(rawValue: "legacy"),
            hostName: browser.connectedHostName.map { displayNameWithoutPeelPrefix($0) } ?? "Peel Pro",
            window: window
        )
    }
    
    private func appSortName(for hostedWindow: HostedPeelWindow) -> String {
        appSortName(for: hostedWindow.window)
    }
    
    private func compareHostedLaunchTime(_ lhs: HostedPeelWindow, _ rhs: HostedPeelWindow, newestFirst: Bool) -> Bool? {
        compareLaunchTime(lhs.window, rhs.window, newestFirst: newestFirst)
    }
    
    private func hostedFocusRankByWindowId(for session: PeelHostSession) -> [UInt32: Int] {
        var result: [UInt32: Int] = [:]
        
        for (index, windowId) in session.recentlyFocusedWindowIds.enumerated() {
            if result[windowId] == nil {
                result[windowId] = index
            }
        }
        
        let fallbackStartIndex = result.count
        
        for (index, window) in session.windows.enumerated() {
            if result[window.windowId] == nil {
                result[window.windowId] = fallbackStartIndex + index
            }
        }
        
        return result
    }
    
    private func compareHostedFocusRank(_ lhs: HostedPeelWindow, _ rhs: HostedPeelWindow, mostRecentFirst: Bool) -> Bool? {
        guard lhs.hostKey == rhs.hostKey,
              let session = browser.session(for: lhs.hostKey) else {
            return nil
        }
        
        return compareFocusRank(
            lhs.window,
            rhs.window,
            focusRankByWindowId: hostedFocusRankByWindowId(for: session),
            mostRecentFirst: mostRecentFirst
        )
    }
    
    private func isHostedAppWindowTieBreakerOrderedBefore(_ lhs: HostedPeelWindow, _ rhs: HostedPeelWindow) -> Bool {
        let lhsName = appSortName(for: lhs)
        let rhsName = appSortName(for: rhs)
        
        let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        
        let hostComparison = lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName)
        if hostComparison != .orderedSame {
            return hostComparison == .orderedAscending
        }
        
        return lhs.window.windowId < rhs.window.windowId
    }
    
    private func isHostedAppWindow(_ lhs: HostedPeelWindow, orderedBefore rhs: HostedPeelWindow) -> Bool {
        switch appWindowSortOrder {
        case .recentlyUsed:
            if let focusSort = compareHostedFocusRank(lhs, rhs, mostRecentFirst: true) {
                return focusSort
            }
        case .leastRecentlyUsed:
            if let focusSort = compareHostedFocusRank(lhs, rhs, mostRecentFirst: false) {
                return focusSort
            }
        case .longestRunning:
            if let launchSort = compareHostedLaunchTime(lhs, rhs, newestFirst: false) {
                return launchSort
            }
        case .shortestRunning:
            if let launchSort = compareHostedLaunchTime(lhs, rhs, newestFirst: true) {
                return launchSort
            }
        }
        
        return isHostedAppWindowTieBreakerOrderedBefore(lhs, rhs)
    }
    
    private func sortedHostedAppWindows(_ windows: [HostedPeelWindow]) -> [HostedPeelWindow] {
        windows.sorted { lhs, rhs in
            isHostedAppWindow(lhs, orderedBefore: rhs)
        }
    }
    
    private var hostedAppWindowSections: [HostedPeelWindowSection] {
        let sessions = connectedAppSessions
        
        guard !sessions.isEmpty else {
            let legacyWindows = browser.windows
                .filter { !isDisplayCaptureWindow($0) }
                .map { legacyHostedWindow(for: $0) }
            
            guard !legacyWindows.isEmpty else { return [] }
            
            return [
                HostedPeelWindowSection(
                    id: "legacy",
                    title: browser.connectedHostName.map { displayNameWithoutPeelPrefix($0) } ?? "Computer",
                    windows: sortedHostedAppWindows(legacyWindows)
                )
            ]
        }
        
        return sessions.map { session in
            let windows = session.windows
                .filter { !isDisplayCaptureWindow($0) }
                .map { hostedWindow(for: session, window: $0) }
            
            return HostedPeelWindowSection(
                id: session.hostKey.rawValue,
                title: displayNameWithoutPeelPrefix(session.host.name),
                windows: sortedHostedAppWindows(windows)
            )
        }
    }
    
    private var hostedAppWindows: [HostedPeelWindow] {
        sortedHostedAppWindows(hostedAppWindowSections.flatMap(\.windows))
    }
    
    private var hostedDisplayCaptureWindows: [HostedPeelWindow] {
        let sessions = connectedAppSessions
        
        guard !sessions.isEmpty else {
            return browser.windows
                .filter { isDisplayCaptureWindow($0) }
                .map { legacyHostedWindow(for: $0) }
                .sorted { $0.window.windowId < $1.window.windowId }
        }
        
        return sessions
            .flatMap { session in
                session.windows
                    .filter { isDisplayCaptureWindow($0) }
                    .map { hostedWindow(for: session, window: $0) }
            }
            .sorted {
                if $0.hostName != $1.hostName {
                    return $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending
                }
                
                return $0.window.windowId < $1.window.windowId
            }
    }
    
    private var displayCaptureWindows: [PeelWindow] {
        browser.windows
            .filter { isDisplayCaptureWindow($0) }
            .sorted { $0.windowId < $1.windowId }
    }
    
    private var openAppWindowCount: Int {
        hostedAppWindows.filter { scenes.isPeeledWindowOpen($0) }.count
    }
    
    private var openDisplayCaptureWindowCount: Int {
        hostedDisplayCaptureWindows.filter { scenes.isPeeledWindowOpen($0) }.count
    }
    
    private func displayCaptureSubtitle(for window: PeelWindow) -> String {
        if window.width > 0, window.height > 0 {
            return "\(window.width) × \(window.height)"
        }
        
        return "Full display stream"
    }
    
    private func displayCaptureSubtitle(for hostedWindow: HostedPeelWindow) -> String {
        displayCaptureSubtitle(for: hostedWindow.window)
    }
    
    private func openPeeledWindowCount() -> Int {
        openPeeledWindowCountSnapshot
    }
    private func refreshOpenPeeledWindowCountSnapshot() {
        openPeeledWindowCountSnapshot = scenes.openPeeledWindowSceneCount()
    }
    private func savedMacDisplayName(for savedMac: PeelSavedPairedMac) -> String {
        displayNameWithoutPeelPrefix(savedMac.displayName)
    }
    
    
    private func beginPairing(for host: PeelHostInfo) {
        pairingHost = host
        pairingPIN = ""
        pairingToken = ""
        showAdvancedToken = false
        showingPairSheet = true
    }
    
    private func requestPairing(for host: PeelHostInfo) {
        beginPairing(for: host)
    }
    
    private func pairingSheetTitle(for host: PeelHostInfo?) -> String {
        guard let host else { return "Pair" }
        return "Pair to Peel Pro on \(hostDisplayName(for: host))"
    }
    
    private var pairingPINTrimmed: String {
        pairingPIN.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var pairingTokenTrimmed: String {
        pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var canSubmitPairingInput: Bool {
        pairingHost != nil &&
        ((pairingPINTrimmed.isEmpty && !pairingTokenTrimmed.isEmpty) ||
         (!pairingPINTrimmed.isEmpty && pairingTokenTrimmed.isEmpty))
    }
    
    private func sanitizePairingPIN(_ newValue: String) {
        let digitsOnly = newValue.filter { $0.isNumber }
        let limitedDigits = String(digitsOnly.prefix(6))
        if pairingPIN != limitedDigits {
            pairingPIN = limitedDigits
        }
        if !limitedDigits.isEmpty && !pairingToken.isEmpty {
            pairingToken = ""
        }
    }
    
    private func pastePairingPINFromClipboard() {
#if canImport(UIKit)
        let pasted = UIPasteboard.general.string ?? ""
        showAdvancedToken = false
        pairingToken = ""
        sanitizePairingPIN(pasted)
#endif
    }
    
    private func pastePairingTokenFromClipboard() {
#if canImport(UIKit)
        let pasted = UIPasteboard.general.string ?? ""
        pairingPIN = ""
        showAdvancedToken = true
        pairingToken = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
#endif
    }
    
    private func copyPeelHostDownloadLink() {
#if canImport(UIKit)
        UIPasteboard.general.string = peelHostDownloadURL.absoluteString
#endif
    }
    
    private func submitPairingInput() {
        guard let host = pairingHost, canSubmitPairingInput else { return }
        
        if !pairingPINTrimmed.isEmpty {
            browser.pairWithPIN(host: host, pin: pairingPINTrimmed)
        } else {
            _ = browser.pair(host: host, token: pairingTokenTrimmed)
        }
        
        showingPairSheet = false
    }
    
    private func primaryHostAction(for host: PeelHostInfo) {
        guard !browser.isPairing(host), !browser.isConnecting(host), !isLocallyPending(host) else { return }

        // Keep the metadata record, but route a paired host whose key is no
        // longer available back through the existing guarded pairing sheet.
        if browser.needsPairingRepair(host) {
            requestPairing(for: host)
            return
        }
        
        if browser.isPaired(host) {
            guard !browser.isConnected(to: host) else { return }
            markHostLocallyPending(host)
            browser.connectAndRequestWindows(for: host)
            
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                if browser.isConnected(to: host) || !browser.isConnecting(host) {
                    clearHostLocallyPending(host)
                }
            }
        } else {
            requestPairing(for: host)
        }
    }
    
    private func isLocallyPending(_ host: PeelHostInfo) -> Bool {
        locallyPendingHostIDs.contains(host.id)
    }
    
    private func markHostLocallyPending(_ host: PeelHostInfo) {
        locallyPendingHostIDs.insert(host.id)
    }
    
    private func clearHostLocallyPending(_ host: PeelHostInfo) {
        locallyPendingHostIDs.remove(host.id)
    }
    
    private var isDisconnectOnCooldown: Bool {
        guard let disconnectCooldownUntil else { return false }
        return Date() < disconnectCooldownUntil
    }
    
    private func beginDisconnectCooldown() {
        let cooldownEnd = Date().addingTimeInterval(0.85)
        disconnectCooldownUntil = cooldownEnd
        
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(850))
            
            if disconnectCooldownUntil == cooldownEnd {
                withAnimation(.easeInOut(duration: 0.2)) {
                    disconnectCooldownUntil = nil
                }
            }
        }
    }
    
    private func presentAppearanceEditor(for host: PeelHostInfo) {
        appearanceEditorHost = host
    }
    
    private func hostSymbolName(for host: PeelHostInfo) -> String {
        hostAppearanceStore.symbolName(for: host)
    }
    
    private func hostStatusText(for host: PeelHostInfo) -> String {
        if browser.isConnected(to: host) {
            return "Connected"
        } else if browser.isConnecting(host) {
            return "Connecting…"
        } else if browser.isPairing(host) {
            return "Pairing…"
        } else if browser.needsPairingRepair(host) {
            return "Pair again"
        } else if browser.isPaired(host) {
            return "Paired"
        } else {
            return "Not paired"
        }
    }
    
    private func hostStatusSymbolName(for host: PeelHostInfo) -> String {
        if browser.isConnected(to: host) {
            return "checkmark.circle.fill"
        } else if browser.needsPairingRepair(host) {
            return "exclamationmark.triangle.fill"
        } else if browser.isPaired(host) {
            return "link.circle.fill"
        } else {
            return "circle"
        }
    }
    
    private func hostStatusColor(for host: PeelHostInfo) -> Color {
        if browser.isConnected(to: host) {
            return .green
        } else if browser.isConnecting(host) || browser.isPairing(host) {
            return .secondary
        } else if browser.needsPairingRepair(host) {
            return .orange
        } else if browser.isPaired(host) {
            return .blue
        } else {
            return .secondary
        }
    }
    
    @ViewBuilder
    private func hostPrimaryActionButton(for host: PeelHostInfo) -> some View {
        if browser.isConnected(to: host) {
            EmptyView()
        } else if isLocallyPending(host) || browser.isConnecting(host) || browser.isPairing(host) {
            ProgressView()
                .controlSize(.small)
                .foregroundStyle(.secondary)
        } else if browser.needsPairingRepair(host) {
            Button("Pair again") {
                primaryHostAction(for: host)
            }
            .buttonStyle(.borderedProminent)
        } else if browser.isPaired(host) {
            Button("Connect") {
                primaryHostAction(for: host)
            }
            .buttonStyle(.bordered)
        } else {
            Button("Pair") {
                primaryHostAction(for: host)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                (colorScheme == .dark ? Color.black : Color.white)
                    .ignoresSafeArea()
                
                mainContent
            }
            
            .sheet(isPresented: $showingPairSheet) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 6) {
                        PeelLoadingView(
                            title: showAdvancedToken
                            ? "Advanced pairing"
                            : pairingHost.map { "Enter code from \(hostDisplayName(for: $0))" } ?? "Enter code from your computer",
                            message: showAdvancedToken
                            ? "Only use this if the 6-digit code is not working. Paste the advanced token from Peel Pro."
                            : "Use the 6-digit code shown in Peel Pro.",
                            variant: .minimal,
                            showsLogo: true
                        )
                        .frame(maxWidth: .infinity)
                        
                        if !showAdvancedToken {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    Button("Paste") {
                                        pastePairingPINFromClipboard()
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    TextField("6-digit code", text: $pairingPIN)
                                        .keyboardType(.numberPad)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: pairingPIN) { _, newValue in
                                            sanitizePairingPIN(newValue)
                                        }
                                }
                            }
                            .padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        
                        HStack(spacing: 14) {
                            Button("Cancel") {
                                showingPairSheet = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: 150, minHeight: 48)
                            
                            Button("Pair") {
                                submitPairingInput()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: 150, minHeight: 48)
                            .disabled(!canSubmitPairingInput)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        
                        DisclosureGroup("Having trouble?", isExpanded: $showAdvancedToken) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Select 'Having trouble?' on Peel Pro, then copy the advanced token")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                HStack(alignment: .top, spacing: 10) {
                                    Button("Paste") {
                                        pastePairingTokenFromClipboard()
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    TextField("Advanced pairing token", text: $pairingToken, axis: .vertical)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .lineLimit(3...8)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: pairingToken) { _, newValue in
                                            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pairingPIN.isEmpty {
                                                pairingPIN = ""
                                            }
                                        }
                                }
                            }
                            .padding(.top, 8)
                        }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: showAdvancedToken) { _, isExpanded in
                            if isExpanded {
                                pairingPIN = ""
                            } else {
                                pairingToken = ""
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                    .navigationTitle("Pair")
                }
            }
            .sheet(item: $appearanceEditorHost) { host in
                NavigationStack {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                Image(systemName: hostAppearanceStore.symbolName(for: host))
                                    .font(.title3)
                                    .frame(width: 28)
                                    .foregroundStyle(.secondary)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hostDisplayName(for: host))
                                        .font(.headline)
                                    
                                    Text("Automatic currently resolves to \(hostAppearanceStore.automaticPreviewTitle(for: host)).")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Section("Computer Icon") {
                            ForEach(PeelMacSymbolChoice.allCases) { choice in
                                Button {
                                    hostAppearanceStore.setOverride(choice, for: host)
                                    appearanceEditorHost = nil
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: choice == .automatic
                                              ? hostAppearanceStore.inferredChoice(for: host).symbolName
                                              : choice.symbolName)
                                        .frame(width: 24)
                                        .foregroundStyle(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.title)
                                                .foregroundStyle(.primary)
                                            
                                            if choice == .automatic {
                                                Text("Uses \(hostAppearanceStore.automaticPreviewTitle(for: host)) for this computer")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        if hostAppearanceStore.overrideChoice(for: host) == choice {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .navigationTitle("Computer Icon")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                appearanceEditorHost = nil
                            }
                        }
                    }
                }
            }
            .alert("Purchase Error", isPresented: purchaseErrorBinding) {
                Button("OK") {
                    store.clearError()
                }
            } message: {
                Text(store.purchaseErrorMessage ?? "Something went wrong.")
            }
            .alert(
                "Forget pairing?",
                isPresented: Binding(
                    get: { forgetPairingHost != nil },
                    set: { newValue in
                        if !newValue {
                            forgetPairingHost = nil
                        }
                    }
                ),
                presenting: forgetPairingHost
            ) { host in
                Button("Cancel", role: .cancel) {
                    forgetPairingHost = nil
                }
                
                Button("Forget", role: .destructive) {
                    if browser.isConnected(to: host) || browser.isConnecting(host) {
                        browser.disconnect(from: host)
                    }
                    browser.forgetPairing(for: host)
                    forgetPairingHost = nil
                }
            } message: { host in
                Text("This will remove the saved pairing for \(hostDisplayName(for: host)). You’ll need to pair again before reconnecting.")
            }
            .alert(
                "Forget pairing?",
                isPresented: Binding(
                    get: { forgetSavedPairingMac != nil },
                    set: { newValue in
                        if !newValue {
                            forgetSavedPairingMac = nil
                        }
                    }
                ),
                presenting: forgetSavedPairingMac
            ) { savedMac in
                Button("Cancel", role: .cancel) {
                    forgetSavedPairingMac = nil
                }
                
                Button("Forget", role: .destructive) {
                    browser.forgetSavedPairing(savedMac)
                    forgetSavedPairingMac = nil
                }
            } message: { savedMac in
                Text("This will remove the saved pairing for \(savedMacDisplayName(for: savedMac)). You’ll need to pair again before reconnecting.")
            }
        }
        .onReceive(browser.$windows) { windows in
            refreshOpenPeeledWindowCountSnapshot()
            handleLauncherAutoOpenHandoffIfNeeded()
            handlePhoneAutoPopupHandoffIfNeeded(windows: windows)
        }
        .onReceive(browser.$hosts) { hosts in
            let inactivePendingIDs = locallyPendingHostIDs.filter { pendingID in
                guard let host = hosts.first(where: { $0.id == pendingID }) else { return true }
                return browser.isConnected(to: host) || !browser.isConnecting(host)
            }
            
            for pendingID in inactivePendingIDs {
                locallyPendingHostIDs.remove(pendingID)
            }
        }
    }
    // The logo art leaves 43 of 256 px transparent on each side (~6.7 pt at
    // 40 pt), so the stack spacing is reduced to keep a ~12 pt visible gap.
    @ScaledMetric(relativeTo: .largeTitle) private var headerLogoSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var headerLogoSpacing: CGFloat = 4

    private var mainContent: some View {
        VStack(alignment: .center, spacing: 16) {
            HStack(spacing: headerLogoSpacing) {
                Image("PeelHostMenuBarIcon_256x256")
                    .resizable()
                    .frame(width: headerLogoSize, height: headerLogoSize)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                Text("Peel Pro")
                    .font(.largeTitle.bold())
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 16) {
            #if debug
                Text(browser.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
#endif
                let _ = browser.pairingStateVersion
                TabView(selection: $selectedTab) {
                    MacsTabView(
                        hostDisplayName: hostDisplayName,
                        savedMacDisplayName: savedMacDisplayName,
                        hostSymbolName: hostSymbolName,
                        hostStatusText: hostStatusText,
                        hostStatusSymbolName: hostStatusSymbolName,
                        hostStatusColor: hostStatusColor,
                        hostPrimaryActionButton: { AnyView(hostPrimaryActionButton(for: $0)) },
                        primaryHostAction: primaryHostAction,
                        isDisconnectOnCooldown: isDisconnectOnCooldown,
                        beginDisconnectCooldown: beginDisconnectCooldown,
                        presentAppearanceEditor: presentAppearanceEditor,
                        forgetPairingHost: $forgetPairingHost,
                        forgetSavedPairingMac: $forgetSavedPairingMac
                    )
                    .tabItem {
                        Label("Computers", systemImage: "desktopcomputer")
                    }
                    .tag(ContentTab.macs)

                    AppsTabView(
                        connectedMacDisplayName: connectedMacDisplayName,
                        appWindows: hostedAppWindows,
                        appWindowSections: hostedAppWindowSections,
                        displayCaptureWindows: hostedDisplayCaptureWindows,
                        canOpenTopApps: canOpenTopApps,
                        quickOpenSymbolName: quickOpenSymbolName,
                        openPeeledWindowCountSnapshot: openPeeledWindowCountSnapshot,
                        appWindowSortOrderBinding: appWindowSortOrderBinding,
                        openAllAvailableApps: openAllAvailableApps,
                        closeAllAvailableApps: closeAllAvailableApps,
                        handleWindowOpenButtonTapped: { hostedWindow in
                            handleWindowOpenButtonTapped(hostedWindow)
                        },
                        closeSelectedWindow: { hostedWindow in
                            closeSelectedWindow(hostedWindow)
                        },
                        showMacsTab: {
                            selectedTab = .macs
                        }
                    )
                    .tabItem {
                        Label("Apps", systemImage: "sharedwithyou")
                    }
                    .tag(ContentTab.apps)

                    DisplaysTabView(
                        connectedMacDisplayName: connectedMacDisplayName,
                        displayCaptureWindows: hostedDisplayCaptureWindows,
                        displayWindowTitle: displayWindowTitle,
                        displayCaptureSubtitle: displayCaptureSubtitle,
                        handleWindowOpenButtonTapped: { hostedWindow in
                            handleWindowOpenButtonTapped(hostedWindow)
                        },
                        closeSelectedWindow: { hostedWindow in
                            closeSelectedWindow(hostedWindow)
                        },
                        showMacsTab: {
                            selectedTab = .macs
                        }
                    )
                    .tabItem {
                        Label("Desktops", systemImage: "display")
                    }
                    .tag(ContentTab.displays)
                    if showHUDTab {
                        HUDTabView(
                            connectedMacDisplayName: connectedMacDisplayName,
                            displayCaptureWindows: hostedDisplayCaptureWindows,
                            displayWindowTitle: displayWindowTitle,
                            displayCaptureSubtitle: displayCaptureSubtitle,
                            showMacsTab: {
                                selectedTab = .macs
                            }
                        )
                        .tabItem {
                            Label("HUD", systemImage: "inset.filled.bottomleading.rectangle")
                        }
                        .tag(ContentTab.hud)
                    }
                }
                .frame(minHeight: 560)
                .onAppear {
                    selectedTab = browser.isConnectionReady ? .apps : .macs
                    refreshOpenPeeledWindowCountSnapshot()
                }
                .onChange(of: showHUDTab) { _, isVisible in
                    if !isVisible && selectedTab == .hud {
                        selectedTab = browser.isConnectionReady ? .apps : .macs
                    }
                }
                
                Spacer()
            }
        }
        .ornament(
            visibility: .visible,
            attachmentAnchor: .scene(.topTrailing),
            contentAlignment: .bottomTrailing
        ) {
            HStack(spacing: 8) {
                Button {
                    showingAudio = true
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.title3)
                        // Blue only while computer audio is actually playing.
                        .foregroundStyle(isComputerAudioPlaying ? Color.blue : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassBackgroundEffect(in: Circle())
                .help("Audio")
                .accessibilityLabel("Audio")
                .accessibilityValue(isComputerAudioPlaying ? "Playing" : "Off")
                .accessibilityIdentifier("peel.home.audio")

                Button { showingMachineStatus = true } label: {
                    Image(systemName: "gauge").font(.title3)
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassBackgroundEffect(in: Circle())
                .help("Computer Status")
                .accessibilityLabel("Computer Status")
                .accessibilityIdentifier("peel.home.status")

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassBackgroundEffect(in: Circle())
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("peel.home.settings")
                
                Button {
                    showingAbout = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassBackgroundEffect(in: Circle())
                .help("About Peel Pro")
                .accessibilityLabel("About Peel Pro")
                .accessibilityIdentifier("peel.home.about")

            }
            .padding(8)
        }
        .alert("Window limit reached", isPresented: $showingWindowCapacityAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Peel supports up to 12 simultaneous windows. Close another window to open this one.")
        }
        .sheet(item: $proFeature) { feature in
            PeelPaywallView(feature: feature).environmentObject(store)
        }
        .sheet(isPresented: $showingAbout) {
            AboutPeelView()
        }
        .sheet(isPresented: $showingAudio) {
            PeelAudioControls()
                .environmentObject(browser)
        }
        .sheet(isPresented: $showingMachineStatus) {
            PeelMachineStatusSheet().environmentObject(browser)
        }
        .sheet(isPresented: $showingSettings) {
            ClientSettingsView(
                showsAgentPresentationSetting: true,
                onAgentPresentationOptInChanged: { _ in
                    browser.refreshAgentPresentationCapabilities()
                }
            )
                .environmentObject(store)
        }
        .overlay {
            WindowSceneReader { scene in
                let sceneID = scene.session.persistentIdentifier
                
                DispatchQueue.main.async {
                    if currentScene?.session.persistentIdentifier != sceneID {
                        currentScene = scene
                        scenes.registerMainScene(scene)
                    }
                }
            }
            .frame(width: 0, height: 0)
            .hidden()
        }
        .onDisappear {
            let scene = currentScene
            scenes.markMainSceneClosed(scene)
        }
    }
    
    private func handleLauncherAutoOpenHandoffIfNeeded() {
        guard let window = browser.consumePendingHostCommandAutoOpenWindow() else { return }
        
        browser.setActiveWindow(window.windowId)
        openSelectedWindow(window)
    }
    
    private func handlePhoneAutoPopupHandoffIfNeeded(windows: [PeelWindow]) {
        _ = windows
    }
    
    private var purchaseErrorBinding: Binding<Bool> {
        Binding(
            get: { store.purchaseErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    store.clearError()
                }
            }
        )
    }
}
