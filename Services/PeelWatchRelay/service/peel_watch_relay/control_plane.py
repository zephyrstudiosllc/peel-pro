"""Provider-verified, durable account/device/session control plane.

Enrollment proves two keys and a verified provider account authorized a pairing.
It is not Apple hardware attestation. Native code must attribute the Watch proof
to its actual current WC peer before returning it. No JSON identity is trusted.
"""
from __future__ import annotations

import hashlib
import hmac
import math
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading
import time
from uuid import uuid4
from dataclasses import dataclass

import jwt
from cryptography.hazmat.primitives.asymmetric import ec

from .auth_crypto import b64, canonical_uuid, enrollment_bytes, fingerprint, request_bytes, scalar, unb64, verify
from .broker import Account, DeviceGrant, RelayError, encode
from .http import RequestAuthority, strict_json
from .rpc import fields
from . import session_continuity as continuity

PHONE_SCOPES = frozenset(("watch.connect", "watch.send", "watch.read"))
AGENT_SCOPES = frozenset(("agent.inbox", "agent.reply", "agent.confirm", "agent.subscribe"))
CHALLENGE_FIELDS = ("provider", "transactionID", "clientID", "redirectURI", "codeChallenge", "expectedNonce",
                    "phonePublicKey", "watchPublicKey", "localEpoch")


@dataclass(frozen=True)
class _SessionAccount(Account):
    # Internal adapter output, never deserialized. Broker callbacks receive it
    # unchanged and can recheck exact credential currentness after async work.
    credential_digest: str = ""

    def __post_init__(self):
        super().__post_init__()
        if not re.fullmatch(r"[0-9a-f]{64}", self.credential_digest):
            raise RelayError("verified_session_digest_required")


class ControlPlane:
    def __init__(self, directory, provider_verifier, *, issuer, principal_key, signing_key, signing_kid,
                 now=time.time):
        # Startup receives independently reviewed real configuration; no generated default.
        from urllib.parse import urlsplit
        parsed = urlsplit(issuer)
        if parsed.scheme != "https" or parsed.path or parsed.query or parsed.fragment or parsed.port not in (None, 443) or not parsed.hostname or parsed.username or parsed.password:
            raise RelayError("public_https_origin_required")
        scalar(issuer, 512)
        if not isinstance(principal_key, bytes) or len(principal_key) != 32:
            raise RelayError("principal_key_required")
        if not isinstance(signing_key, ec.EllipticCurvePrivateKey) or not isinstance(signing_key.curve, ec.SECP256R1):
            raise RelayError("broker_signing_key_required")
        self.issuer, self.principal_key = issuer, principal_key
        self.signing_key, self.signing_kid = signing_key, scalar(signing_kid, 128)
        self.verifier, self.now, self.lock = provider_verifier, now, threading.RLock()
        self.owner_pid = os.getpid()
        self.relay = None
        directory = Path(directory)
        if directory.is_symlink():
            raise RelayError("unsafe_auth_storage")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        meta = directory.stat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) & 0o077:
            raise RelayError("unsafe_auth_storage")
        path = directory / "authority.sqlite3"
        fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            meta = os.fstat(fd)
            if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) & 0o077:
                raise RelayError("unsafe_auth_storage")
        finally:
            os.close(fd)
        self.db = sqlite3.connect(path, isolation_level=None, check_same_thread=False, timeout=1)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS auth_epoch(id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL);
        INSERT OR IGNORE INTO auth_epoch VALUES(1,0);
        CREATE TABLE IF NOT EXISTS auth_accounts(
          principal TEXT PRIMARY KEY, provider TEXT NOT NULL, generation TEXT NOT NULL,
          revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS auth_enrollments(
          id TEXT PRIMARY KEY, principal TEXT NOT NULL REFERENCES auth_accounts(principal),
          provider TEXT NOT NULL, account_generation TEXT NOT NULL, pair_generation TEXT NOT NULL,
          device_id TEXT NOT NULL, phone_key TEXT NOT NULL, watch_key TEXT NOT NULL,
          local_epoch TEXT NOT NULL, identity_expires INTEGER NOT NULL,
          revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS auth_sessions(
          digest TEXT PRIMARY KEY, enrollment TEXT NOT NULL REFERENCES auth_enrollments(id),
          expires INTEGER NOT NULL, kind TEXT NOT NULL, scopes TEXT NOT NULL,
          routes TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS auth_challenges(
          id TEXT PRIMARY KEY, payload BLOB NOT NULL, expires INTEGER NOT NULL,
          consumed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS auth_code_uses(digest TEXT PRIMARY KEY, expires INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS auth_nonces(
          session_digest TEXT NOT NULL, nonce TEXT NOT NULL, expires INTEGER NOT NULL,
          PRIMARY KEY(session_digest,nonce));
        CREATE TABLE IF NOT EXISTS auth_plugin_transactions(
          id TEXT PRIMARY KEY, client_id TEXT NOT NULL, redirect_uri TEXT NOT NULL,
          state TEXT NOT NULL, challenge TEXT NOT NULL, scope TEXT NOT NULL,
          resource TEXT NOT NULL, expires INTEGER NOT NULL,
          code_digest TEXT UNIQUE, enrollment TEXT, route TEXT,
          consumed INTEGER NOT NULL DEFAULT 0);
        """)
        continuity.initialize(self.db)

    def _time(self):
        now = self.now()
        if type(now) not in (int, float) or not math.isfinite(now) or now <= 0 or os.getpid() != self.owner_pid:
            raise RelayError("invalid_auth_clock_or_process")
        return int(now)

    def close(self):
        with self.lock:
            self.db.close()

    def _cleanup(self, now):
        self.db.execute("DELETE FROM auth_challenges WHERE expires<=?", (now,))
        self.db.execute("DELETE FROM auth_nonces WHERE expires<=?", (now,))
        self.db.execute("DELETE FROM auth_code_uses WHERE expires<=?", (now,))
        self.db.execute("DELETE FROM auth_plugin_transactions WHERE expires<=?", (now,))
        self.db.execute("DELETE FROM auth_sessions WHERE expires<=?", (now,))

    def challenge(self, body):
        fields(body, CHALLENGE_FIELDS)
        registration = self.verifier.registration(body["provider"])
        if body["clientID"] != registration.client_id or body["redirectURI"] != registration.redirect_uri:
            raise RelayError("registration_mismatch")
        canonical_uuid(body["transactionID"])
        canonical_uuid(body["localEpoch"])
        unb64(body["codeChallenge"], size=32)
        if not isinstance(body["expectedNonce"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", body["expectedNonce"]):
            raise RelayError("invalid_identity_nonce")
        fingerprint(body["phonePublicKey"])
        fingerprint(body["watchPublicKey"])
        if body["phonePublicKey"] == body["watchPublicKey"]:
            raise RelayError("distinct_peer_keys_required")
        with self.lock:
            now = self._time()
            self._cleanup(now)
            if self.db.execute("SELECT count(*) FROM auth_challenges").fetchone()[0] >= 256:
                raise RelayError("challenge_capacity")
            result = {"challengeID": str(uuid4()), "challenge": secrets.token_urlsafe(32), "expiresAt": now + 120}
            payload = dict(body, **result)
            payload["authEpoch"] = self.db.execute("SELECT value FROM auth_epoch WHERE id=1").fetchone()[0]
            self.db.execute("INSERT INTO auth_challenges(id,payload,expires) VALUES(?,?,?)",
                            (result["challengeID"], encode(payload), result["expiresAt"]))
            return result

    def redeem(self, body):
        fields(body, ("challengeID", "code", "codeVerifier", "phoneSignature", "watchSignature"))
        challenge_id = canonical_uuid(body["challengeID"])
        code = scalar(body["code"], 16384)
        verifier = body["codeVerifier"]
        if not isinstance(verifier, str) or not re.fullmatch(r"[A-Za-z0-9._~-]{43,128}", verifier):
            raise RelayError("invalid_pkce_verifier")
        with self.lock:
            now = self._time()
            row = self.db.execute("SELECT * FROM auth_challenges WHERE id=?", (challenge_id,)).fetchone()
            if row is None or row["consumed"] or row["expires"] <= now:
                raise RelayError("challenge_unavailable")
            challenge = strict_json(row["payload"])
            if challenge["authEpoch"] != self.db.execute("SELECT value FROM auth_epoch WHERE id=1").fetchone()[0]:
                raise RelayError("sign_in_interrupted_by_revocation")
            if not hmac.compare_digest(b64(hashlib.sha256(verifier.encode("ascii")).digest()), challenge["codeChallenge"]):
                raise RelayError("pkce_mismatch")
            signed = enrollment_bytes(challenge)
            verify(challenge["phonePublicKey"], body["phoneSignature"], signed)
            verify(challenge["watchPublicKey"], body["watchSignature"], signed)
            digest = hashlib.sha256((challenge["provider"] + "\0" + code).encode()).hexdigest()
            # Consume before remote IO: an uncertain exchange never redeems twice.
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.db.execute("UPDATE auth_challenges SET consumed=1 WHERE id=?", (challenge_id,))
                self.db.execute("INSERT INTO auth_code_uses VALUES(?,?)", (digest, now + 600))
                self.db.execute("COMMIT")
            except sqlite3.IntegrityError:
                self.db.execute("ROLLBACK")
                raise RelayError("authorization_code_reused") from None
        identity = self.verifier.redeem(challenge, code, verifier)
        # Only this verified object, never body identity fields, creates a principal.
        from .provider_auth import VerifiedProviderIdentity
        if not isinstance(identity, VerifiedProviderIdentity) or identity.provider != challenge["provider"] or identity.client_id != challenge["clientID"] or identity.expires_at <= self._time():
            raise RelayError("verified_identity_required")
        principal = "principal_" + hmac.new(self.principal_key,
            encode([identity.provider, identity.issuer, identity.client_id, identity.subject]), hashlib.sha256).hexdigest()
        with self.lock:
            now = self._time()
            if challenge["authEpoch"] != self.db.execute("SELECT value FROM auth_epoch WHERE id=1").fetchone()[0]:
                raise RelayError("sign_in_interrupted_by_revocation")
            row = self.db.execute("SELECT * FROM auth_accounts WHERE principal=?", (principal,)).fetchone()
            if row is None:
                self.db.execute("INSERT INTO auth_accounts VALUES(?,?,?,0)", (principal, identity.provider, str(uuid4())))
                row = self.db.execute("SELECT * FROM auth_accounts WHERE principal=?", (principal,)).fetchone()
            elif row["revoked"]:
                # Explicit fresh verified sign-in is the only way to open a new account epoch.
                self.db.execute("UPDATE auth_accounts SET generation=?,revoked=0 WHERE principal=?", (str(uuid4()), principal))
                row = self.db.execute("SELECT * FROM auth_accounts WHERE principal=?", (principal,)).fetchone()
            if self.db.execute("""SELECT count(*) FROM auth_enrollments e JOIN auth_application_sessions app ON app.enrollment=e.id
                    WHERE e.principal=? AND e.revoked=0 AND app.revoked=0 AND app.expires>?""", (principal,now)).fetchone()[0] >= 16:
                raise RelayError("enrollment_capacity")
            enrollment = {"enrollmentID": str(uuid4()), "phoneDeviceID": "phone_" + secrets.token_urlsafe(24),
                "accountGeneration": row["generation"], "pairingGeneration": str(uuid4()),
                "localEpoch": challenge["localEpoch"], "phoneKeySHA256": fingerprint(challenge["phonePublicKey"]),
                "watchKeySHA256": fingerprint(challenge["watchPublicKey"])}
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.db.execute("INSERT INTO auth_enrollments VALUES(?,?,?,?,?,?,?,?,?,?,0)",
                    (enrollment["enrollmentID"], principal, identity.provider, row["generation"], enrollment["pairingGeneration"],
                     enrollment["phoneDeviceID"], challenge["phonePublicKey"], challenge["watchPublicKey"],
                     enrollment["localEpoch"], identity.expires_at))
                self.db.execute("INSERT INTO auth_application_sessions VALUES(?,?,?,0)",
                    (enrollment["enrollmentID"], now, now + continuity.MAX_APPLICATION_SECONDS))
                credentials = continuity.create_family(self, enrollment["enrollmentID"], kind="phone",
                    client_id="com.zephyrstudiosllc.Peel", resource=self.issuer + "/v1", route=None, scopes=PHONE_SCOPES)
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
            return dict(enrollment, **credentials, provider=identity.provider, grantedScopes=sorted(PHONE_SCOPES),
                identity={"provider": identity.provider, "issuer": identity.issuer, "clientID": identity.client_id,
                          "subject": identity.subject, "verifiedAt": identity.verified_at, "identityExpiresAt": identity.expires_at})

    def _issue(self, enrollment, expires, kind, scopes, routes):
        if self.db.execute("SELECT count(*) FROM auth_sessions WHERE enrollment=? AND revoked=0", (enrollment,)).fetchone()[0] >= 32:
            raise RelayError("session_capacity")
        token = secrets.token_urlsafe(32)
        self.db.execute("INSERT INTO auth_sessions VALUES(?,?,?,?,?,?,0)",
            (hashlib.sha256(token.encode()).hexdigest(), enrollment, expires, kind, encode(sorted(scopes)), encode(list(routes))))
        return token, expires

    def _session(self, token, *, kind, allow_used_refresh=False):
        unb64(token, size=32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        row = self.db.execute("""SELECT s.*, e.principal,e.provider,e.account_generation,e.pair_generation,
          e.device_id,e.phone_key,e.watch_key,e.local_epoch,e.identity_expires,
          e.revoked AS enrollment_revoked,a.generation AS current_generation,a.revoked AS account_revoked,
          app.expires AS application_expires,app.revoked AS application_revoked,
          f.id AS family_id,f.revoked AS family_revoked,f.expires AS family_expires,m.used AS refresh_used
          FROM auth_sessions s JOIN auth_enrollments e ON e.id=s.enrollment
          JOIN auth_accounts a ON a.principal=e.principal
          JOIN auth_application_sessions app ON app.enrollment=e.id
          JOIN auth_family_members m ON m.digest=s.digest
          JOIN auth_token_families f ON f.id=m.family WHERE s.digest=?""", (digest,)).fetchone()
        now = self._time()
        if (row is None or row["kind"] != kind
                or row["revoked"] and not (allow_used_refresh and kind in ("phoneRefresh", "pluginRefresh") and row["refresh_used"])
                or row["enrollment_revoked"] or row["account_revoked"] or row["application_revoked"] or row["family_revoked"]
                or row["expires"] <= now or row["application_expires"] <= now or row["family_expires"] <= now
                or row["current_generation"] != row["account_generation"]):
            raise RelayError("authentication_required")
        return row

    def authenticate(self, environ):
        path = environ.get("PATH_INFO", "")
        authorization = environ.get("HTTP_AUTHORIZATION", "")
        if not isinstance(authorization, str) or not authorization.startswith("Bearer "):
            raise RelayError("authentication_required")
        token = authorization[7:]
        with self.lock:
            kind = "plugin" if path == "/mcp" else "phoneRefresh" if path == "/v1/native/renew" else "phone"
            row = self._session(token, kind=kind, allow_used_refresh=kind == "phoneRefresh")
            self._cleanup(self._time())
            if kind in ("phone", "phoneRefresh"):
                raw = environ.get("peel.raw_body")
                if not isinstance(raw, bytes):
                    raise RelayError("exact_request_body_required")
                enrollment = environ.get("HTTP_X_PEEL_ENROLLMENT")
                if enrollment != row["enrollment"]:
                    raise RelayError("enrollment_mismatch")
                timestamp = environ.get("HTTP_X_PEEL_TIMESTAMP", "")
                if not isinstance(timestamp, str) or not re.fullmatch(r"[1-9][0-9]{0,11}", timestamp) or abs(int(timestamp) - self._time()) > 30:
                    raise RelayError("request_proof_expired")
                nonce = environ.get("HTTP_X_PEEL_NONCE", "")
                unb64(nonce, size=32)
                proof = request_bytes(path, raw, timestamp, nonce, enrollment)
                verify(row["phone_key"], environ.get("HTTP_X_PEEL_SIGNATURE"), proof)
                if self.db.execute("SELECT count(*) FROM auth_nonces WHERE session_digest=?", (row["digest"],)).fetchone()[0] >= 10000:
                    raise RelayError("proof_nonce_capacity")
                try:
                    self.db.execute("INSERT INTO auth_nonces VALUES(?,?,?)", (row["digest"], nonce, self._time() + 120))
                except sqlite3.IntegrityError:
                    raise RelayError("request_proof_reused") from None
            account = _SessionAccount(row["principal"], row["provider"], "chatGPT" if row["provider"] == "dot" else "x",
                row["account_generation"], frozenset(strict_json(row["scopes"])), row["expires"], frozenset(strict_json(row["routes"])),
                credential_digest=row["digest"])
            device = DeviceGrant(row["device_id"], row["pair_generation"]) if kind in ("phone", "phoneRefresh") else None
            environ["peel.auth_session_digest"] = row["digest"]
            environ["peel.auth_enrollment"] = row["enrollment"]
            return RequestAuthority(account, device)

    def current_device(self, account, grant):
        with self.lock:
            now = self._time()
            if isinstance(account, _SessionAccount):
                session = self.db.execute("""SELECT 1 FROM auth_sessions s
                  JOIN auth_family_members m ON m.digest=s.digest JOIN auth_token_families f ON f.id=m.family
                  WHERE s.digest=? AND s.revoked=0 AND s.expires>? AND f.revoked=0 AND f.expires>?""",
                    (account.credential_digest, now, now)).fetchone()
                if session is None:
                    return False
            row = self.db.execute("""SELECT 1 FROM auth_enrollments e JOIN auth_accounts a ON a.principal=e.principal
             JOIN auth_application_sessions app ON app.enrollment=e.id
             WHERE e.principal=? AND e.provider=? AND e.account_generation=? AND e.device_id=? AND e.pair_generation=?
             AND e.revoked=0 AND a.revoked=0 AND a.generation=e.account_generation AND app.revoked=0 AND app.expires>?""",
                (account.principal, account.provider, account.generation, grant.device_id, grant.pairing_generation, now)).fetchone()
            return row is not None

    def commerce_context(self, account, device, enrollment_id=None):
        """Trusted DB context, never request metadata or Apple-account attestation."""
        if not isinstance(device, DeviceGrant):
            raise RelayError("paired_device_authority_required")
        with self.lock:
            if not self.current_device(account, device):
                raise RelayError("device_authority_changed")
            if isinstance(account, _SessionAccount):
                session = self.db.execute("SELECT enrollment FROM auth_sessions WHERE digest=?", (account.credential_digest,)).fetchone()
                if session is None or enrollment_id is not None and session["enrollment"] != enrollment_id:
                    raise RelayError("pro_context_changed")
                enrollment_id = session["enrollment"]
            elif account.scopes != frozenset(("host.deliver",)):
                raise RelayError("verified_session_required")
            rows = self.db.execute("""SELECT e.*,app.expires AS application_expires FROM auth_enrollments e
                JOIN auth_application_sessions app ON app.enrollment=e.id
                WHERE e.principal=? AND e.provider=? AND e.account_generation=? AND e.device_id=? AND e.pair_generation=?
                AND e.revoked=0 AND app.revoked=0 AND app.expires>?""",
                (account.principal, account.provider, account.generation, device.device_id, device.pairing_generation, self._time())).fetchall()
            rows = [r for r in rows if enrollment_id is None or r["id"] == enrollment_id]
            if len(rows) != 1:
                raise RelayError("pro_context_changed")
            row = rows[0]
            return {"principal":row["principal"], "provider":row["provider"], "accountGeneration":row["account_generation"],
                "enrollmentID":row["id"], "phoneDeviceID":row["device_id"], "phoneKeySHA256":fingerprint(row["phone_key"]),
                "watchKeySHA256":fingerprint(row["watch_key"]), "pairingGeneration":row["pair_generation"],
                "localEpoch":row["local_epoch"], "applicationSessionExpiresAt":row["application_expires"]}

    def route_grant(self, environ, authority, body):
        fields(body, ("routeID", "localEpoch"))
        canonical_uuid(body["localEpoch"])
        if self.relay is None:
            raise RelayError("relay_unavailable")
        # Same lock ordering as broker -> authority validation. Route revoke
        # cannot interleave between current-state inspection and grant signing.
        with self.relay.lock:
            return self._owned_route_grant(environ, authority, body)

    def _owned_route_grant(self, environ, authority, body):
        self.relay.assert_device(authority.account, authority.device, body["routeID"])
        status = self.relay.status(authority.account, body["routeID"])
        paid = self.relay.commerce.require_route(authority.account, self.relay._route(authority.account, body["routeID"]))
        if status["ready"] is not True:
            raise RelayError("connection_not_confirmed")
        with self.lock:
            row = self.db.execute("SELECT * FROM auth_enrollments WHERE id=?", (environ["peel.auth_enrollment"],)).fetchone()
            if row is None or row["revoked"] or body["localEpoch"] != row["local_epoch"] or not self.current_device(authority.account, authority.device):
                raise RelayError("enrollment_changed")
            now = self._time()
            route = status["route"]
            claims = {"iss": self.issuer, "aud": "com.zephyrstudiosllc.Peel.watchkitapp", "sub": authority.account.principal,
                "enrollmentID": row["id"], "phoneDeviceID": row["device_id"], "provider": row["provider"],
                "accountGeneration": row["account_generation"], "pairingGeneration": row["pair_generation"],
                "localEpoch": row["local_epoch"], "routeID": route["routeID"], "routeGeneration": route["generation"],
                "audWatchKeySHA256": fingerprint(row["watch_key"]), "phoneKeySHA256": fingerprint(row["phone_key"]),
                "scopes": ["watch.read", "watch.send"], "iat": now,
                "exp": min(now + 300, int(authority.account.expires_at), self.relay.commerce.effective_expiry(paid)), "jti": str(uuid4())}
            return {"routeGrant": jwt.encode(claims, self.signing_key, algorithm="ES256",
                       headers={"alg": "ES256", "kid": self.signing_kid, "typ": "peel-route+jwt"})}

    def revoke(self, environ, authority, *, account_wide=False):
        # Invalidate DB authority first; in-flight broker effects recheck this adapter.
        with self.lock:
            enrollment = environ["peel.auth_enrollment"]
            if account_wide:
                self.db.execute("UPDATE auth_accounts SET revoked=1 WHERE principal=? AND generation=?",
                                (authority.account.principal, authority.account.generation))
                self.db.execute("UPDATE auth_enrollments SET revoked=1 WHERE principal=?", (authority.account.principal,))
            else:
                self.db.execute("UPDATE auth_enrollments SET revoked=1 WHERE id=?", (enrollment,))
            self.db.execute("UPDATE auth_epoch SET value=value+1 WHERE id=1")
        if self.relay is not None:
            if account_wide:
                self.relay.revoke_account(authority.account)
            else:
                # Broker state remains durable; authority is terminal immediately.
                with self.relay.lock:
                    rows = self.relay.db.execute("SELECT id FROM routes WHERE principal=? AND provider=? AND device_id=?",
                        (authority.account.principal, authority.account.provider, authority.device.device_id)).fetchall()
                    for route in rows:
                        # Trusted teardown uses the existing secret-clearing primitive.
                        self.relay._revoke(route["id"])
        return {"revoked": True}

    def renew(self, environ):
        with self.lock:
            row = self._session(environ["HTTP_AUTHORIZATION"][7:], kind="phoneRefresh", allow_used_refresh=True)
            credentials = continuity.rotate(self, row["digest"], kind="phone", client_id="com.zephyrstudiosllc.Peel",
                resource=self.issuer + "/v1")
            return dict(credentials, provider=row["provider"], enrollmentID=row["enrollment"], phoneDeviceID=row["device_id"],
                accountGeneration=row["account_generation"], pairingGeneration=row["pair_generation"], localEpoch=row["local_epoch"],
                phoneKeySHA256=fingerprint(row["phone_key"]), watchKeySHA256=fingerprint(row["watch_key"]), grantedScopes=sorted(PHONE_SCOPES))

    def delivery_accounts(self):
        # Trusted in-process worker capability; never exposed as an HTTP token.
        with self.lock:
            now = self._time()
            rows = self.db.execute("""SELECT e.*,app.expires AS application_expires FROM auth_enrollments e JOIN auth_accounts a ON a.principal=e.principal
              JOIN auth_application_sessions app ON app.enrollment=e.id
              WHERE e.revoked=0 AND a.revoked=0 AND a.generation=e.account_generation AND app.revoked=0 AND app.expires>?""", (now,)).fetchall()
            return [(Account(row["principal"], row["provider"], "chatGPT" if row["provider"] == "dot" else "x",
                row["account_generation"], frozenset(("host.deliver",)), min(now + 30, row["application_expires"])),
                DeviceGrant(row["device_id"], row["pair_generation"])) for row in rows]
