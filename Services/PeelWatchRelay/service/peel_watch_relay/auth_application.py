"""Single-owner WSGI composition with explicit verified control-plane wiring."""
from __future__ import annotations

from html import escape
from io import BytesIO
import copy
import sqlite3
from urllib.parse import parse_qsl, urlencode, urlsplit

from .broker import RelayError, encode
from .control_plane import AGENT_SCOPES
from .http import Application, strict_json
from .rpc import fields


def unique_form(raw):
    if not isinstance(raw, str) or len(raw) > 32768:
        raise RelayError("invalid_form")
    try:
        pairs = parse_qsl(raw, keep_blank_values=True, strict_parsing=True, max_num_fields=16, encoding="utf-8", errors="strict")
    except (ValueError, UnicodeError):
        raise RelayError("invalid_form") from None
    result = {}
    for key, value in pairs:
        if key in result:
            raise RelayError("duplicate_form_field")
        result[key] = value
    return result


class AuthenticatedApplication:
    def __init__(self, control, relay, oauth, webhook_transport, *, native_approval_uri):
        parsed = urlsplit(native_approval_uri)
        if parsed.scheme != "https" or not parsed.hostname or parsed.query or parsed.fragment or parsed.username or parsed.password:
            raise RelayError("registered_native_approval_uri_required")
        self.control, self.relay, self.oauth = control, relay, oauth
        self.native_approval_uri = native_approval_uri
        self.control.relay = relay
        # This internal environ value can only be set after our body-bound adapter.
        self.application = Application(relay, lambda e: e.get("peel.verified_authority"), webhook_transport)

    def _response(self, start, value, status="200 OK", *, html=False, headers=()):
        payload = value.encode("utf-8") if html else encode(value)
        if len(payload) > 262144:
            raise RelayError("response_too_large")
        start(status, [("Content-Type", "text/html; charset=utf-8" if html else "application/json"),
            ("Content-Length", str(len(payload))), ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"), *headers])
        return [payload]

    def __call__(self, environ, start_response):
        path = environ.get("PATH_INFO", "")
        try:
            expected_host = urlsplit(self.control.issuer).netloc
            # Forwarded headers are not read here. A reviewed trusted TLS proxy must
            # configure wsgi.url_scheme and exact original Host before this layer.
            if environ.get("wsgi.url_scheme") != "https" or environ.get("HTTP_HOST") != expected_host:
                raise RelayError("https_origin_required")
            method = environ.get("REQUEST_METHOD")
            if method == "GET":
                if path == "/.well-known/oauth-protected-resource":
                    return self._response(start_response, self.oauth.resource_metadata())
                if path == "/.well-known/oauth-authorization-server":
                    return self._response(start_response, self.oauth.metadata())
                if path == "/oauth/authorize":
                    query = unique_form(environ.get("QUERY_STRING", ""))
                    pending = self.oauth.begin(query)
                    link = self.native_approval_uri + "?" + urlencode({"oauthTransactionID": pending["transactionID"]})
                    html = ('<!doctype html><html><meta charset="utf-8"><title>Connect Peel Pro</title>'
                        '<h1>Connect Peel Pro</h1><p>Approve this selected agent connection in Peel Pro on your paired iPhone.</p>'
                        '<p>Provider: ' + escape(pending["provider"]) + '</p><p>OAuth client: ' + escape(pending["clientID"]) + '</p>'
                        '<p><a href="' + escape(link, quote=True) + '">Open Peel Pro to review</a></p>'
                        '<p>This grants only the route you approve. It does not import history or control your computer.</p></html>')
                    return self._response(start_response, html, html=True)
                raise RelayError("unknown_path")
            if method != "POST" or environ.get("QUERY_STRING", ""):
                raise RelayError("post_required")
            length = environ.get("CONTENT_LENGTH", "")
            if not isinstance(length, str) or not length.isascii() or not length.isdigit() or not 1 <= int(length) <= 262144:
                raise RelayError("invalid_body_length")
            raw = environ["wsgi.input"].read(int(length))
            if not isinstance(raw, bytes) or len(raw) != int(length):
                raise RelayError("incomplete_body")
            content = environ.get("CONTENT_TYPE", "").split(";", 1)[0].strip()
            if path == "/oauth/token":
                if content != "application/x-www-form-urlencoded" or len(raw) > 32768:
                    raise RelayError("form_required")
                return self._response(start_response, self.oauth.token(unique_form(raw.decode("utf-8"))))
            if content != "application/json":
                raise RelayError("json_required")
            body = strict_json(raw)
            if path == "/v1/native/challenge":
                if len(raw) > 8192:
                    raise RelayError("auth_request_too_large")
                return self._response(start_response, self.control.challenge(body))
            if path == "/v1/native/session":
                if len(raw) > 32768:
                    raise RelayError("auth_request_too_large")
                return self._response(start_response, self.control.redeem(body))
            environ["peel.raw_body"] = raw
            authority = self.control.authenticate(environ)
            environ["peel.verified_authority"] = authority
            if path in ("/v1/native/pro/challenge", "/v1/native/pro/evidence", "/v1/native/pro/withdraw"):
                if authority.device is None:
                    raise RelayError("paired_device_authority_required")
                if len(raw) > (140000 if path.endswith("evidence") else 4096):
                    raise RelayError("invalid_pro_evidence")
                handler = {"/v1/native/pro/challenge": self.relay.commerce.challenge,
                           "/v1/native/pro/evidence": self.relay.commerce.evidence,
                           "/v1/native/pro/withdraw": self.relay.commerce.withdraw}[path]
                return self._response(start_response, handler(authority, body))
            if path == "/v1/native/route-grant":
                return self._response(start_response, self.control.route_grant(environ, authority, body))
            if path == "/v1/native/renew":
                fields(body)
                return self._response(start_response, self.control.renew(environ))
            if path in ("/v1/native/sign-out", "/v1/native/revoke-enrollment"):
                fields(body)
                return self._response(start_response, self.control.revoke(environ, authority, account_wide=path.endswith("sign-out")))
            if path == "/v1/native/plugin/approve":
                return self._response(start_response, self.oauth.approve(environ, authority, body))
            if path == "/v1/native/plugin/review":
                return self._response(start_response, self.oauth.review(authority, body))
            environ["wsgi.input"] = BytesIO(raw)
            if path == "/mcp" and isinstance(body, dict) and body.get("method") == "tools/list":
                result = self.application.mcp.handle(authority.account, body)
                result = copy.deepcopy(result)
                if isinstance(result, dict) and "result" in result:
                    for tool in result["result"].get("tools", []):
                        tool["securitySchemes"] = [{"type": "oauth2", "scopes": sorted(AGENT_SCOPES)}]
                return self._response(start_response, result)
            return self.application(environ, start_response)
        except RelayError as error:
            if error.code == "commerce_unavailable":
                return self._response(start_response, {"error":error.code}, "503 Service Unavailable")
            if path == "/oauth/token":
                code = "invalid_scope" if error.code == "invalid_plugin_scope" else "invalid_request" if error.code in {"invalid_parameters", "invalid_form", "duplicate_form_field", "form_required"} else "invalid_grant"
                return self._response(start_response, {"error": code}, "400 Bad Request")
            unauthorized = error.code in {"authentication_required", "principal_expired", "enrollment_changed", "enrollment_mismatch",
                "request_proof_expired", "request_proof_reused", "invalid_device_proof", "exact_request_body_required",
                "application_session_expired", "invalid_refresh_grant", "refresh_token_reused"}
            headers = [("WWW-Authenticate", 'Bearer resource_metadata="' + self.control.issuer + '/.well-known/oauth-protected-resource"')] if unauthorized else []
            return self._response(start_response, {"error": error.code}, "401 Unauthorized" if unauthorized else "400 Bad Request", headers=headers)
        except (OSError, sqlite3.Error, UnicodeError):
            return self._response(start_response, {"error": "service_unavailable"}, "503 Service Unavailable")
