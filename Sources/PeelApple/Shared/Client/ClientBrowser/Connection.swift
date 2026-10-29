//
//  Connection.swift
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
    // MARK: - Host connection & window list
    
    /// Returns true if we currently have an active, ready connection to this host.
    func isConnected(to host: PeelHostInfo) -> Bool {
        if let session = existingSession(matching: host),
           session.connection != nil,
           session.isConnectionReady {
            return true
        }

        guard connection != nil, isConnectionReady else { return false }
        return connectedHostName == host.name
    }

    /// Returns true if this host has an active session object, even before the session owns the socket.
    func hasSession(for host: PeelHostInfo) -> Bool {
        existingSession(matching: host) != nil
    }

    /// The session that owns this exact host's transport. A saved-address
    /// descriptor resolves by its pairing; a discovered host never resolves to
    /// a saved-address session.
    func owningSession(for host: PeelHostInfo) -> PeelHostSession? {
        guard let session = existingSession(matching: host) else { return nil }
        if !host.isDirectEndpoint && session.isUsingDirectEndpoint { return nil }
        return session
    }

    /// Ready connection on the host's own session. Unlike `isConnected(to:)`,
    /// this never uses the selected session's global host name, so a
    /// saved-address connection is not attributed to a same-named discovered host.
    func hasOwnedReadyConnection(to host: PeelHostInfo) -> Bool {
        guard let session = owningSession(for: host) else { return false }
        return session.connection != nil && session.isConnectionReady
    }

    fileprivate func existingSession(matching host: PeelHostInfo) -> PeelHostSession? {
        if let direct = sessionsByHostKey[host.hostKey] {
            return direct
        }

        if let directPairingID = host.directPairingID,
           let direct = sessionsByHostKey.values.first(where: { $0.directPairingID == directPairingID }) {
            return direct
        }

        // Direct descriptors are resolved only by their exact saved pairing
        // identity. Do not let hostname/display-name heuristics select a
        // different session.
        if host.isDirectEndpoint {
            return nil
        }

        if let hostId = host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty,
           let match = sessionsByHostKey.values.first(where: { session in
               guard !session.isUsingDirectEndpoint else { return false }
               guard let sessionHostId = session.host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
                     !sessionHostId.isEmpty else {
                   return false
               }

               return sessionHostId == hostId
           }) {
            return match
        }

        return sessionsByHostKey.values.first { session in
            guard !session.isUsingDirectEndpoint else { return false }
            return session.host.service.name == host.service.name ||
            session.host.name == host.name
        }
    }
    
    func disconnect(reason: String = "User disconnected") {
        if let selectedSession {
            selectedSession.disconnect(reason: reason)
            return
        }

        disconnectLegacy(reason: reason)
    }

    fileprivate func disconnectLegacy(reason: String = "User disconnected") {
        let disconnectingHostKey = selectedHostKey
        // Prevent any pending auto-reconnect work from firing.
        suppressAutoReconnect = true
        reconnectWorkItem?.cancel()
        delayedConnectWorkItem?.cancel()
        delayedConnectWorkItem = nil
        reconnectAttempt = 0

        // Ensure the state machine doesn't schedule reconnect from `.cancelled`/`.failed`.
        didHandleDisconnectForCurrentConnection = true

        DispatchQueue.main.async {
            self.isConnectBusy = false
            self.resetSession(reason: reason)
            if let disconnectingHostKey {
                self.sessionsByHostKey[disconnectingHostKey]?.isConnectionReady = false
            }
        }
    }

    func disconnect(from host: PeelHostInfo, reason: String = "User disconnected") {
        let session = existingSession(matching: host) ?? session(for: host)

        if let peer = pairedPeer(for: host) {
            forgetLastConnectedPeer(peer)
        }

        session.suppressAutoReconnect = true
        session.pendingReconnectWhenVisible = false
        session.pendingReconnectReason = nil
        session.reconnectWorkItem?.cancel()
        session.reconnectWorkItem = nil
        session.delayedConnectWorkItem?.cancel()
        session.delayedConnectWorkItem = nil
        session.reconnectAttempt = 0
        session.pendingConnectHost = nil
        session.pendingConnectIsAutoReconnect = false
        session.didHandleDisconnectForCurrentConnection = true

        if pendingConnectHost?.hostKey == session.hostKey || pendingConnectHost?.service.name == session.host.service.name {
            pendingConnectHost = nil
            pendingConnectIsAutoReconnect = false
        }

        if selectedHostKey == session.hostKey {
            suppressAutoReconnect = true
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            delayedConnectWorkItem?.cancel()
            delayedConnectWorkItem = nil
            reconnectAttempt = 0
            didHandleDisconnectForCurrentConnection = true
        }

        session.disconnect(reason: reason)
    }
    
    func connectAndRequestWindows(for host: PeelHostInfo, isAutoReconnect: Bool = false, skipResolve: Bool = false) {
        let targetSession = existingSession(matching: host) ?? session(for: host)

        // Manual taps own the visible/global browser state. Background auto-reconnects must not
        // steal selection/status from the row the user just tapped.
        if !isAutoReconnect || selectedHostKey == nil || selectedHostKey == targetSession.hostKey {
            selectedHostKey = targetSession.hostKey
        }

        targetSession.updateHost(host)
        targetSession.connectAndRequestWindows(isAutoReconnect: isAutoReconnect, skipResolve: skipResolve)
    }

    fileprivate func connectAndRequestWindowsLegacy(for host: PeelHostInfo, isAutoReconnect: Bool = false, skipResolve: Bool = false) {
        let targetSession = session(for: host)
        if !isAutoReconnect || selectedHostKey == nil || selectedHostKey == targetSession.hostKey {
            selectedHostKey = targetSession.hostKey
        }
        targetSession.updateHost(host)
        // Any explicit connect attempt should re-enable auto-reconnect.
        if !isAutoReconnect {
            suppressAutoReconnect = false
        }

        let now = Date()
        if now < nextAllowedConnectAt {
            delayedConnectWorkItem?.cancel()

            let delay = nextAllowedConnectAt.timeIntervalSince(now)
            let work = DispatchWorkItem { [weak self] in
                self?.connectAndRequestWindowsLegacy(for: host, isAutoReconnect: isAutoReconnect, skipResolve: skipResolve)
            }

            delayedConnectWorkItem = work
            DispatchQueue.main.async {
                self.isConnectBusy = true
                self.status = "Waiting for \(host.name) to finish refreshing…"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }

        delayedConnectWorkItem?.cancel()
        delayedConnectWorkItem = nil
        
        // If the user taps Connect while we're already connected to THIS host, don't nuke the session.
        if !isAutoReconnect,
           connection != nil,
           isConnectionReady,
           connectedHostName == host.name {
            DispatchQueue.main.async {
                self.status = "Connected to \(host.name)."
                self.isConnectBusy = false
            }
            // Treat this as a "refresh".
            requestWindowListIfReadyOrDefer()
            startWindowListAutoRefresh()
            startPing()
            return
        }
        
        didHandleDisconnectForCurrentConnection = false
        lastConnectedHost = host
        lastConnectedHostName = host.name
        
        DispatchQueue.main.async {
            self.isConnectBusy = true
            targetSession.isConnectBusy = true
        }
        
        // Only reset backoff when the user explicitly connects.
        if !isAutoReconnect {
            reconnectAttempt = 0
            reconnectWorkItem?.cancel()
        }
        status = "Resolving \(host.name)…"
        // Socket boundaries must not inherit any H.264 decoder/receiver state from
        // the previous stream. Keep desiredPullWindowIds intact so ready can reassert.
        if connection != nil {
            resetSession(reason: "Reconnecting")
        } else {
            resetVideoReceiversForConnectionBoundary(reason: isAutoReconnect ? "auto reconnect starting" : "connect starting")
        }
        
        // Always re-resolve before connecting.
        // Pairing changes can restart the host listener and change the advertised port,
        // so using a previously resolved NetService can create paired/connecting loops.
        if !skipResolve {
            pendingConnectHost = host
            pendingConnectIsAutoReconnect = isAutoReconnect
            host.service.resolve(withTimeout: 5)
            status = "Resolving \(host.name)…"

            // Resolve timeout safety net. This path always re-resolves before connecting,
            // so it needs the same timeout protection as the fallback resolve path below.
            resolveTimeoutWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingConnectHost?.name == host.name else { return }
                self.pendingConnectHost = nil
                self.pendingConnectIsAutoReconnect = false
                self.isConnectBusy = false
                self.status = "Couldn’t reach \(host.name). Looking for it again…"
                self.markDiscoveredHostStaleAndRefresh(host, reason: "resolve timeout")
                self.scheduleReconnect(reason: "resolve timeout")
            }
            resolveTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeoutSeconds, execute: work)

            return
        }
        
        // Normal path: resolve only if missing values
        if host.service.hostName == nil || host.service.port == 0 {
            pendingConnectHost = host
            pendingConnectIsAutoReconnect = isAutoReconnect
            host.service.resolve(withTimeout: 5)
            status = "Resolving \(host.name)…"
            
            // ✅ Resolve timeout safety net
            resolveTimeoutWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingConnectHost?.name == host.name else { return } // still the same pending
                self.pendingConnectHost = nil
                self.pendingConnectIsAutoReconnect = false
                self.isConnectBusy = false
                self.status = "Couldn’t reach \(host.name). Looking for it again…"
                self.markDiscoveredHostStaleAndRefresh(host, reason: "resolve timeout")
                self.scheduleReconnect(reason: "resolve timeout")
            }
            resolveTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeoutSeconds, execute: work)
            
            return
        }
        
        guard let hostName = host.service.hostName, host.service.port > 0 else {
            status = "Failed to resolve host."
            markDiscoveredHostStaleAndRefresh(host, reason: "resolve failed")
            DispatchQueue.main.async { self.isConnectBusy = false }
            scheduleReconnect(reason: "resolve failed")
            return
        }
        
        let port = NWEndpoint.Port(rawValue: UInt16(host.service.port))!
        let endpointHost = NWEndpoint.Host(hostName)
        
        // Build secure parameters (TLS-PSK) if we have a pairing for this host.
        let params: NWParameters
        let connectionPSKOrder: PeelTLSPSKOrder
        if let peer = pairedPeer(for: host),
           let psk = pairingStore.psk(for: peer.id),
           !psk.isEmpty {
            targetSession.requiresPairingRepair = false
            connectionPSKOrder = PeelTLS.clientPSKOrder(for: peer, service: host.service)
            params = PeelTLS.makeClientParameters(
                pairingID: peer.id,
                psk: psk,
                pskOrder: connectionPSKOrder
            )
            self.activePairingID = peer.id
        } else {
            targetSession.requiresPairingRepair = pairedPeer(for: host) != nil
            status = "The saved pairing key is unavailable. Pair again with \(host.name)."
            suppressAutoReconnect = true
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempt = 0
            DispatchQueue.main.async { self.isConnectBusy = false }
            return
        }
        
        let connection = NWConnection(host: endpointHost, port: port, using: params)
        let activeConn = connection
        self.connection = connection
        
        status = "Connecting to \(host.name)…"
        // Reset readiness for this new connection attempt.
        isConnectionReady = false
        pendingWindowListRequest = false
        
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            guard self.connection === activeConn else { return }
            switch newState {
            case .ready:
                self.isInWaitingState = false
                self.resolveTimeoutWorkItem?.cancel()
                self.resolveTimeoutWorkItem = nil
                self.reconnectWorkItem?.cancel()
                self.reconnectWorkItem = nil
                self.reconnectAttempt = 0
                self.pendingReconnectWhenVisible = false
                self.pendingReconnectReason = nil
                DispatchQueue.main.async {
                    self.resetVideoReceiversForConnectionBoundary(reason: "connection ready")
                    self.startStreamWatchdog()

                    self.isConnectionReady = true
                    targetSession.isConnectionReady = true
                    targetSession.isConnectBusy = false
                    targetSession.connectedHostName = host.name
                    self.connectedHostName = host.name
                    self.selectedHostKey = targetSession.hostKey
                    self.lastConnectedHost = host
                    self.lastConnectedHostName = host.name
                    if let peer = self.pairedPeer(for: host) {
                        self.pairingStore.updatePeerTLSPSKOrder(
                            pairingID: peer.id,
                            tlsPSKOrder: connectionPSKOrder
                        )
                        self.persistLastConnectedPeer(peer, host: host)
                    }
                    self.status = "Connected to \(host.name). Requesting windows…"

                    // If something tried to request before we were ready, do it now.
                    if self.pendingWindowListRequest {
                        self.pendingWindowListRequest = false
                    }
                    DispatchQueue.main.async { self.isConnectBusy = false }

                    // Identify/capability-gate first, then publish visibility, then enumerate.
                    // Starting video sockets before the control handshake/window list settles was
                    // the easiest way to recreate reconnect/list-empty loops across mixed builds.
                    self.sendClientHello()
                    self.sendJSONMessage(ClientVisibilityMessage(isVisible: self.isClientVisible))
                    self.sendWindowListRequest()
                    self.startWindowListAutoRefresh()
                    self.startPing()
                }
                self.startReceiveLoop()

            case .failed(let error):
                self.isInWaitingState = false
                self.waitingTimeoutWorkItem?.cancel()
                self.waitingTimeoutWorkItem = nil

                if self.shouldInvalidateLocalPairing(for: host, error: error) {
                    self.invalidateLocalPairing(for: host, because: error)
                    return
                }

                DispatchQueue.main.async {
                    let failedBeforeReady = !self.isConnectionReady
                    self.status = "Connection failed: \(error.localizedDescription)"
                    targetSession.status = self.status
                    targetSession.isConnectionReady = false
                    targetSession.isConnectBusy = false
                    self.handleDisconnectOnce("NW failed: \(error.localizedDescription)")

                    if failedBeforeReady {
                        self.markDiscoveredHostStaleAndRefresh(host, reason: "connection failed")
                    }
                }

            case .cancelled:
                self.isInWaitingState = false
                self.waitingTimeoutWorkItem?.cancel()
                self.waitingTimeoutWorkItem = nil
                DispatchQueue.main.async {
                    self.status = "Connection cancelled."
                    targetSession.status = self.status
                    targetSession.isConnectionReady = false
                    targetSession.isConnectBusy = false
                    self.handleDisconnectOnce("NW cancelled")
                }

            case .waiting(let error):
                DispatchQueue.main.async {
                    self.isConnectionReady = false
                    self.status = "Connection waiting: \(error.localizedDescription)"
                    targetSession.status = self.status
                    targetSession.isConnectionReady = false
                    targetSession.isConnectBusy = true
                }

                self.isInWaitingState = true
                self.waitingTimeoutWorkItem?.cancel()

                if self.shouldInvalidateLocalPairing(for: host, error: error) {
                    self.invalidateLocalPairing(for: host, because: error)
                    return
                }

                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard self.isInWaitingState else { return }
                    self.markDiscoveredHostStaleAndRefresh(host, reason: "waiting timeout")
                    self.connection?.cancel()
                    self.handleDisconnectOnce("waiting timeout")
                }
                self.waitingTimeoutWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + waitingTimeoutSeconds, execute: work)

            default:
                break
            }
        }
        
        connection.start(queue: networkQueue)
    }
    
    func sendWindowListRequest() {
        
        // Avoid sending before NWConnection is `.ready`; an early send can fail
        // and make the UI feel like you have to tap Connect twice.
        if !isConnectionReady {
            pendingWindowListRequest = true
            return
        }
        guard let connection = connection else {
            status = "No active connection."
            return
        }
        
        let req = PeelRequest(type: "requestWindowList")
        
        do {
            let data = try JSONEncoder().encode(req)
            var framed = data
            framed.append(0x0A) // newline delimiter for NDJSON
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    DispatchQueue.main.async {
                        self?.handleDisconnectOnce("send failed: \(error.localizedDescription)", sourceConnection: connection)
                    }
                }
            })
        } catch {
        }
    }
    
    func requestWindowListIfReadyOrDefer() {
        if isConnectionReady {
            sendWindowListRequest()
        } else {
            pendingWindowListRequest = true
        }
    }
    
    func startWindowListAutoRefresh() {
        stopWindowListAutoRefresh()
        
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + windowListRefreshInterval,
                       repeating: windowListRefreshInterval,
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.requestWindowListIfReadyOrDefer()
        }
        timer.resume()
        
        windowListRefreshTimer = timer
    }
    
    func stopWindowListAutoRefresh() {
        windowListRefreshTimer?.cancel()
        windowListRefreshTimer = nil
    }

    func markDiscoveredHostStaleAndRefresh(_ host: PeelHostInfo?, reason: String) {
        let apply = { [weak self] in
            guard let self else { return }

            // Do not remove the host from the nearby list for transient resolve/TLS/NW failures.
            // Discovery presence and socket readiness are separate state. Removing here made a
            // paired Mac disappear immediately after Connect and prevented reconnect until Bonjour
            // happened to republish or the host app was restarted.
            if let host {
                let session = self.sessionsByHostKey[host.hostKey]
                    ?? self.sessionsByHostKey.values.first(where: { session in
                        guard let left = session.host.hostId,
                              let right = host.hostId,
                              !left.isEmpty,
                              !right.isEmpty else {
                            return false
                        }
                        return left == right
                    })

                session?.pendingReconnectWhenVisible = true
                if session?.pendingReconnectReason == nil {
                    session?.pendingReconnectReason = reason
                }
            }

            if self.lastConnectedHostName != nil || self.lastConnectedHost != nil {
                self.pendingReconnectWhenVisible = true
                if self.pendingReconnectReason == nil {
                    self.pendingReconnectReason = reason
                }
            }

            // Let any connection reset scheduled on the main queue run first, then
            // restart Bonjour. This avoids touching discovery while streams are active.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restartDiscoveryAfterHostDrop(reason: reason)
            }
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func removeDiscoveredHost(_ host: PeelHostInfo?) {
        guard let host else { return }

        let remove = { [weak self] in
            guard let self else { return }

            self.hosts.removeAll { candidate in
                if let hostId = host.hostId,
                   let candidateHostId = candidate.hostId,
                   !hostId.isEmpty,
                   !candidateHostId.isEmpty,
                   hostId == candidateHostId {
                    return true
                }

                return candidate.name == host.name || candidate.service.name == host.service.name
            }

            self.serviceToHost = self.serviceToHost.filter { _, candidate in
                if let hostId = host.hostId,
                   let candidateHostId = candidate.hostId,
                   !hostId.isEmpty,
                   !candidateHostId.isEmpty,
                   hostId == candidateHostId {
                    return false
                }

                return candidate.name != host.name && candidate.service.name != host.service.name
            }
        }

        if Thread.isMainThread {
            remove()
        } else {
            DispatchQueue.main.async(execute: remove)
        }
    }

    func restartDiscoveryAfterHostDrop(reason: String = "host drop") {
        let restart = { [weak self] in
            guard let self else { return }

            let hasActiveSession = self.sessionsByHostKey.values.contains { session in
                session.connection != nil || session.isConnectionReady || session.isConnectBusy
            }

            // Never bounce Bonjour while a real session/socket is active. The legacy browser-level
            // fields are only shadows now; the actual sockets live on PeelHostSession.
            guard self.connection == nil,
                  self.isConnectionReady == false,
                  self.isConnectBusy == false,
                  hasActiveSession == false else { return }

            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastDiscoveryRestartAt)
            let delay = max(0, self.minDiscoveryRestartInterval - elapsed)

            self.discoveryRestartWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }

                let hasActiveSession = self.sessionsByHostKey.values.contains { session in
                    session.connection != nil || session.isConnectionReady || session.isConnectBusy
                }

                guard self.connection == nil,
                      self.isConnectionReady == false,
                      self.isConnectBusy == false,
                      hasActiveSession == false else { return }

                self.lastDiscoveryRestartAt = Date()
                self.browser.stop()
                self.browser.searchForServices(ofType: "_peel._tcp.", inDomain: "")
                print("🔎 Restarted Peel host discovery: \(reason)")
            }

            self.discoveryRestartWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        if Thread.isMainThread {
            restart()
        } else {
            DispatchQueue.main.async(execute: restart)
        }
    }

    func matchesReconnectTarget(_ host: PeelHostInfo) -> Bool {
        if let targetName = lastConnectedHostName ?? lastConnectedHost?.name {
            if host.name == targetName { return true }
            if host.service.name == targetName { return true }
        }

        if let targetHostId = lastConnectedHost?.hostId,
           let hostId = host.hostId,
           !targetHostId.isEmpty,
           !hostId.isEmpty,
           targetHostId == hostId {
            return true
        }

        return false
    }

    func resetSession(reason: String) {
        if let session = selectedSession { resetProEvidence(for: session) }
        status = "Disconnected (\(reason))"
        nextAllowedConnectAt = max(
            nextAllowedConnectAt,
            Date().addingTimeInterval(postDisconnectConnectCooldown)
        )
        isConnectionReady = false
        connectedHostName = nil
        if let selectedHostKey {
            sessionsByHostKey[selectedHostKey]?.isConnectionReady = false
            sessionsByHostKey[selectedHostKey]?.isConnectBusy = false
            sessionsByHostKey[selectedHostKey]?.connectedHostName = nil
            sessionsByHostKey[selectedHostKey]?.status = status
        }
        stopPing()
        pendingWindowListRequest = false
        pendingConnectHost = nil
        stopWindowListAutoRefresh()
        stopStreamWatchdog()
        pendingWindowListRequest = false
        
        activePairingID = nil
        activeWindowId = nil
        isMouseDownLocally = false
        mouseDownWindowId = nil
        mouseDownButton = "left"
        lastMouseMoveSentAtByWindow.removeAll()
        lastMouseMoveNormByWindow.removeAll()
        selectedSession?.isMouseDownLocally = false
        selectedSession?.mouseDownWindowId = nil
        selectedSession?.mouseDownButton = "left"
        selectedSession?.lastMouseMoveSentAtByWindow.removeAll()
        selectedSession?.lastMouseMoveNormByWindow.removeAll()
        hostCapabilities.removeAll()
        hostConfirmedActiveWindowId = nil
        lastWindowFocusState = nil
        
        // Stop all snapshot / pull timers
        stopAllPullStreams()
        
        // Clear authoritative state
        windows.removeAll()
        snapshots.removeAll()
        snapshotCGImages.removeAll()
#if canImport(UIKit)
        appIconImageCache.removeAll()
#endif
        windowGeometryById.removeAll()
        resetVideoReceiversForConnectionBoundary(reason: "disconnect: \(reason)")
        receiveBuffer.removeAll()
        binaryBuffer.removeAll()
        inFlight.removeAll()
        startedStreamWindowIds.removeAll()
        muxBuffer.removeAll()
        videoReadyWindowIds.removeAll()
        videoFrameCountByWindow.removeAll()
        videoLastFrameByteCountByWindow.removeAll()
        videoLastFrameWasKeyframeByWindow.removeAll()
        videoLastFrameReceivedAtByWindow.removeAll()
        
        hasFreshWindowListForCurrentConnection = false
        streamRepairInProgressWindowIds.removeAll()

        streamStartAttemptAtByWindow.removeAll()
        streamLastRepairAtByWindow.removeAll()
        streamRepairAttemptByWindow.removeAll()
        videoConfigReceivedAtByWindow.removeAll()
        inFlightSince.removeAll()
        
        
        lastWindowListById.removeAll()
        pendingAutoPopupBySource.removeAll()
        autoPopupParentByChild.removeAll()
        lastAutoPopupAtBySource.removeAll()
        lastUserInteractionWindowId = nil
        lastUserInteractionAt = .distantPast
        
        pendingHostCommandAutoOpenWindow = nil
        pendingLauncherCommandIssuedAt = nil
        pendingLauncherExistingFinderWindowIds.removeAll()
        pendingLauncherSuccessorWindow = nil
        pendingLauncherTrackedFinderWindowId = nil
        pendingLauncherSuccessorIssuedAt = nil

        
        connection?.cancel()
        connection = nil
        
        resolveTimeoutWorkItem?.cancel()
        resolveTimeoutWorkItem = nil
        waitingTimeoutWorkItem?.cancel()
        waitingTimeoutWorkItem = nil
        isInWaitingState = false
    }
    
    func scheduleReconnect(reason: String) {
        // If the user explicitly disconnected, don't fight them.
        guard !suppressAutoReconnect else {
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Disconnected."
            }
            return
        }

        guard let name = lastConnectedHostName ?? lastConnectedHost?.name else {
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Disconnected."
            }
            return
        }

        // If the host isn't currently discoverable, don't spin a reconnect loop.
        // Keep the reconnect intent alive so discovery can reconnect when this same host is visible again.
        guard let freshHost = hosts.last(where: { self.matchesReconnectTarget($0) }) else {
            pendingReconnectWhenVisible = true
            pendingReconnectReason = reason
            restartDiscoveryAfterHostDrop(reason: reason)
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Host '\(name)' offline (\(reason)). Waiting…"
            }
            return
        }

        reconnectAttempt += 1
        if reconnectAttempt > maxReconnectAttempts {
            pendingReconnectWhenVisible = true
            pendingReconnectReason = reason
            markDiscoveredHostStaleAndRefresh(freshHost, reason: "reconnect max attempts")
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Reconnect failed after \(self.maxReconnectAttempts) attempts. Looking for the Mac again…"
            }
            return
        }

        DispatchQueue.main.async {
            self.isConnectBusy = true
            self.status = "Disconnected (\(reason)). Reconnecting… (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts))"
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.suppressAutoReconnect else { return }
            guard let latestHost = self.hosts.last(where: { self.matchesReconnectTarget($0) }) else {
                self.pendingReconnectWhenVisible = true
                self.pendingReconnectReason = reason
                self.restartDiscoveryAfterHostDrop(reason: reason)
                DispatchQueue.main.async {
                    self.isConnectBusy = false
                    self.status = "Host '\(freshHost.name)' offline (\(reason)). Waiting…"
                }
                return
            }
            self.connectAndRequestWindows(for: latestHost, isAutoReconnect: true)
        }
        reconnectWorkItem = work

        // Simple backoff: 1s, 2s, 4s, 5s cap. A small jitter avoids repeatedly
        // reconnecting at the exact same point during host listener refreshes.
        let jitter = Double.random(in: 0.0...0.35)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)) * 1.0 + jitter, 5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func handleDisconnectOnce(_ reason: String, sourceConnection: NWConnection? = nil) {
        guard let disconnectingConnection = sourceConnection ?? connection else { return }
        let apply = { [weak self] in
            guard let self, self.connection === disconnectingConnection else { return }

            // Browser connection is a mirror when a real session owns this socket.
            // An in-flight legacy poll must not run a second reset/retry machine.
            if let owner = self.sessionsByHostKey.values.first(where: {
                $0.connection === disconnectingConnection
            }) {
                owner.handleDisconnectOnce(reason, sourceConnection: disconnectingConnection)
                return
            }

            // A lagging mirror can still contain a retired session socket. No
            // legacy reset is allowed while any real session owns lifecycle.
            guard self.sessionsByHostKey.isEmpty else { return }
            guard !self.didHandleDisconnectForCurrentConnection else { return }
            self.didHandleDisconnectForCurrentConnection = true
            self.pendingReconnectWhenVisible = true
            self.pendingReconnectReason = reason
            self.resetSession(reason: reason)

            if !self.isClientVisible {
                self.isConnectBusy = false
                self.status = "Host dropped. Waiting for it to come back…"
                return
            }

            self.scheduleReconnect(reason: reason)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}


extension PeelHostSession {
    /// Resolve, cooldown and retry callbacks all reach this admission boundary.
    /// Hiding may happen after they were scheduled; read current visibility here,
    /// preserving session-owned intent for one normal foreground resume.
    func deferConnectionWhileHidden() -> Bool {
        guard !isClientVisible else { return false }
        lastConnectedHost = host
        lastConnectedHostName = host.name
        pendingReconnectWhenVisible = !suppressAutoReconnect
        if pendingReconnectWhenVisible, pendingReconnectReason == nil {
            pendingReconnectReason = "client is inactive"
        }
        isConnectBusy = false
        status = "Connection paused while Peel Pro is inactive."
        if let browser, browser.selectedHostKey == hostKey {
            browser.isConnectBusy = false
            browser.pendingReconnectWhenVisible = pendingReconnectWhenVisible
            browser.pendingReconnectReason = pendingReconnectReason
            browser.status = status
        }
        return true
    }

    func connectAndRequestWindows(isAutoReconnect: Bool = false, skipResolve: Bool = false) {
        guard let browser else { return }
        guard !deferConnectionWhileHidden() else { return }

        // Manual user-initiated connects should select this row. Auto-reconnects should stay
        // session-local unless this session is already the selected/global one.
        if !isAutoReconnect || browser.selectedHostKey == nil || browser.selectedHostKey == hostKey {
            browser.selectedHostKey = hostKey
        }

        if !isAutoReconnect {
            suppressAutoReconnect = false
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            nextAllowedConnectAt = .distantPast

            if browser.selectedHostKey == hostKey {
                browser.suppressAutoReconnect = false
                browser.pendingReconnectWhenVisible = false
                browser.pendingReconnectReason = nil
                browser.nextAllowedConnectAt = .distantPast
            }
        }

        let now = Date()
        if now < nextAllowedConnectAt {
            delayedConnectWorkItem?.cancel()

            let delay = nextAllowedConnectAt.timeIntervalSince(now)
            let work = DispatchWorkItem { [weak self] in
                self?.connectAndRequestWindows(isAutoReconnect: isAutoReconnect, skipResolve: skipResolve)
            }

            delayedConnectWorkItem = work
            DispatchQueue.main.async {
                self.isConnectBusy = true
                self.status = "Waiting for \(self.host.name) to finish refreshing…"
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = true
                    browser.status = self.status
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }

        delayedConnectWorkItem?.cancel()
        delayedConnectWorkItem = nil

        if !isAutoReconnect,
           connection != nil,
           isConnectionReady,
           connectedHostName == host.name,
           !isUsingDirectEndpoint || connectedTransportEndpoint == currentTransportEndpoint() {
            DispatchQueue.main.async {
                self.status = "Connected to \(self.host.name)."
                self.isConnectBusy = false
                if browser.selectedHostKey == self.hostKey {
                    browser.status = self.status
                    browser.isConnectBusy = false
                }
            }
            requestWindowListIfReadyOrDefer()
            startWindowListAutoRefresh()
            startPing()
            return
        }

        didHandleDisconnectForCurrentConnection = false
        lastConnectedHost = host
        lastConnectedHostName = host.name

        DispatchQueue.main.async {
            self.isConnectBusy = true
            if browser.selectedHostKey == self.hostKey {
                browser.isConnectBusy = true
            }
        }

        if !isAutoReconnect {
            reconnectAttempt = 0
            reconnectWorkItem?.cancel()
        }

        status = isUsingDirectEndpoint
            ? "Connecting to \(host.name) by address…"
            : "Resolving \(host.name)…"
        if browser.selectedHostKey == hostKey {
            browser.status = status
        }

        if connection != nil {
            resetSession(reason: "Reconnecting")
        } else {
            resetVideoReceiversForConnectionBoundary(reason: isAutoReconnect ? "auto reconnect starting" : "connect starting")
        }

        // Always re-resolve before opening a new control connection unless this call
        // is already the post-resolve continuation. Bonjour/NetService can keep old
        // hostName/port values after the host tears down and reopens its listener, and
        // those cached values can point us at a stale ephemeral port forever.
        if !isUsingDirectEndpoint && !skipResolve {
            pendingConnectHost = host
            pendingConnectIsAutoReconnect = isAutoReconnect
            host.service.resolve(withTimeout: 5)
            status = "Resolving \(host.name)…"
            if browser.selectedHostKey == hostKey {
                browser.status = status
            }

            resolveTimeoutWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak browser] in
                guard let self, let browser else { return }
                guard let pendingHost = self.pendingConnectHost,
                      pendingHost.hostKey == self.hostKey ||
                      pendingHost.service.name == self.host.service.name ||
                      pendingHost.name == self.host.name else { return }
                self.pendingConnectHost = nil
                self.pendingConnectIsAutoReconnect = false
                self.isConnectBusy = false
                self.status = "Couldn’t reach \(self.host.name). Looking for it again…"
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                    browser.status = self.status
                }
                browser.markDiscoveredHostStaleAndRefresh(self.host, reason: "resolve timeout")
                self.scheduleReconnect(reason: "resolve timeout")
            }
            resolveTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeoutSeconds, execute: work)
            return
        }

        if !isUsingDirectEndpoint && (host.service.hostName == nil || host.service.port == 0) {
            pendingConnectHost = host
            pendingConnectIsAutoReconnect = isAutoReconnect
            host.service.resolve(withTimeout: 5)
            status = "Resolving \(host.name)…"
            if browser.selectedHostKey == hostKey {
                browser.status = status
            }

            resolveTimeoutWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak browser] in
                guard let self, let browser else { return }
                guard let pendingHost = self.pendingConnectHost,
                      pendingHost.hostKey == self.hostKey ||
                      pendingHost.service.name == self.host.service.name ||
                      pendingHost.name == self.host.name else { return }
                self.pendingConnectHost = nil
                self.pendingConnectIsAutoReconnect = false
                self.isConnectBusy = false
                self.status = "Couldn’t reach \(self.host.name). Looking for it again…"
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                    browser.status = self.status
                }
                browser.markDiscoveredHostStaleAndRefresh(self.host, reason: "resolve timeout")
                self.scheduleReconnect(reason: "resolve timeout")
            }
            resolveTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resolveTimeoutSeconds, execute: work)
            return
        }

        guard let transportEndpoint = currentTransportEndpoint() else {
            status = isUsingDirectEndpoint
                ? "Saved address is unavailable."
                : "Failed to resolve host."
            if browser.selectedHostKey == hostKey {
                browser.status = status
            }
            if !isUsingDirectEndpoint {
                browser.markDiscoveredHostStaleAndRefresh(host, reason: "resolve failed")
            }
            DispatchQueue.main.async {
                self.isConnectBusy = false
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                }
            }
            if !isUsingDirectEndpoint {
                scheduleReconnect(reason: "resolve failed")
            }
            return
        }

        guard let port = NWEndpoint.Port(rawValue: transportEndpoint.port) else {
            status = "Saved address has an invalid port."
            if browser.selectedHostKey == hostKey {
                browser.status = status
            }
            DispatchQueue.main.async {
                self.isConnectBusy = false
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                }
            }
            return
        }
        let endpointHost = NWEndpoint.Host(transportEndpoint.host)

        let params: NWParameters
        let connectionPSKOrder: PeelTLSPSKOrder
        if let peer = connectionPeer(),
           let psk = browser.pairingStore.psk(for: peer.id),
           !psk.isEmpty {
            guard let pskOrder = transportPSKOrder(for: peer) else {
                status = "Connect to this Mac once on the local network before using its saved address."
                suppressAutoReconnect = true
                pendingReconnectWhenVisible = false
                pendingReconnectReason = nil
                DispatchQueue.main.async {
                    self.isConnectBusy = false
                    if browser.selectedHostKey == self.hostKey {
                        browser.isConnectBusy = false
                        browser.status = self.status
                    }
                }
                return
            }
            requiresPairingRepair = false
            connectionPSKOrder = pskOrder
            params = PeelTLS.makeClientParameters(
                pairingID: peer.id,
                psk: psk,
                pskOrder: connectionPSKOrder
            )
            activePairingID = peer.id
            if browser.selectedHostKey == hostKey {
                browser.activePairingID = peer.id
            }
        } else {
            requiresPairingRepair = connectionPeer() != nil
            status = "The saved pairing key is unavailable. Pair again with \(host.name)."
            suppressAutoReconnect = true
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempt = 0
            if browser.selectedHostKey == hostKey {
                browser.status = status
                browser.suppressAutoReconnect = true
                browser.pendingReconnectWhenVisible = false
                browser.pendingReconnectReason = nil
                browser.reconnectWorkItem?.cancel()
                browser.reconnectWorkItem = nil
                browser.reconnectAttempt = 0
            }
            DispatchQueue.main.async {
                self.isConnectBusy = false
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                }
            }
            return
        }

        let newConnection = NWConnection(host: endpointHost, port: port, using: params)
        let activeConn = newConnection
        connection = newConnection
        browser.proEvidenceClient(for: self).connectionDidChange()
        connectedTransportEndpoint = transportEndpoint

        status = "Connecting to \(host.name)…"
        isConnectionReady = false
        pendingWindowListRequest = false

        if browser.selectedHostKey == hostKey {
            browser.connection = newConnection
            browser.status = status
            browser.isConnectionReady = false
            browser.pendingWindowListRequest = false
        }

        newConnection.stateUpdateHandler = { [weak self, weak browser] newState in
            // Serialize the identity check with every state mutation. A callback
            // queued before suspension must not update a replacement on resume.
            DispatchQueue.main.async {
                guard let self, let browser else { return }
                guard self.connection === activeConn else { return }

                switch newState {
                case .ready:
                    // TLS may finish after Home/background. Do not publish a
                    // Hello that would replace another receiver's host session.
                    guard self.isClientVisible else {
                        self.handleDisconnectOnce("Client became inactive before connection ready", sourceConnection: activeConn)
                        return
                    }
                    self.isInWaitingState = false
                    self.resolveTimeoutWorkItem?.cancel()
                    self.resolveTimeoutWorkItem = nil
                    self.reconnectWorkItem?.cancel()
                    self.reconnectWorkItem = nil
                    self.reconnectAttempt = 0
                    self.pendingReconnectWhenVisible = false
                    self.pendingReconnectReason = nil

                    self.resetVideoReceiversForConnectionBoundary(reason: "connection ready")
                    self.startStreamWatchdog()

                    self.isConnectionReady = true
                    self.isConnectBusy = false
                    self.connectedHostName = self.host.name
                    self.lastConnectedHost = self.host
                    self.lastConnectedHostName = self.host.name

                    if browser.selectedHostKey == self.hostKey {
                        browser.connection = activeConn
                        browser.isConnectionReady = true
                        browser.isConnectBusy = false
                        browser.connectedHostName = self.host.name
                        browser.lastConnectedHost = self.host
                        browser.lastConnectedHostName = self.host.name
                        browser.suppressAutoReconnect = self.suppressAutoReconnect
                        browser.pendingReconnectWhenVisible = self.pendingReconnectWhenVisible
                        browser.pendingReconnectReason = self.pendingReconnectReason
                    }

                    if let peer = self.connectionPeer() {
                        browser.pairingStore.updatePeerTLSPSKOrder(
                            pairingID: peer.id,
                            tlsPSKOrder: connectionPSKOrder
                        )
                        browser.persistLastConnectedPeer(peer, host: self.host)
                    }

                    self.status = "Connected to \(self.host.name). Requesting windows…"
                    if browser.selectedHostKey == self.hostKey {
                        browser.status = self.status
                    }

                    self.pendingWindowListRequest = false
                    if browser.selectedHostKey == self.hostKey {
                        browser.pendingWindowListRequest = false
                    }

                    // Identify/capability-gate first, then publish visibility, then enumerate.
                    // Desired streams are restored from the fresh window-list path instead of
                    // immediately opening video sockets against stale pre-reconnect window ids.
                    self.sendClientHello()
                    self.sendJSONMessage(ClientVisibilityMessage(isVisible: browser.isClientVisible))
                    self.sendWindowListRequest()
                    self.startWindowListAutoRefresh()
                    self.startPing()

                    self.startReceiveLoop()

                case .failed(let error):
                    self.isInWaitingState = false
                    self.waitingTimeoutWorkItem?.cancel()
                    self.waitingTimeoutWorkItem = nil

                    if browser.shouldInvalidateLocalPairing(for: self.host, error: error) {
                        browser.invalidateLocalPairing(for: self.host, because: error)
                        return
                    }

                    let failedBeforeReady = !self.isConnectionReady
                    self.status = "Connection failed: \(error.localizedDescription)"
                    self.isConnectionReady = false
                    self.isConnectBusy = false
                    if browser.selectedHostKey == self.hostKey {
                        browser.status = self.status
                        browser.isConnectionReady = false
                        browser.isConnectBusy = false
                    }
                    self.handleDisconnectOnce("NW failed: \(error.localizedDescription)")

                    if failedBeforeReady && !self.isUsingDirectEndpoint {
                        browser.markDiscoveredHostStaleAndRefresh(self.host, reason: "connection failed")
                    }

                case .cancelled:
                    self.isInWaitingState = false
                    self.waitingTimeoutWorkItem?.cancel()
                    self.waitingTimeoutWorkItem = nil
                    self.status = "Connection cancelled."
                    self.isConnectionReady = false
                    self.isConnectBusy = false
                    if browser.selectedHostKey == self.hostKey {
                        browser.status = self.status
                        browser.isConnectionReady = false
                        browser.isConnectBusy = false
                    }
                    self.handleDisconnectOnce("NW cancelled")

                case .waiting(let error):
                    self.isConnectionReady = false
                    self.status = "Connection waiting: \(error.localizedDescription)"
                    self.isConnectBusy = true
                    if browser.selectedHostKey == self.hostKey {
                        browser.isConnectionReady = false
                        browser.status = self.status
                        browser.isConnectBusy = true
                    }

                    self.isInWaitingState = true
                    self.waitingTimeoutWorkItem?.cancel()

                    if browser.shouldInvalidateLocalPairing(for: self.host, error: error) {
                        browser.invalidateLocalPairing(for: self.host, because: error)
                        return
                    }

                    let work = DispatchWorkItem { [weak self, weak browser] in
                        guard let self, let browser else { return }
                        guard self.connection === activeConn, self.isInWaitingState else { return }
                        if !self.isUsingDirectEndpoint {
                            browser.markDiscoveredHostStaleAndRefresh(self.host, reason: "waiting timeout")
                        }
                        self.connection?.cancel()
                        self.handleDisconnectOnce("waiting timeout")
                    }
                    self.waitingTimeoutWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.waitingTimeoutSeconds, execute: work)

                default:
                    break
                }
            }
        }

        newConnection.start(queue: networkQueue)
    }

    func disconnect(reason: String = "User disconnected") {
        if let browser, let peer = connectionPeer() {
            browser.forgetLastConnectedPeer(peer)
        }
        watchFocusProof.invalidate()
        suppressAutoReconnect = true
        pendingReconnectWhenVisible = false
        pendingReconnectReason = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        delayedConnectWorkItem?.cancel()
        delayedConnectWorkItem = nil
        reconnectAttempt = 0
        pendingConnectHost = nil
        pendingConnectIsAutoReconnect = false
        didHandleDisconnectForCurrentConnection = true

        DispatchQueue.main.async {
            self.isConnectBusy = false
            self.resetSession(reason: reason)
        }
    }

    func sendClientHello() {
        guard let browser else { return }
        var capabilities = PeelProtocol.advertisedClientCapabilities
        capabilities.insert(PeelProEvidenceLimits.capability)
#if os(iOS) || os(visionOS)
        if PeelAudioPlatformCapabilities.supportsMacSystemAudio {
            capabilities.insert(PeelCapability.macSystemAudioV1.rawValue)
        }
        if PeelAudioPlatformCapabilities.supportsFullDuplexVoice {
            capabilities.insert(PeelCapability.remoteVoiceV1.rawValue)
        }
#endif
#if os(iOS)
        if PeelAgentNotifications.isOptedIn {
            capabilities.insert(PeelCapability.agentNotificationsV1.rawValue)
        }
#elseif os(visionOS)
        if PeelAgentNotifications.isOptedIn {
            capabilities.insert(PeelCapability.agentNotificationsV1.rawValue)
        }
#endif
#if os(iOS) || os(visionOS)
        if PeelMachineStatusAccess.isOptedIn {
            capabilities.insert(PeelCapability.machineStatusV1.rawValue)
        }
        // Stream window controls can send source media keys; volume only
        // once a source volume scope is selected.
        capabilities.insert(PeelSourceMediaProtocol.mediaKeysCapability)
        if PeelSourceVolumeScopeSelection.selected != nil {
            capabilities.insert(PeelSourceMediaProtocol.volumeCapability)
        }
#endif
        capabilities.insert(PeelRuntimeCapability.hostRenderedCursor)

        let msg = ClientHelloMessage(
            pairingID: activePairingID,
            deviceName: browser.currentDeviceName(),
            deviceModel: browser.currentDeviceModel(),
            platform: browser.currentPlatformString(),
            osVersion: browser.currentOSVersion(),
            appVersion: browser.currentAppVersion(),
            capabilities: capabilities
        )
        sendJSONMessage(msg)
    }

    func openVideoConnectionIfNeeded(windowId: UInt32, nativeExperimentRequest: PeelVideoStreamRequest? = nil) {
        guard let browser else { return }
        guard isConnectionReady else { return }
        guard videoConnectionsByWindowId[windowId] == nil else { return }
        guard !videoConnectInProgressWindowIds.contains(windowId) else { return }

        guard let transportEndpoint = currentTransportEndpoint(),
              let port = NWEndpoint.Port(rawValue: transportEndpoint.port) else {
            status = isUsingDirectEndpoint
                ? "Cannot start video: saved address is unavailable."
                : "Cannot start video: host is not resolved."
            if browser.selectedHostKey == hostKey {
                browser.status = status
            }
            return
        }

        let params: NWParameters
        if let peer = connectionPeer(),
           let psk = browser.pairingStore.psk(for: peer.id),
           !psk.isEmpty {
            guard let pskOrder = transportPSKOrder(for: peer) else {
                status = "Connect to this Mac once on the local network before using its saved address."
                if browser.selectedHostKey == hostKey {
                    browser.status = status
                }
                return
            }
            params = PeelTLS.makeClientParameters(
                pairingID: peer.id,
                psk: psk,
                pskOrder: pskOrder
            )
            activePairingID = peer.id
            if browser.selectedHostKey == hostKey {
                browser.activePairingID = peer.id
            }
        } else {
            status = "Cannot start video: \(host.name) is not paired."
            if browser.selectedHostKey == hostKey {
                browser.status = status
            }
            return
        }

        videoConnectInProgressWindowIds.insert(windowId)

        let endpointHost = NWEndpoint.Host(transportEndpoint.host)
        let videoConnection = NWConnection(host: endpointHost, port: port, using: params)
        let activeVideoConnection = videoConnection

        videoConnectionsByWindowId[windowId] = videoConnection
        videoReceiveBuffersByWindowId[windowId] = Data()

        videoConnection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            guard self.videoConnectionsByWindowId[windowId] === activeVideoConnection else { return }

            switch newState {
            case .ready:
                self.videoConnectInProgressWindowIds.remove(windowId)
                self.sendVideoStreamHello(windowId: windowId, connection: activeVideoConnection, nativeExperimentRequest: nativeExperimentRequest)
                self.startVideoReceiveLoop(windowId: windowId, connection: activeVideoConnection)

            case .failed(let error):
                self.handleUnexpectedVideoConnectionClosure(windowId: windowId,
                    connection: activeVideoConnection, reason: "video failed: \(error.localizedDescription)")

            case .cancelled:
                self.handleUnexpectedVideoConnectionClosure(windowId: windowId,
                    connection: activeVideoConnection, reason: "video cancelled")

            default:
                break
            }
        }

        videoConnection.start(queue: networkQueue)
    }

    static var nativeStreamExperimentFPS: Int? {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
#if os(visionOS)
        return arguments.contains("--peel-request-native-90") ? 90 : nil
#else
        return arguments.contains("--peel-request-native-120") ? 120
            : (arguments.contains("--peel-request-native-60") ? 60 : nil)
#endif
#else
        return nil
#endif
    }

    /// One explicit experiment after baseline video has attached. Recovery and
    /// ordinary starts never renew the experiment automatically.
    func requestNativeStreamExperiment(windowId: UInt32) {
#if DEBUG
        guard Thread.isMainThread, let fps = Self.nativeStreamExperimentFPS,
              let browser, browser.session(for: hostKey) === self,
              isClientVisible, isConnectionReady, connection != nil,
              desiredPullWindowIds.contains(windowId), videoConnectionsByWindowId[windowId] != nil,
              let renderer = videoRenderers[windowId] else { return }
#if os(visionOS)
        // visionOS exposes no public per-window UIScreen. Request a content
        // cadence explicitly; do not invent physical display dimensions.
        _ = renderer
        let request = PeelVideoStreamRequest(maximumFPS: fps, receiverDisplay: nil, visionOS90Experiment: true)
#else
        guard let display = VideoLayerContainerView.receiverDisplayCapabilities(for: renderer.displayLayer) else { return }
        let request = PeelVideoStreamRequest(maximumFPS: fps, receiverDisplay: display)
#endif
        closeVideoConnection(windowId: windowId, reason: "explicit bounded native experiment")
        resetVideoStreamReadiness(windowId: windowId)
        openVideoConnectionIfNeeded(windowId: windowId, nativeExperimentRequest: request)
#endif
    }

    private func sendVideoStreamHello(windowId: UInt32, connection: NWConnection, nativeExperimentRequest: PeelVideoStreamRequest? = nil) {
#if DEBUG
        if let request = nativeExperimentRequest {
            let sourceControl = self.connection
            DispatchQueue.main.async { [weak self] in
                guard let self, let sourceControl,
                      self.connection === sourceControl, self.isConnectionReady, self.isClientVisible,
                      self.videoConnectionsByWindowId[windowId] === connection,
                      self.desiredPullWindowIds.contains(windowId) else { return }
                self.sendVideoStreamHello(windowId: windowId, connection: connection, streamRequest: request)
            }
            return
        }
#endif
        sendVideoStreamHello(windowId: windowId, connection: connection, streamRequest: nil)
    }

    private func sendVideoStreamHello(windowId: UInt32, connection: NWConnection,
                                      streamRequest: PeelVideoStreamRequest?) {
        var capabilities = PeelProtocol.advertisedClientCapabilities
        capabilities.insert(PeelRuntimeCapability.hostRenderedCursor)
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            capabilities.insert(PeelCapability.hevcVideo.rawValue)
        } else {
            capabilities.remove(PeelCapability.hevcVideo.rawValue)
        }
        if streamRequest != nil { capabilities.insert(PeelVideoStreamRequest.capability) }
        let hello = VideoStreamHelloMessage(
            windowId: windowId,
            pairingID: activePairingID,
            capabilities: capabilities,
            streamRequest: streamRequest
        )

        do {
            let data = try JSONEncoder().encode(hello)
            var framed = data
            framed.append(0x0A)
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.handleUnexpectedVideoConnectionClosure(windowId: windowId,
                        connection: connection, reason: "video hello send failed: \(error.localizedDescription)")
                }
            })
        } catch {
            handleUnexpectedVideoConnectionClosure(windowId: windowId,
                connection: connection, reason: "video hello encode failed")
        }
    }

    /// Terminal callbacks belong to their socket, even after a replacement opens.
    /// Intentional close paths call closeVideoConnection directly and never repair.
    func handleUnexpectedVideoConnectionClosure(windowId: UInt32, connection source: NWConnection, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.videoConnectionsByWindowId[windowId] === source else { return }
            self.closeVideoConnection(windowId: windowId, reason: reason)
            self.resetVideoStreamReadiness(windowId: windowId)

            // Keep the sent-start marker until repair is admitted. If its cooldown
            // is still active, the first-frame watchdog retries this zero-frame
            // attempt through the same bounded repair policy.
            guard self.isClientVisible, self.connection != nil, self.isConnectionReady,
                  self.desiredPullWindowIds.contains(windowId),
                  !self.streamRepairInProgressWindowIds.contains(windowId) else { return }
            self.repairStream(windowId: windowId, reason: reason)
        }
    }

    func closeVideoConnection(windowId: UInt32, reason: String = "video closed") {
        videoConnectInProgressWindowIds.remove(windowId)
        videoReceiveBuffersByWindowId.removeValue(forKey: windowId)

        guard let connection = videoConnectionsByWindowId.removeValue(forKey: windowId) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func closeAllVideoConnections(reason: String = "video closed") {
        let windowIds = Array(videoConnectionsByWindowId.keys)
        for windowId in windowIds {
            closeVideoConnection(windowId: windowId, reason: reason)
        }
        videoConnectInProgressWindowIds.removeAll()
        videoReceiveBuffersByWindowId.removeAll()
    }

    func sendWindowListRequest() {
        if !isConnectionReady {
            pendingWindowListRequest = true
            return
        }
        guard let connection = connection else {
            status = "No active connection."
            return
        }

        let req = PeelRequest(type: "requestWindowList")

        do {
            let data = try JSONEncoder().encode(req)
            var framed = data
            framed.append(0x0A)
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    DispatchQueue.main.async {
                        self?.handleDisconnectOnce("send failed: \(error.localizedDescription)", sourceConnection: connection)
                    }
                }
            })
        } catch {
        }
    }

    func requestWindowListIfReadyOrDefer() {
        if isConnectionReady {
            sendWindowListRequest()
        } else {
            pendingWindowListRequest = true
        }
    }

    func startWindowListAutoRefresh() {
        stopWindowListAutoRefresh()

        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + windowListRefreshInterval,
                       repeating: windowListRefreshInterval,
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.requestWindowListIfReadyOrDefer()
        }
        timer.resume()

        windowListRefreshTimer = timer
    }

    func stopWindowListAutoRefresh() {
        windowListRefreshTimer?.cancel()
        windowListRefreshTimer = nil
    }

    func matchesReconnectTarget(_ host: PeelHostInfo) -> Bool {
        if let directPairingID {
            return host.directPairingID == directPairingID
        }

        if let targetName = lastConnectedHostName ?? lastConnectedHost?.name {
            if host.name == targetName { return true }
            if host.service.name == targetName { return true }
        }

        if let targetHostId = lastConnectedHost?.hostId,
           let hostId = host.hostId,
           !targetHostId.isEmpty,
           !hostId.isEmpty,
           targetHostId == hostId {
            return true
        }

        return false
    }

    func resetSession(reason: String) {
        browser?.resetProEvidence(for: self)
        watchFocusConnectionGeneration &+= 1
        watchFocusProof.invalidate()
#if os(iOS) || os(visionOS)
        machineStatusController.reset(reason: "Mac Status is unavailable after disconnect.")
#endif
        stopSystemAudio(reason: "Audio session ended")
        closeAllVideoConnections(reason: "session reset: \(reason)")
        status = "Disconnected (\(reason))"
        nextAllowedConnectAt = max(
            nextAllowedConnectAt,
            Date().addingTimeInterval(postDisconnectConnectCooldown)
        )
        isConnectionReady = false
        connectedHostName = nil
        stopPing()
        pendingWindowListRequest = false
        pendingConnectHost = nil
        pendingConnectIsAutoReconnect = false
        stopWindowListAutoRefresh()
        stopStreamWatchdog()
        pendingWindowListRequest = false

        activePairingID = nil
        activeWindowId = nil
        isMouseDownLocally = false
        mouseDownWindowId = nil
        mouseDownButton = "left"
        lastMouseMoveSentAtByWindow.removeAll()
        lastMouseMoveNormByWindow.removeAll()
        if browser?.selectedHostKey == hostKey {
            browser?.isMouseDownLocally = false
            browser?.mouseDownWindowId = nil
            browser?.mouseDownButton = "left"
            browser?.lastMouseMoveSentAtByWindow.removeAll()
            browser?.lastMouseMoveNormByWindow.removeAll()
        }
        hostCapabilities.removeAll()
        hostConfirmedActiveWindowId = nil
        lastWindowFocusState = nil

        stopAllPullStreams()

        windows.removeAll()
        snapshots.removeAll()
        snapshotCGImages.removeAll()
#if canImport(UIKit)
        appIconImageCache.removeAll()
#endif
        windowGeometryById.removeAll()
        resetVideoReceiversForConnectionBoundary(reason: "disconnect: \(reason)")
        receiveBuffer.removeAll()
        binaryBuffer.removeAll()
        inFlight.removeAll()
        startedStreamWindowIds.removeAll()
        muxBuffer.removeAll()
        videoReadyWindowIds.removeAll()
        videoFrameCountByWindow.removeAll()
        videoLastFrameByteCountByWindow.removeAll()
        videoLastFrameWasKeyframeByWindow.removeAll()
        videoLastFrameReceivedAtByWindow.removeAll()

        hasFreshWindowListForCurrentConnection = false
        streamRepairInProgressWindowIds.removeAll()

        streamStartAttemptAtByWindow.removeAll()
        streamLastRepairAtByWindow.removeAll()
        streamRepairAttemptByWindow.removeAll()
        videoConfigReceivedAtByWindow.removeAll()
        inFlightSince.removeAll()

        lastWindowListById.removeAll()
        pendingAutoPopupBySource.removeAll()
        autoPopupParentByChild.removeAll()
        lastAutoPopupAtBySource.removeAll()
        lastUserInteractionWindowId = nil
        lastUserInteractionAt = .distantPast

        pendingHostCommandAutoOpenWindow = nil
        pendingLauncherCommandIssuedAt = nil
        pendingLauncherExistingFinderWindowIds.removeAll()
        pendingLauncherSuccessorWindow = nil
        pendingLauncherTrackedFinderWindowId = nil
        pendingLauncherSuccessorIssuedAt = nil

        clearAgentPresentationState()
#if os(iOS) || os(visionOS)
        resetRemoteNotificationState()
#endif

        connection?.cancel()
        connection = nil
        connectedTransportEndpoint = nil

        resolveTimeoutWorkItem?.cancel()
        resolveTimeoutWorkItem = nil
        waitingTimeoutWorkItem?.cancel()
        waitingTimeoutWorkItem = nil
        isInWaitingState = false

        if let browser, browser.selectedHostKey == hostKey {
            browser.connection = nil
            browser.isConnectionReady = false
            browser.connectedHostName = nil
            browser.isConnectBusy = false
            browser.status = status
            browser.pendingReconnectWhenVisible = pendingReconnectWhenVisible
            browser.pendingReconnectReason = pendingReconnectReason
            browser.suppressAutoReconnect = suppressAutoReconnect
            browser.windows.removeAll()
        }
    }

    func scheduleReconnect(reason: String) {
        guard !suppressAutoReconnect else {
            DispatchQueue.main.async {
                self.isConnectBusy = false
                if self.status.isEmpty || self.status == "Connecting…" {
                    self.status = "Disconnected."
                }
                if self.browser?.selectedHostKey == self.hostKey {
                    self.browser?.isConnectBusy = false
                    self.browser?.status = self.status
                }
            }
            return
        }

        guard let name = lastConnectedHostName ?? lastConnectedHost?.name else {
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Disconnected."
                if self.browser?.selectedHostKey == self.hostKey {
                    self.browser?.isConnectBusy = false
                    self.browser?.status = self.status
                }
            }
            return
        }

        guard let browser else { return }

        if isUsingDirectEndpoint {
            guard let pairingID = directPairingID,
                  let savedRecord = browser.directEndpointRecord(for: pairingID),
                  browser.pairedPeer(forPairingID: pairingID) != nil else {
                pendingReconnectWhenVisible = false
                pendingReconnectReason = nil
                DispatchQueue.main.async {
                    self.isConnectBusy = false
                    self.status = "Saved address is no longer available."
                    if browser.selectedHostKey == self.hostKey {
                        browser.isConnectBusy = false
                        browser.status = self.status
                    }
                }
                return
            }

            // Reload the current store record before retrying so an address
            // edited while the session was down is the only route attempted.
            configureDirectEndpoint(savedRecord)
            reconnectAttempt += 1
            if reconnectAttempt > maxReconnectAttempts {
                pendingReconnectWhenVisible = true
                pendingReconnectReason = reason
                DispatchQueue.main.async {
                    self.isConnectBusy = false
                    self.status = "Direct reconnect failed after \(self.maxReconnectAttempts) attempts."
                    if browser.selectedHostKey == self.hostKey {
                        browser.isConnectBusy = false
                        browser.status = self.status
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.isConnectBusy = true
                self.status = "Disconnected (\(reason)). Reconnecting by address… (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts))"
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = true
                    browser.status = self.status
                }
            }

            let work = DispatchWorkItem { [weak self, weak browser] in
                guard let self, let browser else { return }
                guard !self.suppressAutoReconnect else { return }
                guard let pairingID = self.directPairingID,
                      let record = browser.directEndpointRecord(for: pairingID),
                      browser.pairedPeer(forPairingID: pairingID) != nil else {
                    return
                }
                self.configureDirectEndpoint(record)
                self.connectAndRequestWindows(isAutoReconnect: true, skipResolve: true)
            }
            reconnectWorkItem = work

            let jitter = Double.random(in: 0.0...0.35)
            let delay = min(pow(2.0, Double(reconnectAttempt - 1)) * 1.0 + jitter, 5.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }

        guard let freshHost = browser.hosts.last(where: { self.matchesReconnectTarget($0) }) else {
            pendingReconnectWhenVisible = true
            pendingReconnectReason = reason
            browser.restartDiscoveryAfterHostDrop(reason: reason)
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Host '\(name)' offline (\(reason)). Waiting…"
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                    browser.status = self.status
                }
            }
            return
        }

        reconnectAttempt += 1
        if reconnectAttempt > maxReconnectAttempts {
            pendingReconnectWhenVisible = true
            pendingReconnectReason = reason
            browser.markDiscoveredHostStaleAndRefresh(freshHost, reason: "reconnect max attempts")
            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Reconnect failed after \(self.maxReconnectAttempts) attempts. Looking for the Mac again…"
                if browser.selectedHostKey == self.hostKey {
                    browser.isConnectBusy = false
                    browser.status = self.status
                }
            }
            return
        }

        DispatchQueue.main.async {
            self.isConnectBusy = true
            self.status = "Disconnected (\(reason)). Reconnecting… (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts))"
            if browser.selectedHostKey == self.hostKey {
                browser.isConnectBusy = true
                browser.status = self.status
            }
        }

        let work = DispatchWorkItem { [weak self, weak browser] in
            guard let self, let browser else { return }
            guard !self.suppressAutoReconnect else { return }
            guard let latestHost = browser.hosts.last(where: { self.matchesReconnectTarget($0) }) else {
                self.pendingReconnectWhenVisible = true
                self.pendingReconnectReason = reason
                browser.restartDiscoveryAfterHostDrop(reason: reason)
                DispatchQueue.main.async {
                    self.isConnectBusy = false
                    self.status = "Host '\(freshHost.name)' offline (\(reason)). Waiting…"
                    if browser.selectedHostKey == self.hostKey {
                        browser.isConnectBusy = false
                        browser.status = self.status
                    }
                }
                return
            }
            self.updateHost(latestHost)
            self.connectAndRequestWindows(isAutoReconnect: true)
        }
        reconnectWorkItem = work

        let jitter = Double.random(in: 0.0...0.35)
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)) * 1.0 + jitter, 5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func handleDisconnectOnce(_ reason: String, sourceConnection: NWConnection? = nil) {
        guard let disconnectingConnection = sourceConnection ?? connection else { return }
        let apply = { [weak self] in
            guard let self,
                  self.connection === disconnectingConnection,
                  !self.didHandleDisconnectForCurrentConnection else { return }
            self.didHandleDisconnectForCurrentConnection = true

            // Publish retry intent before resetSession mirrors the selected session.
            // A background disconnect must remain eligible when the app resumes.
            self.pendingReconnectWhenVisible = true
            self.pendingReconnectReason = reason
            self.resetSession(reason: reason)

            if !self.isClientVisible {
                self.isConnectBusy = false
                self.status = "Host dropped. Waiting for it to come back…"
                return
            }

            self.scheduleReconnect(reason: reason)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
