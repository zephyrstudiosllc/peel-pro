//
//  PeelStore.swift
//  Peel
//
//  Created by Zach on 3/10/26.
//


//
//  PeelStore.swift
//  PeelShared
//
//  Shared by iPad + visionOS targets
//

import Foundation
import StoreKit
import Combine
import SwiftUI

@MainActor
final class PeelStore: ObservableObject {
    enum ProductID {
        static let trial = "peel.pro.3day.freetrial"
        // Keep the existing SKU so every prior lifetime buyer restores full Pro.
        static let lifetime = "peel.pro.lifetime"
        static let monthly = "peel.pro.monthly"
        static let yearly = "peel.pro.yearly"
    }

    private static let cachedLifetimeUnlockKey = "PeelStore.cachedLifetimeUnlock"
    private static let legacyPurchaseRecordKey = "PeelStore.legacyPurchaseRecord"
    private static let aiSubscriptionProductIDsInfoKey = "PeelAISubscriptionProductIDs"
    /// Contains no receipt or transaction metadata. Observers retire the current
    /// Mac proof operation synchronously before this StoreKit update yields.
    static let proEvidenceDidChangeNotification = Notification.Name("PeelStoreProEvidenceDidChange")
    private static var proEvidenceGeneration: UInt64 = 0

    @Published private(set) var products: [Product] = []
    @Published private(set) var trialProduct: Product?
    @Published private(set) var lifetimeProduct: Product?

    @Published private(set) var aiSubscriptionProducts: [Product] = []
    @Published private(set) var aiSubscriptionState: PeelAISubscriptionState = .unresolved

    @Published private(set) var hasLifetimeUnlock: Bool = false
    @Published private(set) var hasStartedTrial: Bool = false
    @Published private(set) var isTrialActive: Bool = false
    @Published private(set) var trialExpirationDate: Date?
    @Published private(set) var hasResolvedAccessState: Bool = false

    @Published var isLoadingProducts: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var isRestoring: Bool = false
    @Published var purchaseErrorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var aiSubscriptionExpirationTask: Task<Void, Never>?
    private var trialExpirationTask: Task<Void, Never>?
    // A suspended refresh must not regrant an explicitly revoked transaction.
    private var revokedSubscriptionTransactionIDs: Set<UInt64> = []
    private var entitlementRefreshGeneration: UInt64 = 0
    private var hasStarted = false
    private var legacyPurchaseState: PeelLegacyPurchaseState

    init() {
        legacyPurchaseState = PeelLegacyPurchasePolicy.restoredState(
            from: UserDefaults.standard.data(forKey: Self.legacyPurchaseRecordKey),
            legacyCachedLifetimeUnlock: UserDefaults.standard.bool(forKey: Self.cachedLifetimeUnlockKey))
        hasLifetimeUnlock = legacyPurchaseState.cachedLifetimeUnlock
        publishProFeatureAccess()
    }

    private let trialDuration: TimeInterval = 3 * 24 * 60 * 60

    /// Previous lifetime purchases and still-active trials retain all Pro
    /// software features, including those added after the original purchase.
    var hasLegacyPurchaseAccess: Bool {
        hasLifetimeUnlock || (isTrialActive && (trialExpirationDate.map { $0 > Date() } ?? false))
    }

    var hasProAccess: Bool {
        PeelCapabilityPolicy.hasProAccess(legacyPurchaseAccess: hasLegacyPurchaseAccess,
                                          subscription: aiSubscriptionState, now: Date())
    }

    private var capabilityPlatform: PeelCapabilityPlatform {
#if os(visionOS)
        .visionOS
#else
        .iOS
#endif
    }

    var freeWindowLimit: Int {
        PeelCapabilityPolicy.freeWindowLimit(platform: capabilityPlatform)
    }

    func canOpenAdditionalWindow(openWindowCount: Int) -> Bool {
        PeelCapabilityPolicy.canOpenAdditionalWindow(openWindowCount: openWindowCount,
                                                     proAccess: hasProAccess,
                                                     platform: capabilityPlatform)
    }

    func canUse(_ capability: PeelProductCapability) -> Bool {
        return PeelCapabilityPolicy.allows(
            capability,
            legacyPurchaseAccess: hasLegacyPurchaseAccess,
            platform: capabilityPlatform,
            subscription: aiSubscriptionState,
            now: Date()
        )
    }

    var aiSubscriptionProductIDs: [String] {
        Self.configuredAISubscriptionProductIDs()
    }

    var hasAISubscription: Bool {
        if case .subscribed(let expiration) = aiSubscriptionState { return expiration > Date() }
        return false
    }

    deinit {
        updatesTask?.cancel()
        aiSubscriptionExpirationTask?.cancel()
        trialExpirationTask?.cancel()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        hasResolvedAccessState = false
        setAISubscriptionState(aiSubscriptionProductIDs.isEmpty
            ? .unavailable(.notConfigured)
            : .unresolved)

        // Listen before the first await so unfinished/external transactions
        // cannot arrive during startup without a listener.
        observeTransactionUpdates()
        await requestProducts()
        await refreshEntitlements()
        hasResolvedAccessState = true
    }

    func requestProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            // The old trial is restore-only; it is not a new offer.
            let storeProducts = try await Product.products(for: [ProductID.lifetime])

            products = storeProducts.sorted { $0.id < $1.id }
            trialProduct = storeProducts.first(where: { $0.id == ProductID.trial })
            lifetimeProduct = storeProducts.first(where: { $0.id == ProductID.lifetime })
        } catch {
            purchaseErrorMessage = "Failed to load purchases: \(error.localizedDescription)"
        }

        await requestAISubscriptionProducts()
    }

    func purchaseTrial(using purchaseAction: PurchaseAction? = nil) async {
        purchaseErrorMessage = "The previous trial is no longer offered. Existing trials can be restored."
    }

    func purchaseLifetime(using purchaseAction: PurchaseAction? = nil) async {
        guard let product = lifetimeProduct else {
            purchaseErrorMessage = "Lifetime product not loaded."
            return
        }

        guard product.type == .nonConsumable, !hasLifetimeUnlock else { return }
        await purchase(product, using: purchaseAction)
    }

    func purchaseAISubscription(_ product: Product, using purchaseAction: PurchaseAction? = nil) async {
        guard !hasLifetimeUnlock else {
            purchaseErrorMessage = "Your lifetime purchase already includes all Peel Pro features."
            return
        }
        let configuredIDs = Set(aiSubscriptionProductIDs)

        guard !configuredIDs.isEmpty else {
            setAISubscriptionState(.unavailable(.notConfigured))
            return
        }

        guard configuredIDs.contains(product.id),
              product.type == .autoRenewable,
              aiSubscriptionProducts.contains(where: { $0.id == product.id }) else {
            purchaseErrorMessage = "Subscription product is unavailable."
            return
        }

        await purchase(product, using: purchaseAction)
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseErrorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func purchase(_ product: Product, using purchaseAction: PurchaseAction? = nil) async {
        guard !isPurchasing else { return }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result: Product.PurchaseResult

            #if os(visionOS)
            guard let purchaseAction else {
                purchaseErrorMessage = "Purchase action unavailable on visionOS."
                return
            }
            result = try await purchaseAction(product)
            #else
            if let purchaseAction {
                result = try await purchaseAction(product)
            } else {
                result = try await product.purchase()
            }
            #endif

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                applyVerifiedTransactionUpdate(transaction)
                await transaction.finish()
                await refreshEntitlements()

            case .userCancelled:
                break

            case .pending:
                purchaseErrorMessage = "Purchase is pending approval."

            @unknown default:
                purchaseErrorMessage = "Unknown purchase result."
            }
        } catch {
            purchaseErrorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func clearError() {
        purchaseErrorMessage = nil
    }

    private func observeTransactionUpdates() {
        guard updatesTask == nil else { return }

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.checkVerified(update)
                    // Commit verified revocation before yielding to finish or
                    // another refresh. Missing current entitlements are not proof.
                    self.applyVerifiedTransactionUpdate(transaction)
                    await transaction.finish()
                    await self.refreshEntitlements()
                } catch {
                    await MainActor.run {
                        self.purchaseErrorMessage = "Transaction verification failed."
                    }
                }
            }
        }
    }

    /// Read-only StoreKit evidence for an authenticated, short-lived Host
    /// challenge. A cached lifetime flag is UX state and is never proof. This
    /// does not purchase, restore, sync, finish transactions or prompt accounts.
    /// Only Apple's verified result supplies the JWS; its payload is not an
    /// assertion of peer identity and the Host still verifies with its authority.
    static func signedProTransactionEvidence(
        isCurrent: @MainActor () -> Bool
    ) async -> [String]? {
        let generation = proEvidenceGeneration
        func current() -> Bool { isCurrent() && generation == proEvidenceGeneration }
        guard current(), !Task.isCancelled else { return nil }
        var selection = PeelProEvidenceSelection()
        for await result in Transaction.currentEntitlements {
            guard current(), !Task.isCancelled else { return nil }
            if let evidence = verifiedProEvidence(result) { selection.include(evidence) }
        }
        guard current(), !Task.isCancelled else { return nil }
        // currentEntitlements omits refunded/revoked products. Look up all four
        // fixed SKUs so a verified latest revocation can reach the authority.
        // Missing/unverified results supply no evidence and never unlock a Mac.
        for productID in PeelProEvidenceLimits.productIDs {
            guard current(), !Task.isCancelled else { return nil }
            let latest = await Transaction.latest(for: productID)
            guard current(), !Task.isCancelled else { return nil }
            if let latest, let evidence = verifiedProEvidence(latest) { selection.include(evidence) }
        }
        guard current(), !Task.isCancelled else { return nil }
        return selection.signedTransactions
    }

    private static func verifiedProEvidence(
        _ result: VerificationResult<StoreKit.Transaction>
    ) -> PeelVerifiedProTransactionEvidence? {
        guard case .verified(let transaction) = result,
              PeelProEvidenceLimits.productIDs.contains(transaction.productID) else { return nil }
        switch transaction.productID {
        case ProductID.lifetime, ProductID.trial:
            guard transaction.productType == .nonConsumable else { return nil }
        case ProductID.monthly, ProductID.yearly:
            guard transaction.productType == .autoRenewable else { return nil }
        default: return nil
        }
        // VerificationResult<Transaction>.jwsRepresentation is Apple's signed
        // compact JWS. Transaction.jsonRepresentation is not signed evidence.
        return PeelVerifiedProTransactionEvidence(productID: transaction.productID,
            transactionID: transaction.id, purchaseDate: transaction.purchaseDate,
            revocationDate: transaction.revocationDate, signedTransaction: result.jwsRepresentation)
    }

    func refreshEntitlements() async {
        entitlementRefreshGeneration &+= 1
        let generation = entitlementRefreshGeneration
        purchaseErrorMessage = nil

        var lifetimeEvidence: [PeelLegacyPurchaseEvidence] = []
        var trialTransactionDate: Date?
        var aiEntitlements: [PeelAISubscriptionEntitlement] = []
        let configuredAIIDs = Set(aiSubscriptionProductIDs)

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                switch transaction.productID {
                case ProductID.lifetime:
                    lifetimeEvidence.append(legacyEvidence(for: transaction))

                case ProductID.trial:
                    if transaction.productType == .nonConsumable, transaction.revocationDate == nil {
                        trialTransactionDate = transaction.purchaseDate
                    }

                default:
                    if configuredAIIDs.contains(transaction.productID) {
                        aiEntitlements.append(await subscriptionEvidence(for: transaction))
                    }
                    break
                }
            } catch {
                // Ignore unverified transactions.
            }
        }

        // Refunded/revoked products are absent from currentEntitlements.
        // A verified latest transaction can supply explicit revocation at launch
        // or restore. Nil/unverified results preserve existing offline ownership.
        if let latest = await Transaction.latest(for: ProductID.lifetime),
           case .verified(let transaction) = latest {
            lifetimeEvidence.append(legacyEvidence(for: transaction))
        }
        // Another refresh or verified update may have replaced this snapshot
        // while StoreKit was suspended. Never reapply stale trial/subscription
        // access after a newer revocation, purchase or renewal.
        guard generation == entitlementRefreshGeneration else { return }
        reconcileLegacyPurchases(lifetimeEvidence)
        hasStartedTrial = trialTransactionDate != nil

        if let startDate = trialTransactionDate {
            let expiration = startDate.addingTimeInterval(trialDuration)
            trialExpirationDate = expiration
            isTrialActive = Date() < expiration
        } else {
            trialExpirationDate = nil
            isTrialActive = false
        }
        scheduleTrialExpiration()
        setAISubscriptionState(PeelAISubscriptionPolicy.reduce(
            configuredProductIDs: aiSubscriptionProductIDs,
            entitlements: aiEntitlements.filter {
                $0.transactionID.map { !revokedSubscriptionTransactionIDs.contains($0) } ?? false
            },
            now: Date()
        ))
        hasResolvedAccessState = true
    }

    /// A verified revocation takes effect before the next asynchronous refresh.
    private func applyVerifiedTransactionUpdate(_ transaction: StoreKit.Transaction) {
        if PeelProEvidenceLimits.productIDs.contains(transaction.productID) {
            Self.proEvidenceGeneration &+= 1
        }
        entitlementRefreshGeneration &+= 1
        reconcileLegacyPurchases([legacyEvidence(for: transaction)])
        if transaction.productID == ProductID.trial, transaction.revocationDate != nil {
            isTrialActive = false
            trialExpirationDate = nil
            trialExpirationTask?.cancel()
            publishProFeatureAccess()
        }
        if aiSubscriptionProductIDs.contains(transaction.productID), transaction.revocationDate != nil {
            revokedSubscriptionTransactionIDs.insert(transaction.id)
            setAISubscriptionState(.unavailable(.expiredOrRevoked))
        }
        if PeelProEvidenceLimits.productIDs.contains(transaction.productID) {
            // This function never suspends. Withdraw before finish/refresh can
            // await, then send Hello using the just-applied local UX state.
            NotificationCenter.default.post(name: Self.proEvidenceDidChangeNotification, object: nil)
        }
    }

    /// Family-shared transactions use the same verified entitlement path as
    /// purchases. Grace requires the matching signed transaction and renewal
    /// info; a billing-retry state alone never extends software access.
    private func subscriptionEvidence(for transaction: StoreKit.Transaction) async -> PeelAISubscriptionEntitlement {
        var graceExpiration: Date?
        if transaction.expirationDate.map({ $0 <= Date() }) == true,
           let status = await transaction.subscriptionStatus,
           status.state == .inGracePeriod,
           case .verified(let statusTransaction) = status.transaction,
           statusTransaction.id == transaction.id,
           statusTransaction.revocationDate == nil,
           case .verified(let renewalInfo) = status.renewalInfo {
            graceExpiration = renewalInfo.gracePeriodExpirationDate
        }
        return PeelAISubscriptionEntitlement(
            productID: transaction.productID,
            productType: Self.aiProductType(from: transaction.productType),
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isVerified: true,
            transactionID: transaction.id,
            isFamilyShared: transaction.ownershipType == .familyShared,
            isUpgraded: transaction.isUpgraded,
            gracePeriodExpirationDate: graceExpiration
        )
    }

    /// Called only with StoreKit transactions that passed verification above.
    private func legacyEvidence(for transaction: StoreKit.Transaction) -> PeelLegacyPurchaseEvidence {
        PeelLegacyPurchaseEvidence(
            productID: transaction.productID,
            transactionID: transaction.id,
            isNonConsumable: transaction.productType == .nonConsumable,
            revocationDate: transaction.revocationDate,
            isVerified: true
        )
    }

    private func reconcileLegacyPurchases(_ evidence: [PeelLegacyPurchaseEvidence]) {
        let next = PeelLegacyPurchasePolicy.reconcile(
            legacyPurchaseState, evidence: evidence, lifetimeProductID: ProductID.lifetime)
        guard next != legacyPurchaseState else { return }
        legacyPurchaseState = next
        // One record holds ownership and minimal transaction IDs together.
        // No receipt, account token or credential is persisted here. The old
        // Boolean is a compatibility fallback; a valid new record takes priority.
        if let record = try? PeelLegacyPurchasePolicy.persistedRecord(for: next) {
            UserDefaults.standard.set(record, forKey: Self.legacyPurchaseRecordKey)
            UserDefaults.standard.set(next.cachedLifetimeUnlock, forKey: Self.cachedLifetimeUnlockKey)
        }
        hasLifetimeUnlock = next.cachedLifetimeUnlock
        publishProFeatureAccess()
    }

    private func requestAISubscriptionProducts() async {
        let configuredIDs = aiSubscriptionProductIDs

        guard !configuredIDs.isEmpty else {
            aiSubscriptionProducts = []
            setAISubscriptionState(.unavailable(.notConfigured))
            return
        }

        do {
            let configuredSet = Set(configuredIDs)
            let storeProducts = try await Product.products(for: configuredIDs)
            aiSubscriptionProducts = storeProducts
                .filter { configuredSet.contains($0.id) && $0.type == .autoRenewable }
                .sorted { $0.id < $1.id }
        } catch {
            aiSubscriptionProducts = []
        }
    }

    private func setAISubscriptionState(_ state: PeelAISubscriptionState) {
        let previousExpiration = activeAISubscriptionExpiration
        aiSubscriptionState = state

        let expiration = activeAISubscriptionExpiration
        publishProFeatureAccess()

        guard previousExpiration != expiration else { return }
        scheduleAISubscriptionExpiration(at: expiration)
    }

    private func publishProFeatureAccess() {
        let subscriptionExpiration = PeelCapabilityPolicy.coordinationExpiration(
            subscription: aiSubscriptionState, now: Date())
        let trialExpiration = isTrialActive ? trialExpirationDate : nil
        let timedExpiration = [subscriptionExpiration, trialExpiration].compactMap { $0 }.max()
        PeelAIFeatureAccess.update(lifetimeAccess: hasLifetimeUnlock, subscriptionExpiration: timedExpiration)
    }

    private func scheduleTrialExpiration() {
        trialExpirationTask?.cancel()
        trialExpirationTask = nil
        guard isTrialActive, let expiration = trialExpirationDate else { return }
        trialExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, expiration.timeIntervalSinceNow)))
            } catch { return }
            guard !Task.isCancelled, let self, self.trialExpirationDate == expiration else { return }
            self.isTrialActive = Date() < expiration
            self.publishProFeatureAccess()
            if self.isTrialActive { self.scheduleTrialExpiration() }
        }
    }

    private var activeAISubscriptionExpiration: Date? {
        // Keep the observed expiration as the scheduled task identity, even at
        // its boundary; the task must still refresh and publish revocation.
        guard case .subscribed(let expirationDate) = aiSubscriptionState else {
            return nil
        }
        return expirationDate
    }

    private func scheduleAISubscriptionExpiration(at expirationDate: Date?) {
        aiSubscriptionExpirationTask?.cancel()
        aiSubscriptionExpirationTask = nil

        guard let expirationDate else { return }

        let delay = max(0, expirationDate.timeIntervalSinceNow)
        aiSubscriptionExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard !Task.isCancelled, let self,
                  self.activeAISubscriptionExpiration == expirationDate else {
                return
            }

            self.aiSubscriptionExpirationTask = nil
            // An early wake (or a wall-clock adjustment) must retain the future
            // grant and schedule its boundary without awaiting StoreKit first.
            guard Date() >= expirationDate else {
                self.scheduleAISubscriptionExpiration(at: expirationDate)
                return
            }
            // Publish date-derived access before StoreKit can suspend. This
            // refreshes connected Host capabilities while preserving lifetime
            // ownership and any still-active legacy trial.
            self.publishProFeatureAccess()
            await self.refreshEntitlements()

            // StoreKit may still report the entitlement if the task woke just
            // before the boundary. Keep one task keyed to the same expiration
            // until the policy observes the transition.
            if self.activeAISubscriptionExpiration == expirationDate {
                self.scheduleAISubscriptionExpiration(at: expirationDate)
            }
        }
    }

    private static func configuredAISubscriptionProductIDs() -> [String] {
        guard let rawIDs = Bundle.main.object(forInfoDictionaryKey: aiSubscriptionProductIDsInfoKey) as? [String] else {
            return []
        }

        var seen = Set<String>()
        return rawIDs.compactMap { rawID in
            let productID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !productID.isEmpty, seen.insert(productID).inserted else {
                return nil
            }
            return productID
        }
    }

    private static func aiProductType(from productType: Product.ProductType) -> PeelAISubscriptionProductType {
        switch productType {
        case .autoRenewable:
            return .autoRenewable
        case .nonRenewable:
            return .nonRenewable
        case .consumable:
            return .consumable
        case .nonConsumable:
            return .nonConsumable
        default:
            return .unknown
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let signedType):
            return signedType
        case .unverified:
            throw PeelStoreError.failedVerification
        }
    }
}

enum PeelStoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "The App Store transaction could not be verified."
        }
    }
}
