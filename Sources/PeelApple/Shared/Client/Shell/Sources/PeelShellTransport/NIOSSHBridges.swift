// Adapted from OrcheSSHtra (Conductor) 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
// See ORIGIN.md for provenance and changes.
//
//  NIOSSHBridges.swift
//  Conductor
//
//  Adapters between NIOSSH's delegate/promise callbacks and the app's
//  transport-agnostic SSH seam. NIOSSH types stay inside Conductor/SSH/.
//

import CryptoKit
import Foundation
import PeelShellCore
import NIOCore
import NIOSSH

extension SSHHostKey {
    /// Converts NIOSSH's opaque public key via its OpenSSH string form
    /// ("algorithm-id base64-blob") — the only public serialization NIOSSH
    /// offers — so fingerprints match `ssh-keygen -lf` exactly. `nonisolated`
    /// (the model itself already is) so the off-main NIOSSH host-key delegate
    /// can build it without a main-actor warning; pure serialization, no
    /// isolation-sensitive state.
    nonisolated init?(niosshKey: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: niosshKey)
        let parts = openSSH.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return nil
        }
        self.init(keyType: String(parts[0]), keyBlob: blob)
    }
}

/// Bridges NIOSSH's promise-based host key callback to the async
/// `SSHHostKeyVerifier` seam (and through it to the known-hosts store and
/// the fingerprint UI).
nonisolated final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let endpoint: SSHEndpoint
    private let verifier: any SSHHostKeyVerifier

    init(endpoint: SSHEndpoint, verifier: any SSHHostKeyVerifier) {
        self.endpoint = endpoint
        self.verifier = verifier
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let presented = SSHHostKey(niosshKey: hostKey) else {
            validationCompletePromise.fail(
                SSHClientError.channelFailure(reason: "Server presented an unparseable host key")
            )
            return
        }
        let endpoint = self.endpoint
        let verifier = self.verifier
        Task {
            switch await verifier.decision(for: presented, endpoint: endpoint) {
            case .trust, .trustOnce:
                validationCompletePromise.succeed(())
            case .reject:
                validationCompletePromise.fail(
                    SSHClientError.hostKeyRejected(fingerprint: presented.fingerprint)
                )
            }
        }
    }
}

/// Offers the configured credential exactly once. NIOSSH semantics: a nil
/// offer means "no more attempts", which ends authentication — so a second
/// callback (the server rejected the first offer) or a server that doesn't
/// accept the method yields nil rather than looping forever.
nonisolated final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let method: SSHAuthMethod
    private var hasOffered = false

    init(username: String, method: SSHAuthMethod) {
        self.username = username
        self.method = method
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOffered else {
            nextChallengePromise.succeed(nil)
            return
        }
        hasOffered = true

        switch method {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.succeed(nil)
                return
            }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .password(.init(password: password))
                )
            )
        case .privateKey(let pem, let passphrase):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.succeed(nil)
                return
            }
            do {
                let key = try Self.parsePrivateKey(pem: pem, passphrase: passphrase)
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username,
                        serviceName: "",
                        offer: .privateKey(.init(privateKey: key))
                    )
                )
            } catch {
                nextChallengePromise.fail(error)
            }
        }
    }

    /// OpenSSH-format ("BEGIN OPENSSH PRIVATE KEY", Ed25519) and PKCS#8/SEC1
    /// PEM (P-256/384/521). Passphrase decryption is still pending.
    static func parsePrivateKey(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        guard passphrase == nil else {
            throw SSHClientError.privateKeyUnsupported(
                reason: "Passphrase-protected keys are not supported yet"
            )
        }
        if pem.contains(OpenSSHPrivateKey.pemHeader) {
            return try OpenSSHPrivateKey.parse(pem: pem)
        }
        if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p256Key: p256)
        }
        if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p384Key: p384)
        }
        if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p521Key: p521)
        }
        throw SSHClientError.privateKeyUnsupported(
            reason: "Unrecognized key format (OpenSSH Ed25519 or PKCS#8/SEC1 PEM with P-256/384/521 supported)"
        )
    }
}
