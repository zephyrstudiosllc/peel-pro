import dataclasses
import io
import json
import unittest
from uuid import uuid4

from peel_watch_relay import RelayError
from peel_watch_relay.http import Application, RequestAuthority
from peel_watch_relay.rpc import MCPDispatcher
from test_broker import Callback, Fixture, SECRET


class RPCHTTPTests(Fixture, unittest.TestCase):
    def setUp(self):
        self.setup_fixture()
        self.rpc = MCPDispatcher(self.store, self.callback)

    def tearDown(self):
        self.close_fixture()

    def rpc_call(self, method, params, account=None):
        return self.rpc.handle(account or self.agent, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})

    def test_mcp_discovery_subscribe_confirm_and_new_message_reply(self):
        discover = self.rpc_call("server/discover", {})["result"]
        self.assertEqual(["2026-07-28"], discover["supportedVersions"])
        self.assertIn("events", discover["capabilities"])
        self.assertEqual("watch.message.created", self.rpc_call("events/list", {})["result"]["events"][0]["name"])
        subscribed = self.rpc_call("events/subscribe", {"name": "watch.message.created", "arguments": {"route_id": self.route_id},
            "delivery": {"mode": "webhook", "url": "https://callback.example.com/events", "secret": SECRET}, "cursor": None})
        self.assertIn("id", subscribed["result"])
        self.assertIn("result", self.rpc_call("tools/call", {"name": "peel_watch_confirm_connection", "arguments": {"route_id": self.route_id, "challenge": self.link["confirmationChallenge"]}}))
        receipt = self.send()
        inbox = json.loads(self.rpc_call("tools/call", {"name": "peel_watch_inbox", "arguments": {"route_id": self.route_id}})["result"]["content"][0]["text"])
        self.assertEqual(receipt["requestID"], inbox["requests"][0]["requestID"])
        replied = self.rpc_call("tools/call", {"name": "peel_watch_reply", "arguments": {"route_id": self.route_id, "generation": self.generation,
            "request_id": receipt["requestID"], "reply_id": "stable-agent-reply", "text": "new response"}})
        self.assertTrue(json.loads(replied["result"]["content"][0]["text"])["stored"])
        self.assertEqual("new response", self.store.replies(self.owner, self.route_id, self.generation)["replies"][0]["text"])

    def test_plugin_cannot_choose_other_route_or_owner_actions(self):
        invalid = self.rpc_call("tools/call", {"name": "peel_watch_inbox", "arguments": {"route_id": "ungranted-route"}})
        self.assertIn("error", invalid)
        self.assertIn("error", self.rpc_call("tools/call", {"name": "peel_watch_send", "arguments": {}}))
        self.assertIn("error", self.rpc_call("events/list", {}, self.owner))

    def test_callback_failure_is_safe_and_never_echoes_secret_or_url(self):
        result = self.rpc_call("events/subscribe", {"name": "watch.message.created", "arguments": {"route_id": self.route_id},
            "delivery": {"mode": "webhook", "url": "https://localhost/private-sensitive", "secret": SECRET}})
        serialized = json.dumps(result)
        self.assertEqual(-32015, result["error"]["code"])
        self.assertNotIn(SECRET, serialized)
        self.assertNotIn("private-sensitive", serialized)
        self.assertFalse(self.store.status(self.owner, self.route_id)["ready"])

    def test_invalid_envelopes_and_extra_scope_fields_rejected(self):
        for message in [[], {"jsonrpc": "2.0", "id": True, "method": "events/list"},
                        {"jsonrpc": "2.0", "id": 1, "method": "events/list", "principal": "forged"}]:
            self.assertIn("error", self.rpc.handle(self.agent, message))
        self.assertIn("error", self.rpc_call("events/list", {"route_id": self.route_id}))
        self.assertIn("error", self.rpc_call("tools/call", {"name": "peel_watch_reply", "arguments": {"account": "forged"}}))
        expired = dataclasses.replace(self.agent, expires_at=self.clock[0])
        self.assertIn("error", self.rpc_call("server/discover", {}, expired))

    def wsgi(self, app, path, body, raw=None, extra=None):
        data = raw if raw is not None else json.dumps(body).encode()
        environ = {"REQUEST_METHOD": "POST", "PATH_INFO": path, "CONTENT_TYPE": "application/json",
                   "CONTENT_LENGTH": str(len(data)), "wsgi.input": io.BytesIO(data)}
        environ.update(extra or {})
        status = []
        reply = b"".join(app(environ, lambda value, headers: status.append(value)))
        return status[0], json.loads(reply) if reply else None

    def test_wsgi_requires_verified_adapter_and_ignores_arbitrary_bearer(self):
        with self.assertRaisesRegex(RelayError, "authentication_adapter_required"):
            Application(self.store, None, self.callback)
        app = Application(self.store, lambda environ: None, self.callback)
        status, _ = self.wsgi(app, "/mcp", {}, extra={"HTTP_AUTHORIZATION": "Bearer unverified-input"})
        self.assertEqual("401 Unauthorized", status)

    def test_phone_wsgi_binds_independent_device_and_full_roundtrip(self):
        self.ready()
        app = Application(self.store, lambda environ: RequestAuthority(self.owner, self.grant), self.callback)
        identifier = str(uuid4())
        status, receipt = self.wsgi(app, "/v1/watch/send", {"route_id": self.route_id, "generation": self.generation, "request_id": identifier, "text": "phone courier data"})
        self.assertEqual("200 OK", status)
        self.assertFalse(receipt["agentReplyReceived"])
        self.store.reply(self.agent, self.route_id, self.generation, identifier, "response", "reply to phone")
        status, page = self.wsgi(app, "/v1/watch/replies", {"route_id": self.route_id, "generation": self.generation})
        self.assertEqual("reply to phone", page["replies"][0]["text"])
        other = dataclasses.replace(self.grant, device_id="different-device")
        bad = Application(self.store, lambda environ: RequestAuthority(self.owner, other), self.callback)
        self.assertEqual("400 Bad Request", self.wsgi(bad, "/v1/watch/status", {"route_id": self.route_id})[0])

    def test_strict_json_duplicate_nan_and_unknown_fields(self):
        app = Application(self.store, lambda environ: RequestAuthority(self.owner, self.grant), self.callback)
        for raw in [b'{"route_id":"a","route_id":"b"}', b'{"after":NaN}', b'[]', b'{"route_id":"\\ud800"}']:
            self.assertEqual("400 Bad Request", self.wsgi(app, "/v1/watch/status", {}, raw=raw)[0])
        self.assertEqual("400 Bad Request", self.wsgi(app, "/v1/watch/connect", {"agent_reference": "dot", "device": "forged"})[0])
