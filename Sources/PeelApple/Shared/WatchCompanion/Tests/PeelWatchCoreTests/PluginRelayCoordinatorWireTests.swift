import XCTest
@testable import PeelWatchCore

final class PluginRelayCoordinatorWireTests: XCTestCase {
    private func fence(provider: CloudAgentProvider = .dot) throws -> PluginRelayFence {
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        return PluginRelayFence(binding: .init(route: try .init(provider: provider, routeID: "route_wire_fixture",
            generation: uuid, accountGeneration: uuid), pairingEpoch: uuid), localEpoch: uuid)
    }

    func testEveryExistingV2KindKeepsFrozenLegacyEncoderBytes() throws {
        let current = try fence(), id = UUID(uuidString: "ABCDEFAB-1234-1234-1234-123456789ABC")!
        let message = try PluginRelayMessage(messageID: id, text: "legacy fixture")
        let receipt = try PluginRelayReceipt(requestID: id, route: current.binding.route,
            receiptID: "receipt_wire_fixture", state: .accepted, agentReplyReceived: false)
        let reply = try PluginRelayReply(requestID: id, replyID: "reply_wire_fixture", text: "reply fixture")
        let chunk = try PluginRelayChunk.split(reply, route: current.binding.route)[0]
        let legacy = [
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .status),
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .send, message: message),
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .receipt, receipt: receipt),
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .chunkRequest, requestID: id, replyID: reply.replyID, chunkIndex: 0),
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .chunk, chunk: chunk),
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .acknowledge, requestID: id, replyID: reply.replyID, digest: chunk.digest),
            try LegacyRelayV2FixtureEnvelope(courierID: id, fence: current, kind: .localStop, cancelCourierID: id)
        ]
        for old in legacy {
            let oldBytes = try old.encoded()
            let decoded = try PluginRelayV2Envelope.decode(oldBytes, expectedFence: current, expectedCourierID: id)
            XCTAssertEqual(try decoded.encoded(), oldBytes, "Existing encoding changed: \(old.kind)")
            XCTAssertNil(decoded.statusReport)
        }
    }

    func testStatusReportAndRefreshAreBoundedAndCourierFenced() throws {
        let current = try fence(), id = UUID()
        let notice = try PluginRelayReplyNotice(requestID: UUID(), replyID: "reply_notice", chunkCount: 4,
            totalUTF8Bytes: 32_000, digest: String(repeating: "a", count: 64))
        let report = PluginRelayStatusReport(state: .connected, remoteReady: true, deliveryMode: .events,
            automaticDeliveryReady: true, minimumRoutineIntervalSeconds: nil, nextReply: notice)
        let response = try PluginRelayV2Envelope(courierID: id, fence: current, kind: .statusReport, statusReport: report)
        let bytes = try response.encoded()
        XCTAssertLessThanOrEqual(bytes.count, 60 * 1_024)
        XCTAssertEqual(try PluginRelayV2Envelope.decode(bytes, expectedFence: current, expectedCourierID: id), response)
        XCTAssertThrowsError(try PluginRelayV2Envelope.decode(bytes, expectedFence: current, expectedCourierID: UUID()))
        XCTAssertThrowsError(try PluginRelayV2Envelope.decode(bytes, expectedFence: fence(provider: .grokBot)))
        let refresh = try PluginRelayV2Envelope(courierID: id, fence: current, kind: .replyRefresh)
        XCTAssertEqual(try PluginRelayV2Envelope.decode(refresh.encoded(), expectedFence: current), refresh)
        XCTAssertThrowsError(try PluginRelayV2Envelope(courierID: id, fence: current, kind: .replyRefresh, statusReport: report))
        XCTAssertThrowsError(try PluginRelayV2Envelope(courierID: id, fence: current, kind: .statusReport))
    }

    func testGrokManualAndPendingReportsCannotInflateAutomaticReadiness() throws {
        let current = try fence(provider: .grokBot)
        let manual = PluginRelayStatusReport(state: .manualReady, remoteReady: true, deliveryMode: .manual,
            automaticDeliveryReady: false, minimumRoutineIntervalSeconds: 300, nextReply: nil)
        XCTAssertNoThrow(try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .statusReport, statusReport: manual))
        let inflated = PluginRelayStatusReport(state: .connected, remoteReady: true, deliveryMode: .events,
            automaticDeliveryReady: true, minimumRoutineIntervalSeconds: nil, nextReply: nil)
        XCTAssertThrowsError(try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .statusReport, statusReport: inflated))
        let pending = PluginRelayStatusReport(state: .authorizePlugin, remoteReady: false, deliveryMode: .events,
            automaticDeliveryReady: false, minimumRoutineIntervalSeconds: nil, nextReply: nil)
        XCTAssertNoThrow(try pending.validate(provider: .dot))
        let fakePending = PluginRelayStatusReport(state: .authorizePlugin, remoteReady: false, deliveryMode: .events,
            automaticDeliveryReady: true, minimumRoutineIntervalSeconds: nil, nextReply: nil)
        XCTAssertThrowsError(try fakePending.validate(provider: .dot))
    }

    func testStrictEnvelopeRejectsUnknownDuplicateAndNullFieldsAtEveryShape() throws {
        let current = try fence(), value = try PluginRelayV2Envelope(courierID: UUID(), fence: current, kind: .status)
        let text = String(decoding: try value.encoded(), as: UTF8.self)
        let unknown = "{\"unknown\":1," + text.dropFirst()
        let duplicate = text.replacingOccurrences(of: "\"kind\":\"status\"", with: "\"kind\":\"status\",\"\\u006bind\":\"status\"")
        let nullPayload = "{\"statusReport\":null," + text.dropFirst()
        let nested = text.replacingOccurrences(of: "\"pairingEpoch\":", with: "\"extra\":true,\"pairingEpoch\":")
        let boolVersion = text.replacingOccurrences(of: "\"version\":2", with: "\"version\":true")
        for malformed in [unknown, duplicate, nullPayload, nested, boolVersion] {
            XCTAssertThrowsError(try PluginRelayV2Envelope.decode(Data(malformed.utf8), expectedFence: current))
        }
        let report = PluginRelayStatusReport(state: .connected, remoteReady: true, deliveryMode: .events,
            automaticDeliveryReady: true, minimumRoutineIntervalSeconds: nil, nextReply: nil)
        let reportText = String(decoding: try PluginRelayV2Envelope(courierID: UUID(), fence: current,
            kind: .statusReport, statusReport: report).encoded(), as: UTF8.self)
        let badReports = [
            reportText.replacingOccurrences(of: "\"remoteReady\":true", with: "\"remoteReady\":true,\"remoteReady\":false"),
            reportText.replacingOccurrences(of: "\"remoteReady\":true", with: "\"nextReply\":null,\"remoteReady\":true"),
            reportText.replacingOccurrences(of: "\"remoteReady\":true", with: "\"minimumRoutineIntervalSeconds\":null,\"remoteReady\":true"),
            reportText.replacingOccurrences(of: "\"remoteReady\":true", with: "\"remoteReady\":1")
        ]
        for malformed in badReports {
            XCTAssertThrowsError(try PluginRelayV2Envelope.decode(Data(malformed.utf8), expectedFence: current))
        }
    }
}
