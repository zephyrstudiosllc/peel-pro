"""Durable new-message inbox, scoped agent replies and Dot MCP Events.

Account and DeviceGrant are trusted adapter outputs, NEVER request JSON. The
HTTP/native composition must verify its own OAuth session and current Peel
pairing proof before constructing them. This module neither invents that
authority nor reads provider credentials. A confirmed plugin route is explicit;
its identifiers are not claimed to be ChatGPT conversation identifiers.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import secrets
import sqlite3
import stat
import threading
import time
import weakref
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable
from uuid import UUID, uuid4

from .webhooks import WebhookError, parse_signing_secret, signed_headers, verify_callback


def utf8(value: str) -> bytes:
    try:
        return value.encode("utf-8")
    except UnicodeError:
        raise RelayError("invalid_unicode") from None


class RelayError(ValueError):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def opaque(value: str, limit: int = 256) -> str:
    if not isinstance(value, str) or not value.strip() or len(utf8(value)) > limit:
        raise RelayError("invalid_identifier")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise RelayError("invalid_identifier")
    return value


def uuid_string(value: str) -> str:
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise RelayError("invalid_generation") from None


def encode(value: object) -> bytes:
    try:
        return json.dumps(value, allow_nan=False, ensure_ascii=False,
                          sort_keys=True, separators=(",", ":")).encode()
    except (ValueError, TypeError, UnicodeError):
        raise RelayError("invalid_payload") from None


@dataclass(frozen=True)
class Account:
    principal: str
    provider: str
    identity_method: str
    generation: str
    scopes: frozenset[str]
    expires_at: float
    route_ids: frozenset[str] = frozenset()

    def __post_init__(self):
        opaque(self.principal)
        if {"dot": "chatGPT", "grokBot": "x"}.get(self.provider) != self.identity_method:
            raise RelayError("identity_provider_mismatch")
        object.__setattr__(self, "generation", uuid_string(self.generation))
        if not isinstance(self.scopes, frozenset) or not all(isinstance(s, str) for s in self.scopes):
            raise RelayError("invalid_scopes")
        if not isinstance(self.route_ids, frozenset) or not all(isinstance(s, str) for s in self.route_ids):
            raise RelayError("invalid_route_scope")
        if type(self.expires_at) not in (int, float) or not math.isfinite(self.expires_at) or self.expires_at <= 0:
            raise RelayError("invalid_principal_expiry")

    def require(self, scope: str):
        if scope not in self.scopes:
            raise RelayError("access_denied")


@dataclass(frozen=True)
class DeviceGrant:
    device_id: str
    pairing_generation: str

    def __post_init__(self):
        opaque(self.device_id)
        object.__setattr__(self, "pairing_generation", uuid_string(self.pairing_generation))


class RelayStore:
    MAX_REQUESTS = 256
    MAX_ROUTES = 64
    MAX_SUBSCRIPTIONS = 8
    MAX_ATTEMPTS = 6
    MAX_REPLY_PAGE_BYTES = 256 * 1024
    EVENT = "watch.message.created"

    def __init__(self, data_directory: Path,
                 authority: Callable[[Account, DeviceGrant], bool], *,
                 now: Callable[[], float] = time.time):
        if not callable(authority):
            raise RelayError("authority_adapter_required")
        if os.name != "posix":
            raise RelayError("posix_backend_required")
        self.authority = authority
        from .commerce_admission import UnavailableCommerce
        self.commerce = UnavailableCommerce()
        self.now = now
        self.owner_pid = os.getpid()
        self.lock = threading.RLock()
        self.owner_fd = None
        directory = Path(data_directory)
        if directory.is_symlink():
            raise RelayError("unsafe_storage")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        meta = directory.stat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) & 0o077:
            raise RelayError("unsafe_storage")
        # WSGI must share ONE store instance across its threads. Enforce that
        # invariant across processes/instances instead of trusting deployment
        # flags; the SQL store and delivery/revoke gate have one owner.
        import fcntl
        lock_fd = os.open(directory / "owner.lock", os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            lock_meta = os.fstat(lock_fd)
            if not stat.S_ISREG(lock_meta.st_mode) or lock_meta.st_uid != os.getuid() or stat.S_IMODE(lock_meta.st_mode) & 0o077:
                raise RelayError("unsafe_storage")
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException as error:
            os.close(lock_fd)
            if isinstance(error, BlockingIOError):
                raise RelayError("store_already_owned") from None
            raise
        self.owner_fd = lock_fd
        self.owner_finalizer = weakref.finalize(self, os.close, lock_fd)
        path = directory / "relay.sqlite3"
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags, 0o600)
        try:
            meta = os.fstat(fd)
            if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) & 0o077:
                raise RelayError("unsafe_storage")
        finally:
            os.close(fd)
        self.db = sqlite3.connect(path, isolation_level=None, check_same_thread=False, timeout=1)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS routes(
          id TEXT PRIMARY KEY, principal TEXT NOT NULL, provider TEXT NOT NULL,
          account_generation TEXT NOT NULL, device_id TEXT NOT NULL,
          pairing_generation TEXT NOT NULL, generation TEXT NOT NULL,
          agent_reference TEXT NOT NULL, mode TEXT NOT NULL,
          challenge_digest TEXT, confirmed INTEGER NOT NULL DEFAULT 0,
          revoked INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS subscriptions(
          id TEXT PRIMARY KEY, route TEXT NOT NULL REFERENCES routes(id),
          callback TEXT NOT NULL, secret TEXT NOT NULL, old_secret TEXT,
          old_until REAL, expires REAL NOT NULL, active INTEGER NOT NULL,
          revision TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS verifications(
          id TEXT PRIMARY KEY, route TEXT NOT NULL REFERENCES routes(id), operation TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS callback_cache(
          id TEXT PRIMARY KEY, expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS requests(
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL,
          route TEXT NOT NULL REFERENCES routes(id), digest TEXT NOT NULL,
          text TEXT NOT NULL, created REAL NOT NULL, reply TEXT,
          reply_id TEXT, UNIQUE(route,id));
        CREATE TABLE IF NOT EXISTS reply_order(
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          request_sequence INTEGER NOT NULL UNIQUE REFERENCES requests(sequence));
        CREATE TABLE IF NOT EXISTS deliveries(
          id TEXT PRIMARY KEY, request_sequence INTEGER NOT NULL REFERENCES requests(sequence),
          subscription TEXT NOT NULL REFERENCES subscriptions(id), body BLOB NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL,
          state TEXT NOT NULL DEFAULT 'pending', last_status INTEGER);
        """)
        # Old routes cannot acquire a fabricated commerce enrollment on restart.
        for table, column in (("routes", "commerce_enrollment"), ("deliveries", "commerce_permit")):
            if column not in {r[1] for r in self.db.execute("PRAGMA table_info(" + table + ")")}:
                self.db.execute("ALTER TABLE " + table + " ADD COLUMN " + column + " TEXT")

    def close(self):
        with self.lock:
            if os.getpid() != self.owner_pid:
                # Never LOCK_UN an inherited flock: parent and child share its
                # open-file description. Closing only this process's duplicate
                # descriptor leaves the parent's lock intact.
                if self.owner_fd is not None:
                    self.owner_finalizer()
                    self.owner_fd = None
                raise RelayError("store_process_changed")
            self.db.close()
            if self.owner_fd is not None:
                import fcntl
                fcntl.flock(self.owner_fd, fcntl.LOCK_UN)
                self.owner_finalizer()
                self.owner_fd = None

    def _time(self) -> float:
        value = self.now()
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise RelayError("invalid_clock")
        return float(value)

    def _route(self, account: Account, route_id: str, *, require_active=False):
        self.authorize(account)
        row = self.db.execute("SELECT * FROM routes WHERE id=?", (opaque(route_id),)).fetchone()
        if row is None or row["principal"] != account.principal or row["provider"] != account.provider:
            raise RelayError("access_denied")
        if row["account_generation"] != account.generation or row["revoked"]:
            raise RelayError("route_revoked")
        if any(s.startswith("agent.") for s in account.scopes) and route_id not in account.route_ids:
            raise RelayError("route_access_denied")
        grant = DeviceGrant(row["device_id"], row["pairing_generation"])
        if not self.authority(account, grant):
            raise RelayError("device_authority_changed")
        if require_active and not self._ready(row):
            raise RelayError("connection_not_confirmed")
        return row

    def authorize(self, account: Account, scope: str | None = None):
        if os.getpid() != self.owner_pid:
            raise RelayError("store_process_changed")
        if not isinstance(account, Account) or account.expires_at <= self._time():
            raise RelayError("principal_expired")
        if scope:
            account.require(scope)

    def assert_device(self, account: Account, grant: DeviceGrant, route_id: str):
        """Bind a phone HTTP operation to its independently verified paired device."""
        with self.lock:
            row = self._route(account, route_id)
            if row["device_id"] != grant.device_id or row["pairing_generation"] != grant.pairing_generation:
                raise RelayError("device_access_denied")

    def _ready(self, route) -> bool:
        if not route["confirmed"] or route["revoked"]:
            return False
        if route["mode"] == "routine":
            return True
        return self.db.execute("SELECT 1 FROM subscriptions WHERE route=? AND active=1 AND expires>? LIMIT 1",
                               (route["id"], self._time())).fetchone() is not None

    @staticmethod
    def reference(row) -> dict:
        return {"kind": "pluginRelay", "provider": row["provider"],
                "routeID": row["id"], "generation": row["generation"],
                "accountGeneration": row["account_generation"]}

    def connect(self, account: Account, grant: DeviceGrant, agent_reference: str) -> dict:
        self.authorize(account, "watch.connect")
        opaque(agent_reference)
        if not self.authority(account, grant):
            raise RelayError("device_access_denied")
        with self.lock:
            self.authorize(account, "watch.connect")
            if not self.authority(account, grant):
                raise RelayError("device_access_denied")
            paid = self.commerce.require_connect(account, grant)
            enrollment = json.loads(paid.binding)["enrollmentID"]
            count = self.db.execute("SELECT count(*) FROM routes WHERE principal=?", (account.principal,)).fetchone()[0]
            if count >= self.MAX_ROUTES:
                raise RelayError("route_capacity")
            # A fresh connection invalidates the same account/provider/device's
            # prior route before publishing new authority. No silent fallback.
            self.db.execute("BEGIN IMMEDIATE")
            try:
                old = self.db.execute("SELECT id FROM routes WHERE principal=? AND provider=? AND device_id=? AND revoked=0",
                                      (account.principal, account.provider, grant.device_id)).fetchall()
                for row in old:
                    self._revoke(row["id"])
                route_id = "route_" + uuid4().hex
                generation = str(uuid4())
                challenge = secrets.token_urlsafe(32)
                self.db.execute("INSERT INTO routes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (route_id, account.principal, account.provider, account.generation,
                     grant.device_id, grant.pairing_generation, generation, agent_reference,
                     "events" if account.provider == "dot" else "routine",
                     hashlib.sha256(utf8(challenge)).hexdigest(), 0, 0, self._time(), enrollment))
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
            route = self._route(account, route_id)
            try:
                self.commerce.bind_route(account, grant, route, paid)
            except BaseException:
                self._revoke(route_id)
                raise
            return {"route": self.reference(route), "confirmationChallenge": challenge,
                    "state": "authorizePlugin", "minimumRoutineIntervalSeconds": 300 if account.provider == "grokBot" else None}

    def confirm(self, account: Account, route_id: str, challenge: str) -> dict:
        account.require("agent.confirm")
        opaque(challenge)
        with self.lock:
            row = self._route(account, route_id)
            self.commerce.require_route(account, row)
            digest = hashlib.sha256(utf8(challenge)).hexdigest()
            if self._time() > row["created"] + 600 or row["challenge_digest"] is None or not hmac.compare_digest(row["challenge_digest"], digest):
                raise RelayError("invalid_confirmation")
            self.db.execute("UPDATE routes SET confirmed=1,challenge_digest=NULL WHERE id=?", (route_id,))
            return self._status(self._route(account, route_id))

    def _status(self, row):
        ready = self._ready(row)
        manual = row["mode"] == "routine"
        return {"route": self.reference(row), "ready": ready,
                "state": ("manualReady" if manual else "connected") if ready else "authorizePlugin",
                "deliveryMode": "manual" if manual else "events",
                "automaticDeliveryReady": ready and not manual,
                "minimumRoutineIntervalSeconds": 300 if row["mode"] == "routine" else None}

    def status(self, account: Account, route_id: str) -> dict:
        account.require("watch.read")
        with self.lock:
            row = self._route(account, route_id)
            self.commerce.require_route(account, row)
            return self._status(row)

    def _revoke(self, route_id: str):
        self.db.execute("UPDATE routes SET revoked=1,challenge_digest=NULL WHERE id=?", (route_id,))
        self.db.execute("UPDATE subscriptions SET active=0,secret='',old_secret=NULL WHERE route=?", (route_id,))
        self.db.execute("DELETE FROM verifications WHERE route=?", (route_id,))
        self.db.execute("UPDATE deliveries SET state='revoked' WHERE request_sequence IN (SELECT sequence FROM requests WHERE route=?) AND state='pending'", (route_id,))

    def revoke(self, account: Account, route_id: str):
        account.require("watch.connect")
        with self.lock:
            self._route(account, route_id)
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self._revoke(route_id)
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise

    def revoke_account(self, account: Account):
        """Called by the trusted sign-out adapter before acknowledging sign-out."""
        self.authorize(account, "watch.connect")
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                rows = self.db.execute("SELECT id FROM routes WHERE principal=? AND provider=? AND revoked=0",
                                       (account.principal, account.provider)).fetchall()
                for row in rows:
                    self._revoke(row["id"])
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise

    def send(self, account: Account, route_id: str, generation: str, request_id: str, text: str) -> dict:
        account.require("watch.send")
        request_id = uuid_string(request_id)
        generation = uuid_string(generation)
        if not isinstance(text, str) or not text.strip() or len(text) > 4000 or len(utf8(text)) > 16000:
            raise RelayError("invalid_message")
        if any(ord(c) < 32 and c not in "\n\t" for c in text) or "\x7f" in text:
            raise RelayError("invalid_message")
        digest = hashlib.sha256(encode([route_id, generation, text])).hexdigest()
        with self.lock:
            row = self._route(account, route_id, require_active=True)
            paid = self.commerce.require_route(account, row)
            if row["generation"] != uuid_string(generation):
                raise RelayError("route_generation_changed")
            existing = self.db.execute("SELECT * FROM requests WHERE route=? AND id=?", (route_id, request_id)).fetchone()
            if existing:
                if existing["digest"] != digest:
                    raise RelayError("reused_request_id")
                return self._receipt(existing, row)
            count = self.db.execute("SELECT count(*) FROM requests WHERE route=?", (route_id,)).fetchone()[0]
            if count >= self.MAX_REQUESTS:
                raise RelayError("inbox_capacity")
            now = self._time()
            self.db.execute("BEGIN IMMEDIATE")
            try:
                cursor = self.db.execute("INSERT INTO requests(id,route,digest,text,created) VALUES(?,?,?,?,?)",
                                         (request_id, route_id, digest, text, now))
                sequence = cursor.lastrowid
                subscriptions = self.db.execute("SELECT * FROM subscriptions WHERE route=? AND active=1 AND expires>?", (route_id, now)).fetchall()
                for sub in subscriptions:
                    event_id = "evt_" + hashlib.sha256(encode([sub["id"], request_id])).hexdigest()
                    body = encode({"eventId": event_id, "name": self.EVENT,
                        "timestamp": datetime.fromtimestamp(now, timezone.utc).isoformat(),
                        "data": {"route_id": route_id, "generation": row["generation"], "request_id": request_id, "text": text}, "cursor": None})
                    self.db.execute("INSERT INTO deliveries(id,request_sequence,subscription,body,next_attempt,commerce_permit) VALUES(?,?,?,?,?,?)",
                                    (event_id, sequence, sub["id"], body, now, paid.id))
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
            request = self.db.execute("SELECT * FROM requests WHERE sequence=?", (sequence,)).fetchone()
            return self._receipt(request, row)

    @staticmethod
    def _receipt(request, route):
        return {"requestID": request["id"], "route": RelayStore.reference(route),
                "receiptID": "request_" + str(request["sequence"]),
                "state": "replied" if request["reply_id"] else "accepted",
                "agentReplyReceived": bool(request["reply_id"])}

    def inbox(self, account: Account, route_id: str, limit=15) -> dict:
        account.require("agent.inbox")
        if type(limit) is not int or not 1 <= limit <= 15:
            raise RelayError("invalid_limit")
        with self.lock:
            row = self._route(account, route_id, require_active=True)
            paid = self.commerce.require_route(account, row)
            requests = self.db.execute("SELECT id,text FROM requests WHERE route=? AND reply_id IS NULL ORDER BY sequence LIMIT ?", (route_id, limit)).fetchall()
            return {"route": self.reference(row), "requests": [{"requestID": x["id"], "text": x["text"]} for x in requests]}

    def reply(self, account: Account, route_id: str, generation: str, request_id: str, reply_id: str, text: str) -> dict:
        account.require("agent.reply")
        request_id = uuid_string(request_id)
        opaque(reply_id)
        if not isinstance(text, str) or not text.strip() or len(utf8(text)) > 32000:
            raise RelayError("invalid_reply")
        if any(ord(c) < 32 and c not in "\n\t" for c in text) or "\x7f" in text:
            raise RelayError("invalid_reply")
        with self.lock:
            row = self._route(account, route_id, require_active=True)
            paid = self.commerce.require_route(account, row)
            if row["generation"] != uuid_string(generation):
                raise RelayError("route_generation_changed")
            request = self.db.execute("SELECT * FROM requests WHERE route=? AND id=?", (route_id, request_id)).fetchone()
            if request is None:
                raise RelayError("unknown_request")
            if request["reply_id"] is not None:
                if request["reply_id"] != reply_id or request["reply"] != text:
                    raise RelayError("reply_conflict")
            else:
                self.db.execute("BEGIN IMMEDIATE")
                try:
                    self.db.execute("UPDATE requests SET reply=?,reply_id=? WHERE sequence=? AND reply_id IS NULL", (text, reply_id, request["sequence"]))
                    self.db.execute("INSERT INTO reply_order(request_sequence) VALUES(?)", (request["sequence"],))
                    self.db.execute("COMMIT")
                except BaseException:
                    self.db.execute("ROLLBACK")
                    raise
            return {"requestID": request_id, "replyID": reply_id, "stored": True}

    def replies(self, account: Account, route_id: str, generation: str, after=0) -> dict:
        account.require("watch.read")
        if type(after) is not int or after < 0:
            raise RelayError("invalid_cursor")
        with self.lock:
            row = self._route(account, route_id, require_active=True)
            paid = self.commerce.require_route(account, row)
            if row["generation"] != uuid_string(generation):
                raise RelayError("route_generation_changed")
            records = self.db.execute("SELECT r.sequence,q.id,q.reply,q.reply_id FROM reply_order r JOIN requests q ON q.sequence=r.request_sequence WHERE q.route=? AND r.sequence>? ORDER BY r.sequence LIMIT 15", (route_id, after)).fetchall()
            page = {"route": self.reference(row), "replies": [], "cursor": after}
            for record in records:
                reply = {"requestID": record["id"], "replyID": record["reply_id"], "text": record["reply"]}
                candidate = {"route": page["route"], "replies": page["replies"] + [reply], "cursor": record["sequence"]}
                if len(encode(candidate)) > self.MAX_REPLY_PAGE_BYTES:
                    if not page["replies"]:
                        raise RelayError("reply_too_large")
                    break
                page = candidate
            return page

    def subscribe(self, account: Account, route_id: str, callback: str, secret: str,
                  transport, *, ttl_ms=3600000) -> dict:
        account.require("agent.subscribe")
        if account.provider != "dot":
            raise RelayError("events_not_established_for_provider")
        parse_signing_secret(secret)
        if type(ttl_ms) is not int or not 60000 <= ttl_ms <= 86400000:
            raise RelayError("invalid_subscription_lifetime")
        subscription_id = "sub_" + hashlib.sha256(encode([account.principal, route_id, self.EVENT, callback])).hexdigest()
        cache_id = hashlib.sha256(encode([account.principal, account.provider, account.generation,
                                         callback, hashlib.sha256(parse_signing_secret(secret)).hexdigest()])).hexdigest()
        operation = uuid4().hex
        with self.lock:
            row = self._route(account, route_id)
            paid = self.commerce.require_route(account, row)
            count = self.db.execute("SELECT count(*) FROM subscriptions WHERE route=?", (route_id,)).fetchone()[0]
            verifying = self.db.execute("SELECT count(*) FROM verifications WHERE route=?", (route_id,)).fetchone()[0]
            prior = self.db.execute("SELECT id FROM subscriptions WHERE id=?", (subscription_id,)).fetchone()
            if not prior and (count >= self.MAX_SUBSCRIPTIONS or verifying >= self.MAX_SUBSCRIPTIONS):
                raise RelayError("subscription_capacity")
            self.db.execute("INSERT OR REPLACE INTO verifications VALUES(?,?,?)", (subscription_id, route_id, operation))
            cached = self.db.execute("SELECT 1 FROM callback_cache WHERE id=? AND expires>?", (cache_id, self._time())).fetchone() is not None
        # Callback I/O happens before activation. A late verification cannot
        # resurrect a revoked/unsubscribed/replaced route or refresh operation.
        try:
            if not cached:
                verify_callback(callback, secret, subscription_id, transport, now=self.now)
        except BaseException:
            with self.lock:
                self.db.execute("DELETE FROM verifications WHERE id=? AND operation=?", (subscription_id, operation))
            raise
        with self.lock:
            row = self._route(account, route_id)
            self.commerce.require_route(account, row, paid.id)
            pending = self.db.execute("SELECT operation FROM verifications WHERE id=?", (subscription_id,)).fetchone()
            if pending is None or pending["operation"] != operation:
                raise RelayError("subscription_changed")
            now = self._time()
            prior = self.db.execute("SELECT secret FROM subscriptions WHERE id=?", (subscription_id,)).fetchone()
            expires = now + ttl_ms / 1000
            self.db.execute("INSERT INTO subscriptions VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET secret=excluded.secret,old_secret=excluded.old_secret,old_until=excluded.old_until,expires=excluded.expires,active=1,revision=excluded.revision", (subscription_id, route_id, callback,
                secret, prior["secret"] if prior and prior["secret"] != secret else None, now + 60, expires, 1, operation))
            self.db.execute("DELETE FROM verifications WHERE id=?", (subscription_id,))
            self.db.execute("DELETE FROM callback_cache WHERE expires<=?", (now,))
            if not cached and self.db.execute("SELECT count(*) FROM callback_cache").fetchone()[0] < 1024:
                self.db.execute("INSERT OR REPLACE INTO callback_cache VALUES(?,?)", (cache_id, now + 300))
            return {"id": subscription_id, "refreshBefore": datetime.fromtimestamp(expires, timezone.utc).isoformat(), "cursor": None, "truncated": False}

    def unsubscribe(self, account: Account, route_id: str, callback: str):
        account.require("agent.subscribe")
        subscription_id = "sub_" + hashlib.sha256(encode([account.principal, route_id, self.EVENT, callback])).hexdigest()
        with self.lock:
            self._route(account, route_id)
            self.db.execute("DELETE FROM verifications WHERE id=?", (subscription_id,))
            self.db.execute("UPDATE subscriptions SET active=0,secret='',old_secret=NULL WHERE id=?", (subscription_id,))
            self.db.execute("UPDATE deliveries SET state='unsubscribed' WHERE subscription=? AND state='pending'", (subscription_id,))

    def deliver_one(self, account: Account, route_id: str, transport) -> dict:
        """Run on a dedicated delivery worker, never the phone/UI request loop.

Admission and one bounded HTTPS attempt serialize with revoke. Revoke can
wait for that admitted <=10s attempt; after revoke returns no new attempt
can start. An already accepted event/agent task cannot be recalled here.
"""
        account.require("host.deliver")
        with self.lock:
            row = self._route(account, route_id, require_active=True)
            now = self._time()
            delivery = self.db.execute("SELECT d.*,s.callback,s.secret,s.old_secret,s.old_until,s.active,s.expires FROM deliveries d JOIN subscriptions s ON s.id=d.subscription JOIN requests q ON q.sequence=d.request_sequence WHERE q.route=? AND d.state='pending' AND d.next_attempt<=? ORDER BY q.sequence LIMIT 1", (route_id, now)).fetchone()
            if delivery is None:
                return {"state": "idle"}
            try:
                if not delivery["commerce_permit"]:
                    raise RelayError("pro_required")
                self.commerce.require_route(account, row, delivery["commerce_permit"])
            except RelayError:
                self.db.execute("UPDATE deliveries SET state='commerce_blocked' WHERE id=?", (delivery["id"],))
                raise
            if not delivery["active"] or delivery["expires"] <= now:
                self.db.execute("UPDATE deliveries SET state='subscription_expired' WHERE id=?", (delivery["id"],))
                return {"state": "subscription_expired"}
            attempts = delivery["attempts"] + 1
            if attempts > self.MAX_ATTEMPTS:
                self.db.execute("UPDATE deliveries SET state='exhausted' WHERE id=?", (delivery["id"],))
                return {"state": "exhausted"}
            # Persist retry deadline BEFORE network I/O. A crash can repeat a
            # webhook with the SAME event ID, never create a second request.
            self.db.execute("UPDATE deliveries SET attempts=?,next_attempt=? WHERE id=?", (attempts, now + min(300, 2 ** attempts), delivery["id"]))
            body = bytes(delivery["body"])
            headers = signed_headers(delivery["id"], delivery["secret"], body, int(now), delivery["subscription"])
            if delivery["old_secret"] and delivery["old_until"] > now:
                old = signed_headers(delivery["id"], delivery["old_secret"], body, int(now), delivery["subscription"])
                headers["webhook-signature"] += " " + old["webhook-signature"]
            status = None
            try:
                status, _ = transport.post(delivery["callback"], body, headers)
                state = "accepted" if 200 <= status < 300 else "pending" if status in (408, 429) or status >= 500 else "rejected"
            except (WebhookError, OSError, TimeoutError):
                state = "pending"
            if state == "pending" and attempts == self.MAX_ATTEMPTS:
                state = "exhausted"
            self.db.execute("UPDATE deliveries SET state=?,last_status=? WHERE id=?", (state, status, delivery["id"]))
            return {"eventID": delivery["id"], "state": state, "attempts": attempts,
                    "agentReplyReceived": False}
