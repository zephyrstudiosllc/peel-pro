import Foundation
import XCTest
@testable import PeelWatchCore

final class CloudAgentConnectionTests: XCTestCase {
    func testPrimaryIdentityRoutesMatchHumanChoice() {
        XCTAssertEqual(CloudAgentSignInMethod.primary(for: .dot), .chatGPT)
        XCTAssertEqual(CloudAgentSignInMethod.primary(for: .grokBot), .x)
        XCTAssertEqual(CloudAgentSignInMethod.primary(for: .dot).title, "Sign in with ChatGPT")
    }
    func testOAuthIdentityAloneNeverEnablesExistingAgentChat() throws {
        let identity = try CloudAgentAccountBinding(provider: .dot, accountID: "fixture-dot-account")
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(identity)).canSend)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(identity),
                                                 conversationCapability: .unavailable(.existingAgentAPIUnverified)).canSend)
        XCTAssertFalse(CloudAgentConnectionStatus.notIntegrated(provider: .dot).canSend)
    }
    func testChatRequiresExactProviderAccountAndSessionGeneration() throws {
        let identity = try CloudAgentAccountBinding(provider: .dot, accountID: "fixture-dot-account")
        let ready = CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(identity), conversationCapability: .verified(identity))
        XCTAssertTrue(ready.canSend)
        let replaced = try CloudAgentAccountBinding(provider: .dot, accountID: identity.accountID)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(replaced), conversationCapability: .verified(identity)).canSend)
        let foreign = try CloudAgentAccountBinding(provider: .grokBot, accountID: identity.accountID, generation: identity.generation)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(identity), conversationCapability: .verified(foreign)).canSend)
        let wrongAccount = try CloudAgentAccountBinding(provider: .dot, accountID: "other-account", generation: identity.generation)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(identity), conversationCapability: .verified(wrongAccount)).canSend)
    }
    func testSignedOutAndAuthorizingAlwaysBlockEvenWithStaleCapability() throws {
        let identity = try CloudAgentAccountBinding(provider: .dot, accountID: "fixture-dot-account")
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .signedOut, conversationCapability: .verified(identity)).canSend)
        XCTAssertFalse(CloudAgentConnectionStatus(provider: .dot, identity: .authorizing, conversationCapability: .verified(identity)).canSend)
    }
    func testConversationReferenceRejectsLateCrossSessionReplyAndRoundTripsWithoutTokens() throws {
        let identity = try CloudAgentAccountBinding(provider: .dot, accountID: "fixture-account")
        let reference = try CloudAgentConversationReference(binding: identity, agentID: "existing-agent", conversationID: "native-conversation")
        let status = CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(identity), conversationCapability: .verified(identity))
        XCTAssertTrue(reference.matches(status))
        let replacement = try CloudAgentAccountBinding(provider: .dot, accountID: identity.accountID)
        XCTAssertFalse(reference.matches(CloudAgentConnectionStatus(provider: .dot, identity: .signedIn(replacement), conversationCapability: .verified(replacement))))
        let data = try JSONEncoder().encode(reference)
        XCTAssertEqual(try JSONDecoder().decode(CloudAgentConversationReference.self, from: data), reference)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["token", "authorization", "endpoint", "channelID", "threadTimestamp"] { XCTAssertFalse(json.contains(forbidden)) }
    }
    func testMalformedOpaqueIdentifiersCannotBypassDecoding() throws {
        XCTAssertThrowsError(try CloudAgentAccountBinding(provider: .dot, accountID: ""))
        XCTAssertThrowsError(try CloudAgentAccountBinding(provider: .dot, accountID: "bad\naccount"))
        let identity = try CloudAgentAccountBinding(provider: .dot, accountID: "fixture-account")
        XCTAssertThrowsError(try CloudAgentConversationReference(binding: identity, agentID: "", conversationID: "native"))
        let reference = try CloudAgentConversationReference(binding: identity, agentID: "agent", conversationID: "native")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        object["conversationID"] = String(repeating: "A", count: 257)
        XCTAssertThrowsError(try JSONDecoder().decode(CloudAgentConversationReference.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
