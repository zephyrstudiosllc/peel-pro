//
//  Recieve.swift
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

#if os(visionOS)
private let peelClientProductName = "Peel Pro"
#elseif os(iOS)
private let peelClientProductName = "Peel Pro"
#else
private let peelClientProductName = "Peel Pro"
#endif

@inline(__always)
private func peelReceivePerfNowMs() -> Double {
    Date.timeIntervalSinceReferenceDate * 1000.0
}

extension PeelClientBrowser {
    // MARK: - NDJSON receive loop
    
    func startReceiveLoop() {
        guard let connection = connection else { return }
        let activeConn = connection
        
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.connection === activeConn else { return }
            
            if let error = error {
                let reason = "Receive error: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    self.handleDisconnectOnce(reason, sourceConnection: activeConn)
                }
                return
            }
            
            if let data = data, !data.isEmpty {
                let receivePerfStartMs = peelReceivePerfNowMs()
                let muxBeforeBytes = self.muxBuffer.count
                let binaryBeforeBytes = self.binaryBuffer.count
                let receiveBeforeMs = receivePerfStartMs

                self.lastAnyDataAt = Date()
                self.selectedSession?.lastAnyDataAt = self.lastAnyDataAt
                PeelClientDiagnostics.logReceiveChunk(
                    
                    ownerName: "browser",
                    byteCount: data.count,
                    muxBufferBytes: muxBeforeBytes,
                    binaryBufferBytes: binaryBeforeBytes
                )

                let metadataDoneMs = peelReceivePerfNowMs()

                if useMuxParser {
                    self.processMuxedIncomingData(data, sourceConnection: activeConn)
                } else {
                    self.processIncomingData(data, sourceConnection: activeConn)
                }

                let receivePerfEndMs = peelReceivePerfNowMs()
                let totalMs = receivePerfEndMs - receivePerfStartMs
                let metadataMs = metadataDoneMs - receiveBeforeMs
                let parseMs = receivePerfEndMs - metadataDoneMs
                if totalMs >= 4.0 || parseMs >= 3.0 || self.muxBuffer.count >= 128 * 1024 || self.binaryBuffer.count >= 128 * 1024 {
                    print(
                        "PeelClientPerf receive owner=browser",
                        "bytes=\(data.count)",
                        "totalMs=\(String(format: "%.2f", totalMs))",
                        "metadataMs=\(String(format: "%.2f", metadataMs))",
                        "parseMs=\(String(format: "%.2f", parseMs))",
                        "muxBefore=\(muxBeforeBytes)",
                        "muxAfter=\(self.muxBuffer.count)",
                        "binaryBefore=\(binaryBeforeBytes)",
                        "binaryAfter=\(self.binaryBuffer.count)"
                    )
                }
            }
            
            if isComplete {
                let reason = "Connection closed by host"
                DispatchQueue.main.async {
                    self.handleDisconnectOnce(reason, sourceConnection: activeConn)
                }
                return
            }
            
            // Keep listening for more messages
            self.startReceiveLoop()
        }
    }
    
    func processIncomingData(_ data: Data, sourceConnection: NWConnection? = nil) {
        let shouldTreatAsBinary =
        isKnownBinaryLeadByte(binaryBuffer.first) ||
        (binaryBuffer.isEmpty && isKnownBinaryLeadByte(data.first))

        if shouldTreatAsBinary {
            if !data.isEmpty {
                if binaryBuffer.isEmpty {
                    binaryBuffer = data
                } else {
                    binaryBuffer.reserveCapacity(binaryBuffer.count + data.count)
                    binaryBuffer.append(data)
                }
            }

            drainBinaryPackets(from: &binaryBuffer)
            expectedBinaryLength = nil
            return
        }

        if receiveBuffer.isEmpty {
            receiveBuffer = data
        } else {
            receiveBuffer.reserveCapacity(receiveBuffer.count + data.count)
            receiveBuffer.append(data)
        }
        
        while let newlineRange = receiveBuffer.firstRange(of: Data([0x0A])) {
            let line = receiveBuffer.subdata(in: 0..<newlineRange.lowerBound)
            receiveBuffer.removeSubrange(0...newlineRange.lowerBound)
            
            guard !line.isEmpty else { continue }
            handleLine(line, sourceConnection: sourceConnection)
        }
    }
    
    func handleLine(_ data: Data, sourceConnection: NWConnection? = nil) {
        do {
            // Peek at the "type" field first
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
            
            switch envelope.type {
            case "hostStreamClock":
                let receivedAt = ProcessInfo.processInfo.systemUptime
                let reply = try JSONDecoder().decode(PeelStreamClockReply.self, from: data)
                guard let sourceConnection, self.connection === sourceConnection else { return }
                self.streamDiagnosticReporter.clock.accept(reply, receivedAt: receivedAt)

            case "windowList":
                let msg = try JSONDecoder().decode(WindowListMessage.self, from: data)
                DispatchQueue.main.async {
                    let visibleWindows = self.userVisibleWindows(from: msg.windows)
                    self.reconcileRecentFocusOrder(with: visibleWindows)
                    
                    self.status = "Received \(visibleWindows.count) windows."
                    
                    // Keep the full raw host list available to internal handoff/popup tracking.
                    // Only the published `windows` array is filtered for the visible picker/list.
                    self.processWindowListForPendingHostCommandAutoOpen(msg.windows)
                    self.processWindowListForPendingLauncherSuccessor(msg.windows)
                    self.processWindowListForAutoPopup(msg.windows)
                    self.windows = visibleWindows
                    self.selectedSession?.windows = visibleWindows
                    self.selectedSession?.status = "Received \(visibleWindows.count) windows."
                    self.selectedSession?.hasFreshWindowListForCurrentConnection = true
                    self.hasFreshWindowListForCurrentConnection = true

                    self.resendPeeledWindowHostingStateIfSupported(freshWindows: msg.windows)
                    self.restoreDesiredPullStreamsIfNeeded()
                    self.lastWindowListAt = Date()
                    self.selectedSession?.lastWindowListAt = self.lastWindowListAt
                }

            case "windowGeometry":
                let msg = try JSONDecoder().decode(WindowGeometryMessage.self, from: data)
                DispatchQueue.main.async {
                    self.windowGeometryById[msg.windowId] = msg
                    self.selectedSession?.windowGeometryById[msg.windowId] = msg
                }
                
            case "inputRejected":
                let msg = try JSONDecoder().decode(InputRejectedMessage.self, from: data)
                DispatchQueue.main.async {
                    self.lastInputRejection = msg
                    self.selectedSession?.lastInputRejection = msg

                    if self.hostConfirmedActiveWindowId == msg.windowId {
                        self.hostConfirmedActiveWindowId = nil
                        self.selectedSession?.hostConfirmedActiveWindowId = nil
                    }

                    var rejections = self.inputRejectionByWindowId
                    rejections[msg.windowId] = msg
                    self.inputRejectionByWindowId = rejections
                    self.selectedSession?.inputRejectionByWindowId = rejections

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        guard self.inputRejectionByWindowId[msg.windowId]?.timestamp == msg.timestamp else {
                            return
                        }

                        var current = self.inputRejectionByWindowId
                        current.removeValue(forKey: msg.windowId)
                        self.inputRejectionByWindowId = current
                        self.selectedSession?.inputRejectionByWindowId = current
                    }
                }
                
            case "windowFocusState":
                let msg = try JSONDecoder().decode(WindowFocusStateMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    let currentIntentWindowId = self.activeWindowId
                    let requestedWindowId = msg.requestedWindowId
                    let confirmedWindowId = msg.activeWindowId

                    let messageMatchesCurrentIntent =
                        requestedWindowId == nil ||
                        requestedWindowId == currentIntentWindowId ||
                        confirmedWindowId == currentIntentWindowId

                    guard messageMatchesCurrentIntent else {
                        print(
                            "PeelClient: ignoring stale focus state",
                            "requested=", requestedWindowId.map(String.init) ?? "nil",
                            "confirmed=", confirmedWindowId.map(String.init) ?? "nil",
                            "currentIntent=", currentIntentWindowId.map(String.init) ?? "nil"
                        )
                        return
                    }

                    self.lastWindowFocusState = msg
                    self.selectedSession?.lastWindowFocusState = msg

                    if let confirmedWindowId {
                        self.hostConfirmedActiveWindowId = confirmedWindowId
                        self.selectedSession?.hostConfirmedActiveWindowId = confirmedWindowId
                        self.recordFocusedWindowId(confirmedWindowId)

                        if self.activeWindowId != confirmedWindowId {
                            self.activeWindowId = confirmedWindowId
                            self.selectedSession?.activeWindowId = confirmedWindowId
                            self.updateStreamRates()
                        }
                    } else if requestedWindowId == currentIntentWindowId {
                        self.hostConfirmedActiveWindowId = nil
                        self.selectedSession?.hostConfirmedActiveWindowId = nil
                    }
                }

            case "pairingRevoked":
                let msg = try JSONDecoder().decode(PairingRevokedMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection,
                          self.activePairingID == msg.pairingId else { return }
                    self.handlePairingRevoked(msg)
                }

            case "hostHello":
                let msg = try JSONDecoder().decode(HostHelloMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    self.handleHostHello(msg)
                }

            case "protocolRejected":
                let msg = try JSONDecoder().decode(ProtocolRejectedMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    self.handleProtocolRejected(msg)
                }
                
            case "hostStreamDebug":
                let msg = try JSONDecoder().decode(HostStreamDebugMessage.self, from: data)
                DispatchQueue.main.async {
                    self.hostStreamDebugByWindow[msg.windowId] = msg
                    self.selectedSession?.hostStreamDebugByWindow[msg.windowId] = msg
                }

            case "presentWindow":
                let msg = try JSONDecoder().decode(PresentWindowMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveAgentPresentation(msg)
                }

            case "manualAgentControlChallenge":
                let msg = try JSONDecoder().decode(PeelManualAgentControlChallenge.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveManualAgentControlChallenge(msg)
                }

            case "agentPairingChallenge":
                let msg = try JSONDecoder().decode(PeelAgentPairingChallengeMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveAgentPairingChallenge(msg)
                }
                
            default:
                break
            }
        } catch {
            return
        }
    }

    func handleHostHello(_ msg: HostHelloMessage) {
        let capabilities = Set(msg.capabilities ?? [])
        hostCapabilities = capabilities
        selectedSession?.hostCapabilities = capabilities

        let compatible = PeelProtocol.isCompatible(
            remoteCurrent: msg.protocolVersion,
            remoteMinimum: msg.minimumSupportedProtocolVersion
        )

        guard compatible else {
            let reason = "This host is not compatible with this version of \(peelClientProductName). Update the host app or \(peelClientProductName) and try again."

            handleProtocolBlocked(reason)

            print(
                "PeelClient: rejected host protocol",
                "host=", msg.hostName,
                "remoteCurrent=", msg.protocolVersion.map(String.init) ?? "nil",
                "remoteMinimum=", msg.minimumSupportedProtocolVersion.map(String.init) ?? "nil",
                "localCurrent=", PeelProtocol.currentProtocolVersion,
                "localMinimum=", PeelProtocol.minimumSupportedProtocolVersion,
                "capabilities=", msg.capabilities ?? []
            )
            return
        }

    }

    func handleProtocolRejected(_ msg: ProtocolRejectedMessage) {
        handleProtocolBlocked(msg.reason)
    }

    func handleProtocolBlocked(_ reason: String) {
        if let selectedSession {
            selectedSession.handleProtocolBlocked(reason)
            return
        }

        suppressAutoReconnect = true
        pendingReconnectWhenVisible = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        nextAllowedConnectAt = .distantFuture
        isConnectionReady = false
        isConnectBusy = false
        status = reason

        stopPing()
        stopWindowListAutoRefresh()
        stopStreamWatchdog()
        stopAllPullStreams()

        let activeConnection = connection
        connection = nil
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()
    }

    func processMuxedIncomingData(_ data: Data, sourceConnection: NWConnection? = nil) {
        let processStartMs = peelReceivePerfNowMs()
        let bufferBeforeBytes = muxBuffer.count
        var loopIterations = 0
        var binaryDrainCount = 0
        var jsonLineCount = 0
        var maxBufferBytes = muxBuffer.count + data.count

        if muxBuffer.isEmpty {
            muxBuffer = data
        } else {
            muxBuffer.reserveCapacity(muxBuffer.count + data.count)
            muxBuffer.append(data)
        }

        let appendDoneMs = peelReceivePerfNowMs()
        maxBufferBytes = max(maxBufferBytes, muxBuffer.count)
        
        while true {
            loopIterations += 1
            maxBufferBytes = max(maxBufferBytes, muxBuffer.count)
            guard !muxBuffer.isEmpty else { return }
            
            if isKnownBinaryLeadByte(muxBuffer.first) {
                let byteCountBeforeDrain = muxBuffer.count
                let drainStartMs = peelReceivePerfNowMs()
                drainBinaryPackets(from: &muxBuffer)
                let drainMs = peelReceivePerfNowMs() - drainStartMs
                binaryDrainCount += 1
                maxBufferBytes = max(maxBufferBytes, muxBuffer.count)
                if drainMs >= 3.0 {
                    print(
                        "PeelClientPerf muxDrain owner=browser",
                        "drainMs=\(String(format: "%.2f", drainMs))",
                        "before=\(byteCountBeforeDrain)",
                        "after=\(muxBuffer.count)",
                        "drains=\(binaryDrainCount)"
                    )
                }

                // If the buffer did not shrink, the current binary packet is incomplete.
                // Return and wait for the next NWConnection receive to append more bytes.
                // Without this guard, an incomplete H.264 frame can spin this loop forever.
                if muxBuffer.count == byteCountBeforeDrain {
                    let totalMs = peelReceivePerfNowMs() - processStartMs
                    let appendMs = appendDoneMs - processStartMs
                    if totalMs >= 4.0 || muxBuffer.count >= 128 * 1024 || loopIterations >= 16 {
                        print(
                            "PeelClientPerf muxReturn owner=browser reason=incompleteBinary",
                            "totalMs=\(String(format: "%.2f", totalMs))",
                            "appendMs=\(String(format: "%.2f", appendMs))",
                            "loops=\(loopIterations)",
                            "binaryDrains=\(binaryDrainCount)",
                            "jsonLines=\(jsonLineCount)",
                            "inputBytes=\(data.count)",
                            "bufferBefore=\(bufferBeforeBytes)",
                            "bufferNow=\(muxBuffer.count)",
                            "maxBuffer=\(maxBufferBytes)"
                        )
                    }
                    return
                }

                continue
            }
            
            guard let nl = muxBuffer.firstIndex(of: 0x0A) else {
                let totalMs = peelReceivePerfNowMs() - processStartMs
                let appendMs = appendDoneMs - processStartMs
                if totalMs >= 4.0 || muxBuffer.count >= 128 * 1024 || loopIterations >= 16 {
                    print(
                        "PeelClientPerf muxReturn owner=browser reason=waitingNewline",
                        "totalMs=\(String(format: "%.2f", totalMs))",
                        "appendMs=\(String(format: "%.2f", appendMs))",
                        "loops=\(loopIterations)",
                        "binaryDrains=\(binaryDrainCount)",
                        "jsonLines=\(jsonLineCount)",
                        "inputBytes=\(data.count)",
                        "bufferBefore=\(bufferBeforeBytes)",
                        "bufferNow=\(muxBuffer.count)",
                        "maxBuffer=\(maxBufferBytes)"
                    )
                }
                return
            }
            
            let line = muxBuffer.subdata(in: 0..<nl)
            muxBuffer.removeSubrange(0...nl)
            
            guard !line.isEmpty else { continue }
            let lineStartMs = peelReceivePerfNowMs()
            handleLine(line, sourceConnection: sourceConnection)
            let lineMs = peelReceivePerfNowMs() - lineStartMs
            jsonLineCount += 1
            if lineMs >= 2.0 {
                print(
                    "PeelClientPerf muxJSON owner=browser",
                    "lineMs=\(String(format: "%.2f", lineMs))",
                    "bytes=\(line.count)",
                    "jsonLines=\(jsonLineCount)"
                )
            }
        }
    }
    
    func startStreamWatchdog() {
        guard !isStreamWatchdogRunning else { return }

        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "watchdog start")
        isStreamWatchdogRunning = true
        streamWatchdog?.invalidate()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isClientVisible else { return }
            guard self.connection != nil, self.isConnectionReady else { return }

            let now = Date()

            // 1) Clear stuck snapshot/JPEG in-flight state.
            for (id, since) in self.inFlightSince {
                if now.timeIntervalSince(since) > self.inFlightTimeout {
                    self.inFlightSince.removeValue(forKey: id)

                    if self.inFlight.contains(id) {
                        self.inFlight.remove(id)
                        self.globalSnapshotsInFlight = max(0, self.globalSnapshotsInFlight - 1)
                    }
                }
            }

            // 2) Ensure every visible/desired stream actually got a startStream.
            for windowId in self.desiredPullWindowIds.sorted() {
                if !self.startedStreamWindowIds.contains(windowId) {
                    self.requestStreamStart(windowId: windowId, reason: "watchdog missing startStream")
                    continue
                }

                // 3) If the local decoder layer has failed, stop/start the stream.
                if let renderer = self.videoRenderers[windowId],
                   renderer.displayLayer.status == .failed || renderer.displayLayer.requiresFlushToResumeDecoding {
                    self.repairStream(windowId: windowId, reason: "display layer failed or requires flush")
                    continue
                }

                // 4) First-frame watchdog.
                // Config is not enough. The stream is not usable until a real videoFrame arrives.
                let frameCount = self.videoFrameCountByWindow[windowId] ?? 0
                guard frameCount == 0 else {
                    continue
                }

                guard let startAt = self.streamStartAttemptAtByWindow[windowId] else {
                    self.requestStreamStart(windowId: windowId, reason: "watchdog missing start timestamp")
                    continue
                }

                let age = now.timeIntervalSince(startAt)

                if age > self.streamFirstFrameTimeout {
                    self.repairStream(
                        windowId: windowId,
                        reason: "no first video frame after \(String(format: "%.1f", age))s"
                    )
                }
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        streamWatchdog = timer
    }
    
    func stopStreamWatchdog() {
        guard isStreamWatchdogRunning else { return }
        PeelClientDiagnostics.logStreamEvent(ownerName: "browser", message: "watchdog stop")
        isStreamWatchdogRunning = false
        streamWatchdog?.invalidate()
        streamWatchdog = nil
    }
}


// MARK: - Per-host session receive loop
extension PeelHostSession {
    // MARK: - NDJSON receive loop
    
    func startReceiveLoop() {
        guard let connection = connection else { return }
        let activeConn = connection
        
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard self.connection === activeConn else { return }
            
            if let error = error {
                let reason = "Receive error: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    self.handleDisconnectOnce(reason, sourceConnection: activeConn)
                }
                return
            }
            
            if let data = data, !data.isEmpty {
                let receivePerfStartMs = peelReceivePerfNowMs()
                let muxBeforeBytes = self.muxBuffer.count
                let binaryBeforeBytes = self.binaryBuffer.count
                let receiveBeforeMs = receivePerfStartMs

                self.lastAnyDataAt = Date()
                PeelClientDiagnostics.logReceiveChunk(
                    
                    ownerName: "session",
                    byteCount: data.count,
                    muxBufferBytes: muxBeforeBytes,
                    binaryBufferBytes: binaryBeforeBytes
                )

                let metadataDoneMs = peelReceivePerfNowMs()

                if useMuxParser {
                    self.processMuxedIncomingData(data, sourceConnection: activeConn)
                } else {
                    self.processIncomingData(data, sourceConnection: activeConn)
                }

                let receivePerfEndMs = peelReceivePerfNowMs()
                let totalMs = receivePerfEndMs - receivePerfStartMs
                let metadataMs = metadataDoneMs - receiveBeforeMs
                let parseMs = receivePerfEndMs - metadataDoneMs
                if totalMs >= 4.0 || parseMs >= 3.0 || self.muxBuffer.count >= 128 * 1024 || self.binaryBuffer.count >= 128 * 1024 {
                    print(
                        "PeelClientPerf receive owner=session",
                        "bytes=\(data.count)",
                        "totalMs=\(String(format: "%.2f", totalMs))",
                        "metadataMs=\(String(format: "%.2f", metadataMs))",
                        "parseMs=\(String(format: "%.2f", parseMs))",
                        "muxBefore=\(muxBeforeBytes)",
                        "muxAfter=\(self.muxBuffer.count)",
                        "binaryBefore=\(binaryBeforeBytes)",
                        "binaryAfter=\(self.binaryBuffer.count)"
                    )
                }
            }
            
            if isComplete {
                let reason = "Connection closed by host"
                DispatchQueue.main.async {
                    self.handleDisconnectOnce(reason, sourceConnection: activeConn)
                }
                return
            }
            
            // Keep listening for more messages
            self.startReceiveLoop()
        }
    }

    func startVideoReceiveLoop(windowId: UInt32, connection: NWConnection) {
        let activeVideoConnection = connection

        activeVideoConnection.receive(minimumIncompleteLength: 1,
                                      maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            self.onVideoStateQueue { [weak self] in
                guard let self else { return }
                guard self.videoConnectionsByWindowId[windowId] === activeVideoConnection else { return }

                if let error {
                    print("PeelClient: video receive error window=\(windowId):", error.localizedDescription)
                    self.handleUnexpectedVideoConnectionClosure(windowId: windowId,
                        connection: activeVideoConnection, reason: "video receive error: \(error.localizedDescription)")
                    return
                }

                if let data, !data.isEmpty {
                    let receivePerfStartMs = peelReceivePerfNowMs()
                    let bufferBeforeBytes = self.videoReceiveBuffersByWindowId[windowId]?.count ?? 0

                    self.lastAnyDataAt = Date()
                    PeelClientDiagnostics.logReceiveChunk(
                        ownerName: "video:\(windowId)",
                        byteCount: data.count,
                        muxBufferBytes: bufferBeforeBytes,
                        binaryBufferBytes: 0
                    )

                    var buffer = self.videoReceiveBuffersByWindowId[windowId] ?? Data()
                    if buffer.isEmpty {
                        buffer = data
                    } else {
                        buffer.reserveCapacity(buffer.count + data.count)
                        buffer.append(data)
                    }

                    let appendDoneMs = peelReceivePerfNowMs()
                    self.drainBinaryPackets(from: &buffer)

                    if buffer.isEmpty {
                        self.videoReceiveBuffersByWindowId.removeValue(forKey: windowId)
                    } else {
                        self.videoReceiveBuffersByWindowId[windowId] = buffer
                    }

                    let receivePerfEndMs = peelReceivePerfNowMs()
                    let totalMs = receivePerfEndMs - receivePerfStartMs
                    let appendMs = appendDoneMs - receivePerfStartMs
                    let drainMs = receivePerfEndMs - appendDoneMs

                    if totalMs >= 4.0 || drainMs >= 3.0 || buffer.count >= 128 * 1024 {
                        print(
                            "PeelClientPerf videoReceive owner=session",
                            "window=\(windowId)",
                            "bytes=\(data.count)",
                            "totalMs=\(String(format: "%.2f", totalMs))",
                            "appendMs=\(String(format: "%.2f", appendMs))",
                            "drainMs=\(String(format: "%.2f", drainMs))",
                            "bufferBefore=\(bufferBeforeBytes)",
                            "bufferAfter=\(buffer.count)"
                        )
                    }
                }

                if isComplete {
                    self.handleUnexpectedVideoConnectionClosure(windowId: windowId,
                        connection: activeVideoConnection, reason: "video connection closed by host")
                    return
                }

                self.startVideoReceiveLoop(windowId: windowId, connection: activeVideoConnection)
            }
        }
    }
    
    func processIncomingData(_ data: Data, sourceConnection: NWConnection? = nil) {
        let shouldTreatAsBinary =
        isKnownBinaryLeadByte(binaryBuffer.first) ||
        (binaryBuffer.isEmpty && isKnownBinaryLeadByte(data.first))

        if shouldTreatAsBinary {
            if !data.isEmpty {
                if binaryBuffer.isEmpty {
                    binaryBuffer = data
                } else {
                    binaryBuffer.reserveCapacity(binaryBuffer.count + data.count)
                    binaryBuffer.append(data)
                }
            }

            drainBinaryPackets(from: &binaryBuffer)
            expectedBinaryLength = nil
            return
        }

        if receiveBuffer.isEmpty {
            receiveBuffer = data
        } else {
            receiveBuffer.reserveCapacity(receiveBuffer.count + data.count)
            receiveBuffer.append(data)
        }
        
        while let newlineRange = receiveBuffer.firstRange(of: Data([0x0A])) {
            let line = receiveBuffer.subdata(in: 0..<newlineRange.lowerBound)
            receiveBuffer.removeSubrange(0...newlineRange.lowerBound)
            
            guard !line.isEmpty else { continue }
            handleLine(line, sourceConnection: sourceConnection)
        }
    }
    
    func handleLine(_ data: Data, sourceConnection: NWConnection? = nil) {
        do {
            // Peek at the "type" field first
            let envelope = try JSONDecoder().decode(PeelClientBrowser.MessageEnvelope.self, from: data)
            
            switch envelope.type {
            case "hostStreamClock":
                let receivedAt = ProcessInfo.processInfo.systemUptime
                let reply = try JSONDecoder().decode(PeelStreamClockReply.self, from: data)
                guard let sourceConnection, self.connection === sourceConnection else { return }
                self.streamDiagnosticReporter.clock.accept(reply, receivedAt: receivedAt)

            case "windowList":
                let msg = try JSONDecoder().decode(WindowListMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    let visibleWindows = self.userVisibleWindows(from: msg.windows)
                    self.reconcileRecentFocusOrder(with: visibleWindows)
                    
                    self.status = "Received \(visibleWindows.count) windows."
                    
                    // Keep the full raw host list available to internal handoff/popup tracking.
                    // Only the published `windows` array is filtered for the visible picker/list.
                    self.processWindowListForPendingHostCommandAutoOpen(msg.windows)
                    self.processWindowListForPendingLauncherSuccessor(msg.windows)
                    self.processWindowListForAutoPopup(msg.windows)
                    self.windows = visibleWindows
                    self.hasFreshWindowListForCurrentConnection = true
                    if self.browser?.selectedHostKey == self.hostKey {
                        self.browser?.windows = visibleWindows
                        self.browser?.status = self.status
                        self.browser?.hasFreshWindowListForCurrentConnection = true
                    }

                    self.resendPeeledWindowHostingStateIfSupported(freshWindows: msg.windows)
                    self.restoreDesiredPullStreamsIfNeeded()
                    self.lastWindowListAt = Date()
                }

            case "windowGeometry":
                let msg = try JSONDecoder().decode(WindowGeometryMessage.self, from: data)
                DispatchQueue.main.async {
                    self.windowGeometryById[msg.windowId] = msg
                    if self.browser?.selectedHostKey == self.hostKey {
                        self.browser?.windowGeometryById[msg.windowId] = msg
                    }
                }
                
            case "inputRejected":
                let msg = try JSONDecoder().decode(InputRejectedMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    self.watchFocusProof.invalidate()
                    self.lastInputRejection = msg
                    if self.browser?.selectedHostKey == self.hostKey {
                        self.browser?.lastInputRejection = msg
                    }

                    if self.hostConfirmedActiveWindowId == msg.windowId {
                        self.hostConfirmedActiveWindowId = nil
                        if self.browser?.selectedHostKey == self.hostKey {
                            self.browser?.hostConfirmedActiveWindowId = nil
                        }
                    }

                    var rejections = self.inputRejectionByWindowId
                    rejections[msg.windowId] = msg
                    self.inputRejectionByWindowId = rejections
                    if self.browser?.selectedHostKey == self.hostKey {
                        self.browser?.inputRejectionByWindowId = rejections
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        guard self.inputRejectionByWindowId[msg.windowId]?.timestamp == msg.timestamp else {
                            return
                        }

                        var current = self.inputRejectionByWindowId
                        current.removeValue(forKey: msg.windowId)
                        self.inputRejectionByWindowId = current
                        if self.browser?.selectedHostKey == self.hostKey {
                            self.browser?.inputRejectionByWindowId = current
                        }
                    }
                }
                
            case "windowFocusState":
                let msg = try JSONDecoder().decode(WindowFocusStateMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    self.watchFocusProof.receive(
                        requestID: msg.focusRequestId,
                        requestedWindowID: msg.requestedWindowId,
                        activeWindowID: msg.activeWindowId,
                        didActivate: msg.didActivateRequestedWindow,
                        connectionGeneration: self.watchFocusConnectionGeneration,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    let currentIntentWindowId = self.activeWindowId
                    let requestedWindowId = msg.requestedWindowId
                    let confirmedWindowId = msg.activeWindowId

                    let messageMatchesCurrentIntent =
                        requestedWindowId == nil ||
                        requestedWindowId == currentIntentWindowId ||
                        confirmedWindowId == currentIntentWindowId

                    guard messageMatchesCurrentIntent else {
                        print(
                            "PeelClient: ignoring stale focus state",
                            "requested=", requestedWindowId.map(String.init) ?? "nil",
                            "confirmed=", confirmedWindowId.map(String.init) ?? "nil",
                            "currentIntent=", currentIntentWindowId.map(String.init) ?? "nil"
                        )
                        return
                    }

                    self.lastWindowFocusState = msg
                    if self.browser?.selectedHostKey == self.hostKey {
                        self.browser?.lastWindowFocusState = msg
                    }

                    if let confirmedWindowId {
                        self.hostConfirmedActiveWindowId = confirmedWindowId
                        if self.browser?.selectedHostKey == self.hostKey {
                            self.browser?.hostConfirmedActiveWindowId = confirmedWindowId
                        }
                        self.recordFocusedWindowId(confirmedWindowId)

                        if self.activeWindowId != confirmedWindowId {
                            self.activeWindowId = confirmedWindowId
                            if self.browser?.selectedHostKey == self.hostKey {
                                self.browser?.activeWindowId = confirmedWindowId
                            }
                            self.updateStreamRates()
                        }
                    } else if requestedWindowId == currentIntentWindowId {
                        self.hostConfirmedActiveWindowId = nil
                        if self.browser?.selectedHostKey == self.hostKey {
                            self.browser?.hostConfirmedActiveWindowId = nil
                        }
                    }
                }

            case "pairingRevoked":
                let msg = try JSONDecoder().decode(PairingRevokedMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection,
                          self.activePairingID == msg.pairingId else { return }
                    self.browser?.resetProEvidence(for: self)
#if os(iOS) || os(visionOS)
                    self.machineStatusController.reset(reason: "Pairing revoked.")
#endif
                    self.browser?.handlePairingRevoked(msg)
                }

            case "hostHello":
                let msg = try JSONDecoder().decode(HostHelloMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    self.handleHostHello(msg)
                    self.browser?.proEvidenceClient(for: self).hostHelloDidChange(sourceConnection: sourceConnection)
                }

            case "proEntitlementChallenge":
                let msg = try PeelProEntitlementWire.decodeChallenge(data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.browser?.proEvidenceClient(for: self).receive(msg, sourceConnection: sourceConnection)
                }

            case "proEntitlementStatus":
                let msg = try PeelProEntitlementWire.decodeStatus(data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.browser?.proEvidenceClient(for: self).receive(msg, sourceConnection: sourceConnection)
                }

            case "protocolRejected":
                let msg = try JSONDecoder().decode(ProtocolRejectedMessage.self, from: data)
                DispatchQueue.main.async {
                    guard let sourceConnection, self.connection === sourceConnection else { return }
                    self.handleProtocolRejected(msg)
                }
                
            case "hostStreamDebug":
                let msg = try JSONDecoder().decode(HostStreamDebugMessage.self, from: data)
                DispatchQueue.main.async {
                    self.hostStreamDebugByWindow[msg.windowId] = msg
                    if self.browser?.selectedHostKey == self.hostKey {
                        self.browser?.hostStreamDebugByWindow[msg.windowId] = msg
                    }
                }

            case "presentWindow":
                let msg = try JSONDecoder().decode(PresentWindowMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveAgentPresentation(msg, sourceConnection: sourceConnection)
                }

#if os(iOS) || os(visionOS)
            case "machineStatus":
                let msg = try JSONDecoder().decode(PeelMachineStatusMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.machineStatusController.receive(msg, sourceConnection: sourceConnection)
                }

            case "machineStatusError":
                let msg = try JSONDecoder().decode(PeelMachineStatusErrorMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.machineStatusController.receive(msg, sourceConnection: sourceConnection)
                }
#endif

#if os(iOS) || os(visionOS)
            case "audioPairingChallenge":
                let msg = try JSONDecoder().decode(PeelAudioPairingChallengeMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.audioController.receive(msg)
                }
            case "audioSessionState":
                let msg = try JSONDecoder().decode(PeelAudioSessionState.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.audioController.receive(msg)
                }
#endif

#if os(iOS) || os(visionOS)
            case "sourceMediaAck":
                guard data.count <= PeelSourceMediaProtocol.maximumLineBytes, let sourceConnection else { return }
                let msg = try JSONDecoder().decode(PeelSourceMediaAck.self, from: data)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.sourceMediaController.receive(msg, sourceConnection: sourceConnection)
                }
            case "sourceVolumeState":
                guard data.count <= PeelSourceMediaProtocol.maximumLineBytes, let sourceConnection else { return }
                let msg = try JSONDecoder().decode(PeelSourceVolumeState.self, from: data)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.sourceMediaController.receive(msg, sourceConnection: sourceConnection)
                }
#endif

#if os(iOS) || os(visionOS)
            case "agentNotification":
                let msg = try JSONDecoder().decode(PeelAgentNotificationMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveAgentNotification(msg, sourceConnection: sourceConnection)
                }
#endif

            case "manualAgentControlChallenge":
                let msg = try JSONDecoder().decode(PeelManualAgentControlChallenge.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveManualAgentControlChallenge(msg)
                }

            case "agentPairingChallenge":
                let msg = try JSONDecoder().decode(PeelAgentPairingChallengeMessage.self, from: data)
                guard let sourceConnection else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connection === sourceConnection else { return }
                    self.receiveAgentPairingChallenge(msg)
                }
                
            default:
                break
            }
        } catch {
            return
        }
    }

    func handleHostHello(_ msg: HostHelloMessage) {
        hostCapabilities = Set(msg.capabilities ?? [])
#if os(iOS) || os(visionOS)
        machineStatusController.refreshAvailability()
#endif

        let compatible = PeelProtocol.isCompatible(
            remoteCurrent: msg.protocolVersion,
            remoteMinimum: msg.minimumSupportedProtocolVersion
        )

        guard compatible else {
            let reason = "This host is not compatible with this version of \(peelClientProductName). Update the host app or \(peelClientProductName) and try again."

            handleProtocolBlocked(reason)

            print(
                "PeelClient: rejected host protocol",
                "host=", msg.hostName,
                "remoteCurrent=", msg.protocolVersion.map(String.init) ?? "nil",
                "remoteMinimum=", msg.minimumSupportedProtocolVersion.map(String.init) ?? "nil",
                "localCurrent=", PeelProtocol.currentProtocolVersion,
                "localMinimum=", PeelProtocol.minimumSupportedProtocolVersion,
                "capabilities=", msg.capabilities ?? []
            )
            return
        }

    }

    func handleProtocolRejected(_ msg: ProtocolRejectedMessage) {
        handleProtocolBlocked(msg.reason)
    }

    func handleProtocolBlocked(_ reason: String) {
#if os(iOS) || os(visionOS)
        browser?.resetProEvidence(for: self)
        machineStatusController.reset(reason: "Mac Status is unavailable after protocol rejection.")
#endif
        closeAllVideoConnections(reason: "protocol blocked")

        suppressAutoReconnect = true
        pendingReconnectWhenVisible = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        nextAllowedConnectAt = .distantFuture
        isConnectionReady = false
        isConnectBusy = false
        status = reason

        stopPing()
        stopWindowListAutoRefresh()
        stopStreamWatchdog()
        stopAllPullStreams()

        let activeConnection = connection
        connection = nil
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()

        if browser?.selectedHostKey == hostKey {
            browser?.status = reason
            browser?.isConnectionReady = false
            browser?.isConnectBusy = false
            browser?.connectedHostName = nil
        }
    }

    func processMuxedIncomingData(_ data: Data, sourceConnection: NWConnection? = nil) {
        let processStartMs = peelReceivePerfNowMs()
        let bufferBeforeBytes = muxBuffer.count
        var loopIterations = 0
        var binaryDrainCount = 0
        var jsonLineCount = 0
        var maxBufferBytes = muxBuffer.count + data.count

        if muxBuffer.isEmpty {
            muxBuffer = data
        } else {
            muxBuffer.reserveCapacity(muxBuffer.count + data.count)
            muxBuffer.append(data)
        }

        let appendDoneMs = peelReceivePerfNowMs()
        maxBufferBytes = max(maxBufferBytes, muxBuffer.count)
        
        while true {
            loopIterations += 1
            maxBufferBytes = max(maxBufferBytes, muxBuffer.count)
            guard !muxBuffer.isEmpty else { return }
            
            if isKnownBinaryLeadByte(muxBuffer.first) {
                let byteCountBeforeDrain = muxBuffer.count
                let drainStartMs = peelReceivePerfNowMs()
                drainBinaryPackets(from: &muxBuffer)
                let drainMs = peelReceivePerfNowMs() - drainStartMs
                binaryDrainCount += 1
                maxBufferBytes = max(maxBufferBytes, muxBuffer.count)
                if drainMs >= 3.0 {
                    print(
                        "PeelClientPerf muxDrain owner=session",
                        "drainMs=\(String(format: "%.2f", drainMs))",
                        "before=\(byteCountBeforeDrain)",
                        "after=\(muxBuffer.count)",
                        "drains=\(binaryDrainCount)"
                    )
                }

                // If the buffer did not shrink, the current binary packet is incomplete.
                // Return and wait for the next NWConnection receive to append more bytes.
                // Without this guard, an incomplete H.264 frame can spin this loop forever.
                if muxBuffer.count == byteCountBeforeDrain {
                    let totalMs = peelReceivePerfNowMs() - processStartMs
                    let appendMs = appendDoneMs - processStartMs
                    if totalMs >= 4.0 || muxBuffer.count >= 128 * 1024 || loopIterations >= 16 {
                        print(
                            "PeelClientPerf muxReturn owner=session reason=incompleteBinary",
                            "totalMs=\(String(format: "%.2f", totalMs))",
                            "appendMs=\(String(format: "%.2f", appendMs))",
                            "loops=\(loopIterations)",
                            "binaryDrains=\(binaryDrainCount)",
                            "jsonLines=\(jsonLineCount)",
                            "inputBytes=\(data.count)",
                            "bufferBefore=\(bufferBeforeBytes)",
                            "bufferNow=\(muxBuffer.count)",
                            "maxBuffer=\(maxBufferBytes)"
                        )
                    }
                    return
                }

                continue
            }
            
            guard let nl = muxBuffer.firstIndex(of: 0x0A) else {
                let totalMs = peelReceivePerfNowMs() - processStartMs
                let appendMs = appendDoneMs - processStartMs
                if totalMs >= 4.0 || muxBuffer.count >= 128 * 1024 || loopIterations >= 16 {
                    print(
                        "PeelClientPerf muxReturn owner=session reason=waitingNewline",
                        "totalMs=\(String(format: "%.2f", totalMs))",
                        "appendMs=\(String(format: "%.2f", appendMs))",
                        "loops=\(loopIterations)",
                        "binaryDrains=\(binaryDrainCount)",
                        "jsonLines=\(jsonLineCount)",
                        "inputBytes=\(data.count)",
                        "bufferBefore=\(bufferBeforeBytes)",
                        "bufferNow=\(muxBuffer.count)",
                        "maxBuffer=\(maxBufferBytes)"
                    )
                }
                return
            }
            
            let line = muxBuffer.subdata(in: 0..<nl)
            muxBuffer.removeSubrange(0...nl)
            
            guard !line.isEmpty else { continue }
            let lineStartMs = peelReceivePerfNowMs()
            handleLine(line, sourceConnection: sourceConnection)
            let lineMs = peelReceivePerfNowMs() - lineStartMs
            jsonLineCount += 1
            if lineMs >= 2.0 {
                print(
                    "PeelClientPerf muxJSON owner=session",
                    "lineMs=\(String(format: "%.2f", lineMs))",
                    "bytes=\(line.count)",
                    "jsonLines=\(jsonLineCount)"
                )
            }
        }
    }
    
    func startStreamWatchdog() {
        guard !isStreamWatchdogRunning else { return }

        PeelClientDiagnostics.logStreamEvent(ownerName: "session", message: "watchdog start")
        isStreamWatchdogRunning = true
        streamWatchdog?.invalidate()

        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isClientVisible else { return }
            guard self.connection != nil, self.isConnectionReady else { return }

            let now = Date()

            // 1) Clear stuck snapshot/JPEG in-flight state.
            for (id, since) in self.inFlightSince {
                if now.timeIntervalSince(since) > self.inFlightTimeout {
                    self.inFlightSince.removeValue(forKey: id)

                    if self.inFlight.contains(id) {
                        self.inFlight.remove(id)
                        self.globalSnapshotsInFlight = max(0, self.globalSnapshotsInFlight - 1)
                    }
                }
            }

            // 2) Ensure every visible/desired stream actually got a startStream.
            for windowId in self.desiredPullWindowIds.sorted() {
                if !self.startedStreamWindowIds.contains(windowId) {
                    self.requestStreamStart(windowId: windowId, reason: "watchdog missing startStream")
                    continue
                }

                // 3) If the local decoder layer has failed, stop/start the stream.
                if let renderer = self.videoRenderers[windowId],
                   renderer.displayLayer.status == .failed || renderer.displayLayer.requiresFlushToResumeDecoding {
                    self.repairStream(windowId: windowId, reason: "display layer failed or requires flush")
                    continue
                }

                // 4) First-frame watchdog.
                // Config is not enough. The stream is not usable until a real videoFrame arrives.
                let frameCount = self.videoFrameCountByWindow[windowId] ?? 0
                guard frameCount == 0 else {
                    continue
                }

                guard let startAt = self.streamStartAttemptAtByWindow[windowId] else {
                    self.requestStreamStart(windowId: windowId, reason: "watchdog missing start timestamp")
                    continue
                }

                let age = now.timeIntervalSince(startAt)

                if age > self.streamFirstFrameTimeout {
                    self.repairStream(
                        windowId: windowId,
                        reason: "no first video frame after \(String(format: "%.1f", age))s"
                    )
                }
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        streamWatchdog = timer
    }
    
    func stopStreamWatchdog() {
        guard isStreamWatchdogRunning else { return }
        PeelClientDiagnostics.logStreamEvent(ownerName: "session", message: "watchdog stop")
        isStreamWatchdogRunning = false
        streamWatchdog?.invalidate()
        streamWatchdog = nil
    }
}
