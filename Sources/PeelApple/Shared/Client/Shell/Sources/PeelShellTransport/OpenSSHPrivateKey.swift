// Adapted from OrcheSSHtra (Conductor) 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
// See ORIGIN.md for provenance and changes.
//
//  OpenSSHPrivateKey.swift
//  Conductor
//
//  Parser for the "openssh-key-v1" private key container — what ssh-keygen
//  has emitted by default since OpenSSH 7.8, i.e. nearly every real user
//  key. Unencrypted Ed25519 keys parse; encrypted keys and other types fail
//  with a reason the UI can show verbatim.
//

import CryptoKit
import Foundation
import PeelShellCore
import NIOSSH

/// Little cursor over SSH wire-format binary data (RFC 4251 style:
/// big-endian u32 length-prefixed strings).
nonisolated struct SSHBinaryReader {
    private let data: Data
    private var offset: Data.Index

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readUInt32() -> UInt32? {
        guard data.distance(from: offset, to: data.endIndex) >= 4 else { return nil }
        let end = data.index(offset, offsetBy: 4)
        let value = data[offset..<end].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset = end
        return value
    }

    mutating func readBytes() -> Data? {
        guard let length = readUInt32(),
              data.distance(from: offset, to: data.endIndex) >= Int(length)
        else { return nil }
        let end = data.index(offset, offsetBy: Int(length))
        let value = data[offset..<end]
        offset = end
        return Data(value)
    }

    mutating func readString() -> String? {
        guard let bytes = readBytes() else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// Consumes and checks a fixed prefix (the container magic).
    mutating func readMagic(_ magic: String) -> Bool {
        let expected = Data(magic.utf8)
        guard data.distance(from: offset, to: data.endIndex) >= expected.count else { return false }
        let end = data.index(offset, offsetBy: expected.count)
        guard data[offset..<end].elementsEqual(expected) else { return false }
        offset = end
        return true
    }
}

nonisolated enum OpenSSHPrivateKey {
    static let pemHeader = "-----BEGIN OPENSSH PRIVATE KEY-----" // secret-scan:allow: public PEM format marker for key detection, not key material
    private static let pemFooter = "-----END OPENSSH PRIVATE KEY-----"

    static func parse(pem: String) throws -> NIOSSHPrivateKey {
        guard let blob = base64Body(of: pem) else {
            throw SSHClientError.privateKeyUnsupported(reason: "Malformed OpenSSH key armor")
        }

        var reader = SSHBinaryReader(data: blob)
        guard reader.readMagic("openssh-key-v1\0") else {
            throw SSHClientError.privateKeyUnsupported(reason: "Not an openssh-key-v1 container")
        }
        guard
            let cipher = reader.readString(),
            let kdf = reader.readString(),
            reader.readBytes() != nil,  // kdf options
            let keyCount = reader.readUInt32()
        else {
            throw SSHClientError.privateKeyUnsupported(reason: "Truncated OpenSSH key container")
        }
        guard cipher == "none", kdf == "none" else {
            throw SSHClientError.privateKeyUnsupported(
                reason: "Passphrase-protected keys are not supported yet"
            )
        }
        guard keyCount == 1 else {
            throw SSHClientError.privateKeyUnsupported(
                reason: "Multi-key OpenSSH containers are not supported"
            )
        }
        guard
            reader.readBytes() != nil,  // public key blob
            let privateSection = reader.readBytes()
        else {
            throw SSHClientError.privateKeyUnsupported(reason: "Truncated OpenSSH key container")
        }

        var priv = SSHBinaryReader(data: privateSection)
        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32(), check1 == check2 else {
            throw SSHClientError.privateKeyUnsupported(
                reason: "Key check bytes mismatch (corrupt key data)"
            )
        }
        guard let keyType = priv.readString() else {
            throw SSHClientError.privateKeyUnsupported(reason: "Truncated OpenSSH key container")
        }

        switch keyType {
        case "ssh-ed25519":
            guard
                priv.readBytes() != nil,  // 32-byte public key
                let scalar = priv.readBytes(), scalar.count == 64
            else {
                throw SSHClientError.privateKeyUnsupported(reason: "Malformed Ed25519 key data")
            }
            // The 64-byte field is seed ‖ public key; CryptoKit wants the seed.
            let seed = scalar.prefix(32)
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
                throw SSHClientError.privateKeyUnsupported(reason: "Invalid Ed25519 seed")
            }
            return NIOSSHPrivateKey(ed25519Key: key)
        default:
            throw SSHClientError.privateKeyUnsupported(
                reason: "OpenSSH key type \(keyType) is not supported yet (Ed25519 only)"
            )
        }
    }

    private static func base64Body(of pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard
            let headerIndex = lines.firstIndex(of: pemHeader),
            let footerIndex = lines.firstIndex(of: pemFooter),
            headerIndex < footerIndex
        else { return nil }
        let body = lines[(headerIndex + 1)..<footerIndex].joined()
        return Data(base64Encoded: body)
    }
}
