from contextlib import contextmanager
import hmac
import json
import secrets
import sqlite3
import time
from urllib.parse import urlparse

from cryptography.fernet import InvalidToken
from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

from .apple import AppleRejected, AppleTransport, AppleUnavailable, IdentityRejected, IdentityVerifier
from .config import Settings
from .store import Store

CONSENT_VERSION = "2026-10-18.v1"
SESSION_LIFETIME = 30 * 86400
CHALLENGE_LIFETIME = 300
MAX_ACCOUNT_GRANTS = 128
MAX_ACCOUNT_SESSIONS = 32


class APIError(Exception):
    def __init__(self, code, status):
        self.code, self.status = code, status


def bounded_string(value, maximum=4096):
    return isinstance(value, str) and 1 <= len(value) <= maximum and not any(ord(x) < 32 for x in value)


def create_app(settings=None, transport=None, clock=time.time):
    app = Flask(__name__, static_folder=None)
    app.config.update(MAX_CONTENT_LENGTH=24576, PROPAGATE_EXCEPTIONS=False, DEBUG=False)
    # The framework must not emit a traceback containing request-local token values.
    app.logger.disabled = True
    @app.after_request
    def headers(response):
        response.headers.update({"Cache-Control": "no-store", "Pragma": "no-cache",
                                 "X-Content-Type-Options": "nosniff",
                                 "Referrer-Policy": "no-referrer",
                                 "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
                                 "Strict-Transport-Security": "max-age=31536000"})
        return response

    try:
        settings = settings or Settings.from_environment()
        settings.validate()
        transport = transport or AppleTransport(settings)
        store = Store(settings)
        verifier = IdentityVerifier(settings.client_id, transport.jwks, clock)
    except (ValueError, OSError, KeyError, TypeError, InvalidToken, sqlite3.Error):
        # No automatic key/database provisioning, token-only mode, or accidental production fallback.
        @app.route("/", defaults={"path": ""}, methods=["GET", "POST", "DELETE", "PUT", "OPTIONS"])
        @app.route("/<path:path>", methods=["GET", "POST", "DELETE", "PUT", "OPTIONS"])
        def unavailable(path):
            return jsonify(error="account_service_unconfigured"), 503
        return app
    app.config["TRUSTED_HOSTS"] = [urlparse(settings.public_origin).hostname]
    app.extensions.update(peel_store=store, peel_transport=transport, peel_verifier=verifier)

    @app.errorhandler(APIError)
    def api_error(error):
        return jsonify(error=error.code), error.status

    @app.errorhandler(IdentityRejected)
    @app.errorhandler(AppleRejected)
    def unauthorized(error):
        return jsonify(error="apple_authorization_rejected"), 401

    @app.errorhandler(AppleUnavailable)
    @app.errorhandler(sqlite3.Error)
    @app.errorhandler(InvalidToken)
    def unavailable(error):
        return jsonify(error="account_service_temporarily_unavailable"), 503

    @app.errorhandler(Exception)
    def unexpected(error):
        if isinstance(error, HTTPException):
            return jsonify(error="invalid_request"), error.code
        return jsonify(error="account_service_temporarily_unavailable"), 503

    @app.before_request
    def secure_request():
        if not request.is_secure:
            raise APIError("https_required", 400)
        # Native-only API. No cookies/CORS/browser OAuth contract in this candidate.
        if request.headers.get("Origin") or request.headers.get("Cookie"):
            raise APIError("native_client_required", 403)
        if request.query_string:
            raise APIError("query_parameters_not_supported", 400)
        maximum = 10 if request.path == "/v1/challenges" else 60
        if not store.rate_limit((request.remote_addr or "unknown") + ":" + ("challenge" if request.path == "/v1/challenges" else "api"),
                                int(clock()), maximum):
            raise APIError("rate_limited", 429)

    def body(allowed):
        if request.mimetype != "application/json":
            raise APIError("json_required", 415)
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate JSON key")
                result[key] = value
            return result
        try:
            value = json.loads(request.get_data(cache=False), object_pairs_hook=unique,
                               parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (ValueError, UnicodeError):
            raise APIError("invalid_json", 400) from None
        if not isinstance(value, dict) or set(value) - set(allowed):
            raise APIError("invalid_fields", 400)
        return value

    def account_response(row):
        return {"account_id": row["id"], "email": store.decrypt(row["email"]) if row["email"] else None,
                "email_collection_consent": bool(row["email_consent"]),
                "marketing_consent": bool(row["marketing_consent"]),
                "consent_version": row["consent_version"],
                "marketing_delivery_configured": False}

    def require_account():
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer ") or len(authorization) != 50:
            raise APIError("sign_in_required", 401)
        token_hash, now = store.token_hash(authorization[7:]), int(clock())
        refresh_operation = "refresh:" + secrets.token_hex(16)
        with store.db() as db:
            row = db.execute("SELECT a.*,s.issued AS session_issued FROM sessions s JOIN accounts a "
                             "ON a.id=s.account_id WHERE s.token_hash=? AND s.expires>?",
                             (token_hash, now)).fetchone()
            if not row:
                raise APIError("sign_in_required", 401)
            stale = row["verified_at"] <= now - 86400
            if stale:
                if (row["refresh_attempt"] > now - 60 or db.execute(
                        "SELECT 1 FROM grant_reservations WHERE subject_key=? AND id LIKE 'refresh:%'",
                        (row["subject_key"],)).fetchone()):
                    raise APIError("account_service_temporarily_unavailable", 503)
                db.execute("UPDATE accounts SET refresh_attempt=? WHERE id=?", (now, row["id"]))
                db.execute("INSERT INTO grant_reservations VALUES(?,?,?)", (refresh_operation, row["subject_key"], now + 300))
        if stale:
            try:
                result = transport.refresh(store.decrypt(row["refresh"]))
                # Stage any newly returned rotation BEFORE validation or generation checks.
                with staged_refresh(store, result.get("refresh_token"), int(clock()), row["subject_key"], optional=True) as rotated:
                    verified = verifier.verify(result.get("id_token"))
                    if not hmac.compare_digest(store.key("subject", verified["sub"]), row["subject_key"]):
                        raise IdentityRejected()
                    rejected = None
                    with store.db() as db:
                        current_grant = db.execute("SELECT refresh FROM accounts WHERE id=?", (row["id"],)).fetchone()
                        active = db.execute("SELECT expires FROM grant_reservations WHERE id=?", (refresh_operation,)).fetchone()
                        if (not current_grant or current_grant["refresh"] != row["refresh"]
                                or not active or active["expires"] <= int(clock())):
                            rejected = "sign_in_required"
                        elif rotated:
                            count = db.execute("SELECT COUNT(*) FROM grants WHERE account_id=?", (row["id"],)).fetchone()[0]
                            reserved = db.execute("SELECT COUNT(*) FROM grant_reservations WHERE subject_key=? AND id<>?", (row["subject_key"], refresh_operation)).fetchone()[0]
                            if rotated["conflict"]:
                                rejected = "apple_revocation_pending"
                            elif not rotated["known"] and count + reserved >= MAX_ACCOUNT_GRANTS:
                                rejected = "account_grant_capacity_reached"
                            else:
                                adopt_refresh(db, rotated, row["id"], now)
                                db.execute("UPDATE accounts SET refresh=? WHERE id=?", (rotated["encrypted"], row["id"]))
                                row = dict(row, refresh=rotated["encrypted"])
                        if not rejected:
                            db.execute("UPDATE accounts SET verified_at=? WHERE id=? AND refresh=?", (now, row["id"], row["refresh"]))
                            current = db.execute("SELECT a.*,s.issued AS session_issued FROM sessions s JOIN accounts a "
                                                 "ON a.id=s.account_id WHERE s.token_hash=? AND s.expires>?",
                                                 (token_hash, now)).fetchone()
                            if not current:
                                rejected = "sign_in_required"
                            else:
                                row = current
                    if rejected:
                        raise APIError(rejected, 401 if rejected == "sign_in_required" else 409)
            except AppleRejected:
                # User-grant rejection erases only the credential generation checked above.
                with store.db() as db:
                    current = db.execute("SELECT refresh FROM accounts WHERE id=?", (row["id"],)).fetchone()
                    if current and current["refresh"] == row["refresh"]:
                        enqueue_account_revocations(db, row, now)
                        db.execute("INSERT OR REPLACE INTO deletion_fences VALUES(?,?)", (row["subject_key"], now))
                        db.execute("DELETE FROM accounts WHERE id=?", (row["id"],))
                raise APIError("fresh_apple_sign_in_required", 401) from None
            except IdentityRejected:
                with store.db() as db:
                    current = db.execute("SELECT refresh FROM accounts WHERE id=?", (row["id"],)).fetchone()
                    if current and current["refresh"] == row["refresh"]:
                        db.execute("DELETE FROM sessions WHERE account_id=?", (row["id"],))
                raise APIError("fresh_apple_sign_in_required", 401) from None
            finally:
                with store.db() as db:
                    db.execute("DELETE FROM grant_reservations WHERE id=?", (refresh_operation,))
        return row, token_hash

    @app.get("/healthz")
    def health():
        # Configuration readiness, not proof Apple endpoints or cPanel acceptance succeeded.
        return jsonify(status="configured", service="peel-accounts-v1")

    @app.post("/v1/challenges")
    def challenge():
        body(())
        now = int(clock())
        challenge_id, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with store.db() as db:
            store.prune(db, now)
            # Global bound protects the tiny shared-hosting database against distributed flooding.
            if db.execute("SELECT COUNT(*) FROM challenges").fetchone()[0] >= 10000:
                raise APIError("rate_limited", 429)
            db.execute("INSERT INTO challenges VALUES(?,?,?,?)",
                       (store.token_hash(challenge_id), nonce, now, now + CHALLENGE_LIFETIME))
        return jsonify(challenge_id=challenge_id, apple_nonce=nonce, expires_in=CHALLENGE_LIFETIME,
                       client_id=settings.client_id, consent_version=CONSENT_VERSION)

    @app.post("/v1/apple/sign-in")
    def sign_in():
        data = body(("challenge_id", "identity_token", "authorization_code",
                     "email_collection_consent", "marketing_consent", "consent_version"))
        for name, maximum in (("challenge_id", 128), ("identity_token", 16384), ("authorization_code", 4096)):
            if not bounded_string(data.get(name), maximum):
                raise APIError("invalid_fields", 400)
        collect = data.get("email_collection_consent", False)
        marketing = data.get("marketing_consent", False)
        if type(collect) is not bool or type(marketing) is not bool or (marketing and not collect):
            raise APIError("invalid_consent", 400)
        if (collect or marketing) and data.get("consent_version") != CONSENT_VERSION:
            raise APIError("consent_version_required", 400)
        now = int(clock())
        reservation = store.token_hash(data["challenge_id"])
        with store.db() as db:
            row = db.execute("SELECT * FROM challenges WHERE id=? AND expires>?", (reservation, now)).fetchone()
        if not row:
            raise APIError("fresh_challenge_required", 401)
        claims = verifier.verify(data["identity_token"], row["nonce"], data["authorization_code"])
        subject_key = store.key("subject", claims["sub"])
        with store.db() as db:
            consumed = db.execute("DELETE FROM challenges WHERE id=? AND expires>?",
                                  (reservation, int(clock()))).rowcount
            if consumed != 1:
                raise APIError("fresh_challenge_required", 401)
            grants = db.execute("SELECT COUNT(*) FROM grants g JOIN accounts a ON a.id=g.account_id "
                                "WHERE a.subject_key=?", (subject_key,)).fetchone()[0]
            pending = db.execute("SELECT COUNT(*) FROM grant_reservations WHERE subject_key=?", (subject_key,)).fetchone()[0]
            if grants + pending >= MAX_ACCOUNT_GRANTS:
                raise APIError("account_grant_capacity_reached", 409)
            # Reserve capacity before exchange, across Passenger workers. No token is issued at the bound.
            db.execute("INSERT INTO grant_reservations VALUES(?,?,?)", (reservation, subject_key, now + 300))
        try:
            result = transport.exchange(data["authorization_code"])
            with staged_refresh(store, result.get("refresh_token"), int(clock()), subject_key) as credential:
                exchanged = verifier.verify(result.get("id_token"), row["nonce"])
                if exchanged["sub"] != claims["sub"]:
                    raise IdentityRejected()
                refresh, grant_id = credential["encrypted"], credential["id"]
                email_claims = exchanged if exchanged.get("email") is not None else claims
                email = email_claims.get("email")
                verified_email = email_claims.get("email_verified") is True or email_claims.get("email_verified") == "true"
                if email is not None and (not isinstance(email, str) or len(email) > 254 or "@" not in email
                                          or any(ord(x) <= 32 or ord(x) == 127 for x in email)):
                    raise IdentityRejected()
                token, reject = secrets.token_urlsafe(32), None
                with store.db() as db:
                    fence = db.execute("SELECT deleted_at FROM deletion_fences WHERE subject_key=?", (subject_key,)).fetchone()
                    reserved = db.execute("SELECT 1 FROM grant_reservations WHERE id=? AND expires>?", (reservation, int(clock()))).fetchone()
                    old = db.execute("SELECT * FROM accounts WHERE subject_key=?", (subject_key,)).fetchone()
                    account_id = old["id"] if old else secrets.token_hex(16)
                    stored_email = store.encrypt(email) if collect and email and verified_email else None
                    if collect and stored_email is None and old and old["email_consent"]:
                        stored_email = old["email"]
                    if not reserved or (fence and row["created"] <= fence["deleted_at"]):
                        reject = "fresh_apple_sign_in_required"
                    elif credential["conflict"]:
                        reject = "apple_revocation_pending"
                    elif collect and stored_email is None:
                        reject = "verified_email_unavailable"
                    if reject:
                        pass  # Staged credential remains queued; no unverified grant is forgotten.
                    else:
                        if old:
                            db.execute("UPDATE accounts SET email=?,email_consent=?,marketing_consent=?,consent_version=?,"
                                       "consent_at=?,refresh=?,verified_at=?,refresh_attempt=0,authorized_at=? WHERE id=?",
                                       (stored_email, collect, marketing, CONSENT_VERSION, now, refresh, now, now, account_id))
                        else:
                            db.execute("INSERT INTO accounts VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                                       (account_id, subject_key, stored_email, collect, marketing, CONSENT_VERSION,
                                        now, refresh, now, 0, now, now))
                        adopt_refresh(db, credential, account_id, now)
                        db.execute("DELETE FROM sessions WHERE account_id=? AND token_hash IN "
                                   "(SELECT token_hash FROM sessions WHERE account_id=? ORDER BY issued DESC,token_hash "
                                   "LIMIT -1 OFFSET ?)", (account_id, account_id, MAX_ACCOUNT_SESSIONS - 1))
                        db.execute("INSERT INTO sessions VALUES(?,?,?,?)",
                                   (store.token_hash(token), account_id, now, now + SESSION_LIFETIME))
                        account = db.execute("SELECT * FROM accounts WHERE id=?", (account_id,)).fetchone()
                if reject:
                    raise APIError(reject, 409 if reject in ("verified_email_unavailable", "apple_revocation_pending") else 401)
                return jsonify(account=account_response(account), session_token=token, expires_in=SESSION_LIFETIME)
        finally:
            with store.db() as db:
                db.execute("DELETE FROM grant_reservations WHERE id=?", (reservation,))

    @app.post("/v1/apple/notifications")
    def apple_notification():
        data = body(("payload",))
        claims = verifier.notification(data.get("payload"))
        event, now = claims["events"], int(clock())
        subject_key = store.key("subject", event["sub"])
        notification_id = store.token_hash(claims["jti"])
        with store.db() as db:
            store.prune(db, now)
            if db.execute("SELECT 1 FROM notifications WHERE id=?", (notification_id,)).fetchone():
                return "", 204
            if db.execute("SELECT COUNT(*) FROM notifications").fetchone()[0] >= 100000:
                raise APIError("notification_capacity_unavailable", 503)
            db.execute("INSERT INTO notifications VALUES(?,?)", (notification_id, claims["iat"]))
            row = db.execute("SELECT * FROM accounts WHERE subject_key=?", (subject_key,)).fetchone()
            if event["type"] in ("consent-revoked", "account-deleted"):
                # Preserve a short fence even if a sign-in is still exchanging its code.
                if not row or row["authorized_at"] <= event["event_time"]:
                    db.execute("INSERT OR REPLACE INTO deletion_fences VALUES(?,?)", (subject_key, now))
                    if row:
                        enqueue_account_revocations(db, row, now)
                        db.execute("DELETE FROM accounts WHERE id=?", (row["id"],))
            elif event["type"] == "email-disabled" and row and row["authorized_at"] <= event["event_time"]:
                db.execute("UPDATE accounts SET email=NULL,email_consent=0,marketing_consent=0 WHERE id=?", (row["id"],))
            # email-enabled acknowledges delivery status only; never re-add email or marketing consent.
        return "", 204

    @app.get("/v1/account")
    def account():
        row, _ = require_account()
        return jsonify(account=account_response(row))

    @app.put("/v1/account/preferences")
    def preferences():
        data = body(("email_collection_consent", "marketing_consent", "consent_version"))
        row, _ = require_account()
        collect = data.get("email_collection_consent", bool(row["email_consent"]))
        marketing = data.get("marketing_consent", False)
        if type(collect) is not bool or type(marketing) is not bool or marketing and not collect:
            raise APIError("invalid_consent", 400)
        if (collect or marketing) and data.get("consent_version") != CONSENT_VERSION:
            raise APIError("consent_version_required", 400)
        if collect and not row["email"]:
            raise APIError("fresh_apple_sign_in_required", 409)
        with store.db() as db:
            updated = db.execute("UPDATE accounts SET email=?,email_consent=?,marketing_consent=?,"
                                 "consent_version=?,consent_at=? WHERE id=?",
                                 (row["email"] if collect else None, collect, marketing, CONSENT_VERSION,
                                  int(clock()), row["id"])).rowcount
            if not updated:
                raise APIError("sign_in_required", 401)
            row = db.execute("SELECT * FROM accounts WHERE id=?", (row["id"],)).fetchone()
        return jsonify(account=account_response(row))

    @app.post("/v1/account/sign-out")
    def sign_out():
        body(())
        _, token_hash = require_account()
        with store.db() as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash,))
        return "", 204

    @app.delete("/v1/account")
    def delete_account():
        data = body(("challenge_id", "identity_token"))
        now = int(clock())
        if data:
            # Fresh native Apple proof can delete even when the grant ledger is full or a
            # company bearer expired. It creates no new refresh credential or company session.
            if not bounded_string(data.get("challenge_id"), 128) or not bounded_string(data.get("identity_token"), 16384):
                raise APIError("invalid_fields", 400)
            challenge_hash = store.token_hash(data["challenge_id"])
            with store.db() as db:
                challenge = db.execute("SELECT * FROM challenges WHERE id=? AND expires>?", (challenge_hash, now)).fetchone()
            if not challenge:
                raise APIError("fresh_challenge_required", 401)
            proof = verifier.verify(data["identity_token"], challenge["nonce"])
            subject_key = store.key("subject", proof["sub"])
            with store.db() as db:
                if db.execute("DELETE FROM challenges WHERE id=? AND expires>?", (challenge_hash, now)).rowcount != 1:
                    raise APIError("fresh_challenge_required", 401)
                row = db.execute("SELECT * FROM accounts WHERE subject_key=?", (subject_key,)).fetchone()
                if not row:
                    # Also fence a first-ever sign-in still exchanging its grant.
                    db.execute("INSERT OR REPLACE INTO deletion_fences VALUES(?,?)", (subject_key, now))
                    pending = subject_pending(db, subject_key)
                    return jsonify(account_deleted=True, apple_revocation_complete=False,
                                   apple_revocation_pending=pending,
                                   manual_apple_revocation_required=not pending), 202 if pending else 200
        else:
            row, _ = require_account()
            if row["session_issued"] < now - 300:
                raise APIError("fresh_apple_sign_in_required", 409)
        with store.db() as db:
            current = db.execute("SELECT * FROM accounts WHERE id=?", (row["id"],)).fetchone()
            if not current:
                raise APIError("sign_in_required", 401)
            jobs = enqueue_account_revocations(db, current, now)
            db.execute("INSERT OR REPLACE INTO deletion_fences VALUES(?,?)", (row["subject_key"], now))
            db.execute("DELETE FROM accounts WHERE id=?", (row["id"],))
        # One immediate network call; additional grants are processed by bounded maintenance.
        if jobs:
            process_revocation(store, transport, jobs[0], now)
        with store.db() as db:
            pending = subject_pending(db, row["subject_key"])
        return jsonify(account_deleted=True, apple_revocation_complete=not pending,
                       apple_revocation_pending=pending), 202 if pending else 200

    return app


@contextmanager
def staged_refresh(store, raw, now, subject_key, optional=False):
    """Durably retain an issued grant before any later check can fail or suspend."""
    if raw is None and optional:
        yield None
        return
    if not bounded_string(raw, 8192):
        raise AppleUnavailable()
    credential = {"id": store.key("grant", raw), "encrypted": store.encrypt(raw)}
    with store.db() as db:
        credential["known"] = bool(db.execute("SELECT 1 FROM grants WHERE id=?", (credential["id"],)).fetchone())
        credential["conflict"] = bool(db.execute("SELECT 1 FROM revocations WHERE id=?", (credential["id"],)).fetchone())
        staged = not credential["known"] and not credential["conflict"]
        credential["staged"], credential["deadline"] = staged, now + 300
        if staged:
            db.execute("INSERT INTO revocations(id,refresh,created,subject_key,next_attempt) VALUES(?,?,?,?,?)",
                       (credential["id"], credential["encrypted"], now, subject_key, now + 300))
    try:
        yield credential
    finally:
        if staged:
            # On success adoption removed this row; on any failure/crash it remains durable.
            with store.db() as db:
                db.execute("UPDATE revocations SET next_attempt=MIN(next_attempt,?) WHERE id=?", (now, credential["id"]))


def adopt_refresh(db, credential, account_id, now):
    queued = db.execute("SELECT * FROM revocations WHERE id=?", (credential["id"],)).fetchone()
    if (credential["conflict"] or (queued and not credential["staged"])
            or (credential["staged"] and (not queued or queued["attempts"] != 0
                                          or queued["next_attempt"] != credential["deadline"]))):
        # Never adopt a grant after maintenance has claimed/revoked it, or remove another
        # operation's revocation request using a stale pre-network snapshot.
        raise APIError("apple_revocation_pending", 409)
    old = db.execute("SELECT account_id FROM grants WHERE id=?", (credential["id"],)).fetchone()
    if old and old["account_id"] != account_id:
        raise IdentityRejected()
    db.execute("INSERT OR IGNORE INTO grants VALUES(?,?,?,?)", (credential["id"], account_id, credential["encrypted"], now))
    db.execute("DELETE FROM revocations WHERE id=?", (credential["id"],))


def subject_pending(db, subject_key):
    return bool(db.execute("SELECT 1 FROM revocations WHERE subject_key=? LIMIT 1", (subject_key,)).fetchone()
                or db.execute("SELECT 1 FROM grant_reservations WHERE subject_key=? LIMIT 1", (subject_key,)).fetchone())


def enqueue_account_revocations(db, row, now):
    grants = db.execute("SELECT id,refresh FROM grants WHERE account_id=?", (row["id"],)).fetchall()
    if not grants:
        # Retain/revoke the current encrypted credential even if a ledger invariant is
        # damaged; never report revocation complete merely because its ledger is empty.
        grants = [{"id": secrets.token_hex(16), "refresh": row["refresh"]}]
    ids = []
    for grant in grants:
        db.execute("INSERT OR IGNORE INTO revocations(id,refresh,created,subject_key) VALUES(?,?,?,?)",
                   (grant["id"], grant["refresh"], now, row["subject_key"]))
        ids.append(grant["id"])
    return ids


def process_revocation(store, transport, job_id, now):
    with store.db() as db:
        job = db.execute("SELECT * FROM revocations WHERE id=? AND next_attempt<=?", (job_id, now)).fetchone()
        if not job:
            return False
        # Reserve work before network; another Passenger/cron worker cannot duplicate this attempt.
        db.execute("UPDATE revocations SET attempts=attempts+1,next_attempt=? WHERE id=?",
                   (now + min(86400, 300 * (2 ** min(job["attempts"], 8))), job_id))
    try:
        transport.revoke(store.decrypt(job["refresh"]))
    except (AppleUnavailable, AppleRejected, InvalidToken):
        return False
    with store.db() as db:
        db.execute("DELETE FROM revocations WHERE id=?", (job_id,))
    return True
