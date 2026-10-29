import time

from test_accounts import prepared, stale_account, token_from


def retained_grants(env):
    with env.store.db() as db:
        return {env.store.decrypt(row[0]) for row in db.execute(
            "SELECT refresh FROM grants UNION ALL SELECT refresh FROM revocations")}


def test_rotation_issued_after_concurrent_delete_is_not_forgotten(env):
    bearer = token_from(env.signin(True))
    stale_account(env)
    env.apple.refreshed_value = "synthetic-review-rotation-after-deletion"
    proof = prepared(env)
    proof = {name: proof[name] for name in ("challenge_id", "identity_token")}
    def deleting():
        env.apple.refresh_hook = None
        response = env.call("DELETE", "/v1/account", proof)
        assert response.status_code in (200, 202)
    env.apple.refresh_hook = deleting
    response = env.call("GET", "/v1/account", bearer=bearer)
    assert response.status_code == 401
    assert env.apple.issued_values - set(env.apple.revoked_values) <= retained_grants(env)


def test_rotation_issued_after_concurrent_signin_is_not_forgotten(env):
    bearer = token_from(env.signin(True))
    stale_account(env)
    env.apple.refreshed_value = "synthetic-review-rotation-after-new-signin"
    new_bearer = []
    def signing_in():
        env.apple.refresh_hook = None
        env.apple.refresh_value = "synthetic-review-new-signin-grant"
        new_bearer.append(token_from(env.signin(True)))
    env.apple.refresh_hook = signing_in
    response = env.call("GET", "/v1/account", bearer=bearer)
    assert response.status_code == 401
    assert env.call("GET", "/v1/account", bearer=new_bearer[0]).status_code == 200
    assert env.apple.issued_values - set(env.apple.revoked_values) <= retained_grants(env)


def test_exchange_issued_grant_on_rejected_subject_is_not_forgotten(env):
    body = prepared(env)
    import jwt
    nonce = jwt.decode(body["identity_token"], options={"verify_signature": False})["nonce"]
    env.apple.exchanged_token = env.token(nonce, sub="synthetic-other-subject")
    response = env.call("POST", "/v1/apple/sign-in", body)
    assert response.status_code == 401
    assert env.apple.issued_values - set(env.apple.revoked_values) <= retained_grants(env)


def test_fresh_proof_delete_before_first_exchange_completion_blocks_resurrection(env):
    sign_in_body = prepared(env)
    proof = prepared(env)
    proof = {name: proof[name] for name in ("challenge_id", "identity_token")}
    # Restore the first exchange response; preparing the separate proof changes fake defaults.
    env.apple.exchanged_token = sign_in_body["identity_token"]
    def deleting():
        env.apple.exchange_hook = None
        response = env.call("DELETE", "/v1/account", proof)
        assert response.status_code in (200, 202)
        assert response.json["account_deleted"] is True
    env.apple.exchange_hook = deleting
    response = env.call("POST", "/v1/apple/sign-in", sign_in_body)
    assert response.status_code == 401
    with env.store.db() as db:
        assert db.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0
    assert env.apple.issued_values - set(env.apple.revoked_values) <= retained_grants(env)


def test_suspended_rotation_cannot_adopt_grant_already_revoked_by_maintenance(env):
    from peel_accounts import create_app
    from peel_accounts.maintenance import run
    now = [int(time.time())]
    app = create_app(env.settings, env.apple, clock=lambda: now[0])
    client = app.test_client()
    def call(method, path, data=None, bearer=None):
        headers = {"Authorization": "Bearer " + bearer} if bearer else {}
        return client.open(path, method=method, json=data,
                           base_url="https://accounts.example.test", headers=headers)
    challenge = call("POST", "/v1/challenges", {}).json
    identity = env.token(challenge["apple_nonce"], exp=now[0]+3600)
    env.apple.exchanged_token = identity
    signed_in = call("POST", "/v1/apple/sign-in", {
        "challenge_id": challenge["challenge_id"], "identity_token": identity,
        "authorization_code": "test-code"})
    bearer = token_from(signed_in)
    with env.store.db() as db:
        db.execute("UPDATE accounts SET verified_at=?", (now[0]-86401,))
    env.apple.refreshed_value = "synthetic-review-suspended-rotation"
    env.apple.refreshed_token = env.token("refresh", exp=now[0]+3600)
    verifier = app.extensions["peel_verifier"]
    real_verify = verifier.verify
    def delayed_verify(token, *args, **kwargs):
        # The web worker is suspended after durable staging. Cron continues independently.
        now[0] += 301
        assert run(env.settings, env.apple, now[0])["completed"] == 1
        return real_verify(token, *args, **kwargs)
    verifier.verify = delayed_verify
    response = call("GET", "/v1/account", bearer=bearer)
    assert env.apple.refreshed_value in env.apple.revoked_values
    assert response.status_code != 200
    assert env.apple.refreshed_value not in retained_grants(env)
