"""Actual fixed-provider code redemption and signature/identity verification.

Public native registrations are operator supplied, never borrowed. No generic
inference permission, email linking, refresh grant or provider token is retained.
"""
from __future__ import annotations

from dataclasses import dataclass
import http.client
import math
import ssl
import socket
import threading
import time
from urllib.parse import urlencode, urlsplit

import jwt

from .auth_crypto import scalar
from .broker import RelayError
from .http import strict_json

OPENAI = "https://auth.openai.com"
DISCOVERY = OPENAI + "/.well-known/openid-configuration"
JWKS = OPENAI + "/.well-known/jwks.json"
OPENAI_TOKEN = OPENAI + "/api/accounts/oauth/token"
X_TOKEN = "https://api.x.com/2/oauth2/token"
X_ME = "https://api.x.com/2/users/me"


@dataclass(frozen=True)
class Registration:
    provider: str
    client_id: str
    redirect_uri: str
    approval_reference: str

    def __post_init__(self):
        if self.provider not in ("dot", "grokBot"):
            raise RelayError("invalid_provider_registration")
        scalar(self.client_id)
        scalar(self.redirect_uri, 2048)
        scalar(self.approval_reference, 512)
        parsed = urlsplit(self.redirect_uri)
        if not parsed.scheme or parsed.fragment or parsed.username or parsed.password or not parsed.path:
            raise RelayError("invalid_provider_registration")
        if self.provider == "dot" and not self.client_id.startswith("oaiapp_"):
            raise RelayError("approved_chatgpt_registration_required")


@dataclass(frozen=True)
class VerifiedProviderIdentity:
    provider: str
    issuer: str
    client_id: str
    subject: str
    verified_at: int
    expires_at: int


class FixedProviderHTTP:
    """TLS verification, fixed destinations, no redirect/cookie/ambient credential."""
    def __call__(self, method, url, *, form=None, bearer=None):
        expected = {DISCOVERY: "GET", JWKS: "GET", OPENAI_TOKEN: "POST", X_TOKEN: "POST", X_ME: "GET"}
        if expected.get(url) != method or bearer is not None and url != X_ME:
            raise RelayError("invalid_provider_request")
        parsed = urlsplit(url)
        body = urlencode(form).encode("ascii") if form is not None else None
        if body is not None and len(body) > 32768:
            raise RelayError("invalid_provider_request")
        headers = {"Accept": "application/json", "Connection": "close"}
        if form is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if bearer is not None:
            headers["Authorization"] = "Bearer " + scalar(bearer, 16384)
        from .webhooks import _resolve_public, _default_resolver, _DeadlineConnection, _default_connector, _remaining, WebhookError
        deadline = time.monotonic() + 15
        active, lock = [], threading.Lock()
        expired = threading.Event()
        def track(sock):
            with lock:
                active.append(sock)
                if expired.is_set():
                    sock.close()
                    raise RelayError("provider_request_failed")
        def expire():
            expired.set()
            with lock:
                for sock in active:
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    sock.close()
        connection, watchdog = None, None
        try:
            addresses = _resolve_public(parsed.hostname, _default_resolver, deadline, time.monotonic)
            connection = _DeadlineConnection(parsed.hostname, addresses[0], deadline, time.monotonic,
                _default_connector, ssl.create_default_context(), track)
            watchdog = threading.Timer(_remaining(deadline, time.monotonic), expire)
            watchdog.daemon = True
            watchdog.start()
            connection.request(method, parsed.path, body, headers)
            response = connection.getresponse()
            if response.status != 200 or response.getheader("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                raise RelayError("provider_request_failed")
            raw = response.read(131073)
            _remaining(deadline, time.monotonic)
            if len(raw) > 131072:
                raise RelayError("provider_response_too_large")
            result = strict_json(raw)
            if not isinstance(result, dict):
                raise RelayError("invalid_provider_response")
            return result
        except (OSError, http.client.HTTPException, ValueError, WebhookError):
            raise RelayError("provider_request_failed") from None
        finally:
            if watchdog is not None:
                watchdog.cancel()
            if connection is not None:
                connection.close()
            with lock:
                for sock in active:
                    sock.close()


class ProviderCodeVerifier:
    def __init__(self, registrations, *, http=None, now=time.time):
        self.registrations = {r.provider: r for r in registrations}
        if not self.registrations or len(self.registrations) != len(registrations):
            raise RelayError("provider_registration_required")
        self.http, self.now = http or FixedProviderHTTP(), now
        self.lock = threading.RLock()
        self.cached = None
        self.cache_until = 0
        self.last_refresh = -math.inf

    def registration(self, provider):
        result = self.registrations.get(provider)
        if result is None:
            raise RelayError("provider_not_configured")
        return result

    def _keys(self, kid):
        with self.lock:
            now = self.now()
            known = self.cached is not None and now < self.cache_until and any(k.get("kid") == kid for k in self.cached)
            if known:
                return self.cached
            if now - self.last_refresh < 10:
                raise RelayError("provider_keys_unavailable")
            self.last_refresh = now
            discovery = self.http("GET", DISCOVERY)
            if (discovery.get("issuer") != OPENAI or discovery.get("jwks_uri") != JWKS
                    or discovery.get("token_endpoint") != OPENAI_TOKEN
                    or discovery.get("authorization_endpoint") != OPENAI + "/api/accounts/authorize"):
                raise RelayError("invalid_provider_discovery")
            advertised = discovery.get("id_token_signing_alg_values_supported")
            if not isinstance(advertised, list) or not 1 <= len(advertised) <= 16:
                raise RelayError("invalid_provider_discovery")
            document = self.http("GET", JWKS)
            keys = document.get("keys")
            if not isinstance(keys, list) or not 1 <= len(keys) <= 32 or not all(isinstance(k, dict) for k in keys):
                raise RelayError("invalid_provider_keys")
            self.cached, self.cache_until, self.algorithms = keys, now + 1800, advertised
            return keys

    def redeem(self, challenge, code, verifier):
        registration = self.registration(challenge["provider"])
        if registration.client_id != challenge["clientID"] or registration.redirect_uri != challenge["redirectURI"]:
            raise RelayError("registration_changed")
        token_url = OPENAI_TOKEN if registration.provider == "dot" else X_TOKEN
        tokens = self.http("POST", token_url, form={"grant_type": "authorization_code", "code": scalar(code, 16384),
            "client_id": registration.client_id, "redirect_uri": registration.redirect_uri, "code_verifier": verifier})
        now = int(self.now())
        if registration.provider == "grokBot":
            if not isinstance(tokens.get("token_type"), str) or tokens["token_type"].lower() != "bearer" or type(tokens.get("expires_in")) is not int or not 1 <= tokens["expires_in"] <= 86400:
                raise RelayError("invalid_provider_token")
            access = scalar(tokens.get("access_token"), 16384)
            scopes = tokens.get("scope", "")
            if not isinstance(scopes, str) or "users.read" not in scopes.split():
                raise RelayError("provider_identity_scope_required")
            me = self.http("GET", X_ME, bearer=access)
            user = me.get("data")
            if not isinstance(user, dict) or not isinstance(user.get("id"), str) or not user["id"].isascii() or not user["id"].isdigit() or not 1 <= len(user["id"]) <= 32:
                raise RelayError("invalid_provider_identity")
            return VerifiedProviderIdentity("grokBot", "https://api.x.com", registration.client_id, user["id"], now, now + min(tokens["expires_in"], 7200))
        raw = scalar(tokens.get("id_token"), 32768)
        try:
            header = jwt.get_unverified_header(raw)
            if set(header) - {"alg", "kid", "typ"} or header.get("alg") not in ("RS256", "ES256"):
                raise RelayError("invalid_provider_token")
            kid = scalar(header.get("kid"))
            keys = [k for k in self._keys(kid) if k.get("kid") == kid]
            if len(keys) != 1 or header["alg"] not in self.algorithms:
                raise RelayError("invalid_provider_token")
            key = keys[0]
            if key.get("alg", header["alg"]) != header["alg"] or key.get("use", "sig") != "sig" or key.get("key_ops", ["verify"]) != ["verify"]:
                raise RelayError("invalid_provider_token")
            # Reject duplicate headers/claims before maintained-library verification.
            from .auth_crypto import unb64
            parts = raw.split(".")
            if len(parts) != 3:
                raise RelayError("invalid_provider_token")
            strict_json(unb64(parts[0], maximum=4096))
            strict_json(unb64(parts[1], maximum=24576))
            verification_key = jwt.PyJWK.from_dict(key).key
            from cryptography.hazmat.primitives.asymmetric import ec, rsa
            if header["alg"] == "RS256" and (not isinstance(verification_key, rsa.RSAPublicKey) or not 2048 <= verification_key.key_size <= 8192):
                raise RelayError("invalid_provider_key")
            if header["alg"] == "ES256" and (not isinstance(verification_key, ec.EllipticCurvePublicKey) or not isinstance(verification_key.curve, ec.SECP256R1)):
                raise RelayError("invalid_provider_key")
            claims = jwt.decode(raw, verification_key, algorithms=[header["alg"]], issuer=OPENAI,
                audience=registration.client_id, options={"require": ["iss", "sub", "aud", "exp", "iat", "nonce"],
                "verify_exp": False, "verify_iat": False, "verify_nbf": False})
            # Use one injectable clock consistently; no expiry grace permits stale grants.
            if any(type(claims.get(k)) is not int for k in ("exp", "iat")) or not now < claims["exp"] or claims["iat"] > now + 5 or claims["iat"] >= claims["exp"]:
                raise RelayError("invalid_provider_token")
            if "nbf" in claims and (type(claims["nbf"]) is not int or claims["nbf"] > now + 5):
                raise RelayError("invalid_provider_token")
            audience = claims["aud"]
            if not isinstance(audience, str) and (not isinstance(audience, list) or not 1 <= len(audience) <= 8 or not all(isinstance(a, str) for a in audience) or len(set(audience)) != len(audience)):
                raise RelayError("invalid_provider_token")
            if claims.get("azp", registration.client_id) != registration.client_id or isinstance(audience, list) and len(audience) > 1 and claims.get("azp") != registration.client_id:
                raise RelayError("invalid_provider_token")
            import hmac
            if not isinstance(claims["nonce"], str) or not hmac.compare_digest(claims["nonce"], challenge["expectedNonce"]):
                raise RelayError("invalid_provider_token")
            subject = scalar(claims["sub"], 256)
            return VerifiedProviderIdentity("dot", OPENAI, registration.client_id, subject, now, min(claims["exp"], now + 86400))
        except (jwt.PyJWTError, ValueError, TypeError, KeyError, IndexError):
            raise RelayError("invalid_provider_token") from None
