import Foundation
import CryptoKit
import Security
import WatchConnectivity
import PeelWatchCore

/// Explicit enrollment dispatch only. No identity code/token/broker bearer/private
/// key is received. Authenticated broker grants target this Watch's actual key;
/// a public route or WC reachability can never call the cloud client installation.
@MainActor
final class PeelWatchCloudEnrollment {
    static let shared = PeelWatchCloudEnrollment()
    private var pending: (provider: CloudAgentProvider, transaction: PluginRelayWatchEnrollmentTransaction, challenge: PluginRelayEnrollmentChallenge)?
    private var authorities: [CloudAgentProvider: PluginRelayVerifiedWatchAuthority] = [:]
    private var contexts: [CloudAgentProvider: PluginRelayWatchResumeContext] = [:]
    private var generations: [CloudAgentProvider: UUID] = [:]
    private var renewing: Set<CloudAgentProvider> = []

    func handle(_ data: Data, from session: WCSession) async -> Data {
        guard session === WCSession.default, session.activationState == .activated,
              session.isCompanionAppInstalled, let request = try? PluginRelayEnrollmentWire.decode(data) else { return Data() }
        do {
            let response: PluginRelayEnrollmentWire
            switch request.kind {
            case .keyRequest:
                let key = try signingKey()
                response = try .init(courierID: request.courierID, kind: .keyResponse,
                    publicKey: PluginRelayEnrollmentCrypto.base64URL(key.publicKey.derRepresentation))
            case .signChallenge:
                guard let challenge = request.challenge, let signature = request.phoneSignature else { return Data() }
                let registration = try approvedRegistration(challenge.provider)
                // Reauthentication replaces only THIS provider. Another agent's
                // authority, durable store and selected UI remain intact.
                await invalidate(challenge.provider)
                let generation = UUID(); generations[challenge.provider] = generation
                pending?.transaction.revoke()
                let transaction = try PluginRelayWatchEnrollmentTransaction(challenge: challenge, phoneSignature: signature,
                    watchKey: signingKey(), approvedClientID: registration.clientID,
                    approvedRedirectURI: registration.redirect, now: Date())
                pending = (challenge.provider, transaction, challenge)
                response = try .init(courierID: request.courierID, kind: .signatureResponse,
                    watchSignature: transaction.watchSignature, challengeID: challenge.challengeID)
            case .installGrant:
                guard let pending, let compact = request.routeGrant else { return Data() }
                self.pending = nil
                let trust = try brokerTrust(), grant = try pending.transaction.consume(compact, trust: trust, now: Date())
                let provider = pending.provider, generation = generations[provider]
                let context = try PluginRelayWatchResumeContext(issuer: trust.issuer, enrollmentID: grant.enrollmentID,
                    phoneDeviceID: grant.phoneDeviceID, fence: grant.fence,
                    phonePublicKey: pending.challenge.phonePublicKey, watchPublicKey: pending.challenge.watchPublicKey)
                try context.matches(grant)
                let next = PluginRelayVerifiedWatchAuthority(grant: grant)
                authorities[provider] = next; contexts[provider] = context
                do {
                    try saveContext(context)
                    try await install(grant: grant, authority: next)
                    guard generations[provider] == generation, authorities[provider] === next else { next.revoke(); return Data() }
                    try next.validateCurrent(grant.fence)
                } catch { next.revoke(); authorities[provider] = nil; return Data() }
                response = try .init(courierID: request.courierID, kind: .installed, grantID: grant.grantID)
            case .resumeRequest:
                guard let provider = request.provider else { return Data() }
                try await resume(provider)
                response = try .init(courierID: request.courierID, kind: .resumeAcknowledged, provider: provider)
            case .invalidate:
                guard let provider = request.provider else { return Data() }
                await invalidate(provider); response = request
            case .resumeAcknowledged, .keyResponse, .signatureResponse, .installed, .renewChallengeRequest, .renewChallenge, .renewProof, .renewed, .renewalUnavailable:
                return Data()
            }
            return try response.encoded()
        } catch { return Data() }
    }
    /// One user/foreground-triggered check. Public disk metadata grants nothing;
    /// every cold restore needs mutual fresh key proof AND a fresh pinned JWS.
    func resume(_ provider: CloudAgentProvider) async throws {
        guard !renewing.contains(provider) else { throw PluginRelayWatchCoordinatorError.busy }
        let context = try contexts[provider] ?? loadContext(provider)
        try await renew(context.fence, expected: context)
    }
    private func install(grant: PluginRelayVerifiedWatchBootstrap, authority: PluginRelayVerifiedWatchAuthority) async throws {
        try await PeelWatchCloudClient.shared.install(fence: grant.fence, authority: authority) { [weak self] fence in
            guard let self, let expected = self.contexts[fence.binding.route.provider] else { throw PluginRelayEnrollmentError.revoked }
            try await self.renew(fence, expected: expected)
        }
    }
    private func renew(_ fence: PluginRelayFence, expected: PluginRelayWatchResumeContext) async throws {
        let provider = fence.binding.route.provider
        guard expected.fence == fence, !renewing.contains(provider) else { throw PluginRelayWatchCoordinatorError.busy }
        renewing.insert(provider); defer { renewing.remove(provider) }
        let generation = generations[provider], courier = PeelWatchCloudCourier()
        let request = try PluginRelayEnrollmentWire(courierID: UUID(), kind: .renewChallengeRequest, resumeContext: expected)
        let first = try await exchange(request, courier: courier)
        guard generations[provider] == generation, first.kind == .renewChallenge,
              let challenge = first.resumeChallenge, let signature = first.phoneSignature else { throw PluginRelayEnrollmentError.expired }
        let transaction = try PluginRelayWatchResumeTransaction(challenge: challenge, phoneSignature: signature,
            expected: expected, watchKey: signingKey(), now: Date())
        let second = try await exchange(.init(courierID: UUID(), kind: .renewProof,
            watchSignature: transaction.watchSignature, challengeID: transaction.challengeID), courier: courier)
        guard generations[provider] == generation, second.kind == .renewed, let compact = second.routeGrant else { throw PluginRelayEnrollmentError.expired }
        let grant = try transaction.consume(compact, trust: brokerTrust(), now: Date())
        guard generations[provider] == generation else { throw PluginRelayEnrollmentError.revoked }
        if let authority = authorities[provider] { try authority.renew(grant) }
        else {
            let authority = PluginRelayVerifiedWatchAuthority(grant: grant)
            authorities[provider] = authority; contexts[provider] = expected
            do { try await install(grant: grant, authority: authority) }
            catch { authority.revoke(); authorities[provider] = nil; throw error }
        }
    }
    private func exchange(_ request: PluginRelayEnrollmentWire, courier: PeelWatchCloudCourier) async throws -> PluginRelayEnrollmentWire {
        let data = try await courier.exchange(request.encoded(), courierID: request.courierID)
        let response = try PluginRelayEnrollmentWire.decode(data, expectedCourierID: request.courierID)
        if response.kind == .renewalUnavailable {
            if response.renewalFailure == "revoked" { throw PluginRelayEnrollmentError.revoked }
            throw PluginRelayEnrollmentError.expired
        }
        return response
    }
    func pairedPhoneDidChange() async {
        // Close EVERY old peer synchronously before any provider's asynchronous
        // cancellation can suspend. A late Grok callback cannot survive a held
        // Dot drain after the actual paired phone changes.
        pending?.transaction.revoke(); pending = nil
        for provider in [CloudAgentProvider.dot, .grokBot] {
            generations[provider] = UUID()
            authorities.removeValue(forKey: provider)?.revoke(); contexts[provider] = nil
            try? FileManager.default.removeItem(at: contextURL(provider))
        }
        await PeelWatchCloudClient.shared.invalidate()
    }
    private func invalidate(_ provider: CloudAgentProvider) async {
        generations[provider] = UUID()
        if pending?.provider == provider { pending?.transaction.revoke(); pending = nil }
        authorities.removeValue(forKey: provider)?.revoke(); contexts[provider] = nil
        try? FileManager.default.removeItem(at: contextURL(provider))
        await PeelWatchCloudClient.shared.invalidate(provider)
    }
    private func contextURL(_ provider: CloudAgentProvider) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PeelPluginRelay", isDirectory: true).appendingPathComponent("resume-" + provider.rawValue + ".json")
    }
    private func saveContext(_ context: PluginRelayWatchResumeContext) throws {
        let url = contextURL(context.fence.binding.route.provider), data = try JSONEncoder().encode(context)
        guard data.count <= 8_192 else { throw PluginRelayEnrollmentError.invalidInput }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
    private func loadContext(_ provider: CloudAgentProvider) throws -> PluginRelayWatchResumeContext {
        let url = contextURL(provider)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, (1...8_192).contains(size.intValue) else { throw PluginRelayEnrollmentError.invalidInput }
        let context = try JSONDecoder().decode(PluginRelayWatchResumeContext.self, from: Data(contentsOf: url))
        guard context.fence.binding.route.provider == provider, context.issuer == (try brokerTrust()).issuer else { throw PluginRelayEnrollmentError.wrongPeer }
        try context.validate(); return context
    }
    private func approvedRegistration(_ provider: CloudAgentProvider) throws -> (clientID: String, redirect: String) {
        guard let all = Bundle.main.object(forInfoDictionaryKey: "PeelCloudIdentityRegistrations") as? [String: [String: String]],
              let values = all[provider.rawValue], let client = values["ClientID"], let redirect = values["RedirectURI"],
              let approval = values["ApprovalReference"], approval.utf8.count >= 8,
              values["ClientType"] == "public-native", values["TokenEndpointAuthMethod"] == "none",
              !["example", "replace", "fixture", "synthetic", "todo"].contains(where: { approval.lowercased().contains($0) }) else {
            throw PluginRelayEnrollmentError.untrustedBroker
        }
        return (client, redirect)
    }
    private func brokerTrust() throws -> PluginRelayBrokerTrust {
        guard let values = Bundle.main.object(forInfoDictionaryKey: "PeelCloudBrokerRegistration") as? [String: String],
              let origin = values["Origin"], let audience = values["Audience"], audience == Bundle.main.bundleIdentifier,
              let kid = values["KeyID"], let spki = values["PublicKeySPKI"], let approval = values["ApprovalReference"], approval.utf8.count >= 8,
              !["example", "replace", "fixture", "synthetic", "todo"].contains(where: { approval.lowercased().contains($0) }) else {
            throw PluginRelayEnrollmentError.untrustedBroker
        }
        return try .init(issuer: origin, audience: audience, keysSPKI: [kid: spki])
    }
    private func signingKey() throws -> P256.Signing.PrivateKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "Peel").watch-plugin-enrollment",
            kSecAttrAccount as String: "watch_p256_v1", kSecAttrSynchronizable as String: false]
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data { return try .init(rawRepresentation: bytes) }
        guard status == errSecItemNotFound else { throw PluginRelayEnrollmentError.invalidInput }
        let key = P256.Signing.PrivateKey()
        var item = query; item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw PluginRelayEnrollmentError.invalidInput }
        return key
    }
}
