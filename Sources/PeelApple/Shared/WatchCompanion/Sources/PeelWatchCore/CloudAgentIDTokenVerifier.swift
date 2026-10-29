#if !os(watchOS)
import Foundation
import Security
import CryptoKit

struct CloudAgentOIDCDiscovery: Decodable {
    let issuer: String; let authorizationEndpoint: String; let tokenEndpoint: String; let jwksURI: String
    let signingAlgorithms: [String]
    enum CodingKeys: String, CodingKey {
        case issuer, authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri", signingAlgorithms = "id_token_signing_alg_values_supported"
    }
    func validate() throws {
        guard issuer == "https://auth.openai.com",
              authorizationEndpoint == "https://auth.openai.com/api/accounts/authorize",
              tokenEndpoint == "https://auth.openai.com/api/accounts/oauth/token",
              jwksURI == "https://auth.openai.com/.well-known/jwks.json",
              !signingAlgorithms.isEmpty, signingAlgorithms.count <= 16 else {
            throw CloudAgentIdentityError.invalidIdentity
        }
    }
}

/// Narrow JOSE verifier using platform cryptography, with no embedded key,
/// token-supplied key URL or algorithm fallback. RS256 and ES256 are this
/// implementation's allowlist, not an assertion about provider deployment.
/// An unimplemented/discovery-unadvertised algorithm blocks sign-in explicitly.
struct CloudAgentIDTokenVerifier {
    private struct Header: Decodable {
        let alg: String; let kid: String; let crit: [String]?; let jku: String?; let x5u: String?; let b64: Bool?
    }
    private struct JWK: Decodable {
        let kty: String; let kid: String?; let alg: String?; let use: String?; let keyOps: [String]?
        let n: String?; let e: String?; let crv: String?; let x: String?; let y: String?
        enum CodingKeys: String, CodingKey { case kty, kid, alg, use, keyOps = "key_ops", n, e, crv, x, y }
    }
    private struct JWKS: Decodable { let keys: [JWK] }
    private enum Audience: Decodable {
        case single(String), multiple([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let string = try? c.decode(String.self) { self = .single(string) }
            else { self = .multiple(try c.decode([String].self)) }
        }
        var values: [String] { switch self { case .single(let value): return [value]; case .multiple(let values): return values } }
    }
    private struct Claims: Decodable {
        let iss: String; let aud: Audience; let sub: String; let exp: Double; let iat: Double; let nonce: String
        let azp: String?; let nbf: Double?
    }
    private struct Token {
        let header: Header; let claims: Data; let signingInput: Data; let signature: Data
    }

    func containsKey(for raw: String, jwks: Data) throws -> Bool {
        let token = try parse(raw)
        return try keys(jwks).contains { $0.kid == token.header.kid }
    }

    func verify(_ raw: String, jwks: Data, discovery: CloudAgentOIDCDiscovery,
                clientID: String, nonce: String, now: Date) throws -> CloudAgentVerifiedIdentity {
        try discovery.validate()
        let token = try parse(raw)
        guard ["RS256", "ES256"].contains(token.header.alg), discovery.signingAlgorithms.contains(token.header.alg) else {
            throw CloudAgentIdentityError.unsupportedSigningAlgorithm
        }
        let matching = try keys(jwks).filter { $0.kid == token.header.kid }
        guard matching.count == 1, let key = matching.first,
              key.alg == nil || key.alg == token.header.alg, key.use == nil || key.use == "sig",
              key.keyOps == nil || key.keyOps == ["verify"] else { throw CloudAgentIdentityError.invalidIdentity }
        switch token.header.alg {
        case "RS256": try verifyRSA(token, key: key)
        case "ES256": try verifyEC(token, key: key)
        default: throw CloudAgentIdentityError.unsupportedSigningAlgorithm
        }
        // Nothing in the payload is trusted until after signature verification.
        let claims = try JSONDecoder().decode(Claims.self, from: token.claims)
        let seconds = now.timeIntervalSince1970
        let audiences = claims.aud.values
        guard seconds.isFinite, claims.iss == discovery.issuer,
              !audiences.isEmpty, audiences.count <= 8, Set(audiences).count == audiences.count,
              audiences.contains(clientID), claims.azp == nil || claims.azp == clientID,
              audiences.count == 1 || claims.azp == clientID,
              claims.exp.isFinite, claims.iat.isFinite, claims.exp > seconds,
              claims.iat <= seconds + 5, claims.iat < claims.exp,
              claims.nbf == nil || (claims.nbf!.isFinite && claims.nbf! <= seconds + 5),
              constantTimeEqual(claims.nonce, nonce) else { throw CloudAgentIdentityError.invalidIdentity }
        return try CloudAgentVerifiedIdentity(provider: .dot, issuer: discovery.issuer, clientID: clientID,
                                              subject: claims.sub, verifiedAt: now,
                                              identityExpiresAt: Date(timeIntervalSince1970: min(claims.exp, seconds + 86_400)))
    }

    private func parse(_ raw: String) throws -> Token {
        guard raw.utf8.count <= 32_768 else { throw CloudAgentIdentityError.invalidIdentity }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw CloudAgentIdentityError.invalidIdentity }
        let header = try JSONDecoder().decode(Header.self, from: decode(parts[0]))
        guard (1...256).contains(header.kid.utf8.count), header.crit == nil,
              header.jku == nil, header.x5u == nil, header.b64 == nil else { throw CloudAgentIdentityError.invalidIdentity }
        return Token(header: header, claims: try decode(parts[1]),
                     signingInput: Data((parts[0] + "." + parts[1]).utf8), signature: try decode(parts[2]))
    }

    private func keys(_ data: Data) throws -> [JWK] {
        guard data.count <= 131_072 else { throw CloudAgentIdentityError.invalidIdentity }
        let keys = try JSONDecoder().decode(JWKS.self, from: data).keys
        guard (1...32).contains(keys.count) else { throw CloudAgentIdentityError.invalidIdentity }
        return keys
    }

    private func verifyRSA(_ token: Token, key: JWK) throws {
        guard key.kty == "RSA", let n = key.n, let e = key.e else { throw CloudAgentIdentityError.invalidIdentity }
        let modulus = try decode(n), exponent = try decode(e)
        guard (256...1024).contains(modulus.count), modulus.first != 0,
              modulus.first! & 0x80 != 0, (1...8).contains(exponent.count), exponent.first != 0,
              exponent.last! & 1 == 1, exponent != Data([1]), token.signature.count == modulus.count else {
            throw CloudAgentIdentityError.invalidIdentity
        }
        let der = wrap(0x30, integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                          kSecAttrKeySizeInBits: modulus.count * 8]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    token.signingInput as CFData, token.signature as CFData, nil) else {
            throw CloudAgentIdentityError.invalidIdentity
        }
    }

    private func verifyEC(_ token: Token, key: JWK) throws {
        guard key.kty == "EC", key.crv == "P-256", let x = key.x, let y = key.y else {
            throw CloudAgentIdentityError.invalidIdentity
        }
        let xBytes = try decode(x), yBytes = try decode(y)
        guard xBytes.count == 32, yBytes.count == 32, token.signature.count == 64 else {
            throw CloudAgentIdentityError.invalidIdentity
        }
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + xBytes + yBytes)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: token.signature)
        guard publicKey.isValidSignature(signature, for: token.signingInput) else { throw CloudAgentIdentityError.invalidIdentity }
    }

    private func integer(_ bytes: Data) -> Data { wrap(0x02, bytes.first! & 0x80 == 0 ? bytes : Data([0]) + bytes) }
    private func wrap(_ tag: UInt8, _ bytes: Data) -> Data {
        let count = bytes.count
        let length: [UInt8] = count < 128 ? [UInt8(count)] : (count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)])
        return Data([tag] + length) + bytes
    }
    private func decode(_ raw: String) throws -> Data {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              raw.utf8.count % 4 != 1 else { throw CloudAgentIdentityError.invalidIdentity }
        let padded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - raw.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64URL(data) == raw else { throw CloudAgentIdentityError.invalidIdentity }
        return data
    }
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
#endif
