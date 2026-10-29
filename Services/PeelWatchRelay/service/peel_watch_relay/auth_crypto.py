"""Bounded canonical proof formats; no default signing key or trusted pin."""
from __future__ import annotations

import base64
import hashlib
import re
from uuid import UUID

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from .broker import RelayError


def scalar(value, maximum=256):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum or any(not 33 <= ord(c) <= 126 for c in value):
        raise RelayError("invalid_auth_scalar")
    return value


def canonical_uuid(value):
    scalar(value, 36)
    try:
        if str(UUID(value)) != value:
            raise ValueError
    except ValueError:
        raise RelayError("invalid_auth_uuid") from None
    return value


def b64(value: bytes):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def unb64(value, *, size=None, maximum=4096):
    scalar(value, maximum * 2)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise RelayError("invalid_auth_encoding")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4))
    except (ValueError, TypeError):
        raise RelayError("invalid_auth_encoding") from None
    if len(raw) > maximum or b64(raw) != value or size is not None and len(raw) != size:
        raise RelayError("invalid_auth_encoding")
    return raw


def public_key(value):
    raw = unb64(value, maximum=256)
    try:
        key = serialization.load_der_public_key(raw)
        if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
            raise ValueError
        if key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) != raw:
            raise ValueError
    except (ValueError, TypeError):
        raise RelayError("invalid_device_key") from None
    return key


def fingerprint(value):
    public_key(value)
    return hashlib.sha256(unb64(value, maximum=256)).hexdigest()


def verify(key_text, signature, message):
    try:
        public_key(key_text).verify(unb64(signature, maximum=80), message, ec.ECDSA(hashes.SHA256()))
    except (InvalidSignature, ValueError, TypeError):
        raise RelayError("invalid_device_proof") from None


def enrollment_bytes(challenge):
    keys = ("challengeID", "challenge", "provider", "transactionID", "clientID", "redirectURI",
            "codeChallenge", "expectedNonce")
    values = [scalar(challenge[k], 2048) for k in keys]
    values += [fingerprint(challenge["phonePublicKey"]), fingerprint(challenge["watchPublicKey"]),
               canonical_uuid(challenge["localEpoch"])]
    return ("peel-native-enrollment-v1\n" + "\n".join(values)).encode("ascii")


def request_bytes(path, body, timestamp, nonce, enrollment_id):
    scalar(path, 128)
    if not path.startswith("/v1/") or "?" in path or "#" in path:
        raise RelayError("invalid_proof_path")
    return ("peel-native-request-v1\nPOST\n" + path + "\n" + hashlib.sha256(body).hexdigest()
            + "\n" + timestamp + "\n" + nonce + "\n" + canonical_uuid(enrollment_id)).encode("ascii")
