import Foundation

/// The model-specific cooldowns reported by ChatGPT's conversation endpoint.
///
/// A model with a `nil` reset date has no active cooldown that this parser can
/// report. It does not represent a quota, a message count, or an unlimited
/// allowance.
public struct ChatGPTModelLimitsSnapshot: Codable, Equatable, Sendable {
    public let models: [ChatGPTModelLimit]
    public let updatedAt: Date

    public init(models: [ChatGPTModelLimit], updatedAt: Date) {
        self.models = models
        self.updatedAt = updatedAt
    }
}

/// A requested ChatGPT model and its currently reported cooldown, if any.
public struct ChatGPTModelLimit: Codable, Equatable, Sendable {
    public let modelSlug: String
    public let title: String
    public let resetsAt: Date?

    public init(modelSlug: String, title: String, resetsAt: Date?) {
        self.modelSlug = modelSlug
        self.title = title
        self.resetsAt = resetsAt
    }
}

/// Parses the narrow, model-cooldown portion of ChatGPT's web responses.
///
/// The parser intentionally does not infer quotas from descriptions, usage
/// percentages, or `limits_progress`. `model_limits` entries are block/reset
/// signals only.
public enum ChatGPTModelLimitsParser {
    public static func parse(
        catalog: Data,
        metadata: Data,
        now: Date = Date()) throws -> ChatGPTModelLimitsSnapshot
    {
        let catalogObject = try Self.object(from: catalog, error: .invalidCatalog)
        let catalogData = Self.catalogData(from: catalogObject)
        guard catalogData.recognized else {
            throw ChatGPTModelLimitsParserError.noRecognizedCatalogEntries
        }

        let metadataObject = try Self.object(from: metadata, error: .invalidMetadata)
        guard metadataObject.keys.contains("model_limits") else {
            throw ChatGPTModelLimitsParserError.missingModelLimits
        }
        guard let rawLimits = metadataObject["model_limits"] as? [Any] else {
            throw ChatGPTModelLimitsParserError.modelLimitsNotArray
        }

        let metadataLimits = Self.metadataLimits(from: rawLimits, now: now)
        let selected = Self.selectCandidates(
            from: catalogData,
            metadataLimits: metadataLimits)
        return ChatGPTModelLimitsSnapshot(models: selected, updatedAt: now)
    }

    /// Returns the selected server slugs for the two requested Pro model
    /// targets. This is useful to the conversation client when it needs to
    /// pass the catalog's actual slug as `requested_default_model`.
    public static func requestedModelSlugs(catalog: Data) throws -> [String] {
        let catalogObject = try Self.object(from: catalog, error: .invalidCatalog)
        let catalogData = Self.catalogData(from: catalogObject)
        guard catalogData.recognized else {
            throw ChatGPTModelLimitsParserError.noRecognizedCatalogEntries
        }
        return Self.selectCandidates(from: catalogData, metadataLimits: [:]).map(\.modelSlug)
    }

    private enum RequestedModel: CaseIterable, Hashable {
        case gpt6
        case gpt56

        var title: String {
            switch self {
            case .gpt6: "GPT-6 Pro"
            case .gpt56: "GPT-5.6 Pro"
            }
        }
    }

    private struct CatalogModel {
        let slug: String
        let title: String?
        let reasoningType: String?
        let order: Int
    }

    private struct CatalogCategory {
        let target: RequestedModel
        let modelSlugs: [String]
        let defaultSlug: String?
        let order: Int
    }

    private struct CatalogData {
        let models: [CatalogModel]
        let categories: [CatalogCategory]
        let recognized: Bool
        let candidatesByTarget: [RequestedModel: [Candidate]]
    }

    private struct Candidate {
        let target: RequestedModel
        let slug: String
        let order: Int
        let isModelRecord: Bool
        let defaultRank: Int?
    }

    private struct MetadataLimit {
        let resetsAt: Date?
        let hasActiveReset: Bool
    }

    private static func object(
        from data: Data,
        error parseError: ChatGPTModelLimitsParserError) throws -> [String: Any]
    {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw parseError
        }
        guard let object = value as? [String: Any] else {
            throw parseError
        }
        return object
    }

    private static func catalogData(from object: [String: Any]) -> CatalogData {
        var recognized = false
        var models: [CatalogModel] = []

        if let rawModels = object["models"] as? [Any] {
            for (index, rawModel) in rawModels.enumerated() {
                guard let modelObject = rawModel as? [String: Any],
                      let slug = Self.nonEmptyString(modelObject["slug"])
                else { continue }
                recognized = true
                let model = CatalogModel(
                    slug: slug,
                    title: Self.nonEmptyString(modelObject["title"]),
                    reasoningType: Self.normalized(modelObject["reasoning_type"]),
                    order: index)
                models.append(model)
            }
        }

        var versionDisplayText: [String: String] = [:]
        if let rawVersions = object["versions"] as? [Any] {
            for rawVersion in rawVersions {
                guard let versionObject = rawVersion as? [String: Any],
                      let id = Self.nonEmptyString(versionObject["id"]),
                      let displayText = Self.nonEmptyString(versionObject["display_text"])
                else { continue }
                versionDisplayText[id] = displayText
            }
        }

        var categories: [CatalogCategory] = []
        var categoryEvidenceBySlug: [String: [(target: RequestedModel, order: Int)]] = [:]
        var categoryDefaultRankBySlug: [String: Int] = [:]

        if let rawCategories = object["categories"] as? [Any] {
            for (index, rawCategory) in rawCategories.enumerated() {
                guard let categoryObject = rawCategory as? [String: Any] else { continue }

                let lane = Self.normalized(modelObject: categoryObject, key: "model_lane")
                let modelVersion = Self.nonEmptyString(categoryObject["model_version"])
                let categoryTitle = Self.nonEmptyString(categoryObject["title"])
                let displayText = modelVersion.flatMap { versionDisplayText[$0] }
                let supportedSlugs = Self.stringArray(categoryObject["supported_models"])
                let defaultSlug = Self.nonEmptyString(categoryObject["default_model"])

                if lane != nil || modelVersion != nil || categoryTitle != nil
                    || categoryObject.keys.contains("supported_models") || defaultSlug != nil
                {
                    recognized = true
                }

                guard lane == "pro" else { continue }
                let targetFields = [modelVersion, categoryTitle, displayText].compactMap(Self.versionMatch)
                let uniqueTargets = Set(targetFields)
                guard uniqueTargets.count == 1, let target = uniqueTargets.first else { continue }

                var slugs = supportedSlugs
                if let defaultSlug, !slugs.contains(defaultSlug) {
                    slugs.append(defaultSlug)
                }
                guard !slugs.isEmpty else { continue }

                let category = CatalogCategory(
                    target: target,
                    modelSlugs: slugs,
                    defaultSlug: defaultSlug,
                    order: index)
                categories.append(category)

                for slug in slugs {
                    categoryEvidenceBySlug[slug, default: []].append((target: target, order: index))
                }
                if let defaultSlug {
                    let rank = categoryDefaultRankBySlug.count
                    if categoryDefaultRankBySlug[defaultSlug] == nil {
                        categoryDefaultRankBySlug[defaultSlug] = rank
                    }
                }
            }
        }

        return CatalogData(
            models: models,
            categories: categories,
            recognized: recognized,
            candidatesByTarget: Self.candidateMap(
                models: models,
                categories: categories,
                categoryEvidenceBySlug: categoryEvidenceBySlug,
                categoryDefaultRankBySlug: categoryDefaultRankBySlug))
    }

    private static func candidateMap(
        models: [CatalogModel],
        categories: [CatalogCategory],
        categoryEvidenceBySlug: [String: [(target: RequestedModel, order: Int)]],
        categoryDefaultRankBySlug: [String: Int]) -> [RequestedModel: [Candidate]]
    {
        // A category is the only place where an optional model title/reasoning
        // value may be filled in. Model records with an explicit non-Pro
        // reasoning type still remain excluded even if a category is broad.
        var candidatesByTarget: [RequestedModel: [Candidate]] = [:]
        for model in models {
            let categoryEvidence = categoryEvidenceBySlug[model.slug] ?? []
            let categoryTargets = Set(categoryEvidence.map(\.target))
            if let reasoningType = model.reasoningType, reasoningType != "pro" {
                continue
            }
            let modelTarget = Self.versionMatch(model.title)
            if modelTarget == nil, let title = model.title, Self.containsModelVersionNumber(in: title) {
                continue
            }
            if let modelTarget, !categoryTargets.isEmpty, !categoryTargets.contains(modelTarget) {
                continue
            }

            let target: RequestedModel? = if let modelTarget {
                model.reasoningType == "pro" || !categoryTargets.isEmpty ? modelTarget : nil
            } else if categoryTargets.count == 1 {
                categoryTargets.first
            } else {
                nil
            }
            guard let target else { continue }

            let defaultRank = categoryDefaultRankBySlug[model.slug]
            candidatesByTarget[target, default: []].append(Candidate(
                target: target,
                slug: model.slug,
                order: model.order,
                isModelRecord: true,
                defaultRank: defaultRank))
        }

        let knownSlugs = Set(models.map(\.slug))
        var syntheticOrder = models.count
        for category in categories {
            for slug in category.modelSlugs where !knownSlugs.contains(slug) {
                candidatesByTarget[category.target, default: []].append(Candidate(
                    target: category.target,
                    slug: slug,
                    order: syntheticOrder,
                    isModelRecord: false,
                    defaultRank: category.defaultSlug == slug ? category.order : nil))
                syntheticOrder += 1
            }
        }

        return candidatesByTarget
    }

    private static func metadataLimits(from rawLimits: [Any], now: Date) -> [String: MetadataLimit] {
        var limits: [String: MetadataLimit] = [:]
        for rawLimit in rawLimits {
            guard let limitObject = rawLimit as? [String: Any],
                  let slug = Self.nonEmptyString(limitObject["model_slug"])
            else { continue }

            let reset = Self.date(from: Self.nonEmptyString(limitObject["resets_after"]))
            let active = reset.map { $0 > now } ?? false
            let candidate = MetadataLimit(resetsAt: active ? reset : nil, hasActiveReset: active)
            guard let previous = limits[slug] else {
                limits[slug] = candidate
                continue
            }
            if candidate.hasActiveReset,
               !previous.hasActiveReset || candidate.resetsAt! > previous.resetsAt!
            {
                limits[slug] = candidate
            }
        }
        return limits
    }

    private static func selectCandidates(
        from catalog: CatalogData,
        metadataLimits: [String: MetadataLimit]) -> [ChatGPTModelLimit]
    {
        let candidatesByTarget = catalog.candidatesByTarget
        return RequestedModel.allCases.compactMap { target in
            guard let candidates = candidatesByTarget[target], !candidates.isEmpty else { return nil }
            let selected = Self.bestCandidate(candidates, metadataLimits: metadataLimits)
            return ChatGPTModelLimit(
                modelSlug: selected.slug,
                title: target.title,
                resetsAt: metadataLimits[selected.slug]?.resetsAt)
        }
    }

    private static func bestCandidate(
        _ candidates: [Candidate],
        metadataLimits: [String: MetadataLimit]) -> Candidate
    {
        candidates.min { lhs, rhs in
            let lhsLimit = metadataLimits[lhs.slug]
            let rhsLimit = metadataLimits[rhs.slug]
            let lhsActive = lhsLimit?.hasActiveReset == true
            let rhsActive = rhsLimit?.hasActiveReset == true
            if lhsActive != rhsActive {
                return lhsActive
            }
            if lhsActive,
               let lhsReset = lhsLimit?.resetsAt,
               let rhsReset = rhsLimit?.resetsAt,
               lhsReset != rhsReset
            {
                return lhsReset > rhsReset
            }
            switch (lhs.defaultRank, rhs.defaultRank) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }
            if lhs.isModelRecord != rhs.isModelRecord {
                return lhs.isModelRecord
            }
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.slug < rhs.slug
        }!
    }

    private static func versionMatch(_ text: String?) -> RequestedModel? {
        guard let text else { return nil }
        let has56 = Self.containsExactVersion("5.6", in: text)
        let has6 = Self.containsExactVersion("6", in: text)
        switch (has6, has56) {
        case (true, false): return .gpt6
        case (false, true): return .gpt56
        default: return nil
        }
    }

    private static func containsExactVersion(_ token: String, in text: String) -> Bool {
        let lowercased = text.lowercased()
        var searchStart = lowercased.startIndex
        while searchStart < lowercased.endIndex,
              let match = lowercased.range(of: token, range: searchStart..<lowercased.endIndex)
        {
            let before = match.lowerBound > lowercased.startIndex
                ? lowercased[lowercased.index(before: match.lowerBound)] : nil
            let after = match.upperBound < lowercased.endIndex
                ? lowercased[match.upperBound] : nil
            if !Self.isVersionContinuation(before), !Self.isVersionContinuation(after) {
                return true
            }
            searchStart = match.upperBound
        }
        return false
    }

    private static func isVersionContinuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character == "."
            || String(character).rangeOfCharacter(from: .alphanumerics) != nil
    }

    private static func containsModelVersionNumber(in text: String) -> Bool {
        guard text.range(of: "gpt", options: [.caseInsensitive]) != nil else { return false }
        return text.unicodeScalars.contains { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
    }

    private static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: Any?) -> String? {
        self.nonEmptyString(value)?.lowercased()
    }

    private static func normalized(modelObject: [String: Any], key: String) -> String? {
        self.normalized(modelObject[key])
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        var result: [String] = []
        for value in values {
            guard let string = Self.nonEmptyString(value), !result.contains(string) else { continue }
            result.append(string)
        }
        return result
    }
}

public enum ChatGPTModelLimitsParserError: Error, Equatable, Sendable {
    case invalidCatalog
    case noRecognizedCatalogEntries
    case invalidMetadata
    case missingModelLimits
    case modelLimitsNotArray
}
