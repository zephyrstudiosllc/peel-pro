import Foundation

@main
struct PeelAgentPairingProofSmoke {
    @MainActor
    static func main() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x5A, count: 32).base64EncodedString()
        let challenge = PeelAgentPairingChallengeMessage(requestId: UUID().uuidString,
            pairingId: "fixture-pairing", nonce: nonce, expiresAt: 2_000_000_030.125)
        let proof = PeelAgentPairingProof.make(challenge, key: key)!
        precondition(PeelAgentPairingProof.verify(proof, challenge: challenge, key: key))
        let roundTrip = try JSONDecoder().decode(PeelAgentPairingChallengeMessage.self,
                                                 from: JSONEncoder().encode(challenge))
        precondition(PeelAgentPairingProof.verify(proof, challenge: roundTrip, key: key))
        precondition(!PeelAgentPairingProof.verify(proof, challenge: challenge, key: Data(repeating: 1, count: 32)))
        precondition(!PeelAgentPairingProof.verify("malformed", challenge: challenge, key: key))
        for altered in [
            PeelAgentPairingChallengeMessage(requestId: UUID().uuidString, pairingId: challenge.pairingId,
                                             nonce: nonce, expiresAt: challenge.expiresAt),
            PeelAgentPairingChallengeMessage(requestId: challenge.requestId, pairingId: "another-pairing",
                                             nonce: nonce, expiresAt: challenge.expiresAt),
            PeelAgentPairingChallengeMessage(requestId: challenge.requestId, pairingId: challenge.pairingId,
                                             nonce: Data(repeating: 7, count: 32).base64EncodedString(), expiresAt: challenge.expiresAt),
            PeelAgentPairingChallengeMessage(requestId: challenge.requestId, pairingId: challenge.pairingId,
                                             nonce: nonce, expiresAt: challenge.expiresAt + 1)
        ] {
            precondition(!PeelAgentPairingProof.verify(proof, challenge: altered, key: key))
        }
        precondition(PeelAgentPairingProof.isFresh(challenge, now: 2_000_000_000.125))
        precondition(!PeelAgentPairingProof.isFresh(challenge, now: challenge.expiresAt))
        precondition(!PeelAgentPairingProof.isFresh(challenge, now: 1_999_999_000))
        precondition(PeelAgentPairingProof.make(challenge, key: Data()) == nil)
        print("PeelAgentPairingProofSmoke: PASS (binding, tampering, expiry and JSON round trip)")
    }
}
