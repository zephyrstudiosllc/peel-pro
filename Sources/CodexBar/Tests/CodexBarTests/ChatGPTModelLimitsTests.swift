import CodexBarCore
import Foundation
import Testing

struct ChatGPTModelLimitsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `selects only the reported GPT Pro targets and preserves active resets`() throws {
        let reset6 = self.now.addingTimeInterval(3600)
        let reset56 = self.now.addingTimeInterval(7200)
        let snapshot = try ChatGPTModelLimitsParser.parse(
            catalog: Self.data(Self.catalogJSON),
            metadata: Self.data(Self.metadataJSON(reset6: reset6, reset56: reset56)),
            now: self.now)

        #expect(snapshot.updatedAt == self.now)
        #expect(snapshot.models == [
            ChatGPTModelLimit(modelSlug: "srv-gpt-six", title: "GPT-6 Pro", resetsAt: reset6),
            ChatGPTModelLimit(modelSlug: "srv-gpt-five-six", title: "GPT-5.6 Pro", resetsAt: reset56),
        ])
    }

    @Test
    func `uses catalog category evidence when model title and reasoning are omitted`() throws {
        let catalog = """
        {
          "models": [
            {"slug": "srv-category-six"},
            {"slug": "srv-category-five-six"}
          ],
          "categories": [
            {
              "model_lane": "pro",
              "model_version": "v6",
              "supported_models": ["srv-category-six"],
              "default_model": "srv-category-six"
            },
            {
              "model_lane": "pro",
              "model_version": "version-56",
              "supported_models": ["srv-category-five-six"],
              "default_model": "srv-category-five-six"
            }
          ],
          "versions": [
            {"id": "v6", "display_text": "GPT-6"},
            {"id": "version-56", "display_text": "GPT-5.6 Pro"}
          ]
        }
        """
        let slugs = try ChatGPTModelLimitsParser.requestedModelSlugs(catalog: Self.data(catalog))
        #expect(slugs == ["srv-category-six", "srv-category-five-six"])

        let snapshot = try ChatGPTModelLimitsParser.parse(
            catalog: Self.data(catalog),
            metadata: Self.data(#"{"model_limits": []}"#),
            now: self.now)
        #expect(snapshot.models == [
            ChatGPTModelLimit(modelSlug: "srv-category-six", title: "GPT-6 Pro", resetsAt: nil),
            ChatGPTModelLimit(modelSlug: "srv-category-five-six", title: "GPT-5.6 Pro", resetsAt: nil),
        ])
    }

    @Test
    func `skips malformed siblings wrong versions and non Pro reasoning`() throws {
        let catalog = """
        {
          "models": [
            null,
            {"title": "GPT-6 Pro", "reasoning_type": "pro"},
            {"slug": "srv-six-one", "title": "GPT-6.1 Pro", "reasoning_type": "pro"},
            {"slug": "srv-six-letter", "title": "GPT-6B Pro", "reasoning_type": "pro"},
            {"slug": "srv-five-six-letter", "title": "GPT-5.6x Pro", "reasoning_type": "pro"},
            {"slug": "srv-six-thinking", "title": "GPT-6 Thinking", "reasoning_type": "thinking"},
            {"slug": "srv-six-standard", "title": "GPT-6", "reasoning_type": "standard"},
            {"slug": "srv-unrelated", "title": "GPT-4 Pro", "reasoning_type": "pro"},
            {"slug": "srv-valid-six", "title": "GPT-6 Pro", "reasoning_type": "pro"},
            {"slug": "srv-valid-five-six", "title": "GPT-5.6 Pro", "reasoning_type": "pro"}
          ],
          "categories": [
            {"model_lane": "pro", "model_version": "6.1", "supported_models": ["srv-six-one"]},
            {"model_lane": "standard", "model_version": "6", "supported_models": ["srv-six-standard"]}
          ]
        }
        """
        let metadata = """
        {
          "model_limits": [
            {"model_slug": "srv-valid-six", "resets_after": "not-a-date"},
            {"model_slug": "srv-valid-five-six", "resets_after": "also-not-a-date"},
            {"model_slug": 42, "resets_after": "2026-01-01T00:00:00Z"},
            {"resets_after": "2026-01-01T00:00:00Z"},
            null
          ]
        }
        """
        let snapshot = try ChatGPTModelLimitsParser.parse(
            catalog: Self.data(catalog), metadata: Self.data(metadata), now: self.now)

        #expect(snapshot.models.map(\.modelSlug) == ["srv-valid-six", "srv-valid-five-six"])
        #expect(snapshot.models.allSatisfy { $0.resetsAt == nil })
        #expect(!snapshot.models.contains { $0.modelSlug == "srv-six-one" })
        #expect(!snapshot.models.contains { $0.modelSlug == "srv-six-letter" })
        #expect(!snapshot.models.contains { $0.modelSlug == "srv-five-six-letter" })
        #expect(!snapshot.models.contains { $0.modelSlug == "srv-six-thinking" })
        #expect(!snapshot.models.contains { $0.modelSlug == "srv-unrelated" })
    }

    @Test
    func `expired and invalid reset dates remain unknown rather than becoming quota values`() throws {
        let metadata = """
        {
          "model_limits": [
            {"model_slug": "srv-gpt-six", "resets_after": "2026-01-01T00:00:00Z"},
            {"model_slug": "srv-gpt-five-six", "resets_after": "invalid"}
          ],
          "limits_progress": [
            {"feature_name": "messages", "remaining": 0, "reset_after": 1}
          ]
        }
        """
        let snapshot = try ChatGPTModelLimitsParser.parse(
            catalog: Self.data(Self.catalogJSON), metadata: Self.data(metadata), now: self.now)

        #expect(snapshot.models.count == 2)
        #expect(snapshot.models.allSatisfy { $0.resetsAt == nil })
        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!encodedText.contains("remaining"))
        #expect(!encodedText.contains("count"))
    }

    @Test
    func `requires recognized catalog arrays and metadata model limits`() throws {
        let validCatalog = Self.data(Self.catalogJSON)
        let validMetadata = Self.data(#"{"model_limits": []}"#)

        #expect(throws: ChatGPTModelLimitsParserError.noRecognizedCatalogEntries) {
            try ChatGPTModelLimitsParser.parse(
                catalog: Self.data(#"{"versions": [{"id": "v", "display_text": "GPT-6 Pro"}]}"#),
                metadata: validMetadata,
                now: self.now)
        }
        #expect(throws: ChatGPTModelLimitsParserError.invalidCatalog) {
            try ChatGPTModelLimitsParser.parse(catalog: Self.data("not-json"), metadata: validMetadata, now: self.now)
        }
        #expect(throws: ChatGPTModelLimitsParserError.missingModelLimits) {
            try ChatGPTModelLimitsParser.parse(
                catalog: validCatalog,
                metadata: Self.data(#"{"limits_progress": []}"#),
                now: self.now)
        }
        #expect(throws: ChatGPTModelLimitsParserError.modelLimitsNotArray) {
            try ChatGPTModelLimitsParser.parse(
                catalog: validCatalog,
                metadata: Self.data(#"{"model_limits": null}"#),
                now: self.now)
        }
        #expect(throws: ChatGPTModelLimitsParserError.invalidMetadata) {
            try ChatGPTModelLimitsParser.parse(catalog: validCatalog, metadata: Self.data("[]"), now: self.now)
        }
    }

    @Test
    func `snapshot round trips with Codable dates`() throws {
        let reset = self.now.addingTimeInterval(1234)
        let snapshot = try ChatGPTModelLimitsParser.parse(
            catalog: Self.data(Self.catalogJSON),
            metadata: Self.data(Self.metadataJSON(reset6: reset, reset56: nil)),
            now: self.now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            ChatGPTModelLimitsSnapshot.self,
            from: encoder.encode(snapshot))
        #expect(decoded == snapshot)
    }

    private static let catalogJSON = """
    {
      "models": [
        {"slug": "srv-gpt-six", "title": "GPT-6 Pro", "reasoning_type": "pro"},
        {"slug": "srv-gpt-five-six", "title": "GPT-5.6 Pro", "reasoning_type": "pro"},
        {"slug": "srv-gpt-six-one", "title": "GPT-6.1 Pro", "reasoning_type": "pro"},
        {"slug": "srv-gpt-six-thinking", "title": "GPT-6 Thinking", "reasoning_type": "thinking"}
      ],
      "categories": [
        {
          "model_lane": "pro",
          "model_version": "6",
          "title": "GPT-6 Pro",
          "supported_models": ["srv-gpt-six"],
          "default_model": "srv-gpt-six"
        },
        {
          "model_lane": "pro",
          "model_version": "5.6",
          "title": "GPT-5.6 Pro",
          "supported_models": ["srv-gpt-five-six"],
          "default_model": "srv-gpt-five-six"
        }
      ]
    }
    """

    private static func metadataJSON(reset6: Date?, reset56: Date?) -> String {
        let reset6Text = reset6.map(Self.iso8601) ?? ""
        let reset56Text = reset56.map(Self.iso8601) ?? ""
        let first = reset6 == nil
            ? "{\"model_slug\": \"srv-gpt-six\"}"
            : "{\"model_slug\": \"srv-gpt-six\", \"resets_after\": \"\(reset6Text)\"}"
        let second = reset56 == nil
            ? "{\"model_slug\": \"srv-gpt-five-six\"}"
            : "{\"model_slug\": \"srv-gpt-five-six\", \"resets_after\": \"\(reset56Text)\"}"
        return "{\"model_limits\": [\(first), \(second)]}"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
