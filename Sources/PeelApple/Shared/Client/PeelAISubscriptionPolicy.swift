//
//  PeelAISubscriptionPolicy.swift
//  Peel
//
//  Pure entitlement policy for the monthly and annual Peel Pro subscriptions.
//  This file intentionally has no StoreKit, account, network, or persistence
//  dependency so its fail-closed rules can be exercised with synthetic data.
//

import Foundation

enum PeelAISubscriptionProductType: Equatable, Sendable {
    case autoRenewable
    case nonRenewable
    case consumable
    case nonConsumable
    case unknown
}

struct PeelAISubscriptionEntitlement: Equatable, Sendable {
    let productID: String
    let productType: PeelAISubscriptionProductType
    let expirationDate: Date?
    let revocationDate: Date?
    let isVerified: Bool
    let transactionID: UInt64?
    let isFamilyShared: Bool
    let isUpgraded: Bool
    /// Supplied only after verifying both the matching status transaction and
    /// renewal info while StoreKit reports billing grace period.
    let gracePeriodExpirationDate: Date?

    init(
        productID: String,
        productType: PeelAISubscriptionProductType,
        expirationDate: Date?,
        revocationDate: Date? = nil,
        isVerified: Bool = true,
        transactionID: UInt64? = nil,
        isFamilyShared: Bool = false,
        isUpgraded: Bool = false,
        gracePeriodExpirationDate: Date? = nil
    ) {
        self.productID = productID
        self.productType = productType
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isVerified = isVerified
        self.transactionID = transactionID
        self.isFamilyShared = isFamilyShared
        self.isUpgraded = isUpgraded
        self.gracePeriodExpirationDate = gracePeriodExpirationDate
    }

    var effectiveExpirationDate: Date? {
        guard isVerified, productType == .autoRenewable,
              revocationDate == nil, !isUpgraded,
              let expirationDate else { return nil }
        return max(expirationDate, gracePeriodExpirationDate ?? expirationDate)
    }

    func isActive(at date: Date) -> Bool {
        effectiveExpirationDate.map { $0 > date } ?? false
    }
}

enum PeelAISubscriptionUnavailableReason: Equatable, Sendable {
    case notConfigured
    case noVerifiedEntitlement
    case expiredOrRevoked
    case noAutoRenewableProduct
    case storeKitUnavailable

    var userMessage: String {
        switch self {
        case .notConfigured:
            return "Subscriptions are not configured in this build"
        case .noVerifiedEntitlement:
            return "No active Peel Pro subscription"
        case .expiredOrRevoked:
            return "The Peel Pro subscription is expired or revoked"
        case .noAutoRenewableProduct:
            return "No auto-renewable Peel Pro subscription is available"
        case .storeKitUnavailable:
            return "Peel Pro subscriptions are temporarily unavailable"
        }
    }
}

enum PeelAISubscriptionState: Equatable, Sendable {
    case unresolved
    case subscribed(expirationDate: Date)
    case unavailable(PeelAISubscriptionUnavailableReason)

    var isSubscribed: Bool {
        if case .subscribed = self {
            return true
        }
        return false
    }

    var userMessage: String {
        switch self {
        case .unresolved:
            return "Checking Peel Pro subscription status"
        case .subscribed(let expirationDate):
            return "Peel Pro subscription active through \(expirationDate.formatted(date: .abbreviated, time: .shortened))"
        case .unavailable(let reason):
            return reason.userMessage
        }
    }
}

enum PeelAISubscriptionPolicy {
    static func reduce(
        configuredProductIDs: [String],
        entitlements: [PeelAISubscriptionEntitlement],
        now: Date
    ) -> PeelAISubscriptionState {
        let configuredIDs = Set(
            configuredProductIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        guard !configuredIDs.isEmpty else {
            return .unavailable(.notConfigured)
        }

        let matchingEntitlements = entitlements.filter {
            configuredIDs.contains($0.productID)
        }

        guard !matchingEntitlements.isEmpty else {
            return .unavailable(.noVerifiedEntitlement)
        }

        let verifiedEntitlements = matchingEntitlements.filter(\.isVerified)

        guard !verifiedEntitlements.isEmpty else {
            return .unavailable(.noVerifiedEntitlement)
        }

        let activeExpirations = verifiedEntitlements
            .filter { $0.isActive(at: now) }
            .compactMap(\.effectiveExpirationDate)

        if let expirationDate = activeExpirations.max() {
            return .subscribed(expirationDate: expirationDate)
        }

        if verifiedEntitlements.contains(where: { $0.productType == .autoRenewable }) {
            return .unavailable(.expiredOrRevoked)
        }

        return .unavailable(.noAutoRenewableProduct)
    }
}
