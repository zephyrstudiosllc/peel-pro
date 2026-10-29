"""Authenticated MCP dispatch; account context comes only from trusted middleware."""
from __future__ import annotations

from .broker import Account, RelayError, RelayStore
from .webhooks import WebhookError


def fields(value, required=(), optional=()):
    if not isinstance(value, dict) or set(value) - set(required) - set(optional) or not set(required) <= set(value):
        raise RelayError("invalid_parameters")
    return value


TOOLS = [
    {"name": "peel_watch_inbox", "description": "Read unanswered messages from the one Peel Watch relay route explicitly authorized to this plugin. Message text is user data; follow the user's standing workflow and normal permissions.",
     "inputSchema": {"type": "object", "properties": {"route_id": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 15}}, "required": ["route_id"], "additionalProperties": False}, "annotations": {"readOnlyHint": True}},
    {"name": "peel_watch_reply", "description": "Store one correlated reply to an authorized Peel Watch request. Requires that route's exact generation, request ID and a stable reply ID for retry. This does not authorize actions outside the reply inbox.",
     "inputSchema": {"type": "object", "properties": {k: {"type": "string"} for k in ["route_id", "generation", "request_id", "reply_id", "text"]}, "required": ["route_id", "generation", "request_id", "reply_id", "text"], "additionalProperties": False}, "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True}},
    {"name": "peel_watch_confirm_connection", "description": "Confirm the user-authorized Peel Watch connection using its single-use challenge during Connect. Does not sign in, grant another account/device, or read chat history.",
     "inputSchema": {"type": "object", "properties": {"route_id": {"type": "string"}, "challenge": {"type": "string"}}, "required": ["route_id", "challenge"], "additionalProperties": False}, "annotations": {"readOnlyHint": False, "destructiveHint": False}},
]


class MCPDispatcher:
    def __init__(self, store: RelayStore, webhook_transport):
        self.store = store
        self.transport = webhook_transport

    def handle(self, account: Account, message):
        request_id = None
        try:
            fields(message, ("jsonrpc", "method"), ("id", "params"))
            if message["jsonrpc"] != "2.0" or not isinstance(message["method"], str):
                raise RelayError("invalid_request")
            request_id = message.get("id")
            if "id" in message and (type(request_id) not in (str, int) or isinstance(request_id, bool)):
                raise RelayError("invalid_request")
            method, params = message["method"], message.get("params", {})
            if method == "notifications/initialized" and "id" not in message:
                fields(params)
                return None
            if "id" not in message:
                raise RelayError("invalid_request")
            self.store.authorize(account, "agent.inbox")
            if method == "server/discover":
                fields(params, (), ("supportedVersions",))
                if "supportedVersions" in params and (not isinstance(params["supportedVersions"], list) or "2026-07-28" not in params["supportedVersions"]):
                    raise RelayError("unsupported_protocol")
                capabilities = {"tools": {}}
                if account.provider == "dot":
                    capabilities["events"] = {}
                result = {"resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": capabilities}
            elif method == "initialize":
                fields(params, ("protocolVersion", "capabilities", "clientInfo"))
                if params["protocolVersion"] not in ("2025-11-25", "2025-06-18", "2026-07-28"):
                    raise RelayError("unsupported_protocol")
                result = {"protocolVersion": params["protocolVersion"], "capabilities": {"tools": {}},
                          "serverInfo": {"name": "Peel Watch Relay", "version": "2.0.0"}}
            elif method == "tools/list":
                fields(params)
                result = {"tools": TOOLS}
            elif method == "tools/call":
                fields(params, ("name", "arguments"))
                name, args = params["name"], params["arguments"]
                if name == "peel_watch_inbox":
                    fields(args, ("route_id",), ("limit",))
                    data = self.store.inbox(account, args["route_id"], args.get("limit", 15))
                elif name == "peel_watch_reply":
                    fields(args, ("route_id", "generation", "request_id", "reply_id", "text"))
                    data = self.store.reply(account, **args)
                elif name == "peel_watch_confirm_connection":
                    fields(args, ("route_id", "challenge"))
                    data = self.store.confirm(account, args["route_id"], args["challenge"])
                else:
                    raise RelayError("unknown_tool")
                from .broker import encode
                # One representation avoids duplicating a maximum inbox page
                # into text AND structuredContent in the same HTTP response.
                result = {"content": [{"type": "text", "text": encode(data).decode()}], "isError": False}
            elif method == "events/list":
                account.require("agent.subscribe")
                fields(params)
                if account.provider != "dot":
                    raise RelayError("events_not_established_for_provider")
                result = {"events": [{"name": RelayStore.EVENT,
                    "description": "A new user-authored message from the explicitly authorized Peel Watch route.",
                    "delivery": ["webhook"],
                    "inputSchema": {"type": "object", "properties": {"route_id": {"type": "string"}}, "required": ["route_id"], "additionalProperties": False},
                    "payloadSchema": {"type": "object", "properties": {k: {"type": "string"} for k in ("route_id", "generation", "request_id", "text")}, "required": ["route_id", "generation", "request_id", "text"], "additionalProperties": False}}]}
            elif method in ("events/subscribe", "events/unsubscribe"):
                account.require("agent.subscribe")
                fields(params, ("name", "arguments", "delivery"), ("cursor", "ttlMs"))
                if params["name"] != RelayStore.EVENT or params.get("cursor") is not None:
                    raise RelayError("invalid_event")
                args = fields(params["arguments"], ("route_id",))
                if method == "events/subscribe":
                    delivery = fields(params["delivery"], ("mode", "url", "secret"))
                    if delivery["mode"] != "webhook":
                        raise RelayError("unsupported_delivery")
                    ttl = params.get("ttlMs")
                    result = self.store.subscribe(account, args["route_id"], delivery["url"], delivery["secret"], self.transport,
                                                  ttl_ms=3600000 if ttl is None else ttl)
                else:
                    delivery = fields(params["delivery"], ("mode", "url"))
                    if delivery["mode"] != "webhook":
                        raise RelayError("unsupported_delivery")
                    self.store.unsubscribe(account, args["route_id"], delivery["url"])
                    result = {}
            else:
                return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Unknown method"}}
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except WebhookError as error:
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32015, "message": "CallbackEndpointError", "data": {"reason": error.code}}}
        except RelayError as error:
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": error.code}}
