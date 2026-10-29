from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from peel_accounts import create_app
from peel_accounts.app import CONSENT_VERSION, process_revocation
from peel_accounts.apple import AppleRejected, AppleUnavailable, IdentityRejected, IdentityVerifier
from peel_accounts.maintenance import run


def prepared(env, **claims):
    challenge = env.call("POST", "/v1/challenges", {}).json
    token = env.token(challenge["apple_nonce"], **claims)
    env.apple.exchanged_token = token
    return {"challenge_id": challenge["challenge_id"], "identity_token": token,
            "authorization_code": "test-code"}


def token_from(response):
    assert response.status_code == 200, response.json
    return response.json["session_token"]


def test_default_no_company_email_no_marketing_and_no_plaintext_credentials(env):
    response = env.signin()
    bearer = token_from(response)
    profile = response.json["account"]
    assert profile["email"] is None
    assert profile["email_collection_consent"] is False
    assert profile["marketing_consent"] is False
    assert profile["marketing_delivery_configured"] is False
    assert "apple" not in profile["account_id"]
    assert env.call("GET", "/v1/account", bearer=bearer).json["account"] == profile
    raw = env.store.path.read_bytes()
    for secret in [bearer, "synthetic-refresh-credential", "test-apple-subject", "synthetic@example.test"]:
        assert secret.encode() not in raw
    assert env.store.path.stat().st_mode & 0o777 == 0o600


def test_email_optin_separate_from_marketing_and_relay_supported(env):
    response = env.signin(True, email="synthetic@privaterelay.appleid.com", is_private_email="true")
    bearer = token_from(response)
    profile = response.json["account"]
    assert profile["email"] == "synthetic@privaterelay.appleid.com"
    assert profile["marketing_consent"] is False
    assert b"synthetic@" not in env.store.path.read_bytes()
    response = env.call("PUT", "/v1/account/preferences", {"marketing_consent": True,
                       "consent_version": CONSENT_VERSION}, bearer)
    assert response.json["account"]["marketing_consent"] is True
    response = env.call("PUT", "/v1/account/preferences", {"email_collection_consent": False}, bearer)
    assert response.json["account"]["email"] is None
    assert response.json["account"]["marketing_consent"] is False
    assert env.call("PUT", "/v1/account/preferences", {"email_collection_consent": True,
                    "consent_version": CONSENT_VERSION}, bearer).status_code == 409


@pytest.mark.parametrize("data", [
    {"email_collection_consent": "true"}, {"marketing_consent": 1},
    {"marketing_consent": True},
    {"email_collection_consent": True},
    {"email_collection_consent": True, "consent_version": "old"},
    {"email": "forged@example.test"},
])
def test_untrusted_fields_and_consent_rejected(env, data):
    body = prepared(env)
    body.update(data)
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 400
    assert env.apple.exchange_calls == 0


@pytest.mark.parametrize("overrides", [
    {"iss": "https://evil.example"}, {"aud": "other.app"},
    {"aud": ["com.zephyrstudiosllc.Peel"]}, {"sub": 123},
    {"sub": ""}, {"exp": int(time.time()) - 300},
    {"iat": int(time.time()) + 300}, {"iat": int(time.time()) - 1000},
    {"iat": True}, {"exp": "9999999999"}, {"nonce": "wrong-nonce"},
    {"nonce": None}, {"c_hash": "wrong-code-hash"},
])
def test_identity_claim_failure_never_contacts_token_endpoint(env, overrides):
    body = prepared(env, **overrides)
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert env.apple.exchange_calls == 0


@pytest.mark.parametrize("algorithm", ["HS256", "none"])
def test_algorithm_confusion_rejected(env, algorithm):
    body = prepared(env)
    claims = jwt.decode(body["identity_token"], options={"verify_signature": False})
    body["identity_token"] = jwt.encode(claims, "attacker" * 8 if algorithm == "HS256" else None,
                                        algorithm=algorithm, headers={"kid": "test-rsa"})
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert env.apple.keys_calls == 0


@pytest.mark.parametrize("header", [{"jku": "https://evil.example/keys"}, {"jwk": {}},
                                    {"x5u": "https://evil.example"}, {"crit": ["anything"]}])
def test_no_attacker_selected_keys(env, header):
    body = prepared(env)
    claims = jwt.decode(body["identity_token"], options={"verify_signature": False})
    body["identity_token"] = jwt.encode(claims, env.key, algorithm="RS256",
                                        headers={"kid": "test-rsa", **header})
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert env.apple.keys_calls == 0


def test_wrong_signature_rejected(env):
    body = prepared(env)
    claims = jwt.decode(body["identity_token"], options={"verify_signature": False})
    wrong = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    body["identity_token"] = jwt.encode(claims, wrong, algorithm="RS256", headers={"kid": "test-rsa"})
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert env.apple.exchange_calls == 0


def test_expired_challenge_and_token_replay(env):
    body = prepared(env)
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 200
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert env.apple.exchange_calls == 1
    other = prepared(env)
    with env.store.db() as db:
        db.execute("UPDATE challenges SET expires=0")
    assert env.call("POST", "/v1/apple/sign-in", other).status_code == 401


def test_challenge_one_use_even_when_code_exchange_unavailable(env):
    body = prepared(env)
    env.apple.exchange_error = AppleUnavailable()
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 503
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert env.apple.exchange_calls == 1


def test_concurrent_replay_one_exchange_and_one_account(env):
    body = prepared(env)
    def attempt(_):
        with env.app.test_client() as client:
            return client.post("/v1/apple/sign-in", json=body,
                               base_url="https://accounts.example.test").status_code
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(attempt, range(4)))
    assert responses.count(200) == 1
    assert responses.count(401) == 3
    assert env.apple.exchange_calls == 1


@pytest.mark.parametrize("changed", [{"sub": "different-subject"}, {"nonce": "different-nonce"}])
def test_code_exchange_must_match_original_identity_and_nonce(env, changed):
    body = prepared(env)
    nonce = jwt.decode(body["identity_token"], options={"verify_signature": False})["nonce"]
    env.apple.exchanged_token = env.token(nonce, **changed) if "nonce" not in changed else env.token(changed["nonce"])
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0


@pytest.mark.parametrize("verified", [False, "false", 1, None])
def test_unverified_email_never_stored(env, verified):
    response = env.signin(True, email_verified=verified)
    assert response.status_code == 409
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0


def test_company_email_falls_back_only_to_signed_native_claim(env):
    body = prepared(env)
    body.update(email_collection_consent=True, consent_version=CONSENT_VERSION)
    claims = jwt.decode(body["identity_token"], options={"verify_signature": False})
    claims.pop("email")
    claims.pop("email_verified")
    env.apple.exchanged_token = jwt.encode(claims, env.key, algorithm="RS256", headers={"kid": "test-rsa"})
    response = env.call("POST", "/v1/apple/sign-in", body)
    assert response.status_code == 200
    assert response.json["account"]["email"] == "synthetic@example.test"


def test_two_device_sessions_and_local_signout(env):
    first = token_from(env.signin())
    second = token_from(env.signin())
    assert env.call("GET", "/v1/account", bearer=first).status_code == 200
    assert env.call("GET", "/v1/account", bearer=second).status_code == 200
    assert env.call("POST", "/v1/account/sign-out", {}, first).status_code == 204
    assert env.call("GET", "/v1/account", bearer=first).status_code == 401
    assert env.call("GET", "/v1/account", bearer=second).status_code == 200


def stale_account(env):
    with env.store.db() as db:
        db.execute("UPDATE accounts SET verified_at=?", (int(time.time()) - 86401,))
    env.apple.refreshed_token = env.token("no-new-native-nonce-needed-for-refresh")


def test_daily_refresh_verified_once_and_never_returns_apple_token(env):
    bearer = token_from(env.signin())
    stale_account(env)
    for _ in range(3):
        response = env.call("GET", "/v1/account", bearer=bearer)
        assert response.status_code == 200
        assert "token" not in response.json
    assert env.apple.refresh_calls == 1


def test_refresh_different_identity_or_revocation_invalidates_all_sessions(env):
    bearer = token_from(env.signin())
    other = token_from(env.signin())
    stale_account(env)
    env.apple.refreshed_token = env.token("refresh", sub="attacker")
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    assert env.call("GET", "/v1/account", bearer=other).status_code == 401


def test_refresh_outage_fails_closed_and_reserves_retry_window(env):
    bearer = token_from(env.signin())
    stale_account(env)
    env.apple.refresh_error = AppleUnavailable()
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 503
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 503
    assert env.apple.refresh_calls == 1


def test_delete_erases_profile_sessions_and_revocation_credential(env):
    first = token_from(env.signin(True))
    second = token_from(env.signin(True))
    response = env.call("DELETE", "/v1/account", {}, first)
    assert response.status_code == 200
    assert response.json == {"account_deleted": True, "apple_revocation_complete": True,
                             "apple_revocation_pending": False}
    assert env.apple.revoke_calls == 1
    for bearer in (first, second):
        assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        for table in ("accounts", "sessions", "revocations"):
            assert db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0] == 0
    assert b"synthetic@example.test" not in env.store.path.read_bytes()


def test_delete_reauth_requirement_is_specific_not_a_false_success(env):
    bearer = token_from(env.signin())
    with env.store.db() as db:
        db.execute("UPDATE sessions SET issued=?", (int(time.time()) - 301,))
    response = env.call("DELETE", "/v1/account", {}, bearer)
    assert response.status_code == 409
    assert response.json["error"] == "fresh_apple_sign_in_required"


def test_delete_outage_erases_now_then_durable_retry_and_alert_counts(env):
    bearer = token_from(env.signin(True))
    env.apple.revoke_error = AppleUnavailable()
    response = env.call("DELETE", "/v1/account", {}, bearer)
    assert response.status_code == 202
    assert response.json["account_deleted"] is True
    assert response.json["apple_revocation_pending"] is True
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        job = db.execute("SELECT * FROM revocations").fetchone()
    assert b"synthetic-refresh" not in job["refresh"]
    now = int(time.time())
    result = run(env.settings, env.apple, now + 8*86400)
    assert result["requires_action_7d"] == 1
    assert result["overdue_24h"] == 1
    env.apple.revoke_error = None
    result = run(env.settings, env.apple, now + 10*86400)
    assert result["completed"] == 1
    assert result["pending"] == 0


def test_deletion_fence_blocks_old_inflight_signin_resurrection(env):
    bearer = token_from(env.signin(True))
    body = prepared(env)
    def deleting():
        with env.app.test_client() as client:
            response = client.delete("/v1/account", json={}, base_url="https://accounts.example.test",
                                     headers={"Authorization": "Bearer " + bearer})
            assert response.status_code == 202
            assert response.json["apple_revocation_complete"] is False
    env.apple.exchange_hook = deleting
    response = env.call("POST", "/v1/apple/sign-in", body)
    assert response.status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0


def test_expired_session_never_returns_profile(env):
    bearer = token_from(env.signin(True))
    with env.store.db() as db:
        db.execute("UPDATE sessions SET expires=0")
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401


def test_fail_closed_disabled_or_missing_configuration(env, monkeypatch):
    monkeypatch.delenv("PEEL_ACCOUNT_CONFIG", raising=False)
    for app in (create_app(), create_app(replace(env.settings, enabled=False), env.apple)):
        response = app.test_client().post("/v1/challenges", json={})
        assert response.status_code == 503
        assert response.json["error"] == "account_service_unconfigured"


@pytest.mark.parametrize("change", [
    {"public_origin": "http://accounts.example.test"},
    {"public_origin": "https://accounts.example.test/path"},
    {"client_id": "another.app"}, {"apple_team_id": "EVILTEAM00"},
    {"apple_key_id": ""}, {"public_webroots": ()},
])
def test_incomplete_or_wrong_production_config_rejected(env, change):
    app = create_app(replace(env.settings, **change), env.apple)
    assert app.test_client().get("/healthz").status_code == 503


def test_private_storage_cannot_be_served_or_world_readable(env):
    app = create_app(replace(env.settings, public_webroots=(env.settings.private_dir.parent,)), env.apple)
    assert app.test_client().get("/healthz").status_code == 503
    env.settings.encryption_key_path.chmod(0o644)
    app = create_app(env.settings, env.apple)
    assert app.test_client().get("/healthz").status_code == 503


def test_https_host_origin_and_cookie_guards(env):
    assert env.client.post("/v1/challenges", json={}, base_url="http://accounts.example.test").status_code == 400
    assert env.client.post("/v1/challenges", json={}, base_url="https://evil.example").status_code == 400
    assert env.call("POST", "/v1/challenges", {}, headers={"Origin": "https://evil.example"}).status_code == 403
    env.client.set_cookie("browser", "no", domain="accounts.example.test")
    assert env.call("POST", "/v1/challenges", {}).status_code == 403


def test_bounded_json_duplicate_fields_query_and_rate_limit(env):
    for data in (b'{"x":1,"x":2}', b'{"value":NaN}', b'[]'):
        response = env.client.post("/v1/challenges", data=data, content_type="application/json",
                                   base_url="https://accounts.example.test")
        assert response.status_code == 400
    assert env.call("POST", "/v1/challenges?token=never-send-secrets-here", {}).status_code == 400
    huge = env.client.post("/v1/apple/sign-in", data=b"x"*25000, content_type="application/json",
                           base_url="https://accounts.example.test")
    assert huge.status_code == 413
    codes = [env.call("POST", "/v1/challenges", {}).status_code for _ in range(12)]
    assert 429 in codes


def test_errors_and_headers_do_not_disclose_identity_tokens(env, caplog):
    body = prepared(env)
    env.apple.exchange_error = AppleUnavailable("SENSITIVE-SHOULD-NOT-APPEAR")
    response = env.call("POST", "/v1/apple/sign-in", body)
    assert response.status_code == 503
    assert "SENSITIVE" not in response.text + caplog.text
    assert body["identity_token"] not in response.text + caplog.text
    assert response.headers["Cache-Control"] == "no-store"
    assert "Access-Control-Allow-Origin" not in response.headers


def test_jwks_rotation_cache_throttle_and_no_stale_fallback(env):
    now = [time.time()]
    calls = []
    current = [{"keys": [env.jwk]}]
    def fetch():
        calls.append(1)
        if isinstance(current[0], Exception):
            raise current[0]
        return current[0]
    verifier = IdentityVerifier(env.settings.client_id, fetch, lambda: now[0])
    verifier._key("test-rsa")
    verifier._key("test-rsa")
    with pytest.raises(IdentityRejected):
        verifier._key("unknown")
    assert len(calls) == 1
    now[0] += 61
    newer = dict(env.jwk, kid="rotated")
    current[0] = {"keys": [newer]}
    verifier._key("rotated")
    assert len(calls) == 2
    now[0] += 3601
    current[0] = AppleUnavailable()
    with pytest.raises(AppleUnavailable):
        verifier._key("rotated")


def test_stale_refresh_failure_cannot_erase_fresh_signin(env):
    bearer = token_from(env.signin(True))
    stale_account(env)
    new_bearer = []
    def fresh_signin():
        env.apple.refresh_hook = None
        new_bearer.append(token_from(env.signin(True)))
    env.apple.refresh_hook = fresh_signin
    env.apple.refresh_error = AppleRejected()
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    assert env.call("GET", "/v1/account", bearer=new_bearer[0]).status_code == 200


def test_stale_refresh_completion_cannot_resurrect_deleted_account(env):
    bearer = token_from(env.signin(True))
    stale_account(env)
    def deleting():
        env.apple.refresh_hook = None
        with env.store.db() as db:
            db.execute("DELETE FROM accounts")
    env.apple.refresh_hook = deleting
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
