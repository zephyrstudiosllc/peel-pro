//
//  DiscoveryDelegates.swift
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

// MARK: - NetServiceBrowserDelegate / NetServiceDelegate

extension PeelClientBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async {
            self.status = "Searching for hosts…"
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self

        let hostInfo = PeelHostInfo(name: service.name, service: service, hostId: parseHostId(from: service))
        serviceToHost[service] = hostInfo

        // Do not add to `hosts` here. A found Bonjour service is only "nearby"
        // after it successfully resolves.
        DispatchQueue.main.async {
            self.status = "Resolving \(service.name)…"
        }

        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        let mappedHostInfo = serviceToHost.removeValue(forKey: service)

        DispatchQueue.main.async {
            let hostInfo = mappedHostInfo ?? self.hosts.first { self.serviceMatches($0, service: service) }

            guard let hostInfo else {
                self.hosts.removeAll { self.serviceMatches($0, service: service) }
                self.status = "Found \(self.hosts.count) host(s)."
                return
            }

            let activeSession = self.sessionMatching(hostInfo)
            let hasLiveSession = activeSession.map { session in
                session.connection != nil || session.isConnectionReady || session.isConnectBusy
            } ?? false

            let hasLegacyLiveConnection =
                (self.connection != nil || self.isConnectionReady || self.isConnectBusy) &&
                (self.connectedHostName == hostInfo.name || self.selectedHostKey == hostInfo.hostKey)

            // Bonjour disappearance is not transport death. A listener can withdraw/republish
            // while the established NWConnection is still valid. Only the NWConnection state
            // machine should decide that a socket is dead.
            if !hasLiveSession && !hasLegacyLiveConnection {
                self.removeDiscoveredHost(hostInfo)
            }

            if self.shouldAutoReconnect(to: hostInfo), !self.suppressAutoReconnect {
                self.pendingReconnectWhenVisible = true
                if self.pendingReconnectReason == nil {
                    self.pendingReconnectReason = "host disappeared"
                }

                activeSession?.pendingReconnectWhenVisible = true
                if activeSession?.pendingReconnectReason == nil {
                    activeSession?.pendingReconnectReason = "host disappeared"
                }

                if !hasLiveSession && !hasLegacyLiveConnection {
                    self.isConnectBusy = false
                    self.status = "Host '\(hostInfo.name)' offline. Waiting…"
                    self.restartDiscoveryAfterHostDrop(reason: "host disappeared")
                    return
                }
            }

            if !hasLiveSession && !hasLegacyLiveConnection {
                self.status = "Found \(self.hosts.count) host(s)."
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let hid = parseHostId(from: sender)
        let resolvedHost = PeelHostInfo(name: sender.name, service: sender, hostId: hid)
        serviceToHost[sender] = resolvedHost

        DispatchQueue.main.async {
            self.upsertResolvedHost(resolvedHost)
            self.status = "Found \(self.hosts.count) host(s)."

            if let pairingResolveService = self.pairingResolveService,
               pairingResolveService === sender,
               let pendingPairHost = self.pendingPairHost,
               self.serviceMatches(pendingPairHost, service: sender),
               let pin = self.pendingPairPIN {
                pairingResolveService.stop()
                self.pairingResolveService = nil
                self.continuePairWithPIN(host: resolvedHost, pin: pin)
                return
            }


            if let pendingSession = self.pendingConnectSession(matching: sender) {
                pendingSession.resolveTimeoutWorkItem?.cancel()
                pendingSession.resolveTimeoutWorkItem = nil
                pendingSession.pendingConnectHost = nil
                let auto = pendingSession.pendingConnectIsAutoReconnect
                pendingSession.pendingConnectIsAutoReconnect = false
                pendingSession.updateHost(resolvedHost)
                pendingSession.connectAndRequestWindows(isAutoReconnect: auto, skipResolve: true)
                return
            }

            // If the user tapped Connect before the service finished resolving,
            // finish the connect with the freshly resolved host so we do not reuse
            // stale NetService address/port state from the pre-resolve value.
            if let pending = self.pendingConnectHost,
               self.serviceMatches(pending, service: sender) {
                self.resolveTimeoutWorkItem?.cancel()
                self.resolveTimeoutWorkItem = nil
                self.pendingConnectHost = nil
                let auto = self.pendingConnectIsAutoReconnect
                self.pendingConnectIsAutoReconnect = false
                self.connectAndRequestWindows(for: resolvedHost, isAutoReconnect: auto, skipResolve: true)
                return
            }

            let existingSession = self.sessionsByHostKey[resolvedHost.hostKey]
            if let existingSession,
               existingSession.connection != nil || existingSession.isConnectionReady || existingSession.isConnectBusy {
                return
            }

            self.status = "Resolved \(sender.name)"
            if !self.suppressAutoReconnect,
               self.pendingConnectHost == nil,
               self.shouldAutoReconnect(to: resolvedHost) {
                self.pendingReconnectWhenVisible = false
                let reason = self.pendingReconnectReason ?? "host resolved"
                self.pendingReconnectReason = nil
                self.status = "Reconnecting to \(resolvedHost.name)…"
                self.connectAndRequestWindows(for: resolvedHost, isAutoReconnect: true, skipResolve: sender.hostName != nil && sender.port > 0)
                print("🔁 Reconnect triggered after resolve: \(resolvedHost.name) (\(reason))")
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        if let pendingHost = pendingPairHost,
           serviceMatches(pendingHost, service: sender) {
            markDiscoveredHostStaleAndRefresh(pendingHost, reason: "pair resolve failed")
            resetPairingAttempt(
                reason: "Pair resolve failed",
                status: "Failed to resolve \(sender.name) for pairing: \(errorDict)"
            )
            return
        }


        if let pendingSession = pendingConnectSession(matching: sender) {
            let pendingHost = pendingSession.pendingConnectHost ?? pendingSession.host
            pendingSession.resolveTimeoutWorkItem?.cancel()
            pendingSession.resolveTimeoutWorkItem = nil
            pendingSession.pendingConnectHost = nil
            pendingSession.pendingConnectIsAutoReconnect = false
            markDiscoveredHostStaleAndRefresh(pendingHost, reason: "resolve failed")

            DispatchQueue.main.async {
                pendingSession.isConnectBusy = false
                pendingSession.status = "Failed to resolve \(sender.name). Looking for it again…"

                if self.selectedHostKey == pendingSession.hostKey {
                    self.isConnectBusy = false
                    self.status = pendingSession.status
                }

                pendingSession.scheduleReconnect(reason: "resolve failed")
            }
            return
        }

        if let pending = pendingConnectHost,
           serviceMatches(pending, service: sender) {
            resolveTimeoutWorkItem?.cancel()
            resolveTimeoutWorkItem = nil
            pendingConnectHost = nil
            pendingConnectIsAutoReconnect = false
            markDiscoveredHostStaleAndRefresh(pending, reason: "resolve failed")

            DispatchQueue.main.async {
                self.isConnectBusy = false
                self.status = "Failed to resolve \(sender.name). Looking for it again…"
                self.scheduleReconnect(reason: "resolve failed")
            }
            return
        }

        let knownHost = serviceToHost.removeValue(forKey: sender)

        DispatchQueue.main.async {
            let hostInfo = knownHost ?? self.hosts.first { self.serviceMatches($0, service: sender) }

            if let hostInfo {
                self.markDiscoveredHostStaleAndRefresh(hostInfo, reason: "resolve failed")
            } else {
                self.restartDiscoveryAfterHostDrop(reason: "resolve failed")
            }

            self.status = "Failed to resolve \(sender.name). Looking for hosts again…"
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String : NSNumber]) {
        print("❌ NetServiceBrowser didNotSearch:", errorDict)
        DispatchQueue.main.async {
            self.status = "Browse failed: \(errorDict)"
        }
    }
}

private extension PeelClientBrowser {
    func pendingConnectSession(matching service: NetService) -> PeelHostSession? {
        let matches = sessionsByHostKey.values.filter { session in
            guard let pendingHost = session.pendingConnectHost else { return false }
            return serviceMatches(pendingHost, service: service) || serviceMatches(session.host, service: service)
        }

        return matches.sorted { lhs, rhs in
            if lhs.hostKey == selectedHostKey { return true }
            if rhs.hostKey == selectedHostKey { return false }
            if lhs.pendingConnectIsAutoReconnect != rhs.pendingConnectIsAutoReconnect {
                return lhs.pendingConnectIsAutoReconnect == false
            }
            return lhs.host.name.localizedCaseInsensitiveCompare(rhs.host.name) == .orderedAscending
        }.first
    }

    func sessionMatching(_ host: PeelHostInfo) -> PeelHostSession? {
        if let direct = sessionsByHostKey[host.hostKey] {
            return direct
        }

        if let hostId = host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty {
            return sessionsByHostKey.values.first { session in
                guard !session.isUsingDirectEndpoint else { return false }
                guard let sessionHostId = session.host.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sessionHostId.isEmpty else {
                    return false
                }
                return sessionHostId == hostId
            }
        }

        return sessionsByHostKey.values.first { session in
            guard !session.isUsingDirectEndpoint else { return false }
            return session.host.name == host.name || session.host.service.name == host.service.name
        }
    }

    func serviceMatches(_ host: PeelHostInfo, service: NetService) -> Bool {
        if host.service == service { return true }
        if host.service.name == service.name { return true }
        if host.name == service.name { return true }

        let serviceHostId = parseHostId(from: service)
        if let serviceHostId,
           let hostId = host.hostId,
           !serviceHostId.isEmpty,
           !hostId.isEmpty,
           serviceHostId == hostId {
            return true
        }

        return false
    }

    func upsertResolvedHost(_ host: PeelHostInfo) {
        if let idx = hosts.firstIndex(where: { existing in
            if let existingHostId = existing.hostId,
               let newHostId = host.hostId,
               !existingHostId.isEmpty,
               !newHostId.isEmpty {
                return existingHostId == newHostId
            }

            return existing.name == host.name || existing.service.name == host.service.name
        }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
    }

    func removeResolvedHost(_ host: PeelHostInfo) {
        hosts.removeAll { candidate in
            if let removedHostId = host.hostId,
               let candidateHostId = candidate.hostId,
               !removedHostId.isEmpty,
               !candidateHostId.isEmpty {
                return removedHostId == candidateHostId
            }

            return candidate.name == host.name || candidate.service.name == host.service.name
        }
    }
}
