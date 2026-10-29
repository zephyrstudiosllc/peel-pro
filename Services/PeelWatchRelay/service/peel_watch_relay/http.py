"""WSGI composition with mandatory independently verified account/device auth.

No default verifier, bearer-token shortcut, listener, port, or credential source
exists. Trusted deployment supplies authenticate(environ)->RequestAuthority.
It must verify issuer/audience/expiry/revocation, scoped plugin grants and the
actual current paired-peer proof. Request fields/headers never create authority.
"""
from __future__ import annotations

from dataclasses import dataclass
import json

from .broker import Account, DeviceGrant, RelayError, RelayStore, encode
from .rpc import MCPDispatcher, fields


@dataclass(frozen=True)
class RequestAuthority:
    account: Account
    device: DeviceGrant | None = None


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RelayError("duplicate_json_key")
            result[key] = value
        return result
    def constant(_):
        raise RelayError("invalid_json")
    def valid_unicode(value):
        if isinstance(value, str):
            value.encode("utf-8")
        elif isinstance(value, dict):
            for key, item in value.items():
                valid_unicode(key)
                valid_unicode(item)
        elif isinstance(value, list):
            for item in value:
                valid_unicode(item)
    try:
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)
        valid_unicode(value)
        return value
    except (ValueError, UnicodeError, RecursionError):
        raise RelayError("invalid_json") from None


class Application:
    def __init__(self, store: RelayStore, authenticate, webhook_transport):
        if not callable(authenticate):
            raise RelayError("authentication_adapter_required")
        self.store, self.authenticate = store, authenticate
        self.mcp = MCPDispatcher(store, webhook_transport)

    def __call__(self, environ, start_response):
        status = "200 OK"
        try:
            if environ.get("REQUEST_METHOD") != "POST":
                raise RelayError("post_required")
            auth = self.authenticate(environ)
            if not isinstance(auth, RequestAuthority) or not isinstance(auth.account, Account):
                status = "401 Unauthorized"
                raise RelayError("authentication_required")
            if environ.get("CONTENT_TYPE", "").split(";", 1)[0].strip() != "application/json":
                raise RelayError("json_required")
            length = environ.get("CONTENT_LENGTH", "")
            if not isinstance(length, str) or not length.isascii() or not length.isdigit() or not 1 <= int(length) <= 262144:
                raise RelayError("invalid_body_length")
            raw = environ["wsgi.input"].read(int(length))
            if not isinstance(raw, bytes) or len(raw) != int(length):
                raise RelayError("incomplete_body")
            body = strict_json(raw)
            path = environ.get("PATH_INFO")
            if path == "/mcp":
                result = self.mcp.handle(auth.account, body)
                if result is None:
                    start_response("202 Accepted", [("Content-Length", "0"), ("Cache-Control", "no-store")])
                    return [b""]
            else:
                if not isinstance(auth.device, DeviceGrant):
                    raise RelayError("paired_device_authority_required")
                fields(body, (), ("route_id", "generation", "request_id", "text", "after", "agent_reference"))
                if path == "/v1/watch/connect":
                    fields(body, ("agent_reference",))
                    result = self.store.connect(auth.account, auth.device, body["agent_reference"])
                else:
                    if "route_id" not in body:
                        raise RelayError("route_required")
                    self.store.assert_device(auth.account, auth.device, body["route_id"])
                    if path == "/v1/watch/status":
                        fields(body, ("route_id",))
                        result = self.store.status(auth.account, body["route_id"])
                    elif path == "/v1/watch/send":
                        fields(body, ("route_id", "generation", "request_id", "text"))
                        result = self.store.send(auth.account, **body)
                    elif path == "/v1/watch/replies":
                        fields(body, ("route_id", "generation"), ("after",))
                        result = self.store.replies(auth.account, **body)
                    elif path == "/v1/watch/disconnect":
                        fields(body, ("route_id",))
                        self.store.revoke(auth.account, body["route_id"])
                        result = {"disconnected": True}
                    else:
                        raise RelayError("unknown_path")
            payload = encode(result)
            if len(payload) > 262144:
                raise RelayError("response_too_large")
        except RelayError as error:
            if status == "200 OK":
                status = "400 Bad Request"
            payload = encode({"error": error.code})
        start_response(status, [("Content-Type", "application/json"), ("Content-Length", str(len(payload))), ("Cache-Control", "no-store")])
        return [payload]
