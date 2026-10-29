import json
from unittest.mock import Mock

import jwt
import pytest
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from peel_accounts.apple import (AppleRejected, AppleTransport, AppleUnavailable, ISSUER,
                                  JWKS_URL, MAX_RESPONSE, REVOKE_URL, TOKEN_URL)


class Response:
    def __init__(self, status=200, body=b"{}"):
        self.status_code = status
        self.body = body
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def iter_content(self, size):
        for offset in range(0, len(self.body), size):
            yield self.body[offset:offset + size]


def test_client_secret_uses_real_es256_library_and_expected_claims(env):
    transport = AppleTransport(env.settings)
    encoded = transport.client_secret()
    key = load_pem_private_key(env.settings.apple_key_path.read_bytes(), None).public_key()
    claims = jwt.decode(encoded, key, algorithms=["ES256"], audience=ISSUER,
                        issuer=env.settings.apple_team_id)
    assert claims["sub"] == env.settings.client_id
    assert 0 < claims["exp"] - claims["iat"] <= 300
    assert jwt.get_unverified_header(encoded)["kid"] == "TESTKEY001"
    assert transport.http.trust_env is False


def test_no_query_credentials_redirects_or_unbounded_network(env):
    transport = AppleTransport(env.settings)
    transport.http.request = Mock(return_value=Response())
    transport.exchange("synthetic-code")
    args, kwargs = transport.http.request.call_args
    assert args == ("POST", TOKEN_URL)
    assert kwargs["data"]["code"] == "synthetic-code"
    assert kwargs["data"]["grant_type"] == "authorization_code"
    assert "redirect_uri" not in kwargs["data"]  # Native flow provided none.
    assert kwargs["allow_redirects"] is False
    assert kwargs["timeout"] == (3.0, 8.0)
    assert kwargs["stream"] is True
    transport.refresh("synthetic-refresh")
    assert transport.http.request.call_args.kwargs["data"]["grant_type"] == "refresh_token"
    transport.http.request = Mock(return_value=Response(body=b""))
    transport.revoke("synthetic-refresh")
    assert transport.http.request.call_args.args == ("POST", REVOKE_URL)
    assert transport.http.request.call_args.kwargs["data"]["token_type_hint"] == "refresh_token"
    transport.http.request = Mock(return_value=Response(body=b'{"keys":[]}'))
    assert transport.jwks() == {"keys": []}
    assert transport.http.request.call_args.args == ("GET", JWKS_URL)


@pytest.mark.parametrize("response,exception", [
    (Response(302), AppleUnavailable), (Response(500), AppleUnavailable),
    (Response(429), AppleUnavailable), (Response(400, b'{"error":"invalid_grant","secret":"never-log"}'), AppleRejected),
    (Response(400, b'{"error":"invalid_client"}'), AppleUnavailable),
    (Response(body=b"invalid"), AppleUnavailable),
    (Response(body=b"[]"), AppleUnavailable),
    (Response(body=b"x" * (MAX_RESPONSE + 1)), AppleUnavailable),
])
def test_redirect_error_malformed_and_oversize_responses_fail_closed(env, response, exception):
    transport = AppleTransport(env.settings)
    transport.http.request = Mock(return_value=response)
    with pytest.raises(exception) as raised:
        transport.exchange("synthetic-code")
    assert "secret" not in str(raised.value)
    assert "never-log" not in str(raised.value)
