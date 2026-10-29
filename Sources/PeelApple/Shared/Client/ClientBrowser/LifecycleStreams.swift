//
//  LifecycleStreams.swift
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
    func stopAllPullStreams() {
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "stopAllPullStreams timers=\(snapshotTimers.count) startedStreams=\(startedStreamWindowIds.count)")
        let windowIdsToClose = Set(desiredPullWindowIds).union(startedStreamWindowIds)
        for windowId in windowIdsToClose {
            selectedSession?.closeVideoConnection(windowId: windowId, reason: "stop all pull streams")
        }
        for (_, timer) in snapshotTimers {
            timer.cancel()
        }
        snapshotTimers.removeAll()
        globalSnapshotsInFlight = 0
        inFlight.removeAll()
        inFlightSince.removeAll()
        startedStreamWindowIds.removeAll()
        selectedSession?.snapshotTimers.removeAll()
        selectedSession?.globalSnapshotsInFlight = 0
        selectedSession?.inFlight.removeAll()
        selectedSession?.inFlightSince.removeAll()
        selectedSession?.startedStreamWindowIds.removeAll()
        selectedSession?.videoConnectInProgressWindowIds.removeAll()
    }
    
    func requestHostFocusForWindow(_ windowId: UInt32, force: Bool = false) {
        let now = Date()

        if !force,
           let last = lastClientActiveWindowRequestAtByWindow[windowId],
           now.timeIntervalSince(last) < clientActiveWindowRequestMinInterval {
            return
        }

        lastClientActiveWindowRequestAtByWindow[windowId] = now
        selectedSession?.lastClientActiveWindowRequestAtByWindow[windowId] = now
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "clientActiveWindow send force=\(force)")
        sendJSONMessage(ClientActiveWindowMessage(windowId: windowId))
    }

    func setActiveWindow(_ windowId: UInt32) {
        let changed = activeWindowId != windowId

        activeWindowId = windowId
        selectedSession?.activeWindowId = windowId
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", windowId: windowId, message: "setActiveWindow changed=\(changed)")

        guard changed else {
            return
        }

        hostConfirmedActiveWindowId = nil
        selectedSession?.hostConfirmedActiveWindowId = nil
        updateStreamRates()
        requestHostFocusForWindow(windowId, force: true)
    }

    func setPeeledWindowHostingMode(_ mode: PeeledWindowHostingMode, for window: PeelWindow) {
        let windowId = window.windowId
        if mode == .inPlace {
            desiredPeeledWindowHostingModes.removeValue(forKey: windowId)
            selectedSession?.desiredPeeledWindowHostingModes.removeValue(forKey: windowId)
        } else {
            desiredPeeledWindowHostingModes[windowId] = mode
            selectedSession?.desiredPeeledWindowHostingModes[windowId] = mode
            rememberPeeledWindowHostingIdentity(window)
        }
        forgetPeeledWindowHostingIdentityIfUnused(for: windowId)
        guard supportsHostCapability(.peeledWindowHostingModes) else { return }
        guard mode == .inPlace || currentPeeledWindowIdentityMatches(window) else { return }
        sendJSONMessage(SetPeeledWindowHostingModeMessage(windowId: windowId, mode: mode))
    }

    func setClientWindowActive(_ isActive: Bool, for window: PeelWindow) {
        let windowId = window.windowId
        if isActive {
            desiredClientWindowActivity[windowId] = true
            selectedSession?.desiredClientWindowActivity[windowId] = true
            rememberPeeledWindowHostingIdentity(window)
        } else {
            desiredClientWindowActivity.removeValue(forKey: windowId)
            selectedSession?.desiredClientWindowActivity.removeValue(forKey: windowId)
        }
        forgetPeeledWindowHostingIdentityIfUnused(for: windowId)
        guard supportsHostCapability(.clientWindowActivity),
              supportsHostCapability(.peeledWindowHostingModes) else { return }
        guard !isActive || currentPeeledWindowIdentityMatches(window) else { return }
        sendJSONMessage(ClientWindowActivityMessage(windowId: windowId, isActive: isActive))
    }

    func resendPeeledWindowHostingStateIfSupported(freshWindows: [PeelWindow]) {
        guard supportsHostCapability(.clientWindowActivity),
              supportsHostCapability(.peeledWindowHostingModes) else { return }
        let matchingWindowIDs = matchingDesiredPeeledWindowIDs(in: freshWindows)
        for windowId in desiredPeeledWindowHostingModes.keys.sorted() where matchingWindowIDs.contains(windowId) {
            guard let mode = desiredPeeledWindowHostingModes[windowId] else { continue }
            sendJSONMessage(SetPeeledWindowHostingModeMessage(windowId: windowId, mode: mode))
        }
        for windowId in desiredClientWindowActivity.keys.sorted() where matchingWindowIDs.contains(windowId) {
            sendJSONMessage(ClientWindowActivityMessage(windowId: windowId, isActive: true))
        }
    }

    private func rememberPeeledWindowHostingIdentity(_ window: PeelWindow) {
        let windowId = window.windowId
        guard desiredPeeledWindowHostingIdentityByWindow[windowId] == nil else { return }
        desiredPeeledWindowHostingIdentityByWindow[windowId] = window
        selectedSession?.desiredPeeledWindowHostingIdentityByWindow[windowId] = window
    }

    private func currentPeeledWindowIdentityMatches(_ expected: PeelWindow) -> Bool {
        currentWindowInstanceMatches(expected)
    }

    func currentWindowInstanceMatches(_ expected: PeelWindow) -> Bool {
        guard hasFreshWindowListForCurrentConnection,
              let current = lastWindowListById[expected.windowId] ?? windows.first(where: {
                  $0.windowId == expected.windowId
              }) else {
            return false
        }
        return peeledWindowIdentity(expected, matches: current)
    }

    private func forgetPeeledWindowHostingIdentityIfUnused(for windowId: UInt32) {
        guard desiredPeeledWindowHostingModes[windowId] == nil,
              desiredClientWindowActivity[windowId] == nil else { return }
        desiredPeeledWindowHostingIdentityByWindow.removeValue(forKey: windowId)
        selectedSession?.desiredPeeledWindowHostingIdentityByWindow.removeValue(forKey: windowId)
    }

    private func matchingDesiredPeeledWindowIDs(in freshWindows: [PeelWindow]) -> Set<UInt32> {
        var freshByID: [UInt32: PeelWindow] = [:]
        for window in freshWindows {
            freshByID[window.windowId] = window
        }
        return Set(desiredPeeledWindowHostingIdentityByWindow.compactMap { windowId, expected in
            guard let current = freshByID[windowId], peeledWindowIdentity(expected, matches: current) else {
                return nil
            }
            return windowId
        })
    }

    private func peeledWindowIdentity(_ expected: PeelWindow, matches current: PeelWindow) -> Bool {
        guard expected.appName == current.appName,
              expected.title == current.title else { return false }
        switch (expected.appLaunchTimeIntervalSince1970, current.appLaunchTimeIntervalSince1970) {
        case let (expectedLaunch?, currentLaunch?):
            return abs(expectedLaunch - currentLaunch) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }
    
    func isHostConfirmedActiveWindow(_ windowId: UInt32) -> Bool {
        hostConfirmedActiveWindowId == windowId
    }
    
    func inputStateDescription(for windowId: UInt32) -> String {
        hostConfirmedActiveWindowId == windowId ? "Active" : "Standby"
    }
    
    func streamStatus(for windowId: UInt32) -> WindowStreamStatus {
        guard connection != nil, isConnectionReady else { return .offline }
        
        let hasStreamIntent = desiredPullWindowIds.contains(windowId) || snapshotTimers[windowId] != nil
        let hasVideoRenderer = videoRenderers[windowId] != nil
        let hasVideoSize = videoContentSizeByWindow[windowId] != nil
        let hasSnapshot = snapshotCGImages[windowId] != nil
        
        // H.264 streams can go quiet when the source window is static.
        // If we have a renderer or a decoded frame and still intend to stream,
        // do not call it disconnected just because no new frame arrived recently.
        if hasStreamIntent && (hasVideoRenderer || hasVideoSize || hasSnapshot) {
            return .active
        }
        
        let now = Date()
        let last = lastFrameAt[windowId] ?? .distantPast
        let age = now.timeIntervalSince(last)
        
        let isActive = (activeWindowId == windowId)
        let softThreshold = isActive ? offlineThresholdActive : offlineThresholdInactive
        
        if hasStreamIntent {
            return age <= max(softThreshold, 10.0) ? .active : .sleeping
        }
        
        return age <= softThreshold ? .sleeping : .offline
    }
    
    func updateStreamRates() {
        // H.264/SCK streaming no longer uses timer-driven JPEG pull loops.
    }
    
    func restartPullTimer(windowId: UInt32, fps: Double) {
        // Disabled for H.264 streaming path.
    }
    
    func restoreDesiredPullStreamsIfNeeded() {
        guard isConnectionReady, connection != nil else { return }
        guard !desiredPullWindowIds.isEmpty else { return }

        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "restoreDesiredPullStreams desired=\(desiredPullWindowIds.sorted()) started=\(startedStreamWindowIds.sorted())")
        let now = Date()

        for windowId in desiredPullWindowIds.sorted() {
            if streamRepairInProgressWindowIds.contains(windowId) {
                continue
            }

            let currentWindow = lastWindowListById[windowId] ?? windows.first(where: {
                $0.windowId == windowId
            })
            let expectedWindow = desiredPullWindowIdentityByWindow[windowId]

            guard let currentWindow,
                  let expectedWindow,
                  peeledWindowIdentity(expectedWindow, matches: currentWindow) else {
                print("PeelClient: not restoring stale desired stream window=\(windowId); missing from fresh windowList")
                if let expectedWindow {
                    endPullStream(for: expectedWindow)
                } else {
                    desiredPullWindowIds.remove(windowId)
                    startedStreamWindowIds.remove(windowId)
                    streamStartAttemptAtByWindow.removeValue(forKey: windowId)
                    selectedSession?.desiredPullWindowIds.remove(windowId)
                    selectedSession?.startedStreamWindowIds.remove(windowId)
                    selectedSession?.streamStartAttemptAtByWindow.removeValue(forKey: windowId)
                }
                continue
            }

            if !startedStreamWindowIds.contains(windowId) {
                requestStreamStart(windowId: windowId, reason: "restore desired stream after fresh windowList")
                continue
            }

            let hasRealFrame = (videoFrameCountByWindow[windowId] ?? 0) > 0
                || snapshotCGImages[windowId] != nil

            guard !hasRealFrame else { continue }

            guard let startedAt = streamStartAttemptAtByWindow[windowId] else {
                streamStartAttemptAtByWindow[windowId] = now
                selectedSession?.streamStartAttemptAtByWindow[windowId] = now
                continue
            }

            let age = now.timeIntervalSince(startedAt)

            if age > streamFirstFrameTimeout {
                repairVideoStreamOnly(
                    windowId: windowId,
                    reason: "started stream without first frame after \(String(format: "%.1f", age))s"
                )
            }
        }
    }
    
    func repairVideoStreamOnly(windowId: UInt32, reason: String) {
        let now = Date()

        if let last = streamLastRepairAtByWindow[windowId],
           now.timeIntervalSince(last) < streamRepairCooldown {
            return
        }

        streamLastRepairAtByWindow[windowId] = now
        let attempt = (streamRepairAttemptByWindow[windowId] ?? 0) + 1
        streamRepairAttemptByWindow[windowId] = attempt
        streamRepairInProgressWindowIds.insert(windowId)

        PeelClientDiagnostics.logStreamEvent(
            ownerName: "browser",
            windowId: windowId,
            message: "video-only repair attempt=\(attempt) reason=\(reason)"
        )

        startedStreamWindowIds.remove(windowId)
        streamStartAttemptAtByWindow.removeValue(forKey: windowId)
        videoReadyWindowIds.remove(windowId)
        videoFrameCountByWindow.removeValue(forKey: windowId)
        videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)

        selectedSession?.startedStreamWindowIds.remove(windowId)
        selectedSession?.streamStartAttemptAtByWindow.removeValue(forKey: windowId)
        selectedSession?.streamRepairAttemptByWindow[windowId] = attempt
        selectedSession?.streamRepairInProgressWindowIds.insert(windowId)
        selectedSession?.closeVideoConnection(windowId: windowId, reason: "stream repair: \(reason)")

        let delay: TimeInterval = attempt >= maxStreamRepairsBeforeReconnect ? 0.35 : 0.15
        if attempt >= maxStreamRepairsBeforeReconnect {
            streamRepairAttemptByWindow[windowId] = 0
            selectedSession?.streamRepairAttemptByWindow[windowId] = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.streamRepairInProgressWindowIds.remove(windowId)
            self.selectedSession?.streamRepairInProgressWindowIds.remove(windowId)

            guard self.isClientVisible,
                  self.isConnectionReady,
                  self.connection != nil,
                  self.desiredPullWindowIds.contains(windowId) else {
                return
            }

            self.requestStreamStart(windowId: windowId, reason: "stream repair: \(reason)")
        }
    }

    func attemptPendingReconnectIfPossible(reason fallbackReason: String = "became visible") {
        guard isClientVisible else { return }

        // Retry from each real session's intent, including Bonjour sessions that
        // disconnected while hidden. Browser reconnect fields are only a mirror.
        for session in sessionsByHostKey.values {
            session.attemptPendingReconnectIfPossible(reason: fallbackReason)
        }
        // A real target session owns its retry/cooldown. Do not race a second
        // browser-level connect against its just-started resolve or delayed retry.
        guard !sessionsByHostKey.values.contains(where: { matchesReconnectTarget($0.host) }) else { return }

        guard pendingReconnectWhenVisible else { return }
        guard !suppressAutoReconnect else { return }
        guard connection == nil else { return }
        guard isConnectBusy == false else { return }
        guard lastConnectedHostName != nil || lastConnectedHost != nil else { return }

        guard let host = hosts.last(where: { self.matchesReconnectTarget($0) }) else {
            refreshDiscoveryAfterLifecycleWake(reason: fallbackReason)
            return
        }

        pendingReconnectWhenVisible = false
        selectedSession?.pendingReconnectWhenVisible = false
        let reason = pendingReconnectReason ?? fallbackReason
        pendingReconnectReason = nil
        selectedSession?.pendingReconnectReason = nil
        status = "Reconnecting to \(host.name)…"
        selectedSession?.status = status
        print("🔁 Pending reconnect triggered: \(host.name) (\(reason))")
        connectAndRequestWindows(for: host, isAutoReconnect: true)
    }
    
    func refreshDiscoveryAfterLifecycleWake(reason: String) {
        guard isClientVisible else { return }
        guard connection == nil else { return }
        guard isConnectBusy == false else { return }

        // Do not touch active sessions, but when disconnected always let Bonjour
        // rebuild itself. This is the force-quit replacement for stale/missing hosts.
        print("🔎 Refreshing Peel host discovery after \(reason)")
        if hosts.isEmpty {
            status = "Looking for hosts…"
        }

        restartDiscoveryAfterHostDrop(reason: reason)
    }
    
    func setupLifecycleObservers() {
#if canImport(UIKit)
        let nc = NotificationCenter.default
        
        lifecycleObservers.append(
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.iCloudPairingClient.pause()
                self?.setClientVisibility(false)
            }
        )
        lifecycleObservers.append(
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.iCloudPairingClient.pause()
                self?.setClientVisibility(false)
            }
        )
        lifecycleObservers.append(
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setClientVisibility(true)
                self?.iCloudPairingClient.refresh()
                self?.refreshDiscoveryAfterLifecycleWake(reason: "became active")
                self?.attemptPendingReconnectIfPossible(reason: "became active")
            }
        )
        lifecycleObservers.append(
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setClientVisibility(true)
                self?.refreshDiscoveryAfterLifecycleWake(reason: "entered foreground")
                self?.attemptPendingReconnectIfPossible(reason: "entered foreground")
            }
        )
#endif
    }
    
    func startPing() {
        stopPing()
        streamDiagnosticReporter.clock.reset()

        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 4.0, repeating: 4.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isClientVisible else { return }
            guard self.connection != nil, self.isConnectionReady else { return }
            self.selectedSession?.lastAnyDataAt = self.lastAnyDataAt
            let probe = self.hostCapabilities.contains(PeelStreamClockReply.capability)
                ? self.streamDiagnosticReporter.clock.makeProbe() : nil
            self.sendJSONMessage(ClientPingMessage(streamClockProbe: probe))
            let sourceConnection = self.connection
            guard self.streamDiagnosticReporter.beginScheduledReport() else { return }
            DispatchQueue.main.async {
                defer { self.streamDiagnosticReporter.finishScheduledReport() }
                guard self.connection === sourceConnection else { return }
                if let session = self.selectedSession { session.sendStreamingDiagnosticsSnapshot() }
                else { self.sendStreamingDiagnosticsSnapshot() }
            }
        }
        timer.resume()
        pingTimer = timer
    }
    
    func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    func sendStreamingDiagnosticsSnapshot() {
        guard isClientVisible, isConnectionReady, connection != nil,
              hostCapabilities.contains(PeelClientStreamMetricsMessage.capability),
              let batch = streamDiagnosticReporter.nextBatchIfDue() else { return }
        let rows = batch.entries.compactMap { entry -> PeelClientStreamMetric? in
#if os(visionOS)
            let spatial = activeSpatialWindowIds.contains(entry.windowId)
#else
            let spatial = false
#endif
            if !spatial { entry.renderer.refreshStreamingPerformanceMetrics() }
            var row = entry.renderer.streamingDiagnosticSnapshot(windowId: entry.windowId, spatial: spatial)
#if os(visionOS)
            if spatial { row?.spatialPipeline = spatialVideoRenderers[entry.windowId]?.streamingDiagnosticSnapshot() }
#endif
            return row
        }
        let message = PeelClientStreamMetricsMessage(sequence: batch.sequence,
            sampledAtClientUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            streams: rows, untrackedRendererRegistrations: batch.untracked)
        guard message.isValid else { return }
        sendJSONMessage(message)
    }
    
    func setClientVisibility(_ visible: Bool) {
        guard visible != isClientVisible else { return }
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "visibility=\(visible)")
        isClientVisible = visible
        // Retire signed-evidence operations at both hide/lock and resume. A new
        // Host challenge is needed; a suspended collector cannot cross either.
        invalidateProEvidence()
        
        // Tell every active host session to stop/resume work.
        //
        // Multi-host moved the real sockets onto PeelHostSession, but this lifecycle hook
        // still used the legacy browser-level connection. That meant a host could keep
        // clientIsVisible=false after a headset/app lifecycle transition, then drop
        // requestWindowList on reconnect/resume and show an empty app/display list.
        let activeSessions = Array(sessionsByHostKey.values)
        let usesLegacyTransport = activeSessions.isEmpty
        if !visible { activeSessions.forEach { $0.stopSystemAudio(reason: "iPad is inactive") } }
        if usesLegacyTransport, connection != nil, isConnectionReady {
            sendJSONMessage(ClientVisibilityMessage(isVisible: visible))
        }
        for session in activeSessions where session.connection != nil && session.isConnectionReady {
            session.sendJSONMessage(ClientVisibilityMessage(isVisible: visible))
            if visible { session.sendClientHello() }
        }

        if visible {
            if usesLegacyTransport {
                startPing()
                if connection != nil {
                    requestWindowListIfReadyOrDefer()
                    if isConnectionReady { startWindowListAutoRefresh() }
                }
            } else {
                // Real sockets belong to sessions. Starting legacy polling on a
                // mirrored socket creates a second disconnect/reconnect owner.
                stopPing()
                stopWindowListAutoRefresh()
                stopStreamWatchdog()
            }

            for session in activeSessions where session.connection != nil {
                session.startPing()
                session.requestWindowListIfReadyOrDefer()
                if session.isConnectionReady {
                    session.startWindowListAutoRefresh()
                    session.startStreamWatchdog()
                }
            }

            refreshDiscoveryAfterLifecycleWake(reason: "became visible")
            attemptPendingReconnectIfPossible(reason: "became visible")

            // Real sessions already own their resolve/cooldown above. A stale
            // browser mirror must not enqueue another connect after that retry.
            if pendingReconnectWhenVisible, connection == nil,
               !activeSessions.contains(where: { matchesReconnectTarget($0.host) }) {
                let reason = pendingReconnectReason ?? "became visible"
                scheduleReconnect(reason: reason)
                selectedSession?.pendingReconnectReason = reason
            }
        } else {
            stopPing()
            stopWindowListAutoRefresh()
            if usesLegacyTransport { stopAllPullStreams() }

            for session in activeSessions {
                session.stopPing()
                session.stopWindowListAutoRefresh()
                session.stopAllPullStreams()
                session.stopStreamWatchdog()
            }
        }

        if visible && usesLegacyTransport { startStreamWatchdog() }
        else { stopStreamWatchdog() }
    }
}

// MARK: - Per-host session lifecycle/stream helpers
extension PeelHostSession {
    func beginWatchControlFocusRequest(windowID: UInt32) -> String? {
        guard connection != nil, isConnectionReady, isClientVisible else {
            watchFocusProof.invalidate()
            return nil
        }

        let changed = activeWindowId != windowID
        activeWindowId = windowID
        hostConfirmedActiveWindowId = nil
        if browser?.selectedHostKey == hostKey {
            browser?.hostConfirmedActiveWindowId = nil
        }
        watchFocusProof.invalidate()
        if changed { updateStreamRates() }

        let requestID = UUID().uuidString
        watchFocusProof.begin(
            requestID: requestID,
            windowID: windowID,
            connectionGeneration: watchFocusConnectionGeneration,
            now: ProcessInfo.processInfo.systemUptime,
            timeout: 2
        )
        // Do not call setActiveWindow here: a changed selection would send a
        // second, uncorrelated focus request and supersede this Host attempt.
        lastClientActiveWindowRequestAtByWindow[windowID] = Date()
        sendJSONMessage(ClientActiveWindowMessage(windowId: windowID, focusRequestId: requestID))
        return requestID
    }

    func isWatchControlFocusConfirmed(requestID: String, windowID: UInt32) -> Bool {
        guard connection != nil, isConnectionReady, isClientVisible,
              activeWindowId == windowID else { return false }
        return watchFocusProof.isConfirmed(
            requestID: requestID,
            windowID: windowID,
            connectionGeneration: watchFocusConnectionGeneration
        )
    }

    func cancelWatchControlFocusRequest(requestID: String) {
        watchFocusProof.cancel(requestID: requestID)
    }

    func stopAllPullStreams() {
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", message: "stopAllPullStreams timers=\(snapshotTimers.count) startedStreams=\(startedStreamWindowIds.count)")
        let windowIdsToClose = Set(desiredPullWindowIds).union(startedStreamWindowIds)
        for windowId in windowIdsToClose {
            closeVideoConnection(windowId: windowId, reason: "stop all pull streams")
        }
        for (_, timer) in snapshotTimers {
            timer.cancel()
        }
        snapshotTimers.removeAll()
        globalSnapshotsInFlight = 0
        inFlight.removeAll()
        inFlightSince.removeAll()
        startedStreamWindowIds.removeAll()
        videoConnectInProgressWindowIds.removeAll()
    }

    func requestHostFocusForWindow(_ windowId: UInt32, force: Bool = false) {
        let now = Date()

        if !force,
           let last = lastClientActiveWindowRequestAtByWindow[windowId],
           now.timeIntervalSince(last) < clientActiveWindowRequestMinInterval {
            return
        }

        lastClientActiveWindowRequestAtByWindow[windowId] = now
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "clientActiveWindow send force=\(force)")
        sendJSONMessage(ClientActiveWindowMessage(windowId: windowId))
    }

    func setActiveWindow(_ windowId: UInt32) {
        let changed = activeWindowId != windowId

        activeWindowId = windowId
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", windowId: windowId, message: "setActiveWindow changed=\(changed)")

        guard changed else {
            return
        }

        hostConfirmedActiveWindowId = nil
        updateStreamRates()
        requestHostFocusForWindow(windowId, force: true)
    }

    func setPeeledWindowHostingMode(_ mode: PeeledWindowHostingMode, for window: PeelWindow) {
        let windowId = window.windowId
        if mode == .inPlace {
            desiredPeeledWindowHostingModes.removeValue(forKey: windowId)
            if browser?.selectedHostKey == hostKey {
                browser?.desiredPeeledWindowHostingModes.removeValue(forKey: windowId)
            }
        } else {
            desiredPeeledWindowHostingModes[windowId] = mode
            if browser?.selectedHostKey == hostKey {
                browser?.desiredPeeledWindowHostingModes[windowId] = mode
            }
            rememberPeeledWindowHostingIdentity(window)
        }
        forgetPeeledWindowHostingIdentityIfUnused(for: windowId)
        guard supportsHostCapability(.peeledWindowHostingModes) else { return }
        guard mode == .inPlace || currentPeeledWindowIdentityMatches(window) else { return }
        sendJSONMessage(SetPeeledWindowHostingModeMessage(windowId: windowId, mode: mode))
    }

    func setClientWindowActive(_ isActive: Bool, for window: PeelWindow) {
        let windowId = window.windowId
        if isActive {
            desiredClientWindowActivity[windowId] = true
            if browser?.selectedHostKey == hostKey {
                browser?.desiredClientWindowActivity[windowId] = true
            }
            rememberPeeledWindowHostingIdentity(window)
        } else {
            desiredClientWindowActivity.removeValue(forKey: windowId)
            if browser?.selectedHostKey == hostKey {
                browser?.desiredClientWindowActivity.removeValue(forKey: windowId)
            }
        }
        forgetPeeledWindowHostingIdentityIfUnused(for: windowId)
        guard supportsHostCapability(.clientWindowActivity),
              supportsHostCapability(.peeledWindowHostingModes) else { return }
        guard !isActive || currentPeeledWindowIdentityMatches(window) else { return }
        sendJSONMessage(ClientWindowActivityMessage(windowId: windowId, isActive: isActive))
    }

    func resendPeeledWindowHostingStateIfSupported(freshWindows: [PeelWindow]) {
        guard supportsHostCapability(.clientWindowActivity),
              supportsHostCapability(.peeledWindowHostingModes) else { return }
        let matchingWindowIDs = matchingDesiredPeeledWindowIDs(in: freshWindows)
        for windowId in desiredPeeledWindowHostingModes.keys.sorted() where matchingWindowIDs.contains(windowId) {
            guard let mode = desiredPeeledWindowHostingModes[windowId] else { continue }
            sendJSONMessage(SetPeeledWindowHostingModeMessage(windowId: windowId, mode: mode))
        }
        for windowId in desiredClientWindowActivity.keys.sorted() where matchingWindowIDs.contains(windowId) {
            sendJSONMessage(ClientWindowActivityMessage(windowId: windowId, isActive: true))
        }
    }

    private func rememberPeeledWindowHostingIdentity(_ window: PeelWindow) {
        let windowId = window.windowId
        guard desiredPeeledWindowHostingIdentityByWindow[windowId] == nil else { return }
        desiredPeeledWindowHostingIdentityByWindow[windowId] = window
        if browser?.selectedHostKey == hostKey {
            browser?.desiredPeeledWindowHostingIdentityByWindow[windowId] = window
        }
    }

    private func currentPeeledWindowIdentityMatches(_ expected: PeelWindow) -> Bool {
        currentWindowInstanceMatches(expected)
    }

    func currentWindowInstanceMatches(_ expected: PeelWindow) -> Bool {
        guard hasFreshWindowListForCurrentConnection,
              let current = lastWindowListById[expected.windowId] ?? windows.first(where: {
                  $0.windowId == expected.windowId
              }) else {
            return false
        }
        return peeledWindowIdentity(expected, matches: current)
    }

    private func forgetPeeledWindowHostingIdentityIfUnused(for windowId: UInt32) {
        guard desiredPeeledWindowHostingModes[windowId] == nil,
              desiredClientWindowActivity[windowId] == nil else { return }
        desiredPeeledWindowHostingIdentityByWindow.removeValue(forKey: windowId)
        if browser?.selectedHostKey == hostKey {
            browser?.desiredPeeledWindowHostingIdentityByWindow.removeValue(forKey: windowId)
        }
    }

    private func matchingDesiredPeeledWindowIDs(in freshWindows: [PeelWindow]) -> Set<UInt32> {
        var freshByID: [UInt32: PeelWindow] = [:]
        for window in freshWindows {
            freshByID[window.windowId] = window
        }
        return Set(desiredPeeledWindowHostingIdentityByWindow.compactMap { windowId, expected in
            guard let current = freshByID[windowId], peeledWindowIdentity(expected, matches: current) else {
                return nil
            }
            return windowId
        })
    }

    private func peeledWindowIdentity(_ expected: PeelWindow, matches current: PeelWindow) -> Bool {
        guard expected.appName == current.appName,
              expected.title == current.title else { return false }
        switch (expected.appLaunchTimeIntervalSince1970, current.appLaunchTimeIntervalSince1970) {
        case let (expectedLaunch?, currentLaunch?):
            return abs(expectedLaunch - currentLaunch) < 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    func isHostConfirmedActiveWindow(_ windowId: UInt32) -> Bool {
        hostConfirmedActiveWindowId == windowId
    }

    func inputStateDescription(for windowId: UInt32) -> String {
        hostConfirmedActiveWindowId == windowId ? "Active" : "Standby"
    }

    func streamStatus(for windowId: UInt32) -> WindowStreamStatus {
        guard connection != nil, isConnectionReady else { return .offline }

        let hasStreamIntent = desiredPullWindowIds.contains(windowId) || snapshotTimers[windowId] != nil
        let hasVideoRenderer = videoRenderers[windowId] != nil
        let hasVideoSize = videoContentSizeByWindow[windowId] != nil
        let hasSnapshot = snapshotCGImages[windowId] != nil

        if hasStreamIntent && (hasVideoRenderer || hasVideoSize || hasSnapshot) {
            return .active
        }

        let now = Date()
        let last = lastFrameAt[windowId] ?? .distantPast
        let age = now.timeIntervalSince(last)

        let isActive = (activeWindowId == windowId)
        let softThreshold = isActive ? offlineThresholdActive : offlineThresholdInactive

        if hasStreamIntent {
            return age <= max(softThreshold, 10.0) ? .active : .sleeping
        }

        return age <= softThreshold ? .sleeping : .offline
    }

    func updateStreamRates() {
        // H.264/SCK streaming no longer uses timer-driven JPEG pull loops.
    }

    func restartPullTimer(windowId: UInt32, fps: Double) {
        // Disabled for H.264 streaming path.
    }

    func restoreDesiredPullStreamsIfNeeded() {
        guard isConnectionReady, connection != nil else { return }
        guard !desiredPullWindowIds.isEmpty else { return }

        PeelClientDiagnostics.logStreamEvent(ownerName: "session", message: "restoreDesiredPullStreams desired=\(desiredPullWindowIds.sorted()) started=\(startedStreamWindowIds.sorted())")
        let now = Date()

        for windowId in desiredPullWindowIds.sorted() {
            if streamRepairInProgressWindowIds.contains(windowId) {
                continue
            }

            let currentWindow = lastWindowListById[windowId] ?? windows.first(where: {
                $0.windowId == windowId
            })
            let expectedWindow = desiredPullWindowIdentityByWindow[windowId]

            guard let currentWindow,
                  let expectedWindow,
                  peeledWindowIdentity(expectedWindow, matches: currentWindow) else {
                print("PeelClient: not restoring stale desired stream window=\(windowId); missing from fresh windowList")
                if let expectedWindow {
                    endPullStream(for: expectedWindow)
                } else {
                    desiredPullWindowIds.remove(windowId)
                    startedStreamWindowIds.remove(windowId)
                    streamStartAttemptAtByWindow.removeValue(forKey: windowId)
                }
                continue
            }

            if !startedStreamWindowIds.contains(windowId) {
                requestStreamStart(windowId: windowId, reason: "restore desired stream after fresh windowList")
                continue
            }

            let hasRealFrame = (videoFrameCountByWindow[windowId] ?? 0) > 0
                || snapshotCGImages[windowId] != nil

            guard !hasRealFrame else { continue }

            guard let startedAt = streamStartAttemptAtByWindow[windowId] else {
                streamStartAttemptAtByWindow[windowId] = now
                continue
            }

            let age = now.timeIntervalSince(startedAt)

            if age > streamFirstFrameTimeout {
                repairVideoStreamOnly(
                    windowId: windowId,
                    reason: "started stream without first frame after \(String(format: "%.1f", age))s"
                )
            }
        }
    }

    func repairVideoStreamOnly(windowId: UInt32, reason: String) {
        let now = Date()

        if let last = streamLastRepairAtByWindow[windowId],
           now.timeIntervalSince(last) < streamRepairCooldown {
            return
        }

        streamLastRepairAtByWindow[windowId] = now
        let attempt = (streamRepairAttemptByWindow[windowId] ?? 0) + 1
        streamRepairAttemptByWindow[windowId] = attempt
        streamRepairInProgressWindowIds.insert(windowId)

        PeelClientDiagnostics.logStreamEvent(
            ownerName: "session",
            windowId: windowId,
            message: "video-only repair attempt=\(attempt) reason=\(reason)"
        )

        startedStreamWindowIds.remove(windowId)
        streamStartAttemptAtByWindow.removeValue(forKey: windowId)
        videoReadyWindowIds.remove(windowId)
        videoFrameCountByWindow.removeValue(forKey: windowId)
        videoLastFrameReceivedAtByWindow.removeValue(forKey: windowId)
        closeVideoConnection(windowId: windowId, reason: "stream repair: \(reason)")

        if browser?.selectedHostKey == hostKey {
            browser?.startedStreamWindowIds.remove(windowId)
            browser?.streamStartAttemptAtByWindow.removeValue(forKey: windowId)
            browser?.streamRepairAttemptByWindow[windowId] = attempt
            browser?.streamRepairInProgressWindowIds.insert(windowId)
            browser?.videoReadyWindowIds.remove(windowId)
        }

        let delay: TimeInterval = attempt >= maxStreamRepairsBeforeReconnect ? 0.35 : 0.15
        if attempt >= maxStreamRepairsBeforeReconnect {
            streamRepairAttemptByWindow[windowId] = 0
            if browser?.selectedHostKey == hostKey {
                browser?.streamRepairAttemptByWindow[windowId] = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.streamRepairInProgressWindowIds.remove(windowId)
            if self.browser?.selectedHostKey == self.hostKey {
                self.browser?.streamRepairInProgressWindowIds.remove(windowId)
            }

            guard self.isClientVisible,
                  self.isConnectionReady,
                  self.connection != nil,
                  self.desiredPullWindowIds.contains(windowId) else {
                return
            }

            self.requestStreamStart(windowId: windowId, reason: "stream repair: \(reason)")
        }
    }

    func attemptPendingReconnectIfPossible(reason fallbackReason: String = "became visible") {
        guard isClientVisible else { return }
        guard pendingReconnectWhenVisible else { return }
        guard !suppressAutoReconnect else { return }
        guard connection == nil else { return }
        guard isConnectBusy == false else { return }
        guard lastConnectedHostName != nil || lastConnectedHost != nil else { return }
        guard let browser else { return }

        if isUsingDirectEndpoint {
            guard let pairingID = directPairingID,
                  let record = browser.directEndpointRecord(for: pairingID),
                  browser.pairedPeer(forPairingID: pairingID) != nil else {
                pendingReconnectWhenVisible = false
                pendingReconnectReason = nil
                status = "Saved address is no longer available."
                return
            }

            pendingReconnectWhenVisible = false
            let reason = pendingReconnectReason ?? fallbackReason
            pendingReconnectReason = nil
            status = "Reconnecting to \(host.name) by address…"
            configureDirectEndpoint(record)
            print("🔁 Pending direct reconnect triggered: \(host.name) (\(reason))")
            connectAndRequestWindows(isAutoReconnect: true, skipResolve: true)
            return
        }

        guard let host = browser.hosts.last(where: { self.matchesReconnectTarget($0) }) else {
            browser.refreshDiscoveryAfterLifecycleWake(reason: fallbackReason)
            return
        }

        pendingReconnectWhenVisible = false
        let reason = pendingReconnectReason ?? fallbackReason
        pendingReconnectReason = nil
        status = "Reconnecting to \(host.name)…"
        print("🔁 Pending reconnect triggered: \(host.name) (\(reason))")
        updateHost(host)
        connectAndRequestWindows(isAutoReconnect: true)
    }

    func startPing() {
        stopPing()
        streamDiagnosticReporter.clock.reset()

        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 4.0, repeating: 4.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isClientVisible else { return }
            guard self.connection != nil, self.isConnectionReady else { return }
            let probe = self.hostCapabilities.contains(PeelStreamClockReply.capability)
                ? self.streamDiagnosticReporter.clock.makeProbe() : nil
            self.sendJSONMessage(ClientPingMessage(streamClockProbe: probe))
            let sourceConnection = self.connection
            guard self.streamDiagnosticReporter.beginScheduledReport() else { return }
            DispatchQueue.main.async {
                defer { self.streamDiagnosticReporter.finishScheduledReport() }
                guard self.connection === sourceConnection else { return }
                self.sendStreamingDiagnosticsSnapshot()
            }
        }
        timer.resume()
        pingTimer = timer
    }

    func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    func sendStreamingDiagnosticsSnapshot() {
        guard isClientVisible, isConnectionReady, connection != nil,
              hostCapabilities.contains(PeelClientStreamMetricsMessage.capability),
              let batch = streamDiagnosticReporter.nextBatchIfDue() else { return }
        let rows = batch.entries.compactMap { entry -> PeelClientStreamMetric? in
#if os(visionOS)
            let spatial = activeSpatialWindowIds.contains(entry.windowId)
#else
            let spatial = false
#endif
            if !spatial { entry.renderer.refreshStreamingPerformanceMetrics() }
            var row = entry.renderer.streamingDiagnosticSnapshot(windowId: entry.windowId, spatial: spatial)
#if os(visionOS)
            if spatial { row?.spatialPipeline = spatialVideoRenderers[entry.windowId]?.streamingDiagnosticSnapshot() }
#endif
            return row
        }
        let message = PeelClientStreamMetricsMessage(sequence: batch.sequence,
            sampledAtClientUptimeSeconds: ProcessInfo.processInfo.systemUptime,
            streams: rows, untrackedRendererRegistrations: batch.untracked)
        guard message.isValid else { return }
        sendJSONMessage(message)
    }

    func setClientVisibility(_ visible: Bool) {
        guard let browser else { return }
        browser.setClientVisibility(visible)
    }
}

enum AgentPresentationValidation {
    case accepted(normalizedRequestID: String)
    case declined(reason: String)
    case unavailable(reason: String)
}

private func validateAgentPresentation(
    _ message: PresentWindowMessage,
    activePairingID: String?,
    isConnectionReady: Bool,
    hasFreshWindowList: Bool,
    windowMatchesCurrentInstance: (PeelWindow) -> Bool
) -> AgentPresentationValidation {
    guard PeelAgentPresentation.isOptedIn else {
        return .declined(reason: "Agent window opening is turned off on this client.")
    }

    guard let activePairingID,
          activePairingID == message.pairingId else {
        return .unavailable(reason: "This request is for a different Mac connection.")
    }

    guard let requestUUID = UUID(uuidString: message.requestId) else {
        return .unavailable(reason: "This request could not be identified.")
    }

    let now = Date().timeIntervalSince1970
    let ttl = message.expiresAt - message.issuedAt
    guard message.issuedAt.isFinite,
          message.expiresAt.isFinite,
          message.expiresAt >= now,
          ttl >= 0,
          ttl <= 60,
          message.issuedAt <= now + 5 else {
        return .unavailable(reason: "This request has expired.")
    }

    guard isConnectionReady, hasFreshWindowList else {
        return .unavailable(reason: "The Mac window list is not ready.")
    }

    guard windowMatchesCurrentInstance(message.window) else {
        return .unavailable(reason: "That Mac window is no longer available.")
    }

    return .accepted(normalizedRequestID: requestUUID.uuidString)
}

extension PeelClientBrowser {
    /// Re-send the client hello after an agent capability preference changes so
    /// a connected Host can immediately observe the new opt-in capability.
    func refreshAgentPresentationCapabilities() {
#if os(iOS) || os(visionOS)
        // Revoke a pending or reported Mac verification before a free-access
        // hello is sent. Other local access remains a UX policy, not evidence.
        if !PeelAIFeatureAccess.isAllowed { invalidateProEvidence() }
        for session in sessionsByHostKey.values {
            session.machineStatusController.handleLocalOptInChanged()
        }
        if !PeelAgentPresentation.isOptedIn {
            for session in sessionsByHostKey.values {
                session.declinePendingAgentPresentationRequestsForOptOut()
            }
            publishAgentPresentationRoutingChange()
        }

        if connection != nil, isConnectionReady {
            sendClientHello()
        }
        for session in sessionsByHostKey.values where session.connection != nil && session.isConnectionReady {
            session.sendClientHello()
        }
#endif
    }

    /// The legacy browser socket has no independent platform scene state or safe
    /// source-session binding, so it must fail closed on its own socket.
    func receiveManualAgentControlChallenge(_ message: PeelManualAgentControlChallenge) {
        // No independent visible-scene/source-session binding on legacy browser.
    }

    func receiveAgentPresentation(_ message: PresentWindowMessage) {
#if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        sendJSONMessage(
            AgentPresentationResultMessage(
                requestId: message.requestId,
                status: "unavailable",
                reason: "Agent presentation is unavailable on this connection."
            )
        )
#endif
    }

    /// The legacy browser socket has no connection-bound pairing session and
    /// must ignore agent pairing challenges.




    func receiveAgentPairingChallenge(_ message: PeelAgentPairingChallengeMessage) {
        // Intentionally fail closed. Pairing proof is only emitted by the
        // real PeelHostSession after its connection and pairing gates pass.
    }
}

extension PeelHostSession {
    func receiveAgentPresentation(
        _ message: PresentWindowMessage,
        sourceConnection: NWConnection
    ) {
#if os(iOS) || os(visionOS)

        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.receiveAgentPresentation(
                    message,
                    sourceConnection: sourceConnection
                )
            }
            return
        }

        guard connection === sourceConnection else { return }

        let validation = validateAgentPresentation(
            message,
            activePairingID: activePairingID,
            isConnectionReady: isConnectionReady,
            hasFreshWindowList: hasFreshWindowListForCurrentConnection,
            windowMatchesCurrentInstance: currentWindowInstanceMatches
        )

        switch validation {
        case .accepted(let normalizedRequestID):
            guard reserveAgentPresentationRequest(normalizedRequestID) else {
                // Duplicate delivery must never open a second scene. The original
                // request remains responsible for its eventual result.
                return
            }

            guard pendingAgentPresentationRequests.count < 8 else {
                sendAgentPresentationResult(
                    requestId: message.requestId,
                    status: "unavailable",
                    reason: "Too many window requests are waiting."
                )
                return
            }

            pendingAgentPresentationRequests.append(
                PeelPendingAgentPresentationRequest(
                    message: message,
                    sourceConnection: sourceConnection
                )
            )
            browser?.publishAgentPresentationRoutingChange()

        case .declined(let reason):
            sendAgentPresentationResult(
                requestId: message.requestId,
                status: "declined",
                reason: reason
            )

        case .unavailable(let reason):
            sendAgentPresentationResult(
                requestId: message.requestId,
                status: "unavailable",
                reason: reason
            )
        }
#endif
    }

    func receiveManualAgentControlChallenge(_ message: PeelManualAgentControlChallenge) {
#if os(iOS) || os(visionOS)
        guard Thread.isMainThread, PeelManualAgentControl.isOptedIn,
              let proofConnection = connection, isConnectionReady,
              let activePairingID, activePairingID == message.pairingId,
              PeelManualAgentControlProof.isFresh(message, now: Date().timeIntervalSince1970),
              let requestID = UUID(uuidString: message.requestId)?.uuidString,
              lastHandledManualAgentControlChallengeRequestID != requestID,
              let key = browser?.pairingStore.psk(for: message.pairingId),
              let proof = PeelManualAgentControlProof.make(message, key: key) else { return }
        lastHandledManualAgentControlChallengeRequestID = requestID
        guard connection === proofConnection, isConnectionReady,
              self.activePairingID == message.pairingId, PeelManualAgentControl.isOptedIn else { return }
        sendJSONMessage(PeelManualAgentControlProofMessage(requestId: message.requestId,
            pairingId: message.pairingId, proof: proof))
#endif
    }

    func receiveAgentPairingChallenge(_ message: PeelAgentPairingChallengeMessage) {
#if os(iOS) || os(visionOS)

        // Receive.swift has already carried and checked the originating socket.
        guard Thread.isMainThread, let proofConnection = connection else { return }

        guard (PeelAgentPresentation.isOptedIn
            || PeelAgentNotifications.isOptedIn
            || PeelMachineStatusAccess.isOptedIn),
              isConnectionReady,
              let activePairingID,
              activePairingID == message.pairingId,
              PeelAgentPairingProof.isFresh(
                  message,
                  now: Date().timeIntervalSince1970
              ),
              let requestUUID = UUID(uuidString: message.requestId) else {
            return
        }

        let normalizedRequestID = requestUUID.uuidString
        guard lastHandledAgentPairingChallengeRequestID != normalizedRequestID else {
            return
        }
        lastHandledAgentPairingChallengeRequestID = normalizedRequestID

        guard let psk = browser?.pairingStore.psk(for: message.pairingId),
              let proof = PeelAgentPairingProof.make(message, key: psk) else {
            return
        }

        guard connection === proofConnection, isConnectionReady,
              self.activePairingID == message.pairingId,
              (PeelAgentPresentation.isOptedIn
                  || PeelAgentNotifications.isOptedIn
                  || PeelMachineStatusAccess.isOptedIn) else { return }
        sendJSONMessage(
            PeelAgentPairingProofMessage(
                requestId: message.requestId,
                pairingId: message.pairingId,
                proof: proof
            )
        )
#endif
    }

    @discardableResult
    func reserveAgentPresentationRequest(_ normalizedRequestID: String) -> Bool {
        guard !handledAgentPresentationRequestIDs.contains(normalizedRequestID) else {
            return false
        }

        handledAgentPresentationRequestIDs.insert(normalizedRequestID)
        handledAgentPresentationRequestOrder.append(normalizedRequestID)

        while handledAgentPresentationRequestOrder.count > maxHandledAgentPresentationRequestIDs {
            let evicted = handledAgentPresentationRequestOrder.removeFirst()
            handledAgentPresentationRequestIDs.remove(evicted)
        }

        return true
    }

    func claimPendingAgentPresentationRequest() -> PeelPendingAgentPresentationRequest? {
        guard !pendingAgentPresentationRequests.isEmpty else { return nil }
        return pendingAgentPresentationRequests.removeFirst()
    }

    func revalidateAgentPresentation(
        _ pendingRequest: PeelPendingAgentPresentationRequest
    ) -> AgentPresentationValidation {
        guard connection === pendingRequest.sourceConnection else {
            return .unavailable(reason: "This request's Mac connection changed.")
        }

        return validateAgentPresentation(
            pendingRequest.message,
            activePairingID: activePairingID,
            isConnectionReady: isConnectionReady,
            hasFreshWindowList: hasFreshWindowListForCurrentConnection,
            windowMatchesCurrentInstance: currentWindowInstanceMatches
        )
    }

    func declinePendingAgentPresentationRequestsForOptOut() {
        let pendingRequests = pendingAgentPresentationRequests
        pendingAgentPresentationRequests.removeAll()

        for pendingRequest in pendingRequests {
            sendAgentPresentationResult(
                for: pendingRequest,
                status: "declined",
                reason: "Agent window opening is turned off on this client."
            )
        }

        if !pendingRequests.isEmpty {
            browser?.publishAgentPresentationRoutingChange()
        }
    }

    func clearAgentPresentationState() {
        pendingAgentPresentationRequests.removeAll()
        handledAgentPresentationRequestIDs.removeAll()
        handledAgentPresentationRequestOrder.removeAll()
        lastHandledAgentPairingChallengeRequestID = nil
        lastHandledManualAgentControlChallengeRequestID = nil
        browser?.publishAgentPresentationRoutingChange()
    }

    @discardableResult
    func sendAgentPresentationResult(
        for pendingRequest: PeelPendingAgentPresentationRequest,
        status: String,
        reason: String? = nil
    ) -> Bool {
        guard connection === pendingRequest.sourceConnection else {
            return false
        }

        sendAgentPresentationResult(
            requestId: pendingRequest.requestId,
            status: status,
            reason: reason
        )
        return true
    }

    func sendAgentPresentationResult(requestId: String, status: String, reason: String? = nil) {
        sendJSONMessage(
            AgentPresentationResultMessage(
                requestId: requestId,
                status: status,
                reason: reason
            )
        )
    }
}
