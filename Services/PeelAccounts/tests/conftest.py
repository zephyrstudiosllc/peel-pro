import base64
import hashlib
import json
import os
import socket
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

from peel_accounts import create_app
from peel_accounts.apple import AppleUnavailable, ISSUER
from peel_accounts.config import CLIENT_ID, Settings


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def denied(*args, **kwargs):
        raise AssertionError("tests must never call real Apple/network")
    monkeypatch.setattr(socket, "create_connection", denied)
    monkeypatch.setattr(socket.socket, "connect", denied)


@pytest.fixture
def env(tmp_path):
    private = tmp_path / "private"
    private.mkdir(mode=0o700)
    apple_key = ec.generate_private_key(ec.SECP256R1())
    paths = [private / "sign-in.p8", private / "encryption.key", private / "lookup.key"]
    values = [apple_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()), Fernet.generate_key(), os.urandom(32)]
    for path, value in zip(paths, values):
        path.write_bytes(value)
        path.chmod(0o600)
    settings = Settings(True, "https://accounts.example.test", (tmp_path / "public",), private,
                        paths[0], paths[1], paths[2], "TESTKEY001")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update(kid="test-rsa", alg="RS256", use="sig")

    def token(base_nonce, code="test-code", **overrides):
        now = int(time.time())
        claims = {"iss": ISSUER, "aud": CLIENT_ID, "iat": now, "exp": now + 300,
                  "sub": "test-apple-subject", "nonce": base_nonce, "email": "synthetic@example.test",
                  "email_verified": "true", "is_private_email": "false",
                  "c_hash": base64.urlsafe_b64encode(hashlib.sha256(code.encode()).digest()[:16]).rstrip(b"=").decode()}
        claims.update(overrides)
        return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test-rsa"})

    class FakeApple:
        keys_calls = 0
        exchange_calls = 0
        refresh_calls = 0
        revoke_calls = 0
        exchanged_token = None
        refreshed_token = None
        exchange_error = None
        refresh_error = None
        refresh_hook = None
        revoke_error = None
        exchange_hook = None
        refresh_value = "synthetic-refresh-credential"
        refreshed_value = None
        issued_values = set()
        revoked_values = []

        def jwks(self):
            self.keys_calls += 1
            return {"keys": [jwk]}

        def exchange(self, code):
            self.exchange_calls += 1
            if self.exchange_hook:
                self.exchange_hook()
            if self.exchange_error:
                raise self.exchange_error
            self.issued_values.add(self.refresh_value)
            return {"id_token": self.exchanged_token, "refresh_token": self.refresh_value}

        def refresh(self, token):
            self.refresh_calls += 1
            if self.refresh_hook:
                self.refresh_hook()
            assert token in self.issued_values
            if self.refresh_error:
                raise self.refresh_error
            result = {"id_token": self.refreshed_token}
            if self.refreshed_value:
                self.issued_values.add(self.refreshed_value)
                result["refresh_token"] = self.refreshed_value
            return result

        def revoke(self, token):
            self.revoke_calls += 1
            assert token in self.issued_values
            self.revoked_values.append(token)
            if self.revoke_error:
                raise self.revoke_error

    apple = FakeApple()
    apple.issued_values, apple.revoked_values = set(), []
    app = create_app(settings, apple)
    client = app.test_client()

    def call(method, path, data=None, bearer=None, **kwargs):
        headers = kwargs.pop("headers", {})
        if bearer:
            headers["Authorization"] = "Bearer " + bearer
        return client.open(path, method=method, json=data,
                           base_url="https://accounts.example.test", headers=headers, **kwargs)

    def signin(collect=False, marketing=False, **claims):
        challenge = call("POST", "/v1/challenges", {}).json
        identity = token(challenge["apple_nonce"], **claims)
        apple.exchanged_token = identity
        body = {"challenge_id": challenge["challenge_id"], "identity_token": identity,
                "authorization_code": "test-code", "email_collection_consent": collect,
                "marketing_consent": marketing, "consent_version": "2026-10-18.v1"}
        return call("POST", "/v1/apple/sign-in", body)

    return SimpleNamespace(settings=settings, app=app, client=client, apple=apple, token=token,
                           key=key, jwk=jwk, call=call, signin=signin,
                           store=app.extensions["peel_store"])
