"""Finite Peel-owned sessions; no provider refresh credentials are stored.

All callers hold ControlPlane.lock. Token families rotate transactionally and
never outlive the fresh verified enrollment's absolute application deadline.
"""
from __future__ import annotations

import hashlib
import json
from uuid import uuid4

from .broker import RelayError, encode

MAX_APPLICATION_SECONDS = 7 * 24 * 60 * 60
PHONE_ACCESS_SECONDS = 15 * 60
PLUGIN_ACCESS_SECONDS = 60 * 60


def initialize(db):
    db.executescript("""
    CREATE TABLE IF NOT EXISTS auth_application_sessions(
      enrollment TEXT PRIMARY KEY REFERENCES auth_enrollments(id),
      verified_at INTEGER NOT NULL, expires INTEGER NOT NULL,
      revoked INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS auth_token_families(
      id TEXT PRIMARY KEY, enrollment TEXT NOT NULL REFERENCES auth_enrollments(id),
      kind TEXT NOT NULL, client_id TEXT NOT NULL, resource TEXT NOT NULL,
      route TEXT, scopes BLOB NOT NULL, expires INTEGER NOT NULL,
      revoked INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS auth_family_members(
      digest TEXT PRIMARY KEY REFERENCES auth_sessions(digest) ON DELETE CASCADE,
      family TEXT NOT NULL REFERENCES auth_token_families(id),
      refresh INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
    """)


def revoke_family(control, family):
    control.db.execute("UPDATE auth_token_families SET revoked=1 WHERE id=?", (family,))
    control.db.execute("UPDATE auth_sessions SET revoked=1 WHERE digest IN (SELECT digest FROM auth_family_members WHERE family=?)", (family,))


def _issue_pair(control, family):
    now = control._time()
    access_kind = family["kind"]
    refresh_kind = "phoneRefresh" if access_kind == "phone" else "pluginRefresh"
    scopes = frozenset(json.loads(family["scopes"]))
    routes = [family["route"]] if family["route"] else []
    duration = PHONE_ACCESS_SECONDS if access_kind == "phone" else PLUGIN_ACCESS_SECONDS
    access, access_expiry = control._issue(family["enrollment"], min(now + duration, family["expires"]), access_kind, scopes, routes)
    refresh, refresh_expiry = control._issue(family["enrollment"], family["expires"], refresh_kind, frozenset(("session.renew",)), routes)
    for token, is_refresh in ((access, 0), (refresh, 1)):
        digest = hashlib.sha256(token.encode("ascii")).hexdigest()
        control.db.execute("INSERT INTO auth_family_members VALUES(?,?,?,0)", (digest, family["id"], is_refresh))
    return {"sessionToken": access, "sessionExpiresAt": access_expiry,
            "refreshToken": refresh, "refreshExpiresAt": refresh_expiry,
            "applicationSessionExpiresAt": family["expires"]}


def create_family(control, enrollment, *, kind, client_id, resource, route, scopes):
    app = control.db.execute("SELECT * FROM auth_application_sessions WHERE enrollment=?", (enrollment,)).fetchone()
    if app is None or app["revoked"] or app["expires"] <= control._time():
        raise RelayError("application_session_expired")
    if kind not in ("phone", "plugin"):
        raise RelayError("invalid_session_family")
    family_id = str(uuid4())
    control.db.execute("INSERT INTO auth_token_families VALUES(?,?,?,?,?,?,?,?,0)",
        (family_id, enrollment, kind, client_id, resource, route, encode(sorted(scopes)), app["expires"]))
    family = control.db.execute("SELECT * FROM auth_token_families WHERE id=?", (family_id,)).fetchone()
    return _issue_pair(control, family)


def rotate(control, digest, *, kind, client_id, resource):
    row = control.db.execute("""SELECT f.*,m.used,m.refresh,s.revoked AS token_revoked
      FROM auth_family_members m JOIN auth_token_families f ON f.id=m.family
      JOIN auth_sessions s ON s.digest=m.digest WHERE m.digest=?""", (digest,)).fetchone()
    if (row is None or not row["refresh"] or row["kind"] != kind or row["client_id"] != client_id
            or row["resource"] != resource or row["revoked"] or row["expires"] <= control._time()):
        raise RelayError("invalid_refresh_grant")
    if row["used"] or row["token_revoked"]:
        revoke_family(control, row["id"])
        raise RelayError("refresh_token_reused")
    # The caller validates the current account/enrollment/generation and (for
    # plugin tokens) exact active route before beginning this transaction.
    control.db.execute("BEGIN IMMEDIATE")
    try:
        control.db.execute("UPDATE auth_family_members SET used=1 WHERE digest=?", (digest,))
        control.db.execute("UPDATE auth_sessions SET revoked=1 WHERE digest IN (SELECT digest FROM auth_family_members WHERE family=?)", (row["id"],))
        result = _issue_pair(control, row)
        control.db.execute("COMMIT")
        return result
    except BaseException:
        control.db.execute("ROLLBACK")
        raise
