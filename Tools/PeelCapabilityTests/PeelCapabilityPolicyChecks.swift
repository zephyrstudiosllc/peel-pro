import Foundation

@main
enum PeelCapabilityPolicyChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(60)
        let active = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly", "peel.pro.yearly"],
            entitlements: [.init(productID: "peel.pro.monthly", productType: .autoRenewable,
                                 expirationDate: future)], now: now)
        let unverified = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [.init(productID: "peel.pro.monthly", productType: .autoRenewable,
                                 expirationDate: future, isVerified: false)], now: now)
        let revoked = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [.init(productID: "peel.pro.monthly", productType: .autoRenewable,
                                 expirationDate: future, revocationDate: now)], now: now)
        let unavailableStates: [PeelAISubscriptionState] = [
            .unresolved, .unavailable(.notConfigured), .unavailable(.storeKitUnavailable),
            .unavailable(.noVerifiedEntitlement), .subscribed(expirationDate: now),
            .subscribed(expirationDate: now.addingTimeInterval(-1)), unverified, revoked
        ]
        let free: [PeelProductCapability] = [
            .appStreaming, .desktopStreaming, .multipleHosts,
            .systemAudio, .duplexVoice, .ordinaryInput, .windowFitting, .machineStatus, .hostUtilities
        ]
        let paid: [PeelProductCapability] = [
            .multipleWindows, .mcpAccess, .agentCoordination, .agentNotifications,
            .legacyAppLauncher, .customMacIcons
        ]
        precondition(Set(free + paid + [.manualShell]) == Set(PeelProductCapability.allCases))

        for state in unavailableStates + [active] {
            for lifetimeOrHonoredTrial in [false, true] {
                for capability in free {
                    precondition(PeelCapabilityPolicy.tier(for: capability) == .free)
                    for platform in [PeelCapabilityPlatform.iOS, .visionOS] {
                        precondition(PeelCapabilityPolicy.allows(capability,
                            legacyPurchaseAccess: lifetimeOrHonoredTrial, platform: platform,
                            subscription: state, now: now))
                    }
                }
                precondition(!PeelCapabilityPolicy.allows(.manualShell,
                    legacyPurchaseAccess: lifetimeOrHonoredTrial, platform: .iOS,
                    subscription: state, now: now))
            }
        }
        for capability in paid {
            precondition(PeelCapabilityPolicy.tier(for: capability) == .pro)
            for state in unavailableStates {
                precondition(!PeelCapabilityPolicy.allows(capability, legacyPurchaseAccess: false,
                    platform: .iOS, subscription: state, now: now))
                precondition(PeelCapabilityPolicy.allows(capability, legacyPurchaseAccess: true,
                    platform: .iOS, subscription: state, now: now),
                    "Every lifetime buyer gets the new Pro, including offline and after a separate subscription ends")
            }
            precondition(PeelCapabilityPolicy.allows(capability, legacyPurchaseAccess: false,
                platform: .iOS, subscription: active, now: now))
            precondition(!PeelCapabilityPolicy.allows(capability, legacyPurchaseAccess: false,
                platform: .iOS, subscription: active, now: future), "Expiry is exclusive")
        }
        for capability in [PeelProductCapability.legacyAppLauncher, .customMacIcons] {
            precondition(PeelCapabilityPolicy.allows(capability, legacyPurchaseAccess: false,
                platform: .visionOS, subscription: .unresolved, now: now),
                "Preserve already free Vision utilities")
        }
        precondition(PeelCapabilityPolicy.freeWindowLimit(platform: .iOS) == 1)
        precondition(PeelCapabilityPolicy.freeWindowLimit(platform: .visionOS) == 2)
        for count in -1...12 {
            for platform in [PeelCapabilityPlatform.iOS, .visionOS] {
                let admitted = PeelCapabilityPolicy.canOpenAdditionalWindow(
                    openWindowCount: count, proAccess: false, platform: platform)
                precondition(admitted == (count < (platform == .visionOS ? 2 : 1)))
                precondition(PeelCapabilityPolicy.canOpenAdditionalWindow(
                    openWindowCount: count, proAccess: true, platform: platform))
            }
        }
        print("PeelCapabilityPolicyChecks: passed (1 flat / 2 Vision, unified Pro, grandfathered lifetime, free basics)")
    }
}
