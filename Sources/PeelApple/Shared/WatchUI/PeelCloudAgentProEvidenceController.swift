#if os(iOS)
import Foundation
import PeelWatchCore

/// Read-only actual StoreKit evidence, collected only for a live authenticated
/// broker challenge. This never purchases, restores, prompts, finishes a
/// transaction, or grants authority from the app's local entitlement UI state.
@MainActor
final class PeelCloudAgentProEvidenceController: PluginRelayProEvidenceSource {
    func signedTransactions(isCurrent: @escaping @Sendable () -> Bool) async throws -> [String] {
        try Task.checkCancellation()
        guard isCurrent() else { throw PluginRelayProError.superseded }
        let transactions = await PeelStore.signedProTransactionEvidence(isCurrent: { isCurrent() })
        try Task.checkCancellation()
        guard isCurrent(), let transactions else { throw PluginRelayProError.unavailable }
        return transactions
    }
}
#endif
