import XCTest
@testable import PeelWatchCore

final class WatchCloudRelayTests: XCTestCase {
    func testIdentityAloneCannotMakeCourierReady() throws {
        let binding = try CloudAgentAccountBinding(provider: .dot, accountID: "account-a")
        let identityOnly = CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(binding))
        let value = WatchCloudResponse(requestID: UUID(), provider: .dot, ready: true,
                                       message: "Identity only", connectionStatus: identityOnly)
        XCTAssertFalse(value.ready)
        XCTAssertFalse(try WatchCloudResponse.decode(value.encoded()).ready)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        json["ready"] = true
        XCTAssertThrowsError(try WatchCloudResponse.decode(JSONSerialization.data(withJSONObject: json)))
    }
    func testChannelsAndProviderScopeCannotCrossDecode() throws {
        let cloud = WatchCloudRequest(kind: .status, provider: .grokBot)
        XCTAssertThrowsError(try WatchStreamRequest.decode(cloud.encoded()))
        XCTAssertThrowsError(try WatchCloudRequest.decode(WatchStreamRequest(kind: .status).encoded()))
        let binding = try CloudAgentAccountBinding(provider: .dot, accountID: "dot-account")
        let conversation = try CloudAgentConversationReference(binding: binding, agentID: "actual-dot", conversationID: "thread")
        XCTAssertThrowsError(try WatchCloudRequest(kind: .replies, provider: .grokBot, conversation: conversation).encoded())
    }
    func testReplyRequiresExactVerifiedAccountGeneration() throws {
        let current = try CloudAgentAccountBinding(provider: .dot, accountID: "account-a")
        let old = try CloudAgentAccountBinding(provider: .dot, accountID: "account-a")
        let status = CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(current), conversationCapability: .verified(current))
        let stale = try CloudAgentConversationReference(binding: old, agentID: "dot", conversationID: "conversation")
        let reply = WatchCloudReply(id: "message", conversation: stale, text: "Old account reply")
        let response = WatchCloudResponse(requestID: UUID(), provider: .dot, ready: true, message: "Ready",
            conversation: stale, replies: [reply], connectionStatus: status)
        XCTAssertThrowsError(try WatchCloudResponse.decode(response.encoded()))
    }
    func testFullLengthProviderReplyFitsAndOverallBudgetStillApplies() throws {
        let binding = try CloudAgentAccountBinding(provider: .grokBot, accountID: "grok-account")
        let status = CloudAgentConnectionStatus(provider: .grokBot, identity: .signedIn(binding), conversationCapability: .verified(binding))
        let conversation = try CloudAgentConversationReference(binding: binding, agentID: "existing-bot", conversationID: "thread")
        let message = WatchCloudReply(id: "reply", conversation: conversation, text: String(repeating: "x", count: 32_000))
        let value = WatchCloudResponse(requestID: UUID(), provider: .grokBot, ready: true, message: "Ready",
            conversation: conversation, replies: [message], connectionStatus: status)
        XCTAssertEqual(try WatchCloudResponse.decode(value.encoded()).replies.first?.text.count, 32_000)
        let overflow = WatchCloudResponse(requestID: UUID(), provider: .grokBot, ready: true, message: "Ready",
            conversation: conversation, replies: [message,message], connectionStatus: status)
        XCTAssertThrowsError(try overflow.encoded())
    }
    func testUnconfiguredStatusContainsNoCredentialOrAlternateRoute() throws {
        let value = WatchCloudResponse(requestID: UUID(), provider: .dot, ready: false, message: "Not integrated")
        let text = String(decoding: try value.encoded(), as: UTF8.self)
        for forbidden in ["token", "slack", "xoxp", "endpoint", "apiKey"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertFalse(try WatchCloudResponse.decode(value.encoded()).ready)
        XCTAssertThrowsError(try WatchCloudRequest(kind: .cancel, provider: .dot).encoded())
    }
}
