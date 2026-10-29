import Foundation

/// Product access only. Pairing, consent, permissions, current sessions and
/// platform/resource limits are enforced separately by the owning feature.
enum PeelProductCapability: CaseIterable, Sendable {
    case appStreaming, desktopStreaming, multipleWindows, multipleHosts
    case systemAudio, duplexVoice, ordinaryInput, windowFitting
    case mcpAccess, agentCoordination, agentNotifications
    case legacyAppLauncher, customMacIcons, machineStatus, hostUtilities, manualShell
}

enum PeelCapabilityPlatform: Sendable {
    case iOS, visionOS
}

enum PeelCapabilityTier: Equatable, Sendable {
    case free
    case pro
    case unavailable
}

enum PeelCapabilityPolicy {
    static func tier(for capability: PeelProductCapability) -> PeelCapabilityTier {
        switch capability {
        case .appStreaming, .desktopStreaming, .multipleHosts,
             .systemAudio, .duplexVoice, .ordinaryInput, .windowFitting,
             .machineStatus, .hostUtilities:
            return .free
        case .multipleWindows, .mcpAccess, .agentCoordination, .agentNotifications,
             .legacyAppLauncher, .customMacIcons:
            return .pro
        case .manualShell:
            return .unavailable
        }
    }

    static func freeWindowLimit(platform: PeelCapabilityPlatform) -> Int {
        platform == .visionOS ? 2 : 1
    }

    /// Admission only: an entitlement expiring must not close existing streams.
    /// Resource and simultaneous-scene capacity remain separate constraints.
    static func canOpenAdditionalWindow(
        openWindowCount: Int,
        proAccess: Bool,
        platform: PeelCapabilityPlatform
    ) -> Bool {
        proAccess || max(0, openWindowCount) < freeWindowLimit(platform: platform)
    }

    /// The historical lifetime SKU grants the same Pro features as either
    /// subscription, without a date cutoff or new purchase requirement.
    /// An already granted, unexpired legacy trial is honored too.
    static func hasProAccess(
        legacyPurchaseAccess: Bool,
        subscription: PeelAISubscriptionState,
        now: Date
    ) -> Bool {
        legacyPurchaseAccess || coordinationExpiration(subscription: subscription, now: now) != nil
    }

    /// `subscription` must come from verified StoreKit reduction. This is a
    /// client UX policy, never proof of entitlement for a remote action server.
    static func allows(
        _ capability: PeelProductCapability,
        legacyPurchaseAccess: Bool,
        platform: PeelCapabilityPlatform,
        subscription: PeelAISubscriptionState,
        now: Date
    ) -> Bool {
        switch tier(for: capability) {
        case .free:
            return true
        case .pro:
            // Preserve the launcher/icon access already included on Vision.
            if platform == .visionOS && (capability == .legacyAppLauncher || capability == .customMacIcons) {
                return true
            }
            return hasProAccess(legacyPurchaseAccess: legacyPurchaseAccess, subscription: subscription, now: now)
        case .unavailable:
            return false // Unfinished manual shell is not a paid benefit.
        }
    }

    static func coordinationExpiration(
        subscription: PeelAISubscriptionState,
        now: Date
    ) -> Date? {
        guard case .subscribed(let expiration) = subscription, expiration > now else {
            return nil
        }
        return expiration
    }
}
