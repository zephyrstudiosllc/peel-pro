//
//  PairingRXBuffer.swift
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
    // MARK: - Pairing recovery
    
    /// Heuristic: if the TLS handshake fails while we *think* we're paired, the Mac host likely
    /// forgot us (or the pairing material rotated). In that case, auto-reconnect loops are pointless;
    /// we should forget local pairing and force a re-pair.
    func shouldInvalidateLocalPairing(for host: PeelHostInfo, error: NWError) -> Bool {
        guard pairedPeer(for: host) != nil else { return false }
        
        let key = host.hostId ?? host.service.name
        let s = (String(describing: error) + " " + error.localizedDescription).lowercased()
        
        // Only treat as fatal when it looks like "unknown PSK identity" / "no shared key" etc.
        let looksLikePSKMismatch =
        s.contains("unknown_psk") ||
        (s.contains("unknown") && s.contains("psk")) ||
        s.contains("psk identity") ||
        s.contains("pre-shared") && s.contains("unknown")
        
        guard looksLikePSKMismatch else {
            // Transient TLS failures happen during sleep/wake/background.
            // Do NOT delete pairing for those.
            return false
        }
        
        let now = Date()
        if let last = pskMismatchLastAt[key], now.timeIntervalSince(last) > pskMismatchWindow {
            pskMismatchCount[key] = 0
        }
        pskMismatchLastAt[key] = now
        pskMismatchCount[key] = (pskMismatchCount[key] ?? 0) + 1
        
        return (pskMismatchCount[key] ?? 0) >= pskMismatchThreshold
    }
    
    func invalidateLocalPairing(for host: PeelHostInfo, because error: NWError) {
        // Mark as handled so the `.cancelled` path from resetSession() doesn't schedule a reconnect.
        didHandleDisconnectForCurrentConnection = true
        
        if let peer = pairedPeer(for: host) {
            iCloudPairingClient.ignoreHost(peer.stableHostId)
            removeDirectEndpoint(for: peer.id)
            pairingStore.removePeer(pairingID: peer.id)
        }
        
        let key = host.hostId ?? host.service.name
        pskMismatchCount[key] = nil
        pskMismatchLastAt[key] = nil
        
        reconnectWorkItem?.cancel()
        reconnectAttempt = 0
        
        DispatchQueue.main.async {
            self.resetSession(reason: "pairing invalid")
            self.isConnectBusy = false
            self.isConnectionReady = false
            self.status = "Pairing rejected by \(host.name). The computer likely forgot this device. Re-pair to continue."
        }
    }
    
    func resetPairingAttempt(reason: String, status: String? = nil) {
        pairingResolveTimeoutWorkItem?.cancel()
        pairingResolveTimeoutWorkItem = nil
        
        pairingWaitingTimeoutWorkItem?.cancel()
        pairingWaitingTimeoutWorkItem = nil
        
        pairingResponseTimeoutWorkItem?.cancel()
        pairingResponseTimeoutWorkItem = nil
        
        pendingPairHost = nil
        pendingPairPIN = nil
        pairingResolveService?.stop()
        pairingResolveService = nil
        pairingFreshResolveRetryUsed = false
        pendingConnectHost = nil
        pendingConnectIsAutoReconnect = false
        suppressAutoReconnect = false
        
        pairingConnection?.stateUpdateHandler = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        
        DispatchQueue.main.async {
            self.pairingHostName = nil
            self.isConnectBusy = false
            let message = status ?? reason
            self.pairingStatus = message
            self.status = message
        }
    }

    nonisolated private static func pairingErrorSummary(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "POSIX \(code.rawValue)"
        case .dns(let code):
            return "DNS \(code)"
        case .tls(let code):
            return "TLS \(code)"
        default:
            return "network error"
        }
    }
    
    func parseHostId(from service: NetService) -> String? {
        guard let txtData = service.txtRecordData() else { return nil }
        let dict = NetService.dictionary(fromTXTRecord: txtData)
        guard let raw = dict["hostId"],
              let s = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else {
            return nil
        }
        return s
    }
    
    func currentDeviceName() -> String {
#if canImport(UIKit)
        return UIDevice.current.name
#else
        return "Peel Client"
#endif
    }
    
    func currentDeviceModel() -> String? {
#if canImport(UIKit)
        return UIDevice.current.model
#else
        return nil
#endif
    }
    
    func currentPlatformString() -> String {
#if os(visionOS)
        return "visionOS"
#elseif os(iOS)
        return "iOS"
#else
        return "unknown"
#endif
    }
    
    func currentOSVersion() -> String? {
#if canImport(UIKit)
        return UIDevice.current.systemVersion
#else
        return nil
#endif
    }
    
    func currentAppVersion() -> String? {
        let b = Bundle.main
        let short = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case (let s?, let b?): return "\(s) (\(b))"
        case (let s?, nil): return s
        case (nil, let b?): return b
        default: return nil
        }
    }

    func retryPairWithFreshResolveOnce(host: PeelHostInfo, pin: String, reason: String) {
        guard pendingPairHost?.name == host.name else { return }
        
        pairingResolveTimeoutWorkItem?.cancel()
        pairingResolveTimeoutWorkItem = nil
        pairingWaitingTimeoutWorkItem?.cancel()
        pairingWaitingTimeoutWorkItem = nil
        pairingResponseTimeoutWorkItem?.cancel()
        pairingResponseTimeoutWorkItem = nil
        
        pairingConnection?.stateUpdateHandler = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        
        pendingConnectHost = nil
        pendingConnectIsAutoReconnect = false
        pendingPairHost = host
        pendingPairPIN = pin
        pairingFreshResolveRetryUsed = true
        suppressAutoReconnect = true
        
        DispatchQueue.main.async {
            self.pairingHostName = host.name
            self.isConnectBusy = true
            let message = "Refreshing pairing info for \(host.name)…"
            self.pairingStatus = message
            self.status = message
        }
        
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingPairHost?.name == host.name else { return }
            self.resetPairingAttempt(
                reason: "Pair retry resolve timeout after \(reason)",
                status: "Could not refresh pairing info for \(host.name). Refresh the code on the computer and try again."
            )
        }
        pairingResolveTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + pairingResolveTimeoutSeconds,
            execute: work
        )
        
        resolvePairingServiceFreshly(for: host)
    }

    private func resolvePairingServiceFreshly(for host: PeelHostInfo) {
        pairingResolveService?.stop()

        let service = NetService(
            domain: host.service.domain,
            type: host.service.type,
            name: host.service.name
        )
        service.delegate = self
        pairingResolveService = service
        service.resolve(withTimeout: 5)
    }
    
    func sendClientHello() {
        var capabilities = PeelProtocol.advertisedClientCapabilities
        // Agent presentation belongs to the real per-host session and its
        // active-scene coordinator, not this legacy browser connection.
        capabilities.remove(PeelCapability.agentPresentationV1.rawValue)
        capabilities.remove(PeelManualAgentControl.capability)
        // Evidence needs the real per-host connection and pairing fences.
        capabilities.remove(PeelProEvidenceLimits.capability)
        capabilities.insert(PeelRuntimeCapability.hostRenderedCursor)

        let msg = ClientHelloMessage(
            pairingID: activePairingID,
            deviceName: currentDeviceName(),
            deviceModel: currentDeviceModel(),
            platform: currentPlatformString(),
            osVersion: currentOSVersion(),
            appVersion: currentAppVersion(),
            capabilities: capabilities
        )
        sendJSONMessage(msg)
    }
    
    private func statusSession(matching host: PeelHostInfo) -> PeelHostSession? {
        if let direct = sessionsByHostKey[host.hostKey] {
            return direct
        }

        if let hostId = host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty,
           let match = sessionsByHostKey.values.first(where: { session in
               guard let sessionHostId = session.host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
                     !sessionHostId.isEmpty else {
                   return false
               }
               return sessionHostId == hostId
           }) {
            return match
        }

        return sessionsByHostKey.values.first { session in
            session.host.service.name == host.service.name ||
            session.host.name == host.name
        }
    }

    func needsPairingRepair(_ host: PeelHostInfo) -> Bool {
        statusSession(matching: host)?.requiresPairingRepair == true
    }

    func isPairing(_ host: PeelHostInfo) -> Bool {
        pairingHostName == host.name && isConnectBusy
    }
    
    func isResolvingPairing(_ host: PeelHostInfo) -> Bool {
        pendingPairHost?.name == host.name && pairingConnection == nil && isConnectBusy
    }
    
    func isConnecting(_ host: PeelHostInfo) -> Bool {
        if let session = statusSession(matching: host) {
            if session.isConnectBusy { return true }
            if session.pendingConnectHost != nil { return true }
            if session.connection != nil && !session.isConnectionReady { return true }
        }

        guard isConnectBusy else { return false }
        
        if pendingConnectHost?.name == host.name || pendingConnectHost?.service.name == host.service.name {
            return true
        }
        
        if connection != nil,
           !isConnectionReady,
           lastConnectedHostName == host.name {
            return true
        }
        
        return false
    }
    
    func isBusy(for host: PeelHostInfo) -> Bool {
        isPairing(host) || isResolvingPairing(host) || isConnecting(host)
    }
    
    func pairWithPIN(host: PeelHostInfo, pin: String) {
        iCloudPairingClient.manualPairingWillBegin()
        let normalized = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 6, normalized.allSatisfy({ $0.isNumber }) else {
            DispatchQueue.main.async { self.status = "Enter a valid 6-digit PIN." }
            return
        }
        // Starting a manual pair attempt must win over any stale connect/reconnect intent.
        pairingResolveTimeoutWorkItem?.cancel()
        pairingResolveTimeoutWorkItem = nil
        pairingWaitingTimeoutWorkItem?.cancel()
        pairingWaitingTimeoutWorkItem = nil
        pairingResponseTimeoutWorkItem?.cancel()
        pairingResponseTimeoutWorkItem = nil

        pendingConnectHost = nil
        pendingConnectIsAutoReconnect = false
        pendingPairHost = nil
        pendingPairPIN = nil
        pairingResolveService?.stop()
        pairingResolveService = nil
        pairingFreshResolveRetryUsed = false
        pairingConnection?.stateUpdateHandler = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        // Pairing uses a separate temporary TLS-PSK connection. Do not let the
        // normal reconnect loop race it while the user is entering a PIN/token.
        suppressAutoReconnect = true
        pendingReconnectWhenVisible = false
        pendingReconnectReason = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0

        // PIN pairing depends on short-lived TXT values such as pinSalt and pairPort.
        // Always re-resolve before using them so we do not pair against stale Bonjour data.
        pendingPairHost = host
        pendingPairPIN = normalized

        DispatchQueue.main.async {
            self.pairingHostName = host.name
            self.isConnectBusy = true
            let message = "Resolving \(host.name) for pairing…"
            self.pairingStatus = message
            self.status = message
        }

        pairingResolveTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingPairHost?.name == host.name else { return }
            self.resetPairingAttempt(
                reason: "Pair resolve timeout",
                status: "Could not reach \(host.name) for pairing. Try again in a moment."
            )
        }
        pairingResolveTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + pairingResolveTimeoutSeconds,
            execute: work
        )

        resolvePairingServiceFreshly(for: host)
        return
    }
    
    func continuePairWithPIN(host: PeelHostInfo, pin: String) {
        pairingResolveTimeoutWorkItem?.cancel()
        pairingResolveTimeoutWorkItem = nil

        pairingWaitingTimeoutWorkItem?.cancel()
        pairingWaitingTimeoutWorkItem = nil

        pairingResponseTimeoutWorkItem?.cancel()
        pairingResponseTimeoutWorkItem = nil

        let shouldRetryPairingOnce = !pairingFreshResolveRetryUsed

        pairingConnection?.stateUpdateHandler = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        pendingConnectHost = nil
        pendingConnectIsAutoReconnect = false
        suppressAutoReconnect = true
        pendingReconnectWhenVisible = false
        pendingReconnectReason = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0

        let txtData = host.service.txtRecordData()
        let txt = txtData.map(NetService.dictionary(fromTXTRecord:)) ?? [:]

        let hostId = txt["hostId"].flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let saltB64 = txt["pinSalt"].flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let portStr = txt["pairPort"].flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostId.isEmpty else {
            // Do not remove the host from discovery for transient pairing TXT churn.
            resetPairingAttempt(
                reason: "Pairing identity missing",
                status: "Host didn’t advertise a stable pairing identity. Looking for it again…"
            )
            return
        }

        guard let salt = Data(base64Encoded: saltB64), !salt.isEmpty else {
            // Do not remove the host from discovery for transient pairing TXT churn.
            resetPairingAttempt(
                reason: "Pairing data incomplete",
                status: "Host pairing data is incomplete. Looking for it again…"
            )
            return
        }

        guard let portStr,
              let port = UInt16(portStr),
              port > 0 else {
            resetPairingAttempt(
                reason: "Pairing endpoint missing",
                status: "The computer is refreshing pairing. Try again in a moment."
            )
            return
        }
        let pinPSK = PeelTLS.derivePairingPinPSK(pin: pin, salt: salt, hostId: hostId)
        let pinProof = PeelTLS.makePairingPinProof(
            pinPSK: pinPSK,
            hostId: hostId,
            clientDeviceId: clientDeviceId
        )

        guard let hostName = host.service.hostName else {
            // Do not remove the host from discovery for transient resolve churn.
            resetPairingAttempt(
                reason: "Pair hostName missing",
                status: "Could not resolve the computer for pairing. Looking for it again…"
            )
            return
        }

        let pskOrder = PeelTLS.clientPSKOrder(for: nil, service: host.service)
        let params = PeelTLS.makeClientParameters(
            pairingID: PeelTLS.pairingPinIdentity,
            psk: pinPSK,
            pskOrder: pskOrder
        )
        let conn = NWConnection(host: NWEndpoint.Host(hostName),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: params)
        pairingConnection = conn

        DispatchQueue.main.async {
            self.pairingHostName = host.name
            let message = "Pairing with \(host.name)…"
            self.pairingStatus = message
            self.status = message
            self.isConnectBusy = true
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pairingWaitingTimeoutWorkItem?.cancel()
                self.pairingWaitingTimeoutWorkItem = nil

                let clientName: String = {
#if canImport(UIKit)
                    return UIDevice.current.name
#else
                    return "Peel Client"
#endif
                }()

                let req = PairRequestMessage(
                    clientName: clientName,
                    clientDeviceId: self.clientDeviceId,
                    pinProof: pinProof
                )
                guard let data = try? JSONEncoder().encode(req) else {
                    self.resetPairingAttempt(
                        reason: "Pair encode failed",
                        status: "Pairing failed: could not build pairing request."
                    )
                    return
                }

                conn.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }

                    if let error {
                        if shouldRetryPairingOnce {
                            self.pendingPairPIN = nil
                            self.retryPairWithFreshResolveOnce(host: host, pin: pin, reason: "send failed")
                        } else {
                            self.resetPairingAttempt(
                                reason: "Pair send failed",
                                status: "Connection error while pairing (\(Self.pairingErrorSummary(error))). Refresh the code on the computer and try again."
                            )
                        }
                        return
                    }

                    self.pairingResponseTimeoutWorkItem?.cancel()
                    let timeoutWork = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.resetPairingAttempt(
                            reason: "Pair response timeout",
                            status: "Pairing timed out waiting for \(host.name). Check the PIN/token, or restart Peel Pro on the computer."
                        )
                    }
                    self.pairingResponseTimeoutWorkItem = timeoutWork
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + self.pairingResponseTimeoutSeconds,
                        execute: timeoutWork
                    )

                    self.receivePairingResponseBuffered(
                        on: conn,
                        host: host,
                        hostId: hostId,
                        pskOrder: pskOrder
                    )
                })

            case .waiting(let error):
                self.pairingWaitingTimeoutWorkItem?.cancel()

                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if shouldRetryPairingOnce {
                        self.pendingPairPIN = nil
                        self.retryPairWithFreshResolveOnce(
                            host: host,
                            pin: pin,
                            reason: "connection waiting timeout"
                        )
                    } else {
                        self.resetPairingAttempt(
                            reason: "Pair waiting timeout",
                            status: "Connection error while pairing. Try again in a moment."
                        )
                    }
                }

                self.pairingWaitingTimeoutWorkItem = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + self.pairingWaitingTimeoutSeconds,
                    execute: work
                )

                DispatchQueue.main.async {
                    let message = "Waiting for \(host.name) to accept pairing (\(Self.pairingErrorSummary(error)))…"
                    self.pairingStatus = message
                    self.status = message
                }

            case .failed(let error):
                if shouldRetryPairingOnce {
                    self.pendingPairPIN = nil
                    self.retryPairWithFreshResolveOnce(host: host, pin: pin, reason: "connection failed")
                    return
                }
                
                let errorText = (String(describing: error) + " " + error.localizedDescription).lowercased()
                let status: String
                if errorText.contains("psk") || errorText.contains("tls") || errorText.contains("authentication") || errorText.contains("cancelled") {
                    status = "Wrong PIN/token. Refresh the code on the computer and try again."
                } else {
                    status = "Connection error while pairing. Refresh the code on the computer and try again."
                }
                self.resetPairingAttempt(
                    reason: "Pair failed",
                    status: "\(status) (\(Self.pairingErrorSummary(error)))"
                )

            case .cancelled:
                guard self.pairingConnection === conn else { return }
                self.resetPairingAttempt(reason: "Pair cancelled")

            default:
                break
            }
        }

        conn.start(queue: networkQueue)
    }
    
    final class PairingRXBuffer {
        var data = Data()
    }
    
    func receivePairingResponseBuffered(
        on conn: NWConnection,
        host: PeelHostInfo,
        hostId: String,
        pskOrder: PeelTLSPSKOrder
    ) {
        let buffer = PairingRXBuffer()
        let retryPIN = pairingFreshResolveRetryUsed ? nil : pendingPairPIN

        func loop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self else { return }

                if let error {
                    if let retryPIN {
                        self.pendingPairPIN = nil
                        self.retryPairWithFreshResolveOnce(host: host, pin: retryPIN, reason: "receive failed")
                    } else {
                        self.resetPairingAttempt(
                            reason: "Pair receive failed",
                            status: "Connection error while pairing (\(Self.pairingErrorSummary(error))). Refresh the code on the computer and try again."
                        )
                    }
                    return
                }

                if let data, !data.isEmpty {
                    buffer.data.append(data)

                    if let resp = try? JSONDecoder().decode(PairResponseMessage.self, from: buffer.data) {
                        guard resp.accepted else {
                            if let retryPIN {
                                self.pendingPairPIN = nil
                                self.retryPairWithFreshResolveOnce(host: host, pin: retryPIN, reason: "pair rejected")
                            } else {
                                self.resetPairingAttempt(
                                    reason: "Pair rejected",
                                    status: resp.reason ?? "Wrong PIN/token. Refresh the code on the computer and try again."
                                )
                            }
                            conn.cancel()
                            return
                        }

                        guard !resp.psk.isEmpty else {
                            self.resetPairingAttempt(
                                reason: "Pair missing PSK",
                                status: "Pairing failed: host accepted but did not send pairing material."
                            )
                            conn.cancel()
                            return
                        }

                        let savedPeer: PeelPairedPeer
                        do {
                            savedPeer = try self.pairingStore.addPeerPersistingKey(
                                displayName: resp.hostName,
                                serviceName: host.service.name,
                                stableHostId: hostId.isEmpty ? nil : hostId,
                                tlsPSKOrder: pskOrder,
                                pairingID: resp.pairingId,
                                psk: resp.psk
                            )
                        } catch {
                            self.resetPairingAttempt(
                                reason: "Pairing key storage failed",
                                status: "Could not save the pairing key on this device. Existing pairings were kept. Try again."
                            )
                            conn.cancel()
                            return
                        }
                        let savedHost = PeelHostInfo(
                            name: host.name,
                            service: host.service,
                            hostId: hostId.isEmpty ? nil : hostId
                        )
                        self.persistLastConnectedPeer(savedPeer, host: savedHost)

                        self.pairingResponseTimeoutWorkItem?.cancel()
                        self.pairingResponseTimeoutWorkItem = nil
                        self.pairingWaitingTimeoutWorkItem?.cancel()
                        self.pairingWaitingTimeoutWorkItem = nil
                        self.pendingPairHost = nil
                        self.pendingPairPIN = nil
                        self.pairingFreshResolveRetryUsed = false
                        self.pendingConnectHost = nil
                        self.pendingConnectIsAutoReconnect = false
                        self.pairingConnection?.stateUpdateHandler = nil
                        self.pairingConnection = nil
                        DispatchQueue.main.async {
                            if let idx = self.hosts.firstIndex(where: { existing in
                                if let existingHostId = existing.hostId,
                                   !existingHostId.isEmpty,
                                   !hostId.isEmpty {
                                    return existingHostId == hostId
                                }

                                return existing.name == host.name
                            }) {
                                self.hosts[idx] = PeelHostInfo(
                                    name: host.name,
                                    service: host.service,
                                    hostId: hostId.isEmpty ? nil : hostId
                                )
                            }

                            self.prepareReconnectAfterPairing(with: savedHost)
                            self.markPairingStateChanged()

                            self.pairingHostName = nil
                            let message = "Paired with \(resp.hostName). Connecting…"
                            self.pairingStatus = message
                            self.status = message
                            self.isConnectBusy = false
                            self.attemptPendingReconnectIfPossible(reason: "paired host available")
                        }

                        conn.stateUpdateHandler = nil
                        conn.cancel()
                        return
                    }

                    if buffer.data.count > 64 * 1024 {
                        self.resetPairingAttempt(
                            reason: "Pair malformed response",
                            status: "Pairing failed because the computer sent an unreadable response. Restart Peel Pro on the computer and try again."
                        )
                        return
                    }
                }

                if isComplete {
                    if let retryPIN {
                        self.pendingPairPIN = nil
                        self.retryPairWithFreshResolveOnce(host: host, pin: retryPIN, reason: "connection closed early")
                    } else {
                        self.resetPairingAttempt(
                            reason: "Pair closed early",
                            status: "Connection closed while pairing. Refresh the code on the computer and try again."
                        )
                    }
                    return
                }

                loop()
            }
        }

        loop()
    }

    func prepareReconnectAfterPairing(with host: PeelHostInfo) {
        let targetSession = session(for: host)
        let reconnectAt = Date().addingTimeInterval(postPairConnectCooldown)

        // Control connections use session state. A repaired pairing must retire
        // its missing-key suppression and wait for the Host's TLS listener refresh.
        targetSession.requiresPairingRepair = false
        targetSession.suppressAutoReconnect = false
        targetSession.reconnectAttempt = 0
        targetSession.reconnectWorkItem?.cancel()
        targetSession.reconnectWorkItem = nil
        targetSession.delayedConnectWorkItem?.cancel()
        targetSession.delayedConnectWorkItem = nil
        targetSession.nextAllowedConnectAt = reconnectAt
        targetSession.lastConnectedHost = host
        targetSession.lastConnectedHostName = host.name
        targetSession.pendingReconnectWhenVisible = true
        targetSession.pendingReconnectReason = "paired host available"

        lastConnectedHost = host
        lastConnectedHostName = host.name
        pendingReconnectWhenVisible = true
        pendingReconnectReason = "paired host available"
        suppressAutoReconnect = false
        nextAllowedConnectAt = reconnectAt
    }
}
