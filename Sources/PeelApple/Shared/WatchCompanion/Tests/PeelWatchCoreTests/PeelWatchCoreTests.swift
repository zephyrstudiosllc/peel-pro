import Foundation
import XCTest
@testable import PeelWatchCore

final class PeelWatchCoreTests: XCTestCase {
    private func draft(
        id: UUID = UUID(),
        provider: CompanionProvider = .openAI,
        text: String = "A local draft",
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) throws -> CompanionDraft {
        try CompanionDraft(id: id, provider: provider, text: text, createdAt: createdAt)
    }

    private func assertValidationError<T>(
        _ expected: CompanionValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? CompanionValidationError, expected, file: file, line: line)
        }
    }

    func testDraftTrimsBoundaryWhitespace() throws {
        let item = try draft(text: " \n\tHello\nthere \t\n")
        XCTAssertEqual(item.text, "Hello\nthere")
    }

    func testBlankDraftCannotBeCreated() {
        assertValidationError(.emptyText) { try draft(text: " \t\n") }
    }

    func testTextLimitCountsCharactersAndAcceptsBoundary() throws {
        XCTAssertEqual(try draft(text: String(repeating: "a", count: 4_000)).text.count, 4_000)
        assertValidationError(.textTooLong(maximum: 4_000)) {
            try draft(text: String(repeating: "a", count: 4_001))
        }
    }

    func testNonFiniteCreationDateIsRejected() {
        assertValidationError(.invalidDate) { try draft(createdAt: Date(timeIntervalSinceReferenceDate: .infinity)) }
    }

    func testAllProvidersExplicitlyHaveNoLiveConnectionCapabilities() {
        for provider in CompanionProvider.allCases {
            XCTAssertFalse(provider.liveCapabilities.accountSignIn)
            XCTAssertFalse(provider.liveCapabilities.textChat)
            XCTAssertFalse(provider.liveCapabilities.voiceChat)
            XCTAssertFalse(provider.liveCapabilities.remoteSessionControl)
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.systemImage.isEmpty)
        }
        XCTAssertEqual(Set(CompanionProvider.allCases.map(\.id)).count, 3)
    }

    func testEnvelopeRoundTripPreservesProviderIdentityAndText() throws {
        for provider in CompanionProvider.allCases {
            let item = try draft(provider: provider, text: "Hello 🌍")
            let envelope = CompanionEnvelope(draft: item)
            XCTAssertEqual(try CompanionEnvelope(data: envelope.encodedData()), envelope)
            XCTAssertEqual(envelope.version, 1)
        }
    }

    func testUnknownEnvelopeVersionCannotFallBackToCurrentDecoder() throws {
        let data = Data(#"{"version":2,"draft":{}}"#.utf8)
        assertValidationError(.unsupportedVersion(2)) { try CompanionEnvelope(data: data) }
    }

    func testMalformedAndEmptyPayloadAreRejected() {
        for text in ["", "garbage", "[]", "{}", #"{"version":1,"draft":{}}"#] {
            assertValidationError(.malformedPayload) { try CompanionEnvelope(data: Data(text.utf8)) }
        }
    }

    func testUnknownProviderAndInvalidDraftFieldsAreRejectedOnDecode() throws {
        let valid = try CompanionEnvelope(draft: draft()).encodedData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var contents = try XCTUnwrap(json["draft"] as? [String: Any])
        contents["provider"] = "unknown-provider"
        json["draft"] = contents
        let unknownProvider = try JSONSerialization.data(withJSONObject: json)
        assertValidationError(.malformedPayload) { try CompanionEnvelope(data: unknownProvider) }
        contents["provider"] = "openAI"
        contents["text"] = " \n"
        json["draft"] = contents
        let blank = try JSONSerialization.data(withJSONObject: json)
        assertValidationError(.emptyText) { try CompanionEnvelope(data: blank) }
        contents["text"] = String(repeating: "a", count: 4_001)
        json["draft"] = contents
        let tooLong = try JSONSerialization.data(withJSONObject: json)
        assertValidationError(.textTooLong(maximum: 4_000)) { try CompanionEnvelope(data: tooLong) }
    }

    func testByteLimitAcceptsExactBoundaryAndRejectsOneMoreByte() throws {
        let envelope = CompanionEnvelope(draft: try draft())
        var data = try envelope.encodedData()
        data.append(Data(repeating: 0x20, count: CompanionEnvelope.maximumPayloadBytes - data.count))
        XCTAssertEqual(try CompanionEnvelope(data: data), envelope)
        data.append(0x20)
        assertValidationError(.payloadTooLarge(maximum: CompanionEnvelope.maximumPayloadBytes)) {
            try CompanionEnvelope(data: data)
        }
    }

    func testOversizeInputFailsBeforeJSONParsing() {
        let data = Data(repeating: 0xFF, count: CompanionEnvelope.maximumPayloadBytes + 1)
        assertValidationError(.payloadTooLarge(maximum: CompanionEnvelope.maximumPayloadBytes)) {
            try CompanionEnvelope(data: data)
        }
    }

    func testUnicodeDraftMayFitCharacterLimitButCannotBypassWireByteLimit() throws {
        let item = try draft(text: String(repeating: "👨‍👩‍👧‍👦", count: 1_000))
        assertValidationError(.payloadTooLarge(maximum: CompanionEnvelope.maximumPayloadBytes)) {
            try CompanionEnvelope(draft: item).encodedData()
        }
    }

    func testInboxRedeliveryIsIdempotentAndCannotChangeProvider() throws {
        let first = try draft(provider: .openAI, text: "Original")
        let altered = try draft(id: first.id, provider: .grok, text: "Changed")
        var inbox = CompanionInbox()
        XCTAssertTrue(inbox.insert(first))
        XCTAssertFalse(inbox.insert(first))
        XCTAssertFalse(inbox.insert(altered))
        XCTAssertEqual(inbox.drafts, [first])
        XCTAssertTrue(inbox.drafts(for: .grok).isEmpty)
    }

    func testInboxRejectsNewDeliveryAtCapWithoutDeletingExistingDrafts() throws {
        var inbox = CompanionInbox()
        var inserted: [CompanionDraft] = []
        for index in 0..<100 {
            let item = try draft(text: "Draft \(index)")
            inserted.append(item)
            XCTAssertTrue(inbox.insert(item))
        }
        let fullInbox = inbox
        for index in 100..<105 {
            XCTAssertFalse(inbox.insert(try draft(text: "Draft \(index)")))
            XCTAssertEqual(inbox, fullInbox)
        }
        XCTAssertEqual(inbox.drafts.count, 100)
        XCTAssertEqual(inbox.drafts.first, inserted.last)
        XCTAssertEqual(inbox.drafts.last, inserted.first)
        XCTAssertEqual(inbox.drafts, inserted.reversed())
    }

    func testDuplicateDeliveryAtCapacityCannotModifyOrReorderExistingDrafts() throws {
        let existing = try (0..<100).map { try draft(text: "Draft \($0)") }
        var inbox = CompanionInbox(drafts: existing)
        let fullInbox = inbox
        let altered = try draft(id: existing[99].id, provider: .grok, text: "Changed")
        XCTAssertFalse(inbox.insert(existing[0]))
        XCTAssertFalse(inbox.insert(altered))
        XCTAssertEqual(inbox, fullInbox)
    }

    func testArrayInitializerUsesFirstHundredDistinctIDsInSuppliedOrder() throws {
        let existing = try (0..<105).map { try draft(text: "Draft \($0)") }
        let seeded = [existing[0], existing[0]] + Array(existing.dropFirst())
        let inbox = CompanionInbox(drafts: seeded)
        XCTAssertEqual(inbox.drafts, Array(existing.prefix(100)))
    }

    func testProviderFilteringDoesNotMixDrafts() throws {
        let openAI = try draft(provider: .openAI)
        let grok = try draft(provider: .grok)
        let claude = try draft(provider: .claude)
        let inbox = CompanionInbox(drafts: [openAI, grok, claude])
        XCTAssertEqual(inbox.drafts(for: .openAI), [openAI])
        XCTAssertEqual(inbox.drafts(for: .grok), [grok])
        XCTAssertEqual(inbox.drafts(for: .claude), [claude])
    }

    func testInboxRoundTripDeduplicatesWithoutReordering() throws {
        let first = try draft(provider: .claude)
        let second = try draft(provider: .grok)
        let arrayData = try JSONEncoder().encode([first, second, first])
        let data = Data("{\"drafts\":".utf8) + arrayData + Data("}".utf8)
        let inbox = try JSONDecoder().decode(CompanionInbox.self, from: data)
        XCTAssertEqual(inbox.drafts, [first, second])
        XCTAssertEqual(try JSONDecoder().decode(CompanionInbox.self, from: JSONEncoder().encode(inbox)), inbox)
    }

    func testOversizeInboxDecodeIsRejectedEvenWhenIDsAreDuplicates() throws {
        let repeated = Array(repeating: try draft(), count: 101)
        let arrayData = try JSONEncoder().encode(repeated)
        let data = Data("{\"drafts\":".utf8) + arrayData + Data("}".utf8)
        assertValidationError(.tooManyDrafts(maximum: 100)) {
            try JSONDecoder().decode(CompanionInbox.self, from: data)
        }
    }

    func testDiskStoreMissingFileStartsEmptyAndSaveSurvivesNewInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("nested/drafts.json")
        let store = CompanionDiskStore(fileURL: fileURL)
        XCTAssertEqual(try store.load(), CompanionInbox())
        let inbox = CompanionInbox(drafts: [try draft(provider: .claude)])
        try store.save(inbox)
        XCTAssertEqual(try CompanionDiskStore(fileURL: fileURL).load(), inbox)
        var replacement = inbox
        replacement.insert(try draft(provider: .grok))
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
    }

    func testCorruptDiskDataIsReportedWithoutReplacingFile() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let corrupt = Data("broken JSON".utf8)
        try corrupt.write(to: fileURL)
        assertValidationError(.malformedPayload) { try CompanionDiskStore(fileURL: fileURL).load() }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testOversizeDiskFileIsRejectedBeforeDecoding() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(repeating: 0, count: CompanionDiskStore.maximumStoredBytes + 1).write(to: fileURL)
        assertValidationError(.payloadTooLarge(maximum: CompanionDiskStore.maximumStoredBytes)) {
            try CompanionDiskStore(fileURL: fileURL).load()
        }
    }

    func testOfficialClaudeCodeURLsAreAcceptedWithoutImplyingConnection() throws {
        for value in ["https://claude.ai/code", "https://claude.ai/code/", "https://claude.ai/code/session_123-ABC", " https://claude.ai/code/session_123 \n"] {
            let url = try OfficialClaudeSessionURL.validated(value)
            XCTAssertEqual(url.host, "claude.ai")
            XCTAssertEqual(url.scheme, "https")
        }
    }

    func testClaudeSessionURLRejectsCredentialsTokensLookalikeHostsAndAmbiguousPaths() {
        let values = [
            "http://claude.ai/code",
            "https://claude.ai.evil.example/code/session",
            "https://evil.example/claude.ai/code/session",
            "https://user@claude.ai/code/session",
            "https://user:secret@claude.ai/code/session",
            "https://claude.ai:443/code/session",
            "https://claude.ai/code/session?token=secret",
            "https://claude.ai/code/session?anything=secret",
            "https://claude.ai/code/session#secret",
            "https://claude.ai/chat/session",
            "https://claude.ai/code-other/session",
            "https://claude.ai/code/../chat/session",
            "https://claude.ai/code/%2E%2E/chat/session",
            "https://claude.ai/code/%2Fsession",
            "https://claude.ai/code//session",
            "https://claude.ai/code/session with spaces",
            "https://claude.ai/code/session\\other",
            "claude://code/session",
            "//claude.ai/code/session",
            "https://claude.ai/code/" + String(repeating: "a", count: 2_048)
        ]
        for value in values {
            assertValidationError(.invalidSessionURL) { try OfficialClaudeSessionURL.validated(value) }
        }
    }
}
