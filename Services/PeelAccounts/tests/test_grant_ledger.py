import secrets
import time

from peel_accounts.app import MAX_ACCOUNT_GRANTS, MAX_ACCOUNT_SESSIONS
from peel_accounts.maintenance import run
from test_accounts import prepared, stale_account, token_from


def test_duplicate_grant_is_deduplicated_and_every_distinct_grant_revoked(env):
    first = token_from(env.signin())
    token_from(env.signin())
    env.apple.refresh_value = "synthetic-second-device-refresh"
    second = token_from(env.signin())
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == 2
    response = env.call("DELETE", "/v1/account", {}, second)
    assert response.status_code == 202
    assert response.json["apple_revocation_pending"] is True
    result = run(env.settings, env.apple, int(time.time()))
    assert result["pending"] == 0
    assert set(env.apple.revoked_values) == {"synthetic-refresh-credential", "synthetic-second-device-refresh"}
    for bearer in (first, second):
        assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == 0


def fill_grants(env):
    with env.store.db() as db:
        account = db.execute("SELECT id FROM accounts").fetchone()[0]
        for number in range(MAX_ACCOUNT_GRANTS - 1):
            value = "synthetic-old-grant-" + str(number)
            env.apple.issued_values.add(value)
            db.execute("INSERT INTO grants VALUES(?,?,?,?)",
                       (env.store.key("grant", value), account, env.store.encrypt(value), int(time.time())))


def test_grant_bound_fails_before_exchange_without_dropping_credentials_and_fresh_proof_can_delete(env):
    token_from(env.signin())
    fill_grants(env)
    body = prepared(env)
    before = env.apple.exchange_calls
    response = env.call("POST", "/v1/apple/sign-in", body)
    assert response.status_code == 409
    assert response.json["error"] == "account_grant_capacity_reached"
    assert env.apple.exchange_calls == before
    # Existing bearer may be expired; fresh signed Apple nonce proof can always request deletion
    # without creating another OAuth grant or company session.
    proof = {"challenge_id": body["challenge_id"], "identity_token": body["identity_token"]}
    response = env.call("DELETE", "/v1/account", proof)
    assert response.status_code == 202
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM revocations").fetchone()[0] == MAX_ACCOUNT_GRANTS - 1
    assert env.call("DELETE", "/v1/account", proof).status_code == 401


def test_daily_refresh_rotation_retains_both_grants(env):
    bearer = token_from(env.signin())
    stale_account(env)
    env.apple.refreshed_value = "synthetic-rotated-refresh"
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 200
    with env.store.db() as db:
        row = db.execute("SELECT * FROM accounts").fetchone()
        assert env.store.decrypt(row["refresh"]) == "synthetic-rotated-refresh"
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == 2
    assert env.call("DELETE", "/v1/account", {}, bearer).status_code == 202
    run(env.settings, env.apple, int(time.time()))
    assert set(env.apple.revoked_values) == {"synthetic-refresh-credential", "synthetic-rotated-refresh"}


def test_unexpected_rotation_at_bound_retained_for_revocation_not_dropped(env):
    bearer = token_from(env.signin())
    fill_grants(env)
    stale_account(env)
    env.apple.refreshed_value = "synthetic-over-capacity-rotation"
    response = env.call("GET", "/v1/account", bearer=bearer)
    assert response.status_code == 409
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == MAX_ACCOUNT_GRANTS
        job = db.execute("SELECT * FROM revocations").fetchone()
        assert env.store.decrypt(job["refresh"]) == "synthetic-over-capacity-rotation"


def test_fresh_delete_proof_without_stored_account_requires_manual_apple_revoke(env):
    proof = prepared(env)
    response = env.call("DELETE", "/v1/account", {"challenge_id": proof["challenge_id"],
                         "identity_token": proof["identity_token"]})
    assert response.status_code == 200
    assert response.json["account_deleted"] is True
    assert response.json["manual_apple_revocation_required"] is True
    assert response.json["apple_revocation_pending"] is False
    assert env.apple.exchange_calls == 0


def test_parallel_signin_capacity_is_reserved_before_network(env):
    import threading
    from concurrent.futures import ThreadPoolExecutor
    token_from(env.signin())
    fill_grants(env)
    # Leave one slot for two different, valid concurrent authentication attempts.
    with env.store.db() as db:
        oldest = db.execute("SELECT id FROM grants LIMIT 1").fetchone()[0]
        db.execute("DELETE FROM grants WHERE id=?", (oldest,))
    first = prepared(env)
    first_token = env.apple.exchanged_token
    second = prepared(env)
    env.apple.exchanged_token = first_token
    env.apple.refresh_value = "synthetic-concurrent-new-grant"
    entered, release = threading.Event(), threading.Event()
    def hold_exchange():
        entered.set()
        assert release.wait(5)
    env.apple.exchange_hook = hold_exchange
    def first_attempt():
        with env.app.test_client() as client:
            return client.post("/v1/apple/sign-in", json=first,
                               base_url="https://accounts.example.test").status_code
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(first_attempt)
        assert entered.wait(5)
        blocked = env.call("POST", "/v1/apple/sign-in", second)
        assert blocked.status_code == 409
        assert blocked.json["error"] == "account_grant_capacity_reached"
        release.set()
        assert future.result(timeout=5) == 200
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == MAX_ACCOUNT_GRANTS
        assert db.execute("SELECT COUNT(*) FROM grant_reservations").fetchone()[0] == 0


def test_company_session_bound_keeps_latest_and_does_not_drop_apple_grants(env):
    bearer = token_from(env.signin())
    with env.store.db() as db:
        account = db.execute("SELECT id FROM accounts").fetchone()[0]
        for number in range(MAX_ACCOUNT_SESSIONS + 3):
            db.execute("INSERT INTO sessions VALUES(?,?,?,?)",
                       (secrets.token_hex(32), account, 100 + number, int(time.time()) + 1000))
    newest = token_from(env.signin())
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == MAX_ACCOUNT_SESSIONS
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == 1
    assert env.call("GET", "/v1/account", bearer=newest).status_code == 200


def test_empty_ledger_never_false_claims_revocation_complete(env):
    bearer = token_from(env.signin())
    with env.store.db() as db:
        db.execute("DELETE FROM grants")
    env.apple.revoke_error = __import__('peel_accounts.apple', fromlist=['AppleUnavailable']).AppleUnavailable()
    response = env.call("DELETE", "/v1/account", {}, bearer)
    assert response.status_code == 202
    assert response.json["apple_revocation_complete"] is False


def test_rotation_after_deletion_is_retained_for_explicit_revocation(env):
    bearer = token_from(env.signin())
    stale_account(env)
    env.apple.refreshed_value = "synthetic-rotation-after-delete"
    def deleting():
        env.apple.refresh_hook = None
        with env.store.db() as db:
            db.execute("DELETE FROM accounts")
    env.apple.refresh_hook = deleting
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    with env.store.db() as db:
        jobs = db.execute("SELECT * FROM revocations").fetchall()
        assert any(env.store.decrypt(job["refresh"]) == "synthetic-rotation-after-delete" for job in jobs)
    run(env.settings, env.apple, int(time.time()))
    assert "synthetic-rotation-after-delete" in env.apple.revoked_values


def test_exchange_invalid_identity_does_not_forget_returned_grant(env):
    body = prepared(env)
    env.apple.exchanged_token = "invalid-token"
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    with env.store.db() as db:
        job = db.execute("SELECT * FROM revocations").fetchone()
        assert env.store.decrypt(job["refresh"]) == "synthetic-refresh-credential"
    run(env.settings, env.apple, int(time.time()))
    assert "synthetic-refresh-credential" in env.apple.revoked_values


def test_fresh_delete_before_first_signin_exchange_completion_fences_creation(env):
    body = prepared(env)
    def delete_without_profile():
        proof = prepared(env)
        # Keep exchange's actual identity response bound to the original sign-in nonce.
        env.apple.exchanged_token = body["identity_token"]
        response = env.call("DELETE", "/v1/account", {"challenge_id": proof["challenge_id"],
                           "identity_token": proof["identity_token"]})
        assert response.status_code == 202
        assert response.json["apple_revocation_pending"] is True
    env.apple.exchange_hook = delete_without_profile
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM revocations").fetchone()[0] == 1


def test_adoption_cannot_remove_another_revocation_request(env):
    from peel_accounts.app import APIError, adopt_refresh, staged_refresh
    import pytest
    bearer = token_from(env.signin())
    with env.store.db() as db:
        account_id = db.execute("SELECT id FROM accounts").fetchone()[0]
    now = int(time.time())
    with staged_refresh(env.store, "synthetic-in-flight-rotation", now, env.store.key("subject", "test-apple-subject")) as credential:
        # A maintenance worker has claimed this grant; a late response must never adopt it.
        with env.store.db() as db:
            db.execute("UPDATE revocations SET attempts=1,next_attempt=? WHERE id=?", (now + 600, credential["id"]))
        with pytest.raises(APIError) as error:
            with env.store.db() as db:
                adopt_refresh(db, credential, account_id, now)
        assert error.value.code == "apple_revocation_pending"
    with env.store.db() as db:
        assert db.execute("SELECT 1 FROM revocations WHERE id=?", (credential["id"],)).fetchone()
        assert not db.execute("SELECT 1 FROM grants WHERE id=?", (credential["id"],)).fetchone()


def test_delete_during_exchange_stays_pending_until_late_grant_revoked(env):
    bearer = token_from(env.signin())
    body = prepared(env)
    env.apple.refresh_value = "synthetic-late-exchange-grant"
    deletions = []
    def deleting():
        deletions.append(env.call("DELETE", "/v1/account", {}, bearer))
    env.apple.exchange_hook = deleting
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert deletions[0].status_code == 202
    assert deletions[0].json["apple_revocation_pending"] is True
    assert deletions[0].json["apple_revocation_complete"] is False
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grant_reservations").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM revocations").fetchone()[0] == 1
    env.apple.exchange_hook = None
    run(env.settings, env.apple, int(time.time()))
    assert "synthetic-late-exchange-grant" in env.apple.revoked_values


def test_delete_during_daily_refresh_stays_pending_until_rotation_revoked(env):
    bearer = token_from(env.signin())
    stale_account(env)
    env.apple.refreshed_value = "synthetic-late-refresh-grant"
    deletions = []
    def deleting():
        # Use fresh Apple proof for deletion; bearer daily-refresh would recursively authenticate.
        proof = prepared(env)
        deletions.append(env.call("DELETE", "/v1/account", {"challenge_id": proof["challenge_id"],
                                      "identity_token": proof["identity_token"]}))
    env.apple.refresh_hook = deleting
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    assert deletions[0].status_code == 202
    assert deletions[0].json["apple_revocation_pending"] is True
    assert deletions[0].json["apple_revocation_complete"] is False
    run(env.settings, env.apple, int(time.time()))
    assert "synthetic-late-refresh-grant" in env.apple.revoked_values


def test_no_profile_retry_reports_its_existing_subject_revocation_queue(env):
    from peel_accounts.apple import AppleUnavailable
    bearer = token_from(env.signin())
    env.apple.revoke_error = AppleUnavailable()
    assert env.call("DELETE", "/v1/account", {}, bearer).status_code == 202
    proof = prepared(env)
    response = env.call("DELETE", "/v1/account", {"challenge_id": proof["challenge_id"],
                        "identity_token": proof["identity_token"]})
    assert response.status_code == 202
    assert response.json["apple_revocation_pending"] is True
    assert response.json["manual_apple_revocation_required"] is False


def test_expired_unresolved_operation_never_becomes_false_revocation_complete(env):
    bearer = token_from(env.signin())
    with env.store.db() as db:
        subject = db.execute("SELECT subject_key FROM accounts").fetchone()[0]
        db.execute("INSERT INTO grant_reservations VALUES(?,?,?)", ("simulated-lost-worker", subject, 1))
    response = env.call("DELETE", "/v1/account", {}, bearer)
    assert response.status_code == 202
    result = run(env.settings, env.apple, int(time.time()) + 10*86400)
    assert result["uncertain_operations_5m"] == 1
    proof = prepared(env)
    response = env.call("DELETE", "/v1/account", {"challenge_id": proof["challenge_id"],
                         "identity_token": proof["identity_token"]})
    assert response.status_code == 202
    assert response.json["apple_revocation_complete"] is False


def test_refresh_can_use_exact_128th_slot_excluding_its_own_operation(env):
    bearer = token_from(env.signin())
    fill_grants(env)
    with env.store.db() as db:
        active = env.store.key("grant", "synthetic-refresh-credential")
        retired = db.execute("SELECT id FROM grants WHERE id<>? LIMIT 1", (active,)).fetchone()[0]
        db.execute("DELETE FROM grants WHERE id=?", (retired,))
    stale_account(env)
    env.apple.refreshed_value = "synthetic-exact-last-slot"
    response = env.call("GET", "/v1/account", bearer=bearer)
    assert response.status_code == 200
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grants").fetchone()[0] == MAX_ACCOUNT_GRANTS
        assert db.execute("SELECT COUNT(*) FROM grant_reservations").fetchone()[0] == 0
