//
//  PairingState.swift
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
    // MARK: - Pairing
    
    private var lastConnectedPairingIDKey: String { "Peel.lastConnectedPairingID" } // legacy
    private var lastConnectedServiceNameKey: String { "Peel.lastConnectedServiceName" } // legacy
    private var lastConnectedStableHostIDKey: String { "Peel.lastConnectedStableHostID" } // legacy
    private var lastConnectedPairingIDsKey: String { "Peel.lastConnectedPairingIDs" }

    func persistedLastConnectedPairingIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: lastConnectedPairingIDsKey) ?? [])
    }

    func rememberLastConnectedPeer(_ peer: PeelPairedPeer) {
        var ids = persistedLastConnectedPairingIDs()
        ids.insert(peer.id)
        UserDefaults.standard.set(Array(ids), forKey: lastConnectedPairingIDsKey)
    }

    func forgetLastConnectedPeer(_ peer: PeelPairedPeer) {
        var ids = persistedLastConnectedPairingIDs()
        ids.remove(peer.id)
        UserDefaults.standard.set(Array(ids), forKey: lastConnectedPairingIDsKey)
    }

    func persistLastConnectedPeer(_ peer: PeelPairedPeer, host: PeelHostInfo? = nil) {
        rememberLastConnectedPeer(peer)
        UserDefaults.standard.set(peer.id, forKey: lastConnectedPairingIDKey)
        UserDefaults.standard.set(host?.service.name ?? peer.serviceName, forKey: lastConnectedServiceNameKey)

        if let hostId = host?.hostId ?? peer.stableHostId, !hostId.isEmpty {
            UserDefaults.standard.set(hostId, forKey: lastConnectedStableHostIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastConnectedStableHostIDKey)
        }
    }

    func clearPersistedLastConnectedPeer() {
        UserDefaults.standard.removeObject(forKey: lastConnectedPairingIDKey)
        UserDefaults.standard.removeObject(forKey: lastConnectedServiceNameKey)
        UserDefaults.standard.removeObject(forKey: lastConnectedStableHostIDKey)
        UserDefaults.standard.removeObject(forKey: lastConnectedPairingIDsKey)
    }

    /// Returns true if we have a saved PSK for this discovered host.
    func isPaired(_ host: PeelHostInfo) -> Bool {
        pairedPeer(for: host) != nil
    }
    
    var pairedMacCount: Int {
        pairingStore.paired.count
    }

    func primeReconnectFromSavedPairingIfNeeded() {
        guard connection == nil else { return }
        guard isConnectionReady == false else { return }
        guard !suppressAutoReconnect else { return }
        guard pendingReconnectWhenVisible == false else { return }
        guard lastConnectedHostName == nil, lastConnectedHost == nil else {
            pendingReconnectWhenVisible = true
            if pendingReconnectReason == nil {
                pendingReconnectReason = "restore previous connection"
            }
            return
        }

        let defaults = UserDefaults.standard
        let savedPairingIDs = persistedLastConnectedPairingIDs()
        let savedPairingID = defaults.string(forKey: lastConnectedPairingIDKey)
        let savedServiceName = defaults.string(forKey: lastConnectedServiceNameKey)
        let savedStableHostID = defaults.string(forKey: lastConnectedStableHostIDKey)

        // Enrollment alone does not express connection intent, including after
        // a later app restart. Keep the legacy fallback for manual pairings.
        let savedPeer = pairingStore.paired.first { peer in
            if savedPairingIDs.contains(peer.id) { return true }
            if let savedPairingID, peer.id == savedPairingID {
                rememberLastConnectedPeer(peer)
                return true
            }
            if let savedStableHostID, peer.stableHostId == savedStableHostID { return true }
            if let savedServiceName, peer.serviceName == savedServiceName { return true }
            return false
        } ?? pairingStore.paired.first(where: { $0.iCloudEnrollmentID == nil })

        guard let savedPeer else { return }

        lastConnectedHostName = savedPeer.serviceName
        pendingReconnectWhenVisible = true
        pendingReconnectReason = "restore previous connection"
    }

    func shouldAutoReconnect(to host: PeelHostInfo) -> Bool {
        guard let peer = pairedPeer(for: host) else { return false }

        if persistedLastConnectedPairingIDs().contains(peer.id) {
            return true
        }

        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastConnectedPairingIDKey) == peer.id {
            rememberLastConnectedPeer(peer)
            return true
        }

        return false
    }

    
    
    var savedPairedMacs: [PeelSavedPairedMac] {
        pairingStore.paired.map {
            PeelSavedPairedMac(
                id: $0.id,
                displayName: $0.displayName,
                serviceName: $0.serviceName,
                stableHostId: $0.stableHostId
            )
        }
    }

    var hiddenSavedPairedMacs: [PeelSavedPairedMac] {
        savedPairedMacs.filter { savedMac in
            !hosts.contains { host in
                pairedPeer(for: host)?.id == savedMac.id
            }
        }
    }

    func forgetSavedPairing(_ savedMac: PeelSavedPairedMac) {
        iCloudPairingClient.ignoreHost(savedMac.stableHostId)
        removeDirectEndpoint(for: savedMac.id)
        if let peer = pairingStore.paired.first(where: { $0.id == savedMac.id }) {
            forgetLastConnectedPeer(peer)
        }
        pairingStore.removePeer(pairingID: savedMac.id)
        markPairingStateChanged()

        if lastConnectedHostName == savedMac.serviceName || lastConnectedHost?.hostId == savedMac.stableHostId {
            clearPersistedLastConnectedPeer()
            lastConnectedHost = nil
            lastConnectedHostName = nil
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            suppressAutoReconnect = true
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempt = 0
        }
    }
    /// Pair this discovered host using a pairing token generated by the Mac host.
    /// The token must match the host's Bonjour service name.
    @discardableResult
    func pair(host: PeelHostInfo, token: String) -> Bool {
        iCloudPairingClient.manualPairingWillBegin()
        guard let invite = PeelPairingInvitation.decodeToken(token),
              let psk = invite.psk,
              !psk.isEmpty else {
            DispatchQueue.main.async {
                let message = "Invalid pairing token."
                self.pairingStatus = message
                self.status = message
            }
            return false
        }
        
        // Ensure the token is for the exact Bonjour service we discovered.
        // Prefer stable hostId match (new tokens)
        if let tokenHostId = invite.hostId {
            guard let discoveredHostId = host.hostId, tokenHostId == discoveredHostId else {
                DispatchQueue.main.async {
                    let message = "Token is for a different Mac (hostId mismatch)."
                    self.pairingStatus = message
                    self.status = message
                }
                return false
            }
        } else {
            // Legacy tokens: service name must match
            guard invite.serviceName == host.service.name else {
                DispatchQueue.main.async {
                    let message = "Token is for ‘\(invite.serviceName)’, not ‘\(host.service.name)’."
                    self.pairingStatus = message
                    self.status = message
                }
                return false
            }
        }
        
        let savedPeer = pairingStore.addPeer(
            displayName: invite.hostDisplayName,
            serviceName: host.service.name,              // store the discovered name (current)
            stableHostId: invite.hostId,  // stable if possible
            tlsPSKOrder: PeelTLS.clientPSKOrder(for: nil, service: host.service),
            pairingID: invite.pairingID,
            psk: psk
        )
        persistLastConnectedPeer(savedPeer, host: host)
        
        markPairingStateChanged()
        lastConnectedHost = host
        lastConnectedHostName = host.name
        pendingReconnectWhenVisible = true
        pendingReconnectReason = "paired host available"
        suppressAutoReconnect = false
        
        DispatchQueue.main.async {
            let message = "Paired with \(invite.hostDisplayName)."
            self.pairingStatus = message
            self.status = message
        }
        return true
    }
    

    func pairedPeer(for host: PeelHostInfo) -> PeelPairedPeer? {
        // Paired-peer lookup debug logging disabled.
        // Direct descriptors carry an explicit pairing identity and must never
        // fall through to Bonjour service/name heuristics.
        if let directPairingID = host.directPairingID {
            return pairedPeer(forPairingID: directPairingID)
        }

        // 1) Best: stable hostId match (rename-proof)
        if let hid = host.hostId,
           let match = pairingStore.paired.first(where: { $0.stableHostId == hid }) {
            // If service name changed, update it silently.
            if match.serviceName != host.service.name {
                pairingStore.updatePeerMetadata(pairingID: match.id, serviceName: host.service.name, stableHostId: hid)
            }
            return match
        }
        
        // 2) Legacy: serviceName exact match
        let serviceName = host.service.name
        if let match = pairingStore.paired.first(where: { $0.serviceName == serviceName }) {
            // If we now know hostId, attach it (auto-upgrade).
            if let hid = host.hostId, match.stableHostId != hid {
                pairingStore.updatePeerMetadata(pairingID: match.id, serviceName: serviceName, stableHostId: hid)
            }
            return match
        }
        
        // 3) Auto-heal heuristic: if exactly one pairing exists and the Bonjour name looks like "Peel on <displayName>"
        if pairingStore.paired.count == 1, let only = pairingStore.paired.first {
            let dn = only.displayName.lowercased()
            if !dn.isEmpty, serviceName.lowercased().contains(dn) {
                pairingStore.updatePeerMetadata(pairingID: only.id, serviceName: serviceName, stableHostId: host.hostId)
                return only
            }
        }
        
        return nil
    }
    
    /// Remove the local pairing material for a discovered host (client-side forget).
    /// Useful when the Mac host has forgotten us and TLS-PSK handshakes start failing.
    func forgetPairing(for host: PeelHostInfo) {
        guard let peer = pairedPeer(for: host) else { return }
        iCloudPairingClient.ignoreHost(peer.stableHostId)
        forgetLastConnectedPeer(peer)
        
        let revoke = PairingRevokedMessage(
            pairingId: peer.id,
            deviceId: clientDeviceId,
            reason: "Client forgot pairing"
        )
        
        if connection != nil, isConnectionReady, connectedHostName == host.name {
            sendJSONMessage(revoke)
        }
        
        removeDirectEndpoint(for: peer.id)
        pairingStore.removePeer(pairingID: peer.id)
        markPairingStateChanged()
        
        if connectedHostName == host.name || lastConnectedHostName == host.name {
            clearPersistedLastConnectedPeer()
            suppressAutoReconnect = true
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            lastConnectedHost = nil
            lastConnectedHostName = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempt = 0
            didHandleDisconnectForCurrentConnection = true
            resetSession(reason: "pairing forgotten")
        }
        
        DispatchQueue.main.async {
            self.isConnectBusy = false
            self.status = "Forgot pairing for \(host.name). Re-pair to connect again."
        }
    }
    
    func handlePairingRevoked(_ message: PairingRevokedMessage) {
        let revokedPeer = pairingStore.paired.first { peer in
            peer.id == message.pairingId
        }
        if let revokedPeer {
            iCloudPairingClient.ignoreHost(revokedPeer.stableHostId)
            forgetLastConnectedPeer(revokedPeer)
        }
        
        removeDirectEndpoint(for: message.pairingId)
        pairingStore.removePeer(pairingID: message.pairingId)
        markPairingStateChanged()
        
        if activePairingID == message.pairingId || revokedPeer?.displayName == connectedHostName || revokedPeer?.serviceName == connectedHostName {
            clearPersistedLastConnectedPeer()
            suppressAutoReconnect = true
            pendingReconnectWhenVisible = false
            pendingReconnectReason = nil
            lastConnectedHost = nil
            lastConnectedHostName = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectAttempt = 0
            didHandleDisconnectForCurrentConnection = true
            resetSession(reason: "pairing revoked")
        }
        
        isConnectBusy = false
        status = "Pairing was removed on the Mac. Re-pair to continue."
    }
    
}
