import Foundation

private enum AudioProofChecks {
    static let requestID = "01234567-89AB-CDEF-0123-456789ABCDEF"
    static let pairingID = "fixture-pairing"
    static let nonce = Data(repeating: 0xA5, count: 32).base64EncodedString()
    static let key = Data(repeating: 0x11, count: 32)
    static let wrongKey = Data(repeating: 0x22, count: 32)
    static let now = 1_800_000_000.0
    static let expiry = now + 10

    static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAILED: " + label) }
    }

    static func challenge(
        requestID: String = requestID,
        pairingID: String = pairingID,
        nonce: String = nonce,
        expiresAt: Double = expiry
    ) -> PeelAudioPairingChallengeMessage {
        PeelAudioPairingChallengeMessage(requestId: requestID, pairingId: pairingID,
                                         nonce: nonce, expiresAt: expiresAt)
    }

    static func proof(for challenge: PeelAudioPairingChallengeMessage) -> String {
        guard let proof = PeelAudioPairingProof.make(challenge, key: key) else {
            fatalError("FAILED: make valid proof")
        }
        return proof
    }

    static func testValidAdmissionAndDomainSeparation() {
        let audioChallenge = challenge()
        let audioProof = proof(for: audioChallenge)
        require(PeelAudioPairingProof.verify(audioProof, challenge: audioChallenge, key: key),
                "valid audio proof verifies")

        let agentChallenge = PeelAgentPairingChallengeMessage(
            requestId: requestID, pairingId: pairingID, nonce: nonce, expiresAt: expiry)
        guard let agentProof = PeelAgentPairingProof.make(agentChallenge, key: key) else {
            fatalError("FAILED: make valid agent proof")
        }
        require(PeelAgentPairingProof.verify(agentProof, challenge: agentChallenge, key: key),
                "valid agent proof verifies")
        require(!PeelAudioPairingProof.verify(agentProof, challenge: audioChallenge, key: key),
                "agent proof cannot cross the audio domain")
        require(!PeelAgentPairingProof.verify(audioProof, challenge: agentChallenge, key: key),
                "audio proof cannot cross the agent domain")
    }

    static func testChangedBoundFieldsAreRejected() {
        let original = challenge()
        let validProof = proof(for: original)
        let requestChanged = challenge(requestID: "01234567-89AB-CDEF-0123-456789ABCDE0")
        let pairingChanged = challenge(pairingID: "other-pairing")
        let nonceChanged = challenge(nonce: Data(repeating: 0xA6, count: 32).base64EncodedString())
        let expiryChanged = challenge(expiresAt: expiry + 1)

        require(!PeelAudioPairingProof.verify(validProof, challenge: requestChanged, key: key),
                "request ID change rejected")
        require(!PeelAudioPairingProof.verify(validProof, challenge: pairingChanged, key: key),
                "pairing ID change rejected")
        require(!PeelAudioPairingProof.verify(validProof, challenge: nonceChanged, key: key),
                "nonce change rejected")
        require(!PeelAudioPairingProof.verify(validProof, challenge: expiryChanged, key: key),
                "expiry change rejected")
    }

    static func testWrongAndMalformedKeysAreRejected() {
        let current = challenge()
        let validProof = proof(for: current)
        require(!PeelAudioPairingProof.verify(validProof, challenge: current, key: wrongKey),
                "wrong key rejected")
        require(!PeelAudioPairingProof.verify(validProof, challenge: current,
                                              key: Data(repeating: 0, count: 31)),
                "short key rejected")
        require(!PeelAudioPairingProof.verify("not-base64", challenge: current, key: key),
                "malformed proof rejected")

        require(PeelAudioPairingProof.make(challenge(requestID: "not-a-uuid"), key: key) == nil,
                "invalid request ID cannot make proof")
        require(PeelAudioPairingProof.make(
            challenge(nonce: Data(repeating: 0, count: 31).base64EncodedString()), key: key) == nil,
            "short nonce cannot make proof")
        require(PeelAudioPairingProof.make(challenge(pairingID: ""), key: key) == nil,
                "empty pairing ID cannot make proof")
        require(PeelAudioPairingProof.make(
            challenge(pairingID: String(repeating: "a", count: 257)), key: key) == nil,
            "oversized pairing ID cannot make proof")
        require(PeelAudioPairingProof.make(challenge(pairingID: "pair\u{0}ing"), key: key) == nil,
                "NUL pairing ID cannot make proof")
        require(PeelAudioPairingProof.make(challenge(expiresAt: 0), key: key) == nil,
                "nonpositive expiry cannot make proof")
        require(PeelAudioPairingProof.make(challenge(expiresAt: .nan), key: key) == nil,
                "NaN expiry cannot make proof")
    }

    static func testFreshnessBoundaries() {
        require(PeelAudioPairingProof.isFresh(challenge(expiresAt: now + 1), now: now),
                "future expiry is fresh")
        require(PeelAudioPairingProof.isFresh(challenge(expiresAt: now + 60), now: now),
                "sixty-second upper bound is fresh")
        require(!PeelAudioPairingProof.isFresh(challenge(expiresAt: now), now: now),
                "expiry at now is stale")
        require(!PeelAudioPairingProof.isFresh(challenge(expiresAt: now - 1), now: now),
                "past expiry is stale")
        require(!PeelAudioPairingProof.isFresh(challenge(expiresAt: now + 60.001), now: now),
                "expiry beyond freshness window is stale")
        require(!PeelAudioPairingProof.isFresh(challenge(expiresAt: .nan), now: now),
                "NaN expiry is stale")
        require(!PeelAudioPairingProof.isFresh(challenge(expiresAt: .infinity), now: now),
                "infinite expiry is stale")
        require(!PeelAudioPairingProof.isFresh(challenge(expiresAt: now + 1), now: .nan),
                "NaN clock is stale")
    }

    static func testCodableWireRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let request = PeelAudioSessionRequest(requestId: requestID, enabled: true)
        let requestData = try encoder.encode(request)
        let requestObject = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        require(requestObject?["type"] as? String == "audioSessionRequest",
                "request wire type")
        let decodedRequest = try decoder.decode(PeelAudioSessionRequest.self, from: requestData)
        require(decodedRequest.enabled, "request wire enabled")

        let state = PeelAudioSessionState(requestId: requestID, pairingId: pairingID,
                                          status: "ready", reason: "fixture", ticket: "ticket")
        let stateData = try encoder.encode(state)
        let decodedState = try decoder.decode(PeelAudioSessionState.self, from: stateData)
        require(decodedState.type == "audioSessionState" && decodedState.status == "ready" &&
                    decodedState.reason == "fixture" && decodedState.ticket == "ticket",
                "state wire round trip")

        let hello = PeelAudioStreamHello(requestId: requestID, pairingId: pairingID, ticket: "ticket")
        let helloData = try encoder.encode(hello)
        let decodedHello = try decoder.decode(PeelAudioStreamHello.self, from: helloData)
        require(decodedHello.type == "audioStreamHello" && decodedHello.version == 1 &&
                    decodedHello.requestId == requestID && decodedHello.pairingId == pairingID &&
                    decodedHello.ticket == "ticket",
                "stream hello wire round trip")

        let challengeData = try encoder.encode(challenge())
        let decodedChallenge = try decoder.decode(PeelAudioPairingChallengeMessage.self,
                                                   from: challengeData)
        require(decodedChallenge.type == "audioPairingChallenge" &&
                    decodedChallenge.requestId == requestID && decodedChallenge.pairingId == pairingID &&
                    decodedChallenge.nonce == nonce && decodedChallenge.expiresAt == expiry,
                "challenge wire round trip")
        let proofMessage = PeelAudioPairingProofMessage(requestId: requestID, pairingId: pairingID,
                                                        proof: proof(for: challenge()))
        let proofData = try encoder.encode(proofMessage)
        let decodedProof = try decoder.decode(PeelAudioPairingProofMessage.self, from: proofData)
        require(decodedProof.type == "audioPairingProof" && decodedProof.requestId == requestID &&
                    decodedProof.pairingId == pairingID && decodedProof.proof == proofMessage.proof,
                "proof wire round trip")
    }
}

@main
struct PeelAudioProofAdmissionChecks {
    static func main() {
        AudioProofChecks.testValidAdmissionAndDomainSeparation()
        AudioProofChecks.testChangedBoundFieldsAreRejected()
        AudioProofChecks.testWrongAndMalformedKeysAreRejected()
        AudioProofChecks.testFreshnessBoundaries()
        do {
            try AudioProofChecks.testCodableWireRoundTrips()
        } catch {
            fatalError("FAILED: Codable wire round trips: " + String(describing: error))
        }
        print("PeelAudioProofAdmissionChecks passed")
    }
}
