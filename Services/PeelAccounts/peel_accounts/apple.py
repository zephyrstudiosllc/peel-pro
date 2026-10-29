"""Apple-only HTTPS transport; JWT signatures are verified by PyJWT/cryptography."""
import base64
import hashlib
import hmac
import json
import threading
import time

import jwt
import requests
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import load_pem_private_key

ISSUER = "https://appleid.apple.com"
JWKS_URL = ISSUER + "/auth/keys"
TOKEN_URL = ISSUER + "/auth/token"
REVOKE_URL = ISSUER + "/auth/revoke"
MAX_RESPONSE = 65536


class AppleUnavailable(Exception):
    pass


class AppleRejected(Exception):
    pass


class IdentityRejected(Exception):
    pass


class AppleTransport:
    def __init__(self, settings):
        self.settings = settings
        self.key = load_pem_private_key(settings.apple_key_path.read_bytes(), password=None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or self.key.curve.name != "secp256r1":
            raise ValueError("Apple signing key must be an EC P-256 private key")
        self.http = requests.Session()
        self.http.trust_env = False  # Ignore ambient proxy/netrc authentication configuration.

    def _json(self, url, data=None):
        # URLs are constants, never caller-supplied. No redirects or tokens in query strings.
        try:
            with self.http.request("POST" if data is not None else "GET", url, data=data,
                                   timeout=(3.0, 8.0), allow_redirects=False, stream=True,
                                   headers={"Accept": "application/json"}) as response:
                body = bytearray()
                deadline = time.monotonic() + 10
                for block in response.iter_content(4096):
                    body.extend(block)
                    if len(body) > MAX_RESPONSE or time.monotonic() > deadline:
                        raise AppleUnavailable()
                if response.status_code != 200:
                    # Only an invalid user grant is an authorization rejection. A bad service
                    # key/client configuration must not erase otherwise valid user accounts.
                    try:
                        error_code = json.loads(body).get("error")
                    except (ValueError, AttributeError):
                        error_code = None
                    if response.status_code == 400 and error_code == "invalid_grant":
                        raise AppleRejected()
                    raise AppleUnavailable()
                if not body and url == REVOKE_URL:
                    return {}
                value = json.loads(body)
                if not isinstance(value, dict):
                    raise AppleUnavailable()
                return value
        except (requests.RequestException, ValueError, UnicodeError) as error:
            # Do not expose exception/response bodies: OAuth responses can contain credentials.
            raise AppleUnavailable() from None

    def jwks(self):
        return self._json(JWKS_URL)

    def client_secret(self):
        now = int(time.time())
        return jwt.encode({"iss": self.settings.apple_team_id, "iat": now, "exp": now + 300,
                           "aud": ISSUER, "sub": self.settings.client_id}, self.key,
                          algorithm="ES256", headers={"kid": self.settings.apple_key_id})

    def exchange(self, code):
        return self._json(TOKEN_URL, {"client_id": self.settings.client_id,
                                     "client_secret": self.client_secret(), "code": code,
                                     "grant_type": "authorization_code"})

    def refresh(self, token):
        return self._json(TOKEN_URL, {"client_id": self.settings.client_id,
                                     "client_secret": self.client_secret(), "refresh_token": token,
                                     "grant_type": "refresh_token"})

    def revoke(self, token):
        self._json(REVOKE_URL, {"client_id": self.settings.client_id,
                               "client_secret": self.client_secret(), "token": token,
                               "token_type_hint": "refresh_token"})


class IdentityVerifier:
    """Bounded one-hour public-key cache. No stale-key fallback and no token-selected URL."""
    def __init__(self, client_id, fetch_jwks, clock=time.time):
        self.client_id = client_id
        self.fetch_jwks = fetch_jwks
        self.clock = clock
        self.keys = {}
        self.loaded_at = 0
        self.refresh_attempt = 0
        self.lock = threading.Lock()

    def _key(self, kid):
        now = self.clock()
        with self.lock:
            if now - self.loaded_at < 3600 and kid in self.keys:
                return self.keys[kid]
            # Unknown kids cannot force unbounded network traffic. Retry key rotation after 60s.
            if self.refresh_attempt and now - self.refresh_attempt < 60:
                raise IdentityRejected()
            self.refresh_attempt = now
            raw = self.fetch_jwks()
            values = raw.get("keys")
            if not isinstance(values, list) or not 1 <= len(values) <= 12:
                raise AppleUnavailable()
            keys = {}
            try:
                for item in values:
                    if (not isinstance(item, dict) or item.get("kty") != "RSA"
                            or item.get("alg") != "RS256" or item.get("use") != "sig"):
                        continue
                    key_id = item.get("kid")
                    if not isinstance(key_id, str) or not 1 <= len(key_id) <= 128 or key_id in keys:
                        raise ValueError()
                    if (not isinstance(item.get("n"), str) or not 256 <= len(item["n"]) <= 1368
                            or not isinstance(item.get("e"), str) or not 2 <= len(item["e"]) <= 16):
                        raise ValueError()
                    key = jwt.PyJWK.from_dict(item, algorithm="RS256").key
                    if not 2048 <= key.key_size <= 8192:
                        raise ValueError()
                    keys[key_id] = key
            except (jwt.PyJWTError, ValueError, TypeError, AttributeError):
                raise AppleUnavailable() from None
            self.keys, self.loaded_at = keys, now
            if kid not in keys:
                raise IdentityRejected()
            return keys[kid]

    def _claims(self, token, required):
        if not isinstance(token, str) or not 32 <= len(token) <= 16384:
            raise IdentityRejected()
        try:
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256" or header.get("crit") or any(
                    name in header for name in ("jku", "jwk", "x5u")):
                raise IdentityRejected()
            kid = header.get("kid")
            if not isinstance(kid, str) or not 1 <= len(kid) <= 128:
                raise IdentityRejected()
            return jwt.decode(token, self._key(kid), algorithms=["RS256"],
                              audience=self.client_id, issuer=ISSUER, leeway=30,
                              options={"require": required, "strict_aud": True})
        except (jwt.PyJWTError, ValueError, TypeError, KeyError):
            raise IdentityRejected() from None

    def verify(self, token, nonce=None, code=None):
        claims = self._claims(token, ["iss", "aud", "exp", "iat", "sub"])
        now = self.clock()
        if (type(claims["exp"]) is not int or type(claims["iat"]) is not int
                or claims["exp"] <= now - 30 or claims["iat"] > now + 30 or now - claims["iat"] > 600):
            raise IdentityRejected()
        subject = claims["sub"]
        if not isinstance(subject, str) or not 1 <= len(subject) <= 255:
            raise IdentityRejected()
        if nonce is not None and (not isinstance(claims.get("nonce"), str)
                                   or not hmac.compare_digest(claims["nonce"].encode(), nonce.encode())):
            raise IdentityRejected()
        if code is not None and "c_hash" in claims:
            expected = base64.urlsafe_b64encode(hashlib.sha256(code.encode()).digest()[:16]).rstrip(b"=").decode()
            if not isinstance(claims["c_hash"], str) or not hmac.compare_digest(claims["c_hash"].encode(), expected.encode()):
                raise IdentityRejected()
        return claims

    def notification(self, token):
        claims = self._claims(token, ["iss", "aud", "iat", "jti", "events"])
        now = self.clock()
        if (type(claims["iat"]) is not int or claims["iat"] > now + 30
                or claims["iat"] < now - 7*86400 or not isinstance(claims["jti"], str)
                or not 1 <= len(claims["jti"]) <= 255
                or ("exp" in claims and type(claims["exp"]) is not int)):
            raise IdentityRejected()
        event = claims["events"]
        # Apple documents an object; reject string-encoded/untyped events instead of guessing.
        if (not isinstance(event, dict)
                or event.get("type") not in ("email-enabled", "email-disabled", "consent-revoked", "account-deleted")
                or not isinstance(event.get("sub"), str) or not 1 <= len(event["sub"]) <= 255
                or type(event.get("event_time")) is not int
                or event["event_time"] > min(now + 30, claims["iat"] + 30)):
            raise IdentityRejected()
        return claims
