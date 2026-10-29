import time

import jwt
import pytest

from peel_accounts.apple import AppleRejected, ISSUER


def notification(env, kind="consent-revoked", **overrides):
    now = int(time.time())
    claims = {"iss": ISSUER, "aud": env.settings.client_id, "iat": now, "jti": "test-event-1",
              "events": {"type": kind, "sub": "test-apple-subject", "event_time": now}}
    claims.update(overrides)
    return jwt.encode(claims, env.key, algorithm="RS256", headers={"kid": "test-rsa"})


@pytest.mark.parametrize("kind", ["consent-revoked", "account-deleted"])
def test_verified_apple_notification_erases_account_and_all_sessions(env, kind):
    signin = env.signin(True)
    bearer = signin.json["session_token"]
    payload = notification(env, kind)
    response = env.call("POST", "/v1/apple/notifications", {"payload": payload})
    assert response.status_code == 204
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
    # Idempotent retry does not recreate credentials or call Apple token endpoints.
    assert env.call("POST", "/v1/apple/notifications", {"payload": payload}).status_code == 204
    assert env.apple.revoke_calls == 0


def test_email_disabled_erases_email_and_marketing_never_auto_reenabled(env):
    bearer = env.signin(True, True).json["session_token"]
    assert env.call("POST", "/v1/apple/notifications", {"payload": notification(env, "email-disabled")}).status_code == 204
    profile = env.call("GET", "/v1/account", bearer=bearer).json["account"]
    assert profile["email"] is None
    assert profile["email_collection_consent"] is False
    assert profile["marketing_consent"] is False
    assert env.call("POST", "/v1/apple/notifications", {"payload": notification(env, "email-enabled", jti="event2")}).status_code == 204
    assert env.call("GET", "/v1/account", bearer=bearer).json["account"] == profile


@pytest.mark.parametrize("override", [
    {"aud": "other.app"}, {"iss": "https://evil.example"}, {"jti": 123},
    {"iat": int(time.time()) - 8*86400}, {"iat": int(time.time()) + 300},
    {"events": {"type": "consent-revoked", "sub": "test-apple-subject"}},
    {"events": "not-an-event-object"},
    {"events": {"type": "consent-revoked", "sub": "test-apple-subject", "event_time": int(time.time()) + 300}},
])
def test_invalid_notification_never_erases_profile(env, override):
    bearer = env.signin(True).json["session_token"]
    response = env.call("POST", "/v1/apple/notifications", {"payload": notification(env, **override)})
    assert response.status_code == 401
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 200


def test_delayed_old_notification_does_not_erase_recreated_account(env):
    bearer = env.signin(True).json["session_token"]
    payload = notification(env, events={"type": "account-deleted", "sub": "test-apple-subject",
                                        "event_time": int(time.time()) - 10})
    assert env.call("POST", "/v1/apple/notifications", {"payload": payload}).status_code == 204
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 200


def test_daily_refresh_invalid_grant_erases_company_profile_and_credential(env):
    bearer = env.signin(True).json["session_token"]
    with env.store.db() as db:
        db.execute("UPDATE accounts SET verified_at=?", (int(time.time()) - 86401,))
    env.apple.refresh_error = AppleRejected()
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
