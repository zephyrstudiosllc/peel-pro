import XCTest
import StoreKit
import StoreKitTest
import SwiftUI
import UIKit
import ProStoreKitHost

/// The production store and reducers are compiled unchanged into this test
/// bundle. Only StoreKit's local service supplies transactions and test errors.
@MainActor
final class ProStoreKitTests: XCTestCase {
    private let monthly = "peel.pro.monthly"
    private let yearly = "peel.pro.yearly"
    private let lifetime = "peel.pro.lifetime"
    private let phaseKey = "PeelProValidation.completedPhase"
    private let lifetimeIDKey = "PeelProValidation.lifetimeTransactionID"
    private var lifecycleOnly: Bool { ProcessInfo.processInfo.environment["PEEL_PRO_LIFECYCLE_ONLY"] == "1" }
    private let paidFeatures: [PeelProductCapability] = [
        .multipleWindows, .mcpAccess, .agentCoordination,
        .agentNotifications, .legacyAppLauncher, .customMacIcons
    ]

    private enum Failure: Error { case unsafeEnvironment, missingVerifiedTransaction, conditionTimedOut }

    /// Fail at the precise suspended API instead of letting a cold simulator
    /// consume the outer xcodebuild timeout. The real operation is unchanged.
    private func step(_ label: String, operation: @escaping @MainActor () async throws -> Void) async throws {
        NSLog("PEEL_PRO_STEP_BEGIN %@", label)
        let completed = expectation(description: label)
        var result: Result<Void, Error>?
        let work = Task { @MainActor in
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 25)
        guard let result else {
            work.cancel()
            NSLog("PEEL_PRO_STEP_TIMEOUT %@", label)
            throw Failure.conditionTimedOut
        }
        try result.get()
        NSLog("PEEL_PRO_STEP_END %@", label)
    }

    private func session(expectedPreviousPhase: Int) throws -> SKTestSession {
        let environment = ProcessInfo.processInfo.environment
        let expected = try XCTUnwrap(environment["PEEL_PRO_TEST_UDID"])
        guard environment["SIMULATOR_UDID"] == expected,
              environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("Peel-Pro-StoreKit-") == true,
              Bundle.main.bundleIdentifier == "dev.peel.provalidation.storekit.host" else {
            XCTFail("Refusing StoreKit control outside the dedicated task simulator and fixture app")
            throw Failure.unsafeEnvironment
        }
        guard UserDefaults.standard.integer(forKey: phaseKey) == expectedPreviousPhase else {
            XCTFail("Each phase requires the previous real process launch to finish")
            throw Failure.unsafeEnvironment
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProProducts", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.timeRate = .realTime
        session.askToBuyEnabled = false
        session.interruptedPurchasesEnabled = false
        let known = Set([monthly, yearly, lifetime, "peel.pro.3day.freetrial"])
        guard session.allTransactions().allSatisfy({ known.contains($0.productIdentifier) }) else {
            throw Failure.unsafeEnvironment
        }
        // Deliberately never reset/clear existing transactions or defaults.
        return session
    }

    private func complete(_ phase: Int) {
        UserDefaults.standard.set(phase, forKey: phaseKey)
        print("PEEL_PRO_STOREKIT_PHASE_\(phase)_PASS")
    }

    private func store() async -> PeelStore {
        let store = PeelStore()
        await store.start()
        XCTAssertTrue(store.hasResolvedAccessState)
        return store
    }

    private func purchaseContext() async throws -> PurchaseAction {
        try await eventually("A foreground SwiftUI purchase context is required, as in the shipping paywall") {
            FixturePurchaseContext.action != nil && UIApplication.shared.connectedScenes.contains {
                $0.activationState == .foregroundActive
            }
        }
        return try XCTUnwrap(FixturePurchaseContext.action)
    }

    private func logTransactions(_ session: SKTestSession) async {
        for transaction in session.allTransactions() {
            NSLog("PEEL_PRO_FIXTURE product=%@ id=%llu state=%ld pending=%@ expires=%@ cancelled=%@",
                  transaction.productIdentifier, UInt64(transaction.identifier), transaction.state.rawValue,
                  String(transaction.pendingAskToBuyConfirmation), String(describing: transaction.expirationDate),
                  String(describing: transaction.cancelDate))
        }
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                NSLog("PEEL_PRO_CURRENT verified product=%@ id=%llu environment=%@ expires=%@ revoked=%@",
                      transaction.productID, transaction.id, String(describing: transaction.environment),
                      String(describing: transaction.expirationDate), String(describing: transaction.revocationDate))
            case .unverified(let transaction, _):
                NSLog("PEEL_PRO_CURRENT unverified product=%@ id=%llu", transaction.productID, transaction.id)
            }
        }
    }

    func testDiagnosticReadPhase1History() async throws {
        let session = try session(expectedPreviousPhase: 1)
        await logTransactions(session)
        let store = await store()
        NSLog("PEEL_PRO_DIAGNOSTIC lifetime=%@ subscription=%@ pro=%@ state=%@",
              String(store.hasLifetimeUnlock), String(store.hasAISubscription), String(store.hasProAccess),
              String(describing: store.aiSubscriptionState))
        _ = try await purchaseContext()
        NSLog("PEEL_PRO_DIAGNOSTIC real SwiftUI purchase context available")
    }

    private func assertAccess(_ expected: Bool, store: PeelStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.hasProAccess, expected, file: file, line: line)
        for capability in paidFeatures {
            XCTAssertEqual(store.canUse(capability), expected, "\(capability)", file: file, line: line)
        }
        XCTAssertEqual(PeelAIFeatureAccess.isAllowed, expected, "Actual runtime gate must agree with the store", file: file, line: line)
        XCTAssertFalse(PeelAIFeatureAccess.isDevelopmentPreview, "Debug must not bypass paid access", file: file, line: line)
        XCTAssertEqual(store.freeWindowLimit, 1, file: file, line: line)
        XCTAssertTrue(store.canOpenAdditionalWindow(openWindowCount: 0), file: file, line: line)
        XCTAssertEqual(store.canOpenAdditionalWindow(openWindowCount: 1), expected, file: file, line: line)
        XCTAssertEqual(store.canOpenAdditionalWindow(openWindowCount: 2), expected, file: file, line: line)
        let freeFeatures: [PeelProductCapability] = [.appStreaming, .desktopStreaming, .ordinaryInput,
                .systemAudio, .duplexVoice, .windowFitting, .multipleHosts, .machineStatus, .hostUtilities]
        for capability in freeFeatures {
            XCTAssertTrue(store.canUse(capability), "Basic \(capability) remains free", file: file, line: line)
        }
        XCTAssertFalse(store.canUse(.manualShell), "Unavailable work is not a purchasable benefit", file: file, line: line)
    }

    private func eventually(_ description: String, condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTFail(description)
        throw Failure.conditionTimedOut
    }

    private func verifiedLatest(_ identifier: String, revoked: Bool = false) async throws -> StoreKit.Transaction {
        var found: StoreKit.Transaction?
        try await eventually("Expected verified local transaction for \(identifier), revoked=\(revoked)") {
            guard let result = await StoreKit.Transaction.latest(for: identifier) else { return false }
            guard case .verified(let transaction) = result else {
                XCTFail("StoreKit verification failed for test evidence")
                return false
            }
            guard (transaction.revocationDate != nil) == revoked else { return false }
            XCTAssertEqual(transaction.environment, .xcode)
            XCTAssertEqual(transaction.productID, identifier)
            guard transaction.environment == .xcode else { throw Failure.unsafeEnvironment }
            found = transaction
            return true
        }
        return try XCTUnwrap(found)
    }

    private func settle(_ store: PeelStore, access: Bool) async throws {
        try await eventually("Production store did not settle to Pro=\(access)") {
            await store.refreshEntitlements()
            return store.hasProAccess == access && PeelAIFeatureAccess.isAllowed == access
        }
        assertAccess(access, store: store)
    }

    private func makePurchase(_ product: Product, store: PeelStore, session: SKTestSession, using action: PurchaseAction) async throws {
        if lifecycleOnly {
            try await step("signed StoreKit external purchase \(product.id)") {
                let transaction = try await session.buyProduct(identifier: product.id)
                XCTAssertEqual(transaction.environment, .xcode)
                XCTAssertEqual(transaction.productID, product.id)
                NSLog("PEEL_PRO_EXTERNAL_PURCHASE product=%@ id=%llu", transaction.productID, transaction.id)
            }
        } else {
            try await step("production purchase action \(product.id)") {
                if product.id == self.lifetime {
                    await store.purchaseLifetime(using: action)
                } else {
                    await store.purchaseAISubscription(product, using: action)
                }
            }
        }
    }

    private func attachRenderedPaywall(_ store: PeelStore) async throws {
        NSLog("PEEL_PRO_RENDER_BEGIN")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        let previousController = window.rootViewController
        let controller = UIHostingController(rootView: PeelPaywallView(feature: .general).environmentObject(store))
        window.rootViewController = controller
        defer { window.rootViewController = previousController }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        func capture(_ name: String) {
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("ProductionPaywall-Free-Top")
        NSLog("PEEL_PRO_RENDER_TOP_ATTACHED")
        func firstScrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap(firstScrollView).first
        }
        if let scroll = firstScrollView(controller.view) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            capture("ProductionPaywall-Free-Bottom")
            NSLog("PEEL_PRO_RENDER_BOTTOM_ATTACHED")
        }
        NSLog("PEEL_PRO_RENDER_END")
    }

    func testPhase1CatalogFreeAndCancelled() async throws {
        try await catalogFree(includeCancelledPurchase: true)
    }

    func testPhase1CatalogFree() async throws {
        guard lifecycleOnly else { throw Failure.unsafeEnvironment }
        try await catalogFree(includeCancelledPurchase: false)
    }

    private func catalogFree(includeCancelledPurchase: Bool) async throws {
        let session = try session(expectedPreviousPhase: 0)
        XCTAssertNil(UserDefaults.standard.object(forKey: phaseKey))
        guard session.allTransactions().isEmpty else {
            await logTransactions(session)
            XCTFail("Initial phase requires empty StoreKit history; no reset is permitted")
            throw Failure.unsafeEnvironment
        }
        let store = await store()
        let purchase = try await purchaseContext()
        assertAccess(false, store: store)
        let products = try await Product.products(for: [monthly, yearly, lifetime])
        XCTAssertEqual(Set(products.map(\.id)), Set([monthly, yearly, lifetime]))
        for (identifier, price) in [(monthly, "4.99"), (yearly, "29.99"), (lifetime, "119.99")] {
            let product = try XCTUnwrap(products.first { $0.id == identifier })
            XCTAssertEqual(product.price, try XCTUnwrap(Decimal(string: price)))
            XCTAssertTrue(product.isFamilyShareable, "Local catalog metadata; this does not prove live Family Sharing")
            XCTAssertEqual(product.type, identifier == lifetime ? .nonConsumable : .autoRenewable)
        }
        let month = try XCTUnwrap(store.aiSubscriptionProducts.first { $0.id == monthly })
        let year = try XCTUnwrap(store.aiSubscriptionProducts.first { $0.id == yearly })
        XCTAssertEqual(month.subscription?.subscriptionGroupID, year.subscription?.subscriptionGroupID)
        XCTAssertEqual(month.subscription?.groupLevel, year.subscription?.groupLevel)
        XCTAssertEqual(month.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(month.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(year.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(year.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(PeelCapabilityPolicy.freeWindowLimit(platform: .visionOS), 2)
        XCTAssertTrue(PeelCapabilityPolicy.canOpenAdditionalWindow(openWindowCount: 1, proAccess: false, platform: .visionOS))
        XCTAssertFalse(PeelCapabilityPolicy.canOpenAdditionalWindow(openWindowCount: 2, proAccess: false, platform: .visionOS))

        if includeCancelledPurchase {
            try await step("set cancelled-purchase error") {
                try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
            }
            try await step("production lifetime purchase with cancelled result") { await store.purchaseLifetime(using: purchase) }
            try await step("clear cancelled-purchase error") {
                try await session.setSimulatedError(nil, forAPI: .purchase)
            }
            assertAccess(false, store: store)
            XCTAssertFalse(session.allTransactions().contains { $0.state == .purchased || $0.state == .restored },
                           "Cancellation may have failed history, but must not create a completed purchase")
        } else {
            // Clear only the previous diagnostic error override, never history.
            try await step("clear diagnostic purchase error override") {
                try await session.setSimulatedError(nil, forAPI: .purchase)
            }
            NSLog("PEEL_PRO_SCOPE signed-external-purchase-lifecycle; purchase-action completion NOT tested")
        }

        // Keep the original key-window controller untouched until all purchase
        // interactions finish. Screenshot rendering is separate from billing.
        try await attachRenderedPaywall(store)
        await logTransactions(session)
        try await settle(store, access: false)
        complete(1)
    }

    func testPhase2MonthlyPurchaseRestoreCancellationAndRefund() async throws {
        let session = try session(expectedPreviousPhase: 1)
        await logTransactions(session)
        let store = await store()
        let purchase = try await purchaseContext()
        assertAccess(false, store: store)
        let month = try XCTUnwrap(store.aiSubscriptionProducts.first { $0.id == monthly })
        try await makePurchase(month, store: store, session: session, using: purchase)
        try await settle(store, access: true)
        XCTAssertTrue(store.hasAISubscription)
        XCTAssertFalse(store.hasLifetimeUnlock)
        let transaction = try await verifiedLatest(monthly)
        XCTAssertNotNil(transaction.expirationDate)
        let fixture = try XCTUnwrap(session.allTransactions().first { UInt64($0.identifier) == transaction.id })
        try session.disableAutoRenewForTransaction(identifier: fixture.identifier)
        await store.refreshEntitlements()
        assertAccess(true, store: store)
        XCTAssertFalse(try XCTUnwrap(session.allTransactions().first { $0.identifier == fixture.identifier }).autoRenewingEnabled)
        try await step("production monthly restore") { await store.restorePurchases() }
        assertAccess(true, store: store)
        XCTAssertNil(store.purchaseErrorMessage)
        try session.refundTransaction(identifier: fixture.identifier)
        _ = try await verifiedLatest(monthly, revoked: true)
        try await settle(store, access: false)
        complete(2)
    }

    func testPhase3YearlyPurchaseAndExpiration() async throws {
        let session = try session(expectedPreviousPhase: 2)
        let store = await store()
        let purchase = try await purchaseContext()
        assertAccess(false, store: store)
        let year = try XCTUnwrap(store.aiSubscriptionProducts.first { $0.id == yearly })
        try await makePurchase(year, store: store, session: session, using: purchase)
        try await settle(store, access: true)
        XCTAssertTrue(store.hasAISubscription)
        let transaction = try await verifiedLatest(yearly)
        XCTAssertNotNil(transaction.expirationDate)
        try session.expireSubscription(productIdentifier: yearly)
        try await settle(store, access: false)
        try await step("production expired-yearly restore") { await store.restorePurchases() }
        assertAccess(false, store: store)
        complete(3)
    }

    func testPhase4GrandfatheredLifetimePurchase() async throws {
        try await grandfatheredLifetime(expectedPreviousPhase: 3)
    }

    func testIndependentGrandfatheredLifetime() async throws {
        guard lifecycleOnly else { throw Failure.unsafeEnvironment }
        try await grandfatheredLifetime(expectedPreviousPhase: 2)
    }

    private func grandfatheredLifetime(expectedPreviousPhase: Int) async throws {
        let session = try session(expectedPreviousPhase: expectedPreviousPhase)
        // Read real fixture history and signed entitlements before any mutation.
        await logTransactions(session)
        let store = await store()
        NSLog("PEEL_PRO_LIFETIME_BASELINE lifetime=%@ subscription=%@ pro=%@ state=%@",
              String(store.hasLifetimeUnlock), String(store.hasAISubscription), String(store.hasProAccess),
              String(describing: store.aiSubscriptionState))
        assertAccess(false, store: store)
        guard !store.hasProAccess, !PeelAIFeatureAccess.isAllowed else { throw Failure.unsafeEnvironment }
        if expectedPreviousPhase == 2 { _ = try await verifiedLatest(monthly, revoked: true) }
        let oldDate = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        let historicPurchase = try await session.buyProduct(identifier: lifetime, options: [.purchaseDate(oldDate)])
        XCTAssertEqual(historicPurchase.environment, .xcode)
        let transaction = try await verifiedLatest(lifetime)
        XCTAssertEqual(transaction.id, historicPurchase.id)
        XCTAssertLessThan(transaction.purchaseDate, Date().addingTimeInterval(-300 * 24 * 60 * 60))
        try await settle(store, access: true)
        XCTAssertTrue(store.hasLifetimeUnlock)
        XCTAssertFalse(store.hasAISubscription)
        let beforeDuplicateAttempt = session.allTransactions().count
        await store.purchaseAISubscription(try XCTUnwrap(store.aiSubscriptionProducts.first { $0.id == monthly }))
        XCTAssertEqual(session.allTransactions().count, beforeDuplicateAttempt,
                       "Lifetime ownership must block charging for a redundant subscription")
        assertAccess(true, store: store)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "PeelStore.legacyPurchaseRecord"))
        UserDefaults.standard.set(String(transaction.id), forKey: lifetimeIDKey)
        complete(4)
    }

    func testPhase5LifetimeRelaunchRestoreAndRefund() async throws {
        let session = try session(expectedPreviousPhase: 4)
        let initial = PeelStore()
        XCTAssertTrue(initial.hasLifetimeUnlock, "New process restores the historical purchase cache immediately")
        await initial.start()
        assertAccess(true, store: initial)
        try await step("production lifetime restore after relaunch") { await initial.restorePurchases() }
        assertAccess(true, store: initial)
        XCTAssertNil(initial.purchaseErrorMessage)
        let transaction = try await verifiedLatest(lifetime)
        XCTAssertEqual(String(transaction.id), UserDefaults.standard.string(forKey: lifetimeIDKey))
        let fixture = try XCTUnwrap(session.allTransactions().first { UInt64($0.identifier) == transaction.id })
        try session.refundTransaction(identifier: fixture.identifier)
        _ = try await verifiedLatest(lifetime, revoked: true)
        // The real listener must revoke cached lifetime access without us
        // manually refreshing. A later refresh tests the launch/restore path too.
        try await eventually("Verified refund update did not clear the production cache") {
            !initial.hasLifetimeUnlock && !initial.hasProAccess && !PeelAIFeatureAccess.isAllowed
        }
        assertAccess(false, store: initial)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "PeelStore.cachedLifetimeUnlock"))
        try await settle(initial, access: false)
        complete(5)
    }

    func testPhase6RevokedRelaunchAndNewLifetimePurchase() async throws {
        let session = try session(expectedPreviousPhase: 5)
        let store = await store()
        let purchase = try await purchaseContext()
        XCTAssertFalse(store.hasLifetimeUnlock, "A real process restart must not recover the refunded grant")
        assertAccess(false, store: store)
        try await step("production revoked-lifetime restore after relaunch") { await store.restorePurchases() }
        assertAccess(false, store: store)
        let revoked = try await verifiedLatest(lifetime, revoked: true)
        try await makePurchase(try XCTUnwrap(store.lifetimeProduct), store: store, session: session, using: purchase)
        let replacement = try await verifiedLatest(lifetime)
        XCTAssertNotEqual(replacement.id, revoked.id)
        try await settle(store, access: true)
        XCTAssertTrue(store.hasLifetimeUnlock)
        // Restoring the real service history, including the old refund, cannot
        // revoke this separate new verified lifetime transaction.
        try await step("production replacement lifetime restore") { await store.restorePurchases() }
        assertAccess(true, store: store)
        XCTAssertTrue(session.allTransactions().contains { UInt64($0.identifier) == replacement.id })
        complete(6)
    }

    /// Kept last because the local StoreKit test service has been observed to
    /// return a signed active entitlement for a previously declined/failed test
    /// transaction on a later process launch. Do not weaken production trust to
    /// compensate for that fixture inconsistency or contaminate later scenarios.
    func testPhase7PendingAndDeclinedWithoutAccess() async throws {
        let session = try session(expectedPreviousPhase: 6)
        let store = await store()
        let purchase = try await purchaseContext()
        assertAccess(true, store: store)
        let lifetimeTransaction = try await verifiedLatest(lifetime)
        let fixture = try XCTUnwrap(session.allTransactions().first { UInt64($0.identifier) == lifetimeTransaction.id })
        try session.refundTransaction(identifier: fixture.identifier)
        _ = try await verifiedLatest(lifetime, revoked: true)
        try await settle(store, access: false)

        let month = try XCTUnwrap(store.aiSubscriptionProducts.first { $0.id == monthly })
        session.askToBuyEnabled = true
        try await step("production monthly purchase awaiting Ask to Buy") {
            await store.purchaseAISubscription(month, using: purchase)
        }
        assertAccess(false, store: store)
        XCTAssertEqual(store.purchaseErrorMessage, "Purchase is pending approval.")
        let pending = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        XCTAssertEqual(pending.productIdentifier, monthly)
        try session.declineAskToBuyTransaction(identifier: pending.identifier)
        session.askToBuyEnabled = false
        NSLog("PEEL_PRO_ASK_TO_BUY_DECLINED")
        try await settle(store, access: false)
        await logTransactions(session)
        complete(7)
    }
}
