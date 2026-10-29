import Foundation

/// Minimal evidence copied only after StoreKit transaction verification.
/// Tests can model rejected/unverified input without importing StoreKit.
struct PeelLegacyPurchaseEvidence: Sendable {
    let productID: String
    let transactionID: UInt64
    let isNonConsumable: Bool
    let revocationDate: Date?
    let isVerified: Bool
}

struct PeelLegacyPurchaseState: Equatable, Sendable {
    var cachedLifetimeUnlock: Bool
    /// Persisted known grants allow a separate valid purchase to survive
    /// another transaction's revocation, including replay after restart.
    var verifiedActiveTransactionIDs: Set<UInt64> = []
    /// Persistent tombstones prevent an older suspended refresh from regranting
    /// the same transaction after verified revocation, including across restart.
    var revokedTransactionIDs: Set<UInt64> = []
}

enum PeelLegacyPurchasePolicy {
    private struct PersistedRecord: Codable {
        let version: Int
        let cachedLifetimeUnlock: Bool
        let verifiedActiveTransactionIDs: [String]
        let revokedTransactionIDs: [String]
    }

    static func reconcile(
        _ state: PeelLegacyPurchaseState,
        evidence: [PeelLegacyPurchaseEvidence],
        lifetimeProductID: String
    ) -> PeelLegacyPurchaseState {
        let matching = evidence.filter {
            $0.isVerified && $0.isNonConsumable &&
                $0.productID == lifetimeProductID
        }
        guard !matching.isEmpty else { return state }

        var result = state
        let revoked = Set(matching.filter { $0.revocationDate != nil }.map(\.transactionID))
        result.revokedTransactionIDs.formUnion(revoked)
        result.verifiedActiveTransactionIDs.subtract(result.revokedTransactionIDs)

        let active = Set(matching.filter {
            $0.revocationDate == nil && !result.revokedTransactionIDs.contains($0.transactionID)
        }.map(\.transactionID))
        result.verifiedActiveTransactionIDs.formUnion(active)

        if !result.verifiedActiveTransactionIDs.isEmpty {
            result.cachedLifetimeUnlock = true
        } else if !revoked.isEmpty {
            result.cachedLifetimeUnlock = false
        }
        // Empty, unverified, or stale revoked-ID evidence never grants access
        // and never erases an unrelated previously verified offline cache.
        return result
    }

    /// Store ownership and provenance in one value so replay after restart
    /// cannot revoke an unrelated valid grant through partially saved state.
    static func persistedRecord(for state: PeelLegacyPurchaseState) throws -> Data {
        try JSONEncoder().encode(PersistedRecord(
            version: 1,
            cachedLifetimeUnlock: state.cachedLifetimeUnlock,
            verifiedActiveTransactionIDs: state.verifiedActiveTransactionIDs.sorted().map(String.init),
            revokedTransactionIDs: state.revokedTransactionIDs.sorted().map(String.init)
        ))
    }

    /// The old Boolean is compatibility ownership, never a new purchase proof.
    /// Missing/corrupt records preserve that fallback; ID strings cannot promote
    /// a stored false ownership flag. Valid revocations defeat conflicting IDs.
    static func restoredState(from data: Data?, legacyCachedLifetimeUnlock: Bool) -> PeelLegacyPurchaseState {
        guard let data,
              let record = try? JSONDecoder().decode(PersistedRecord.self, from: data),
              record.version == 1 else {
            return .init(cachedLifetimeUnlock: legacyCachedLifetimeUnlock)
        }
        let revoked = transactionIDs(from: record.revokedTransactionIDs)
        let active = transactionIDs(from: record.verifiedActiveTransactionIDs)
        let retained = active.subtracting(revoked)
        // A malformed false record cannot acquire ownership from ID metadata.
        let owned = record.cachedLifetimeUnlock && (active.isEmpty || !retained.isEmpty)
        return .init(cachedLifetimeUnlock: owned,
                     verifiedActiveTransactionIDs: owned ? retained : [],
                     revokedTransactionIDs: revoked)
    }

    /// Preserve valid IDs even when another stored element is malformed.
    static func transactionIDs(from values: [String]?) -> Set<UInt64> {
        Set((values ?? []).compactMap { value in
            guard let id = UInt64(value), String(id) == value else { return nil }
            return id
        })
    }
}
