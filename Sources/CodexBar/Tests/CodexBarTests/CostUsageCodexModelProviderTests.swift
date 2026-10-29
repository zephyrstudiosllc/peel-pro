import Foundation
import Testing
@testable import CodexBarCore

/// Synthetic rollouts only: recorded `session_meta.payload.model_provider` qualifies Codex rows so local
/// and custom providers keep measured tokens without ever resolving to a vendor price.
struct CostUsageCodexModelProviderTests {
    private func sessionMeta(timestamp: String, provider: String?) -> [String: Any] {
        var payload: [String: Any] = ["id": "fixture-session", "cwd": "/tmp/fixture-project"]
        if let provider {
            payload["model_provider"] = provider
        }
        return ["type": "session_meta", "timestamp": timestamp, "payload": payload]
    }

    private func turnContext(timestamp: String, model: String) -> [String: Any] {
        ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]]
    }

    private func tokenCount(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }

    private func parse(
        provider: String?,
        model: String = "gpt-5.5") throws -> (CostUsageScanner.CodexParseResult, String)
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "provider-\(provider ?? "none").jsonl",
            contents: env.jsonl([
                self.sessionMeta(timestamp: env.isoString(for: day), provider: provider),
                self.turnContext(timestamp: env.isoString(for: day.addingTimeInterval(1)), model: model),
                self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    input: 100,
                    cached: 40,
                    output: 10),
            ]))
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        return (parsed, CostUsageScanner.CostUsageDayRange.dayKey(from: day))
    }

    @Test
    func `recorded local provider qualifies rows and keeps measured tokens`() throws {
        let (parsed, dayKey) = try self.parse(provider: "ollama")

        #expect(parsed.days[dayKey]?["model-provider:ollama/gpt-5.5"] == [100, 40, 10])
        #expect(parsed.days[dayKey]?["gpt-5.5"] == nil)
        #expect(parsed.rows.first?.model == "model-provider:ollama/gpt-5.5")
        #expect(parsed.rows.first?.rawModel == "gpt-5.5")
        #expect(parsed.lastModel == "model-provider:ollama/gpt-5.5")
    }

    @Test
    func `openai and unrecorded providers keep existing keys and estimate semantics`() throws {
        for provider in ["openai", "chatgpt", nil] as [String?] {
            let (parsed, dayKey) = try self.parse(provider: provider)
            #expect(parsed.days[dayKey]?["gpt-5.5"] == [100, 40, 10])
            #expect(parsed.lastModel == "gpt-5.5")
        }
    }

    @Test
    func `custom provider is qualified without keeping its recorded id`() throws {
        let (parsed, dayKey) = try self.parse(provider: "My-Private-Proxy")

        #expect(parsed.days[dayKey]?["model-provider:custom/gpt-5.5"] == [100, 40, 10])
        #expect(parsed.days[dayKey]?.keys.contains { $0.lowercased().contains("private") } == false)
        #expect(parsed.lastModel == "model-provider:custom/gpt-5.5")
    }

    @Test
    func `resumed scan restores provider qualification from persisted last model`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let head = try env.jsonl([
            self.sessionMeta(timestamp: env.isoString(for: day), provider: "lmstudio"),
        ])
        let tail = try env.jsonl([
            self.turnContext(timestamp: env.isoString(for: day.addingTimeInterval(1)), model: "fixture-local-model"),
            self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 50, cached: 0, output: 5),
        ])
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "resume.jsonl", contents: head + tail)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        // The checkpoint was taken after session_meta and before any model evidence.
        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            startOffset: Int64(head.utf8.count),
            initialModel: "model-provider:lmstudio/")

        #expect(parsed.days[dayKey]?["model-provider:lmstudio/fixture-local-model"] == [50, 0, 5])
        #expect(parsed.lastModel == "model-provider:lmstudio/fixture-local-model")
        #expect(CostUsageCodexModelProvider.restore(lastModel: "model-provider:lmstudio/").model == nil)
        #expect(CostUsageCodexModelProvider.restore(lastModel: "gpt-5.5").token == nil)
    }

    @Test
    func `oversized leaf session meta still yields a provider recorded before the cut`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso = env.isoString(for: day)
        let filler = String(repeating: "x", count: 300 * 1024)
        let metaLine = #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"id":"fixture-session","# +
            #""model_provider":"ollama","instructions":"\#(filler)"}}"# + "\n"
        let tail = try env.jsonl([
            self.turnContext(timestamp: env.isoString(for: day.addingTimeInterval(1)), model: "gpt-5.5"),
            self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 10, cached: 0, output: 1),
        ])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "oversized-meta.jsonl",
            contents: metaLine + tail)

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["model-provider:ollama/gpt-5.5"] == [10, 0, 1])
    }

    @Test
    func `qualified models never resolve a vendor or custom price`() {
        // The label is a known cloud model (it has a published Fast rate), so only the qualification
        // prevents pricing.
        #expect(CostUsagePricing.codexAPIFastMultiplier(model: "gpt-5.5") == 2.5)
        #expect(CostUsagePricing.codexAPIFastMultiplier(model: "model-provider:ollama/gpt-5.5") == nil)
        for model in ["model-provider:ollama/gpt-5.5", "model-provider:custom/gpt-5.5"] {
            #expect(CostUsagePricing.resolvedCodexPricing(
                model: model,
                modelsDevCatalog: nil,
                modelsDevCacheRoot: nil) == nil)
            #expect(CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 1000,
                cachedInputTokens: 0,
                outputTokens: 100) == nil)
            #expect(CostUsagePricing.codexPriorityCostUSD(model: model, inputTokens: 1000, outputTokens: 100) == nil)
        }
    }

    @Test
    func `provenance and display labels are typed`() {
        let local = CostUsageCodexModelProvider.provenance(of: "model-provider:ollama/gpt-oss:20b")
        #expect(local.endpoint == .local && local.localProviderID == "ollama" && local.model == "gpt-oss:20b")
        let custom = CostUsageCodexModelProvider.provenance(of: "model-provider:custom/gpt-5.5")
        #expect(custom.endpoint == .custom && custom.localProviderID == nil && custom.model == "gpt-5.5")
        let vendor = CostUsageCodexModelProvider.provenance(of: "gpt-5.5")
        #expect(vendor.endpoint == .openAIOrUnrecorded && vendor.model == "gpt-5.5")
        #expect(CostUsageCodexModelProvider.qualifierToken(forRecordedProvider: " OSS ") == "oss")
        #expect(CostUsageCodexModelProvider.qualifierToken(forRecordedProvider: "") == nil)
        #expect(UsageFormatter.modelDisplayName("model-provider:ollama/gpt-oss:20b").hasSuffix("(local · ollama)"))
        #expect(UsageFormatter.modelDisplayName("model-provider:custom/gpt-5.5").hasSuffix("(custom provider)"))
    }

    @Test
    func `persisted session metadata without a provider still decodes`() throws {
        let json = #"{"sessionId":"fixture","isSubagentThread":false}"#
        let metadata = try JSONDecoder().decode(
            CostUsageScanner.CodexSessionMetadata.self,
            from: Data(json.utf8))
        #expect(metadata.sessionId == "fixture")
        #expect(metadata.modelProvider == nil)
    }
}
