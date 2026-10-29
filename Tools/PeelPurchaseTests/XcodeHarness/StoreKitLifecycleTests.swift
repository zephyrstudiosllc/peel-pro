import XCTest
import StoreKit
import StoreKitTest

@MainActor
final class StoreKitLifecycleTests: XCTestCase {
    private let productID = "dev.peel.disposable.fixture.lifetime"
    private let recordKey = "DisposableLegacyRecord"
    private let phaseKey = "DisposableCompletedPhase"
    private let boughtIDKey = "DisposableBoughtTransactionID"

    private func session() throws -> SKTestSession {
        let environment = ProcessInfo.processInfo.environment
        let expected = try XCTUnwrap(environment["PEEL_DISPOSABLE_UDID"])
        XCTAssertEqual(environment["SIMULATOR_UDID"], expected)
        guard environment["SIMULATOR_UDID"] == expected,
              environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("Peel-StoreKit-Disposable-") == true,
              Bundle.main.bundleIdentifier == "dev.peel.disposable.storekit.host" else {
            throw Failure.notDisposable
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalPurchases", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        // No reset/clear is needed: the runner created a brand-new simulator.
        guard session.allTransactions().allSatisfy({ $0.productIdentifier == productID }) else {
            throw Failure.unexpectedTransaction
        }
        return session
    }

    private func verified(_ result: VerificationResult<StoreKit.Transaction>?) throws -> StoreKit.Transaction {
        guard case .verified(let transaction) = result else {
            if case .unverified(let transaction, let error) = result {
                XCTFail("StoreKit returned unverified fixture: environment=\(transaction.environment), error=\(error)")
            } else {
                XCTFail("StoreKit returned no transaction")
            }
            throw Failure.notVerified
        }
        XCTAssertEqual(transaction.productID, productID)
        XCTAssertEqual(transaction.environment, .xcode)
        guard transaction.productID == productID, transaction.environment == .xcode else {
            throw Failure.notLocal
        }
        return transaction
    }

    private func latest(expectedID: UInt64? = nil) async throws -> StoreKit.Transaction {
        // An external test purchase can be delivered asynchronously. Retry only
        // absence or an older verified result, never unverified evidence.
        for _ in 0..<50 {
            if let result = await StoreKit.Transaction.latest(for: productID) {
                let transaction = try verified(result)
                if expectedID == nil || transaction.id == expectedID { return transaction }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try verified(nil)
    }

    private func logUpdate(_ result: VerificationResult<StoreKit.Transaction>) {
        switch result {
        case .verified(let update):
            print("LOCAL_STOREKIT_UPDATE verified=true product=\(update.productID) id=\(update.id) environment=\(update.environment) revoked=\(update.revocationDate != nil)")
        case .unverified(let update, let error):
            print("LOCAL_STOREKIT_UPDATE verified=false product=\(update.productID) id=\(update.id) environment=\(update.environment) revoked=\(update.revocationDate != nil) error=\(error)")
        }
    }

    private func evidence(_ transaction: StoreKit.Transaction) -> PeelLegacyPurchaseEvidence {
        .init(productID: transaction.productID, transactionID: transaction.id,
              isNonConsumable: transaction.productType == .nonConsumable,
              revocationDate: transaction.revocationDate, isVerified: true)
    }

    private func apply(_ state: PeelLegacyPurchaseState, _ transaction: StoreKit.Transaction) -> PeelLegacyPurchaseState {
        PeelLegacyPurchasePolicy.reconcile(state, evidence: [evidence(transaction)], lifetimeProductID: productID)
    }

    private func current() async throws -> [StoreKit.Transaction] {
        var transactions: [StoreKit.Transaction] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            transactions.append(try verified(result))
        }
        return transactions
    }

    private func save(_ state: PeelLegacyPurchaseState, phase: Int) throws {
        UserDefaults.standard.set(try PeelLegacyPurchasePolicy.persistedRecord(for: state), forKey: recordKey)
        UserDefaults.standard.set(phase, forKey: phaseKey)
    }

    private func load() throws -> PeelLegacyPurchaseState {
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: recordKey))
        return PeelLegacyPurchasePolicy.restoredState(from: data, legacyCachedLifetimeUnlock: false)
    }

    func testPhase1BuyAndPersist() async throws {
        let session = try session()
        let receivedPurchase = expectation(description: "Verified external StoreKit purchase update")
        var listenerReady = false
        let updates = Task { @MainActor in
            var iterator = StoreKit.Transaction.updates.makeAsyncIterator()
            listenerReady = true
            while let result = await iterator.next() {
                logUpdate(result)
                guard case .verified(let update) = result, update.productID == productID,
                      update.revocationDate == nil else { continue }
                receivedPurchase.fulfill()
                break
            }
        }
        defer { updates.cancel() }
        while !listenerReady { await Task.yield() }
        XCTAssertNil(UserDefaults.standard.object(forKey: phaseKey), "Phase1 must start in a fresh fixture container")
        XCTAssertTrue(session.allTransactions().isEmpty)
        let before = try await current()
        XCTAssertTrue(before.isEmpty)
        let products = try await Product.products(for: [productID])
        let product = try XCTUnwrap(products.first)
        XCTAssertEqual(product.type, .nonConsumable)
        let purchase = try await session.buyProduct(identifier: productID)
        await fulfillment(of: [receivedPurchase], timeout: 15)
        let transaction = try await latest(expectedID: purchase.id)
        XCTAssertNil(transaction.revocationDate)
        let owned = apply(.init(cachedLifetimeUnlock: false), transaction)
        XCTAssertTrue(owned.cachedLifetimeUnlock)
        let entitlements = try await current()
        XCTAssertEqual(entitlements.map(\.id), [transaction.id])
        guard owned.cachedLifetimeUnlock, transaction.revocationDate == nil,
              entitlements.map(\.id) == [transaction.id] else { throw Failure.policyFailed }
        await transaction.finish()
        UserDefaults.standard.set(String(transaction.id), forKey: boughtIDKey)
        try save(owned, phase: 1)
        print("LOCAL_STOREKIT_PHASE1_PURCHASE_CORE_PASS verified buy/currentEntitlements/persist transaction=\(transaction.id)")
    }

    func testPhase2RelaunchRestoreAndRefund() async throws {
        let session = try session()
        let receivedRevocation = expectation(description: "Verified StoreKit refund update")
        var revokedTransaction: StoreKit.Transaction?
        var listenerReady = false
        let updates = Task { @MainActor in
            var iterator = StoreKit.Transaction.updates.makeAsyncIterator()
            listenerReady = true
            while let result = await iterator.next() {
                logUpdate(result)
                guard case .verified(let update) = result, update.productID == productID,
                      update.revocationDate != nil else { continue }
                revokedTransaction = update
                receivedRevocation.fulfill()
                break
            }
        }
        defer { updates.cancel() }
        while !listenerReady { await Task.yield() }
        // Match app startup: observe before restore or current-entitlement reads.
        XCTAssertEqual(UserDefaults.standard.integer(forKey: phaseKey), 1)
        var owned = try load()
        XCTAssertTrue(owned.cachedLifetimeUnlock, "Actual new process must recover persisted purchase")
        try await AppStore.sync()
        let restored = try await current()
        XCTAssertEqual(restored.count, 1)
        let transaction = try XCTUnwrap(restored.first)
        XCTAssertEqual(String(transaction.id), UserDefaults.standard.string(forKey: boughtIDKey))
        owned = apply(owned, transaction)
        XCTAssertTrue(owned.cachedLifetimeUnlock)
        let testTransaction = try XCTUnwrap(session.allTransactions().first { String($0.identifier) == String(transaction.id) })
        try session.refundTransaction(identifier: testTransaction.identifier)
        await fulfillment(of: [receivedRevocation], timeout: 15)
        if let revokedTransaction {
            XCTAssertEqual(revokedTransaction.environment, .xcode)
            owned = apply(owned, revokedTransaction)
            XCTAssertFalse(owned.cachedLifetimeUnlock)
        }
        let afterRefund = try await current()
        XCTAssertTrue(afterRefund.isEmpty)
        let latestTransaction = try await latest()
        _ = try XCTUnwrap(latestTransaction.revocationDate, "Require real verified revocation even if update delivery fails")
        owned = apply(owned, latestTransaction)
        XCTAssertFalse(owned.cachedLifetimeUnlock)
        XCTAssertTrue(owned.revokedTransactionIDs.contains(transaction.id))
        XCTAssertFalse(apply(owned, transaction).cachedLifetimeUnlock, "Stale pre-refund result cannot revive grant")
        guard !owned.cachedLifetimeUnlock, afterRefund.isEmpty else { throw Failure.policyFailed }
        await latestTransaction.finish()
        try save(owned, phase: 2)
        print("LOCAL_STOREKIT_PHASE2_REFUND_CORE_PASS actual relaunch/restore/refund latest/cache revoke; updateReceived=\(revokedTransaction != nil)")
    }

    func testPhase3RelaunchRevocationAndRepurchase() async throws {
        let session = try session()
        XCTAssertEqual(UserDefaults.standard.integer(forKey: phaseKey), 2)
        var state = try load()
        XCTAssertFalse(state.cachedLifetimeUnlock, "Actual new process retains revoked ownership")
        try await AppStore.sync()
        let restored = try await current()
        XCTAssertTrue(restored.isEmpty, "Restore cannot resurrect a refunded non-consumable")
        let revoked = try await latest()
        XCTAssertNotNil(revoked.revocationDate)
        XCTAssertFalse(apply(state, revoked).cachedLifetimeUnlock)
        let purchase = try await session.buyProduct(identifier: productID)
        let replacement = try await latest(expectedID: purchase.id)
        XCTAssertNil(replacement.revocationDate)
        XCTAssertNotEqual(replacement.id, revoked.id)
        state = apply(state, replacement)
        XCTAssertTrue(state.cachedLifetimeUnlock)
        XCTAssertTrue(apply(state, revoked).cachedLifetimeUnlock, "Older refund does not erase distinct new purchase")
        await replacement.finish()
        try save(state, phase: 3)
        print("LOCAL_STOREKIT_PHASE3 actual relaunch/revoked restore/distinct repurchase assertions completed")
    }

    private enum Failure: Error { case notDisposable, unexpectedTransaction, notVerified, notLocal, policyFailed }
}
