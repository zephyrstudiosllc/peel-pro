import Foundation

/// Where a Codex session's requests were served, taken only from the rollout's structured
/// `session_meta.payload.model_provider` field. No configuration, environment variable or endpoint
/// URL is read, so a provider ID is evidence of a provider *kind*, never of an address or a bill.
public enum CostUsageModelEndpoint: String, Sendable, Codable, Equatable {
    /// OpenAI's own provider (`openai`/`chatgpt`) or a log that recorded no provider. These rows keep
    /// the existing API-price estimate semantics.
    case openAIOrUnrecorded = "openai-or-unrecorded"
    /// One of Codex's built-in local providers (`oss`, `ollama`, `lmstudio`). Never priced.
    case local
    /// Any other recorded provider ID (a proxy, another cloud, a self-hosted server). Who serves and
    /// bills it is unknown, so it is never priced. The recorded ID itself is not kept.
    case custom
}

public struct CostUsageCodexModelProvenance: Sendable, Equatable {
    public let endpoint: CostUsageModelEndpoint
    /// The fixed built-in ID for `.local` rows; `nil` otherwise.
    public let localProviderID: String?
    /// The model label without provider qualification.
    public let model: String
}

/// Provider qualification of stored Codex model keys. Rows from a non-OpenAI provider are stored as
/// `model-provider:<token>/<model>` so they stay distinct from the same cloud label, carry their
/// provenance through every existing cache/report path, and never resolve to a catalog price.
public enum CostUsageCodexModelProvider {
    static let qualifierPrefix = "model-provider:"
    static let customToken = "custom"
    // Provider-specific by design: Codex CLI's fixed built-in provider IDs.
    static let openAIProviderIDs: Set<String> = ["openai", "chatgpt"]
    static let localProviderIDs: Set<String> = ["oss", "ollama", "lmstudio"]

    /// The qualifier for a recorded `model_provider`, or `nil` when rows keep their existing key.
    static func qualifierToken(forRecordedProvider raw: String?) -> String? {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty else {
            return nil
        }
        if self.openAIProviderIDs.contains(id) { return nil }
        if self.localProviderIDs.contains(id) { return id }
        return self.customToken
    }

    /// Qualifies an already-normalized model key. Idempotent.
    static func qualifiedModel(_ model: String, token: String?) -> String {
        guard let token, !self.isQualified(model) else { return model }
        return self.qualifierPrefix + token + "/" + model
    }

    /// The resume value for `lastModel`: keeps the provider qualification even before any model is seen.
    static func persistedLastModel(_ model: String?, token: String?) -> String? {
        guard let token else { return model }
        return self.qualifierPrefix + token + "/" + (model ?? "")
    }

    /// Restores the provider token and raw model evidence from a persisted `lastModel`.
    static func restore(lastModel: String?) -> (token: String?, model: String?) {
        guard let lastModel, let split = self.split(lastModel) else { return (nil, lastModel) }
        return (split.token, split.model.isEmpty ? nil : split.model)
    }

    public static func isQualified(_ storedModel: String) -> Bool {
        storedModel.hasPrefix(self.qualifierPrefix)
    }

    /// Typed provenance for a stored model key (as found in reports, breakdowns and `modelsUsed`).
    public static func provenance(of storedModel: String) -> CostUsageCodexModelProvenance {
        guard let split = self.split(storedModel) else {
            return CostUsageCodexModelProvenance(
                endpoint: .openAIOrUnrecorded,
                localProviderID: nil,
                model: storedModel)
        }
        if self.localProviderIDs.contains(split.token) {
            return CostUsageCodexModelProvenance(endpoint: .local, localProviderID: split.token, model: split.model)
        }
        return CostUsageCodexModelProvenance(endpoint: .custom, localProviderID: nil, model: split.model)
    }

    private static func split(_ storedModel: String) -> (token: String, model: String)? {
        guard self.isQualified(storedModel) else { return nil }
        let rest = storedModel.dropFirst(self.qualifierPrefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let token = String(rest[..<slash])
        guard !token.isEmpty else { return nil }
        return (token, String(rest[rest.index(after: slash)...]))
    }
}
