import Foundation

@main
enum PeelAISubscriptionPolicyChecks {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() {
        missingConfigurationIsUnavailable()
        activeVerifiedAutoRenewableSubscriptionIsGranted()
        latestActiveExpirationWins()
        expiredAndRevokedSubscriptionsAreUnavailable()
        unverifiedAndNonSubscriptionTransactionsDoNotGrantSubscription()
        nonAutoRenewableTransactionsDoNotGrantSubscription()
        missingExpirationFailsClosed()
        familySharingUsesTheSameVerifiedRules()
        billingGraceIsBoundedAndRevocationWins()
        upgradedTransactionDoesNotDoubleGrant()
        print("PeelAISubscriptionPolicyChecks: passed")
    }

    private static func missingConfigurationIsUnavailable() {
        let state = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: [],
            entitlements: [fixture(type: .autoRenewable, expiration: 1_900_000_000)],
            now: now
        )

        precondition(state == .unavailable(.notConfigured))
    }

    private static func activeVerifiedAutoRenewableSubscriptionIsGranted() {
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        let state = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [fixture(type: .autoRenewable, expiration: expiration.timeIntervalSince1970)],
            now: now
        )

        precondition(state == .subscribed(expirationDate: expiration))
    }

    private static func latestActiveExpirationWins() {
        let earlier = Date(timeIntervalSince1970: 1_850_000_000)
        let later = Date(timeIntervalSince1970: 1_950_000_000)
        let state = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly", "peel.pro.yearly"],
            entitlements: [
                fixture(id: "peel.pro.monthly", type: .autoRenewable, expiration: earlier.timeIntervalSince1970),
                fixture(id: "peel.pro.yearly", type: .autoRenewable, expiration: later.timeIntervalSince1970)
            ],
            now: now
        )

        precondition(state == .subscribed(expirationDate: later))
    }

    private static func expiredAndRevokedSubscriptionsAreUnavailable() {
        let expired = fixture(type: .autoRenewable, expiration: 1_700_000_000)
        let revoked = fixture(
            type: .autoRenewable,
            expiration: 1_900_000_000,
            revocation: Date(timeIntervalSince1970: 1_750_000_000)
        )

        precondition(
            PeelAISubscriptionPolicy.reduce(
                configuredProductIDs: ["peel.pro.monthly"],
                entitlements: [expired],
                now: now
            ) == .unavailable(.expiredOrRevoked)
        )
        precondition(
            PeelAISubscriptionPolicy.reduce(
                configuredProductIDs: ["peel.pro.monthly"],
                entitlements: [revoked],
                now: now
            ) == .unavailable(.expiredOrRevoked)
        )
    }

    private static func unverifiedAndNonSubscriptionTransactionsDoNotGrantSubscription() {
        let unverified = fixture(
            type: .autoRenewable,
            expiration: 1_900_000_000,
            verified: false
        )
        let lifetime = fixture(
            id: "peel.pro.lifetime",
            type: .nonConsumable,
            expiration: nil
        )

        let state = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [unverified, lifetime],
            now: now
        )

        precondition(state == .unavailable(.noVerifiedEntitlement))
    }

    private static func nonAutoRenewableTransactionsDoNotGrantSubscription() {
        let nonRenewable = fixture(
            type: .nonRenewable,
            expiration: 1_900_000_000
        )
        let consumable = fixture(
            id: "peel.ai.credits",
            type: .consumable,
            expiration: nil
        )

        let state = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly", "peel.ai.credits"],
            entitlements: [nonRenewable, consumable],
            now: now
        )

        precondition(state == PeelAISubscriptionState.unavailable(.noAutoRenewableProduct))
    }

    private static func missingExpirationFailsClosed() {
        let state = PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [fixture(type: .autoRenewable, expiration: nil)],
            now: now
        )

        precondition(state == .unavailable(.expiredOrRevoked))
    }

    private static func familySharingUsesTheSameVerifiedRules() {
        for id in ["peel.pro.monthly", "peel.pro.yearly"] {
            let family = PeelAISubscriptionEntitlement(productID: id, productType: .autoRenewable,
                expirationDate: now.addingTimeInterval(60), isFamilyShared: true)
            precondition(PeelAISubscriptionPolicy.reduce(configuredProductIDs: [id],
                entitlements: [family], now: now) == .subscribed(expirationDate: now.addingTimeInterval(60)))
            let revokedFamily = PeelAISubscriptionEntitlement(productID: id, productType: .autoRenewable,
                expirationDate: now.addingTimeInterval(60), revocationDate: now, isFamilyShared: true)
            precondition(PeelAISubscriptionPolicy.reduce(configuredProductIDs: [id],
                entitlements: [revokedFamily], now: now) == .unavailable(.expiredOrRevoked))
        }
    }

    private static func billingGraceIsBoundedAndRevocationWins() {
        let graceEnd = now.addingTimeInterval(60)
        let grace = PeelAISubscriptionEntitlement(productID: "peel.pro.monthly", productType: .autoRenewable,
            expirationDate: now.addingTimeInterval(-60), gracePeriodExpirationDate: graceEnd)
        precondition(PeelAISubscriptionPolicy.reduce(configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [grace], now: now) == .subscribed(expirationDate: graceEnd))
        precondition(PeelAISubscriptionPolicy.reduce(configuredProductIDs: ["peel.pro.monthly"],
            entitlements: [grace], now: graceEnd) == .unavailable(.expiredOrRevoked))
        let revoked = PeelAISubscriptionEntitlement(productID: "peel.pro.monthly", productType: .autoRenewable,
            expirationDate: now.addingTimeInterval(-60), revocationDate: now,
            gracePeriodExpirationDate: graceEnd)
        precondition(!revoked.isActive(at: now))
        let unverified = PeelAISubscriptionEntitlement(productID: "peel.pro.monthly", productType: .autoRenewable,
            expirationDate: now.addingTimeInterval(-60), isVerified: false,
            gracePeriodExpirationDate: graceEnd)
        precondition(!unverified.isActive(at: now))
    }

    private static func upgradedTransactionDoesNotDoubleGrant() {
        let upgraded = PeelAISubscriptionEntitlement(productID: "peel.pro.monthly", productType: .autoRenewable,
            expirationDate: now.addingTimeInterval(60), isUpgraded: true)
        precondition(!upgraded.isActive(at: now))
    }

    private static func fixture(
        id: String = "peel.pro.monthly",
        type: PeelAISubscriptionProductType,
        expiration: TimeInterval?,
        revocation: Date? = nil,
        verified: Bool = true
    ) -> PeelAISubscriptionEntitlement {
        PeelAISubscriptionEntitlement(
            productID: id,
            productType: type,
            expirationDate: expiration.map(Date.init(timeIntervalSince1970:)),
            revocationDate: revocation,
            isVerified: verified
        )
    }
}
