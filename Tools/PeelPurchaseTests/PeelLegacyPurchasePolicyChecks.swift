import Foundation

@main
enum PeelLegacyPurchasePolicyChecks {
    private static let product = "peel.pro.lifetime"
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() async {
        explicitRevocationClearsLegacyCache()
        uncertainEvidencePreservesOwnership()
        matchingVerifiedEvidenceIsRequiredForNewGrants()
        revokedIDsSurviveRestartAndRejectStaleSnapshots()
        distinctPurchaseRemainsValid()
        distinctPurchaseSurvivesRestartAndOldRevocation()
        repeatedAndReorderedEventsAreIdempotent()
        corruptPreferencesNeverGrantAccess()
        legacyBooleanMigrationIsPreserved()
        await suspendedRefreshCannotUndoRevocation()
        print("PeelLegacyPurchasePolicyChecks: passed (10 revocation and preservation scenarios)")
    }

    private static func fixture(_ id: UInt64 = 1, revoked: Bool = false,
                                verified: Bool = true, productID: String = product,
                                nonConsumable: Bool = true) -> PeelLegacyPurchaseEvidence {
        .init(productID: productID, transactionID: id, isNonConsumable: nonConsumable,
              revocationDate: revoked ? date : nil, isVerified: verified)
    }

    private static func reduce(_ state: PeelLegacyPurchaseState,
                               _ evidence: [PeelLegacyPurchaseEvidence]) -> PeelLegacyPurchaseState {
        PeelLegacyPurchasePolicy.reconcile(state, evidence: evidence, lifetimeProductID: product)
    }

    private static func explicitRevocationClearsLegacyCache() {
        let owned = PeelLegacyPurchaseState(cachedLifetimeUnlock: true)
        let revoked = reduce(owned, [fixture(revoked: true)])
        precondition(!revoked.cachedLifetimeUnlock)
        precondition(revoked.revokedTransactionIDs == [1])
        precondition(!reduce(revoked, []).cachedLifetimeUnlock)
    }

    private static func uncertainEvidencePreservesOwnership() {
        let owned = PeelLegacyPurchaseState(cachedLifetimeUnlock: true)
        // Pending/cancelled purchase, failed sync, missing backend and unresolved
        // startup supply no verified transaction. None is revocation evidence.
        precondition(reduce(owned, []) == owned)
        precondition(reduce(owned, [fixture(revoked: true, verified: false)]) == owned)
        precondition(reduce(owned, [fixture(productID: "unrelated.product")]) == owned)
    }

    private static func matchingVerifiedEvidenceIsRequiredForNewGrants() {
        let empty = PeelLegacyPurchaseState(cachedLifetimeUnlock: false)
        for evidence in [[], [fixture(verified: false)],
                         [fixture(productID: "peel.pro.3day.freetrial")],
                         [fixture(nonConsumable: false)]] {
            precondition(!reduce(empty, evidence).cachedLifetimeUnlock)
        }
        precondition(reduce(empty, [fixture()]).cachedLifetimeUnlock)
        precondition(reduce(empty, [fixture(0)]).cachedLifetimeUnlock,
                     "Do not invent a nonzero restriction on a verified StoreKit UInt64 ID")
    }

    private static func revokedIDsSurviveRestartAndRejectStaleSnapshots() {
        let revoked = reduce(.init(cachedLifetimeUnlock: true), [fixture(revoked: true)])
        let restarted = restart(revoked, oldBoolean: true)
        precondition(!restarted.cachedLifetimeUnlock, "The new record overrides a stale old Boolean")
        precondition(!reduce(restarted, [fixture()]).cachedLifetimeUnlock)
        precondition(reduce(restarted, [fixture(2)]).cachedLifetimeUnlock)
    }

    private static func distinctPurchaseRemainsValid() {
        let both = reduce(.init(cachedLifetimeUnlock: false), [fixture(1), fixture(2)])
        let oneRevoked = reduce(both, [fixture(1, revoked: true)])
        precondition(oneRevoked.cachedLifetimeUnlock)
        precondition(oneRevoked.verifiedActiveTransactionIDs == [2])
        precondition(!reduce(oneRevoked, [fixture(2, revoked: true)]).cachedLifetimeUnlock)
    }

    private static func restart(_ state: PeelLegacyPurchaseState, oldBoolean: Bool) -> PeelLegacyPurchaseState {
        let data = try! PeelLegacyPurchasePolicy.persistedRecord(for: state)
        return PeelLegacyPurchasePolicy.restoredState(from: data, legacyCachedLifetimeUnlock: oldBoolean)
    }

    private static func distinctPurchaseSurvivesRestartAndOldRevocation() {
        let both = reduce(.init(cachedLifetimeUnlock: false), [fixture(1), fixture(2)])
        let oneRevoked = reduce(both, [fixture(1, revoked: true)])
        let restarted = restart(oneRevoked, oldBoolean: false)
        precondition(restarted == oneRevoked)
        let replayed = reduce(restarted, [fixture(1, revoked: true)])
        let uncertain = reduce(replayed, [fixture(2, revoked: true, verified: false)])
        precondition(reduce(uncertain, []).cachedLifetimeUnlock)
        precondition(uncertain.verifiedActiveTransactionIDs == [2])
        precondition(!reduce(uncertain, [fixture(2, revoked: true)]).cachedLifetimeUnlock)
    }

    private static func repeatedAndReorderedEventsAreIdempotent() {
        let state = PeelLegacyPurchaseState(cachedLifetimeUnlock: true)
        let events = [fixture(), fixture(revoked: true), fixture(2)]
        let result = reduce(state, events)
        precondition(reduce(result, events) == result)
        precondition(reduce(state, events.reversed()) == result)
        precondition(reduce(result, [fixture(revoked: true)]).cachedLifetimeUnlock)
    }

    private static func corruptPreferencesNeverGrantAccess() {
        precondition(PeelLegacyPurchasePolicy.transactionIDs(from: nil).isEmpty)
        let parsed = PeelLegacyPurchasePolicy.transactionIDs(
            from: ["1", "bad", "0", "-1", "01", "18446744073709551616", "2", "2"])
        precondition(parsed == [0, 1, 2])
        let state = PeelLegacyPurchaseState(cachedLifetimeUnlock: false, revokedTransactionIDs: parsed)
        precondition(!reduce(state, []).cachedLifetimeUnlock)
        precondition(!reduce(state, [fixture()]).cachedLifetimeUnlock)

        let contradictory = PeelLegacyPurchaseState(cachedLifetimeUnlock: false,
            verifiedActiveTransactionIDs: [2], revokedTransactionIDs: [1])
        let restored = restart(contradictory, oldBoolean: true)
        precondition(!restored.cachedLifetimeUnlock && restored.verifiedActiveTransactionIDs.isEmpty)
        precondition(!reduce(restored, [fixture(1, revoked: true)]).cachedLifetimeUnlock)

        let malformed = Data(#"{"version":1,"cachedLifetimeUnlock":false,"verifiedActiveTransactionIDs":["bad","2"],"revokedTransactionIDs":["1","bad"]}"#.utf8)
        let decoded = PeelLegacyPurchasePolicy.restoredState(from: malformed, legacyCachedLifetimeUnlock: true)
        precondition(!decoded.cachedLifetimeUnlock && decoded.verifiedActiveTransactionIDs.isEmpty)
        precondition(decoded.revokedTransactionIDs == [1])
        let contradictoryRevoked = PeelLegacyPurchaseState(cachedLifetimeUnlock: true,
            verifiedActiveTransactionIDs: [1], revokedTransactionIDs: [1])
        precondition(!restart(contradictoryRevoked, oldBoolean: true).cachedLifetimeUnlock)
    }

    private static func legacyBooleanMigrationIsPreserved() {
        for data: Data? in [nil, Data("corrupt".utf8)] {
            let unowned = PeelLegacyPurchasePolicy.restoredState(from: data, legacyCachedLifetimeUnlock: false)
            precondition(!unowned.cachedLifetimeUnlock && unowned.verifiedActiveTransactionIDs.isEmpty)
            let owned = PeelLegacyPurchasePolicy.restoredState(from: data, legacyCachedLifetimeUnlock: true)
            precondition(owned.cachedLifetimeUnlock && owned.verifiedActiveTransactionIDs.isEmpty)
            precondition(!reduce(owned, [fixture(revoked: true)]).cachedLifetimeUnlock)
        }
    }

    @MainActor
    private final class SuspendedRefresh {
        var state = PeelLegacyPurchaseState(cachedLifetimeUnlock: true)
        var resume: CheckedContinuation<Void, Never>?
        func refresh() async {
            let oldSnapshot = [PeelLegacyPurchasePolicyChecks.fixture()]
            await withCheckedContinuation { resume = $0 }
            state = PeelLegacyPurchasePolicyChecks.reduce(state, oldSnapshot)
        }
    }

    @MainActor
    private static func suspendedRefreshCannotUndoRevocation() async {
        let store = SuspendedRefresh()
        let refresh = Task { await store.refresh() }
        while store.resume == nil { await Task.yield() }
        store.state = reduce(store.state, [fixture(revoked: true)])
        precondition(!store.state.cachedLifetimeUnlock)
        store.resume?.resume()
        await refresh.value
        precondition(!store.state.cachedLifetimeUnlock)
    }
}
