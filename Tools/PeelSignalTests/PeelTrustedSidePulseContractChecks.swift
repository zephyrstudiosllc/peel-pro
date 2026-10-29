import Foundation

@main
enum PeelTrustedSidePulseContractChecks {
    private static let pairingID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let publisherHostID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let publisherNodeID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private static let otherPublisherNodeID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private static let subscriberHostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let subscriberNodeID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let otherPairingID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private static let otherPublisherHostID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private static let otherSubscriberHostID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private static let otherSubscriberNodeID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!

    private static let clientNonce = Data(repeating: 0x11, count: PeelSignalContract.nonceBytes)
    private static let serverNonce = Data(repeating: 0x22, count: PeelSignalContract.nonceBytes)
    private static let key = Data(repeating: 0x33, count: PeelSignalContract.keyBytes)

    static func main() throws {
        try testRoundTripAndWireBounds()
        try testValidRoleSeparatedProofs()
        try testBindingAndTamperRejection()
        try testMalformedInputRejection()
        try testFeatureNegotiation()
        try testFeatureValidation()
        print("Peel trusted SidePulse contract checks passed")
    }

    private static func testRoundTripAndWireBounds() throws {
        let hello = try makeHello()
        let serverProof = try PeelSignalAuthentication.serverProof(
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key)
        let challenge = try PeelSignalAuthentication.makeChallenge(
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key)
        let proofMessage = try PeelSignalProof(proof: serverProof)

        let helloData = try PeelSignalContract.encode(hello)
        let challengeData = try PeelSignalContract.encode(challenge)
        let proofData = try PeelSignalContract.encode(proofMessage)
        precondition(helloData.count <= PeelSignalContract.maximumJSONBytes)
        precondition(challengeData.count <= PeelSignalContract.maximumJSONBytes)
        precondition(proofData.count <= PeelSignalContract.maximumJSONBytes)
        let decodedHello = try PeelSignalContract.decode(PeelSignalHello.self, from: helloData)
        let decodedChallenge = try PeelSignalContract.decode(PeelSignalChallenge.self, from: challengeData)
        let decodedProof = try PeelSignalContract.decode(PeelSignalProof.self, from: proofData)
        precondition(decodedHello == hello)
        precondition(decodedChallenge == challenge)
        precondition(decodedProof == proofMessage)
        precondition(PeelSignalAuthentication.verifyServerProof(challenge, hello: hello, key: key))

        let framePayload = Data("{\"type\":\"nearbySignalFrame\"}".utf8)
        let frame = try PeelSignalFrame(payload: framePayload)
        let frameData = try PeelSignalContract.encodeFrame(frame)
        let decodedFrame = try PeelSignalContract.decodeFrame(from: frameData)
        precondition(decodedFrame == frame)

        let maximumPayload = try PeelSignalFrame(
            payload: Data(repeating: 0x7A, count: PeelSignalContract.maximumFramePayloadBytes))
        precondition(maximumPayload.payload.count == PeelSignalContract.maximumFramePayloadBytes)
        let maximumFrameData = try PeelSignalContract.encodeFrame(maximumPayload)
        precondition(maximumFrameData.count <= PeelSignalContract.maximumFrameJSONBytes)
        expectThrow {
            _ = try PeelSignalContract.encode(maximumPayload)
        }
        expectThrow {
            _ = try PeelSignalFrame(
                payload: Data(repeating: 0x7A, count: PeelSignalContract.maximumFramePayloadBytes + 1))
        }
        expectThrow {
            _ = try PeelSignalContract.decodeFrame(
                from: Data(repeating: 0x20, count: PeelSignalContract.maximumFrameJSONBytes + 1))
        }

        let nonce = PeelSignalAuthentication.mintNonce()
        precondition(nonce.count == PeelSignalContract.nonceBytes)
    }

    private static func testValidRoleSeparatedProofs() throws {
        let hello = try makeHello()
        let serverProof = try PeelSignalAuthentication.serverProof(
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key)
        let clientProof = try PeelSignalAuthentication.clientProof(
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key)

        precondition(serverProof.count == PeelSignalContract.proofBytes)
        precondition(clientProof.count == PeelSignalContract.proofBytes)
        let repeatedServerProof = try PeelSignalAuthentication.serverProof(
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key)
        precondition(serverProof == repeatedServerProof)
        precondition(serverProof != clientProof, "role domains must produce distinct proofs")
        precondition(PeelSignalAuthentication.verifyServerProof(
            serverProof,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))
        precondition(PeelSignalAuthentication.verifyClientProof(
            clientProof,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        let clientMessage = try PeelSignalProof(proof: clientProof)
        precondition(PeelSignalAuthentication.verifyClientProof(
            clientMessage,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))
    }

    private static func testBindingAndTamperRejection() throws {
        let hello = try makeHello()
        let proof = try PeelSignalAuthentication.serverProof(
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key)

        var tampered = proof
        tampered[0] ^= 0x01
        precondition(!PeelSignalAuthentication.verifyServerProof(
            tampered,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        let changedPairing = try makeHello(pairingId: otherPairingID)
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: changedPairing,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        let changedPublisher = try makeHello(publisherHostId: otherPublisherHostID)
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: changedPublisher,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: otherPublisherNodeID,
            key: key))

        let changedSubscriberHost = try makeHello(subscriberHostId: otherSubscriberHostID)
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: changedSubscriberHost,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        let changedSubscriberNode = try makeHello(subscriberNodeId: otherSubscriberNodeID)
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: changedSubscriberNode,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        let changedClientNonce = try makeHello(clientNonce: Data(repeating: 0x44, count: 32))
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: changedClientNonce,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        let changedServerNonce = Data(repeating: 0x55, count: 32)
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: hello,
            serverNonce: changedServerNonce,
            publisherNodeId: publisherNodeID,
            key: key))

        precondition(!PeelSignalAuthentication.verifyClientProof(
            proof,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: key))
        precondition(!PeelSignalAuthentication.verifyServerProof(
            proof,
            hello: hello,
            serverNonce: serverNonce,
            publisherNodeId: publisherNodeID,
            key: Data(repeating: 0x66, count: 32)))
    }

    private static func testMalformedInputRejection() throws {
        let hello = try makeHello()

        expectThrow {
            _ = try PeelSignalHello(
                pairingId: pairingID,
                publisherHostId: publisherHostID,
                subscriberHostId: subscriberHostID,
                subscriberNodeId: subscriberNodeID,
                clientNonce: Data(repeating: 0x01, count: 31))
        }
        expectThrow {
            _ = try PeelSignalChallenge(
                serverNonce: Data(repeating: 0x02, count: 33),
                publisherNodeId: publisherNodeID,
                proof: Data(repeating: 0x03, count: 32))
        }
        expectThrow {
            _ = try PeelSignalProof(proof: Data(repeating: 0x04, count: 31))
        }
        expectThrow {
            _ = try PeelSignalAuthentication.serverProof(
                hello: hello,
                serverNonce: serverNonce,
                publisherNodeId: publisherNodeID,
                key: Data(repeating: 0x05, count: 31))
        }

        let validHelloJSON = try String(
            data: PeelSignalContract.encode(hello),
            encoding: .utf8
        )!
        let malformedNonceJSON = validHelloJSON.replacingOccurrences(
            of: Data(clientNonce).base64EncodedString(),
            with: Data(repeating: 0x06, count: 31).base64EncodedString())
        expectThrow {
            _ = try PeelSignalContract.decode(
                PeelSignalHello.self,
                from: Data(malformedNonceJSON.utf8))
        }

        let malformedUUIDJSON = validHelloJSON.replacingOccurrences(
            of: pairingID.uuidString,
            with: "not-a-uuid")
        expectThrow {
            _ = try PeelSignalContract.decode(
                PeelSignalHello.self,
                from: Data(malformedUUIDJSON.utf8))
        }

        let wrongTypeJSON = validHelloJSON.replacingOccurrences(
            of: PeelSignalHello.messageType,
            with: "otherMessage")
        expectThrow {
            _ = try PeelSignalContract.decode(
                PeelSignalHello.self,
                from: Data(wrongTypeJSON.utf8))
        }

        let invalidBase64JSON = validHelloJSON.replacingOccurrences(
            of: Data(clientNonce).base64EncodedString(),
            with: "%%%not-base64%%")
        expectThrow {
            _ = try PeelSignalContract.decode(
                PeelSignalHello.self,
                from: Data(invalidBase64JSON.utf8))
        }
    }

    private static let allFeatures = ["activate.v1", "agents.v1", "usage.v1"]

    /// Old/new peers in both directions, explicit v2 negotiation binding both
    /// lists, and downgrade/upgrade tampering failing closed.
    private static func testFeatureNegotiation() throws {
        // v1 hello → v1 challenge, byte-identical to the legacy path.
        let legacyHello = try makeHello()
        let v1 = try PeelSignalAuthentication.makeNegotiatedChallenge(
            hello: legacyHello, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key,
            supportedFeatures: allFeatures)
        let legacy = try PeelSignalAuthentication.makeChallenge(
            hello: legacyHello, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key)
        precondition(v1 == legacy && v1.features == nil, "A v1 hello must get the unchanged v1 challenge")
        precondition(PeelSignalAuthentication.verifyNegotiatedServerProof(v1, hello: legacyHello, key: key))
        precondition(PeelSignalAuthentication.negotiatedFeatures(challenge: v1).isEmpty)
        let legacyClient = try PeelSignalAuthentication.negotiatedClientProof(hello: legacyHello, challenge: v1, key: key)
        let expectedLegacyClient = try PeelSignalAuthentication.clientProof(
            hello: legacyHello, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key)
        precondition(legacyClient == expectedLegacyClient)

        // New viewer → old publisher: the old publisher ignores `features`
        // and answers v1; the socket stays LED-only.
        let featured = try makeHello(features: allFeatures)
        let oldPublisher = try PeelSignalAuthentication.makeChallenge(
            hello: featured, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key)
        precondition(oldPublisher.features == nil)
        precondition(PeelSignalAuthentication.verifyNegotiatedServerProof(oldPublisher, hello: featured, key: key))
        let toOld = try PeelSignalProof(proof: PeelSignalAuthentication.negotiatedClientProof(
            hello: featured, challenge: oldPublisher, key: key))
        precondition(PeelSignalAuthentication.verifyClientProof(
            toOld, hello: featured, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key),
            "An old publisher must accept the new viewer's v1 proof")
        precondition(PeelSignalAuthentication.negotiatedFeatures(challenge: oldPublisher).isEmpty)

        // Old viewer (no features) → new publisher: covered by the v1 case above.

        // New ↔ new: explicit v2 with the granted subset.
        let v2 = try PeelSignalAuthentication.makeNegotiatedChallenge(
            hello: featured, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key,
            supportedFeatures: ["agents.v1", "usage.v1", "unknown.v9"])
        precondition(v2.features == ["agents.v1", "usage.v1"], "Grant only requested ∩ supported")
        precondition(PeelSignalAuthentication.verifyNegotiatedServerProof(v2, hello: featured, key: key))
        let v2Client = try PeelSignalProof(proof: PeelSignalAuthentication.negotiatedClientProof(
            hello: featured, challenge: v2, key: key))
        precondition(PeelSignalAuthentication.verifyNegotiatedClientProof(v2Client, hello: featured, challenge: v2, key: key))
        precondition(PeelSignalAuthentication.negotiatedFeatures(challenge: v2) == ["agents.v1", "usage.v1"])
        precondition(v2.proof != legacy.proof, "v2 uses a separate domain/transcript")

        // Empty grant is still explicit v2 (and still binds both lists).
        let none = try PeelSignalAuthentication.makeNegotiatedChallenge(
            hello: featured, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key, supportedFeatures: [])
        precondition(none.features == [] && PeelSignalAuthentication.verifyNegotiatedServerProof(none, hello: featured, key: key))

        // Stripping the challenge list cannot downgrade into a valid v1.
        let stripped = try PeelSignalChallenge(serverNonce: v2.serverNonce, publisherNodeId: v2.publisherNodeId,
                                               proof: v2.proof, features: nil)
        precondition(!PeelSignalAuthentication.verifyNegotiatedServerProof(stripped, hello: featured, key: key))
        // Adding a list to a v1 challenge cannot upgrade it.
        let upgraded = try PeelSignalChallenge(serverNonce: oldPublisher.serverNonce,
                                               publisherNodeId: oldPublisher.publisherNodeId,
                                               proof: oldPublisher.proof, features: ["agents.v1"])
        precondition(!PeelSignalAuthentication.verifyNegotiatedServerProof(upgraded, hello: featured, key: key))
        // Changing the granted list breaks the MAC.
        let widened = try PeelSignalChallenge(serverNonce: v2.serverNonce, publisherNodeId: v2.publisherNodeId,
                                              proof: v2.proof, features: allFeatures)
        precondition(!PeelSignalAuthentication.verifyNegotiatedServerProof(widened, hello: featured, key: key))
        // Changing the requested list breaks the MAC.
        let narrowerHello = try makeHello(features: ["agents.v1", "usage.v1"])
        precondition(!PeelSignalAuthentication.verifyNegotiatedServerProof(v2, hello: narrowerHello, key: key))
        // A grant outside the request is refused even before MAC checks.
        let agentsOnly = try makeHello(features: ["agents.v1"])
        precondition(!PeelSignalAuthentication.verifyNegotiatedServerProof(v2, hello: agentsOnly, key: key))
        // A v2 challenge never verifies against a featureless hello.
        precondition(!PeelSignalAuthentication.verifyNegotiatedServerProof(v2, hello: legacyHello, key: key))

        // Client side: a v1 proof cannot satisfy a v2 challenge, and a v2
        // proof for a different grant is rejected.
        let v1Proof = try PeelSignalProof(proof: PeelSignalAuthentication.clientProof(
            hello: featured, serverNonce: serverNonce, publisherNodeId: publisherNodeID, key: key))
        precondition(!PeelSignalAuthentication.verifyNegotiatedClientProof(v1Proof, hello: featured, challenge: v2, key: key))
        let noneProof = try PeelSignalProof(proof: PeelSignalAuthentication.negotiatedClientProof(
            hello: featured, challenge: none, key: key))
        precondition(!PeelSignalAuthentication.verifyNegotiatedClientProof(noneProof, hello: featured, challenge: v2, key: key))
        let wrongKey = Data(repeating: 0x44, count: PeelSignalContract.keyBytes)
        precondition(!PeelSignalAuthentication.verifyNegotiatedClientProof(v2Client, hello: featured, challenge: v2, key: wrongKey))

        // Wire round trip and legacy-decoder tolerance of the new keys.
        let helloData = try PeelSignalContract.encode(featured)
        let decodedFeatured = try PeelSignalContract.decode(PeelSignalHello.self, from: helloData)
        precondition(decodedFeatured == featured)
        let challengeData = try PeelSignalContract.encode(v2)
        let decodedV2 = try PeelSignalContract.decode(PeelSignalChallenge.self, from: challengeData)
        precondition(decodedV2 == v2)
        let legacyHelloJSON = try PeelSignalContract.encode(legacyHello)
        precondition(!String(decoding: legacyHelloJSON, as: UTF8.self).contains("features"),
                     "A v1 hello must not emit the features key")
        _ = try JSONDecoder().decode(LegacyHelloShape.self, from: helloData)
        _ = try JSONDecoder().decode(LegacyChallengeShape.self, from: challengeData)
    }

    private static func testFeatureValidation() throws {
        let canonical = try PeelSignalContract.validateFeatures(allFeatures)
        precondition(canonical == allFeatures)
        let empty = try PeelSignalContract.validateFeatures([])
        precondition(empty.isEmpty)
        for bad in [["agents.v1", "activate.v1"], ["agents.v1", "agents.v1"], ["Agents.v1"], ["agents v1"], [""],
                    [String(repeating: "a", count: 33)], (0..<9).map { "f\($0)" }] {
            expectThrow { _ = try PeelSignalContract.validateFeatures(bad) }
            expectThrow { _ = try makeHello(features: bad) }
        }
        let unsorted = """
        {"type":"peelSignalHello","pairingId":"\(pairingID.uuidString)","publisherHostId":"\(publisherHostID.uuidString)",
        "subscriberHostId":"\(subscriberHostID.uuidString)","subscriberNodeId":"\(subscriberNodeID.uuidString)",
        "clientNonce":"\(clientNonce.base64EncodedString())","features":["usage.v1","agents.v1"]}
        """
        expectThrow { _ = try PeelSignalContract.decode(PeelSignalHello.self, from: Data(unsorted.utf8)) }
    }

    /// The pre-negotiation decoders' key sets: extra keys are ignored.
    private struct LegacyHelloShape: Decodable {
        let type: String
        let pairingId: String
        let publisherHostId: String
        let subscriberHostId: String
        let subscriberNodeId: String
        let clientNonce: String
    }

    private struct LegacyChallengeShape: Decodable {
        let type: String
        let serverNonce: String
        let publisherNodeId: String
        let proof: String
    }

    private static func makeHello(
        pairingId: UUID = pairingID,
        publisherHostId: UUID = publisherHostID,
        subscriberHostId: UUID = subscriberHostID,
        subscriberNodeId: UUID = subscriberNodeID,
        clientNonce: Data = clientNonce,
        features: [String]? = nil
    ) throws -> PeelSignalHello {
        try PeelSignalHello(
            pairingId: pairingId,
            publisherHostId: publisherHostId,
            subscriberHostId: subscriberHostId,
            subscriberNodeId: subscriberNodeId,
            clientNonce: clientNonce,
            features: features)
    }

    private static func expectThrow(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected the operation to reject malformed input")
        } catch {
            // Expected.
        }
    }
}
