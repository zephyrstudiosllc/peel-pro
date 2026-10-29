from peel_accounts.apple import AppleUnavailable
from test_accounts import prepared, stale_account, token_from


def test_delete_during_known_exchange_reports_pending_not_complete(env):
    bearer = token_from(env.signin())
    body = prepared(env)
    env.apple.refresh_value = "synthetic-review-late-exchange-grant"
    deleted = []
    def deleting():
        env.apple.exchange_hook = None
        deleted.append(env.call("DELETE", "/v1/account", {}, bearer))
    env.apple.exchange_hook = deleting
    assert env.call("POST", "/v1/apple/sign-in", body).status_code == 401
    assert deleted[0].json["account_deleted"] is True
    assert deleted[0].json["apple_revocation_complete"] is False
    assert deleted[0].json["apple_revocation_pending"] is True
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM revocations").fetchone()[0] == 1


def test_delete_during_known_refresh_reports_pending_not_complete(env):
    bearer = token_from(env.signin())
    stale_account(env)
    proof = prepared(env)
    proof = {name: proof[name] for name in ("challenge_id", "identity_token")}
    env.apple.refreshed_value = "synthetic-review-late-refresh-grant"
    deleted = []
    def deleting():
        env.apple.refresh_hook = None
        deleted.append(env.call("DELETE", "/v1/account", proof))
    env.apple.refresh_hook = deleting
    assert env.call("GET", "/v1/account", bearer=bearer).status_code == 401
    assert deleted[0].json["account_deleted"] is True
    assert deleted[0].json["apple_revocation_complete"] is False
    assert deleted[0].json["apple_revocation_pending"] is True


def test_repeat_fresh_proof_delete_reports_existing_durable_queue(env):
    bearer = token_from(env.signin())
    env.apple.revoke_error = AppleUnavailable()
    initial = env.call("DELETE", "/v1/account", {}, bearer)
    assert initial.status_code == 202
    proof = prepared(env)
    proof = {name: proof[name] for name in ("challenge_id", "identity_token")}
    repeated = env.call("DELETE", "/v1/account", proof)
    assert repeated.json["account_deleted"] is True
    assert repeated.json["apple_revocation_complete"] is False
    assert repeated.json["apple_revocation_pending"] is True
    assert repeated.status_code == 202


def test_expired_unresolved_operation_remains_pending_and_emits_maintenance_alert(env):
    import time
    from peel_accounts.maintenance import run
    bearer = token_from(env.signin())
    now = int(time.time())
    with env.store.db() as db:
        subject = db.execute("SELECT subject_key FROM accounts").fetchone()[0]
        db.execute("INSERT INTO grant_reservations VALUES(?,?,?)",
                   ("synthetic-review-suspended-operation", subject, now-1))
    deleted = env.call("DELETE", "/v1/account", {}, bearer)
    assert deleted.status_code == 202
    assert deleted.json["apple_revocation_complete"] is False
    result = run(env.settings, env.apple, now)
    assert result["pending"] == 0
    assert result["uncertain_operations_5m"] == 1
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM grant_reservations").fetchone()[0] == 1
    proof = prepared(env)
    proof = {name: proof[name] for name in ("challenge_id", "identity_token")}
    repeated = env.call("DELETE", "/v1/account", proof)
    assert repeated.status_code == 202
    assert repeated.json["apple_revocation_pending"] is True
