#!/usr/bin/env python3
"""Focused, host-independent tests for the Peel MCP adapter."""

from __future__ import annotations

import io
import json
import os
import socket
import tempfile
import threading
import time
import unittest
import uuid

from peel_mcp_server import (
    BRIDGE_TIMEOUT_SECONDS,
    DEFAULT_SOCKET_PATH,
    MAX_PAYLOAD_BYTES,
    BridgeClient,
    BridgeError,
    PeelMCPServer,
    default_socket_path,
    run_stdio,
)


def _json_line(value):
    return json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"


class UnixFixture:
    """Owned temporary AF_UNIX fixture; no real Host or user data involved."""

    def __init__(self, response, delay=0.0):
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="peel-mcp-")
        self.path = os.path.join(self._temporary_directory.name, "bridge.sock")
        self.response = response
        self.delay = delay
        self.received = None
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen(1)
        self._listener.settimeout(1.0)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, traceback):
        try:
            self._listener.close()
        finally:
            self._thread.join(timeout=2.0)
            self._temporary_directory.cleanup()

    def _serve(self):
        try:
            connection, _ = self._listener.accept()
        except (OSError, socket.timeout):
            return
        with connection:
            connection.settimeout(1.0)
            request = bytearray()
            try:
                while b"\n" not in request:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    request.extend(chunk)
                    if len(request) > MAX_PAYLOAD_BYTES:
                        break
            except OSError:
                return
            self.received = bytes(request).split(b"\n", 1)[0]
            if self.delay:
                time.sleep(self.delay)
            reply = self.response(self.received) if callable(self.response) else self.response
            try:
                connection.sendall(reply)
            except OSError:
                pass


class BridgeClientTests(unittest.TestCase):
    def test_default_socket_path_targets_unified_host(self):
        self.assertEqual(DEFAULT_SOCKET_PATH, "~/.peel/bridge.sock")
        self.assertEqual(
            default_socket_path(), os.path.expanduser("~/.peel/bridge.sock")
        )
        self.assertEqual(BridgeClient().socket_path, default_socket_path())

    def test_explicit_socket_override_is_preserved(self):
        explicit = "/tmp/peel-explicit-agentbridge.sock"
        self.assertEqual(BridgeClient(explicit).socket_path, explicit)

    def test_forwards_one_uuid_request_and_returns_result(self):
        def response(request):
            decoded = json.loads(request.decode("utf-8"))
            self.assertEqual(decoded["version"], 1)
            self.assertEqual(decoded["method"], "listWindows")
            self.assertEqual(decoded["params"], {"targetPairingId": "test-pair"})
            uuid.UUID(decoded["id"])
            return _json_line({"version": 1, "id": decoded["id"], "result": {"windows": []}})

        with UnixFixture(response) as fixture:
            result = BridgeClient(fixture.path, timeout=1).request(
                "listWindows", {"targetPairingId": "test-pair"}
            )
        self.assertEqual(result, {"windows": []})

    def test_partial_reply_is_a_protocol_error(self):
        with UnixFixture(b'{"version":1') as fixture:
            with self.assertRaises(BridgeError) as raised:
                BridgeClient(fixture.path, timeout=1).request("listDevices", {})
        self.assertEqual(raised.exception.code, "bridge_protocol_error")

    def test_oversize_reply_is_rejected_before_unbounded_read(self):
        with UnixFixture(b"x" * (MAX_PAYLOAD_BYTES + 1) + b"\n") as fixture:
            with self.assertRaises(BridgeError) as raised:
                BridgeClient(fixture.path, timeout=1).request("listDevices", {})
        self.assertEqual(raised.exception.code, "bridge_payload_too_large")

    def test_timeout_is_a_clear_error(self):
        with UnixFixture(b'{"version":1}\n', delay=0.2) as fixture:
            with self.assertRaises(BridgeError) as raised:
                BridgeClient(fixture.path, timeout=0.03).request("listDevices", {})
        self.assertEqual(raised.exception.code, "bridge_timeout")

    def test_invalid_reply_is_a_protocol_error(self):
        invalid_replies = (
            b"not-json\n",
            _json_line({"version": 2, "id": "wrong", "result": {}}),
            _json_line({"version": 1, "id": "wrong", "result": {}}),
            _json_line({"version": 1, "id": "wrong", "result": {}, "error": {}}),
        )
        for invalid_reply in invalid_replies:
            with self.subTest(invalid_reply=invalid_reply[:20]):
                with UnixFixture(invalid_reply) as fixture:
                    with self.assertRaises(BridgeError) as raised:
                        BridgeClient(fixture.path, timeout=1).request("listDevices", {})
                self.assertEqual(raised.exception.code, "bridge_protocol_error")

    def test_absent_service_does_not_look_accepted(self):
        with tempfile.TemporaryDirectory(prefix="peel-mcp-absent-") as directory:
            absent = os.path.join(directory, "missing.sock")
            with self.assertRaises(BridgeError) as raised:
                BridgeClient(absent, timeout=1).request("listDevices", {})
        self.assertEqual(raised.exception.code, "bridge_unavailable")


class FakeBridge:
    def __init__(self, result=None, error=None):
        self.result = result if result is not None else {"accepted": True}
        self.error = error
        self.calls = []

    def request(self, method, params):
        self.calls.append((method, params))
        if self.error:
            raise self.error
        return self.result


class MCPServerTests(unittest.TestCase):
    def _initialized_server(self, bridge=None):
        server = PeelMCPServer(bridge or FakeBridge())
        init = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "init-1",
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                },
            }
        )
        self.assertEqual(
            init["result"]["capabilities"],
            {"tools": {}, "prompts": {}, "resources": {}},
        )
        self.initialize_response = init
        self.assertIsNone(
            server.handle_message(
                {"jsonrpc": "2.0", "method": "notifications/initialized"}
            )
        )
        return server

    def test_initialize_instructions_cover_source_target_and_ack_contract(self):
        self._initialized_server()
        instructions = self.initialize_response["result"]["instructions"]
        for marker in (
            "source Mac",
            "receiving",
            "connected=true and agentReady=true",
            "candidate readiness only",
            "exact Host error",
            "Do not infer a specific",
            "task context names an eligible targetPairingId",
            "sole eligible receiver without asking",
            "genuinely ambiguous",
            "no receiver currently meets both flags",
            "unavailable error means the bridge or Host is unavailable",
            "opens or activates the view in Peel",
            "acknowledged that the view opened or activated",
            "canPresent=false",
            "truncated=true, use a unique exact presentable match already returned",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, instructions)

    def test_tools_list_advertises_nine_bounded_tools(self):
        server = self._initialized_server()
        response = server.handle_message(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
        )
        names = [tool["name"] for tool in response["result"]["tools"]]
        self.assertEqual(
            names,
            [
                "peel_list_devices",
                "peel_list_windows",
                "peel_list_apps",
                "peel_launch_app",
                "peel_present_window",
                "peel_notify",
                "peel_get_stream_diagnostics",
                "peel_inspect_window",
                "peel_control_window",
            ],
        )
        apps = response["result"]["tools"][2]
        self.assertEqual(apps["inputSchema"]["required"], ["targetPairingId"])
        self.assertEqual(apps["inputSchema"]["properties"]["query"]["maxLength"], 120)
        self.assertIn("480 UTF-8 bytes", apps["inputSchema"]["properties"]["query"]["description"])
        launch = response["result"]["tools"][3]
        self.assertEqual(
            launch["inputSchema"]["required"], ["targetPairingId", "appId"]
        )
        self.assertEqual(launch["inputSchema"]["properties"]["appId"]["maxLength"], 128)
        present = response["result"]["tools"][4]
        self.assertEqual(present["inputSchema"]["properties"]["context"]["maxLength"], 1000)
        self.assertIn("never executable", present["inputSchema"]["properties"]["context"]["description"])

        for tool in response["result"]["tools"][1:6]:
            with self.subTest(tool=tool["name"]):
                self.assertIn(
                    "eligible receiving Peel-device identity",
                    tool["inputSchema"]["properties"]["targetPairingId"]["description"],
                )
        self.assertIn("reuse", response["result"]["tools"][1]["description"])
        self.assertIn("source Mac", response["result"]["tools"][1]["description"])
        self.assertIn("already names an eligible receiver", response["result"]["tools"][0]["description"])
        self.assertIn("no receiver currently meets both flags", response["result"]["tools"][0]["description"])
        self.assertIn("candidate readiness only", response["result"]["tools"][0]["description"])
        self.assertIn("Do not infer a specific", response["result"]["tools"][0]["description"])
        self.assertIn("view opened or activated", present["description"])

    def test_diagnostics_is_read_only_and_rejects_arbitrary_arguments(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        listed = server.handle_message({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        diagnostic = next(tool for tool in listed["result"]["tools"] if tool["name"] == "peel_get_stream_diagnostics")
        self.assertEqual(diagnostic["annotations"], {"readOnlyHint": True, "openWorldHint": False})
        self.assertIn("remain null", diagnostic["description"])
        result = server.handle_message({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "peel_get_stream_diagnostics", "arguments": {}}})
        self.assertFalse(result["result"].get("isError", False))
        self.assertEqual(bridge.calls, [("getStreamDiagnostics", {})])
        for index, arguments in enumerate(({"path": "/tmp/anything"}, {"targetPairingId": "other"},
                          {"reset": True}, {"duration": 300})):
            rejected = server.handle_message({"jsonrpc": "2.0", "id": 3 + index, "method": "tools/call",
                "params": {"name": "peel_get_stream_diagnostics", "arguments": arguments}})
            self.assertTrue(rejected["result"]["isError"])
        self.assertEqual(len(bridge.calls), 1)

    def test_show_me_this_app_prompt_describes_exact_desktop_first_order(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        listed = server.handle_message(
            {"jsonrpc": "2.0", "id": "prompt-list", "method": "prompts/list"}
        )
        self.assertEqual(
            [prompt["name"] for prompt in listed["result"]["prompts"]],
            ["show_me_this_app"],
        )
        fetched = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "prompt-get",
                "method": "prompts/get",
                "params": {
                    "name": "show_me_this_app",
                    "arguments": {"app": "Xcode"},
                },
            }
        )
        self.assertEqual(
            fetched["result"]["description"],
            "Resolve the source-Mac app/window from conversation context, "
            "use the sole eligible receiving Peel client without an unnecessary "
            "question, ask only genuine source or receiver ambiguity, and "
            "present the exact current source window or desktop in Peel Pro on the "
            "receiving device.",
        )
        prompt_text = fetched["result"]["messages"][0]["content"]["text"]
        self.assertIn("built-in computer-use context", prompt_text)
        self.assertIn("conversation's task context", prompt_text)
        self.assertIn("source Mac", prompt_text)
        self.assertIn("receiving", prompt_text)
        self.assertIn("candidate readiness only", prompt_text)
        self.assertIn("exact Host error", prompt_text)
        self.assertIn("Do not infer a specific", prompt_text)
        self.assertIn("explicitly names a `targetPairingId`", prompt_text)
        self.assertIn("unique exact presentable match already returned", prompt_text)
        self.assertIn("absent from a complete window list", prompt_text)
        self.assertIn("without asking", prompt_text)
        self.assertIn("view opened or activated", prompt_text)
        self.assertIn("canPresent: false", prompt_text)
        self.assertIn("truncated: true", prompt_text)
        self.assertLess(prompt_text.index("peel_list_devices"), prompt_text.index("peel_list_windows"))
        self.assertLess(prompt_text.index("peel_list_windows"), prompt_text.index("peel_list_apps"))
        self.assertLess(prompt_text.index("peel_list_apps"), prompt_text.index("peel_launch_app"))
        self.assertLess(prompt_text.index("peel_launch_app"), prompt_text.index("peel_present_window"))
        self.assertIn("optional `query`", prompt_text)
        self.assertIn("invalidates older opaque app IDs", prompt_text)
        self.assertIn("ask which source window", prompt_text)
        self.assertIn("window-only inspect/control", prompt_text)
        self.assertIn("single-use inspectionId", prompt_text)
        self.assertEqual(bridge.calls, [])

    def test_show_me_this_app_prompt_rejects_unknown_argument(self):
        server = self._initialized_server()
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "prompt-invalid",
                "method": "prompts/get",
                "params": {
                    "name": "show_me_this_app",
                    "arguments": {"windowTitle": "Unexpected"},
                },
            }
        )
        self.assertEqual(response["error"]["code"], -32602)

    def test_workflow_resource_is_static_and_does_not_call_bridge(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        listed = server.handle_message(
            {"jsonrpc": "2.0", "id": "resource-list", "method": "resources/list"}
        )
        self.assertEqual(
            [resource["uri"] for resource in listed["result"]["resources"]],
            ["peel://workflow/show-me-this-app"],
        )
        read = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "resource-read",
                "method": "resources/read",
                "params": {"uri": "peel://workflow/show-me-this-app"},
            }
        )
        content = read["result"]["contents"][0]
        self.assertEqual(content["mimeType"], "text/markdown")
        self.assertIn("peel_present_window", content["text"])
        self.assertIn("peel_list_apps", content["text"])
        self.assertIn("peel_launch_app", content["text"])
        self.assertIn("optional `query`", content["text"])
        self.assertIn("kind: desktop", content["text"])
        self.assertIn("synthetic `windowId`", content["text"])
        self.assertIn("displayId", content["text"])
        self.assertIn("connected: true", content["text"])
        self.assertIn("agentReady: true", content["text"])
        self.assertIn("candidate readiness only", content["text"])
        self.assertIn("Do not infer a specific", content["text"])
        self.assertIn("opens or activates the view in Peel", content["text"])
        self.assertIn("view opened or activated", content["text"])
        self.assertIn("canPresent: false", content["text"])
        self.assertIn("truncated: true", content["text"])
        self.assertIn("unique exact presentable match already returned", content["text"])
        self.assertEqual(bridge.calls, [])

    def test_unknown_resource_uri_is_not_forwarded(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "resource-invalid",
                "method": "resources/read",
                "params": {"uri": "peel://workflow/unknown"},
            }
        )
        self.assertEqual(response["error"]["code"], -32002)
        self.assertEqual(bridge.calls, [])

    def test_local_computer_route_is_explicit_and_consent_bound(self):
        server = self._initialized_server()
        instructions = self.initialize_response["result"]["instructions"]
        for marker in (
            'targetPairingId "local"',
            "never satisfies receiver selection",
            "Allow AI to use apps on this Mac",
            "no tool can turn it on",
            "consent_required",
            "status focused",
            "keyboard or mouse interrupts",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, instructions)
        response = server.handle_message({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = {tool["name"]: tool for tool in response["result"]["tools"]}
        self.assertEqual(len(tools), 9, "the local route adds no new tool or argument")
        self.assertIn("localComputer", tools["peel_list_devices"]["description"])
        self.assertIn("never a receiver candidate", tools["peel_list_devices"]["description"])
        for name in ("peel_list_windows", "peel_list_apps", "peel_launch_app", "peel_present_window", "peel_notify"):
            with self.subTest(tool=name):
                self.assertIn('"local"', tools[name]["inputSchema"]["properties"]["targetPairingId"]["description"])
                self.assertNotIn("localConsent", tools[name]["inputSchema"]["properties"])
        for name in ("peel_inspect_window", "peel_control_window"):
            with self.subTest(tool=name):
                self.assertIn('"local"', tools[name]["inputSchema"]["properties"]["targetPairingId"]["description"])
        self.assertIn("local target has no notify method", tools["peel_notify"]["description"])
        prompt = server.handle_message({"jsonrpc": "2.0", "id": 3, "method": "prompts/get",
                                        "params": {"name": "show_me_this_app", "arguments": {}}})
        prompt_text = prompt["result"]["messages"][0]["content"]["text"]
        self.assertIn("Local computer route", prompt_text)

    def test_local_target_is_forwarded_unchanged_for_target_tools(self):
        calls = (
            ("peel_list_windows", {"targetPairingId": "local"}, "listWindows"),
            ("peel_list_apps", {"targetPairingId": "local", "query": "Terminal"}, "listApps"),
            ("peel_present_window", {"targetPairingId": "local", "windowId": 21}, "presentWindow"),
            ("peel_inspect_window", {"targetPairingId": "local", "windowId": 21,
                                     "windowToken": str(uuid.uuid4())}, "inspectWindow"),
        )
        for name, arguments, method in calls:
            with self.subTest(tool=name):
                bridge = FakeBridge(result={"status": "ok"})
                server = self._initialized_server(bridge)
                response = server.handle_message({"jsonrpc": "2.0", "id": name, "method": "tools/call",
                                                  "params": {"name": name, "arguments": arguments}})
                self.assertFalse(response["result"]["isError"])
                self.assertEqual(bridge.calls, [(method, arguments)])

    def test_local_consent_error_is_reported_as_tool_error(self):
        bridge = FakeBridge(error=BridgeError("consent_required", "Turn on local AI access in Peel Pro."))
        server = self._initialized_server(bridge)
        response = server.handle_message({"jsonrpc": "2.0", "id": "c", "method": "tools/call",
            "params": {"name": "peel_list_windows", "arguments": {"targetPairingId": "local"}}})
        self.assertTrue(response["result"]["isError"])
        self.assertIn("consent_required", response["result"]["content"][0]["text"])

    def test_list_apps_forwards_target_without_query(self):
        bridge = FakeBridge(result={"apps": [], "truncated": False})
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "apps",
                "method": "tools/call",
                "params": {
                    "name": "peel_list_apps",
                    "arguments": {"targetPairingId": "test-pair"},
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            bridge.calls,
            [("listApps", {"targetPairingId": "test-pair"})],
        )

    def test_list_apps_forwards_optional_query(self):
        bridge = FakeBridge(result={"apps": [], "truncated": False})
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "apps-query",
                "method": "tools/call",
                "params": {
                    "name": "peel_list_apps",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "query": "Xcode",
                    },
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            bridge.calls,
            [("listApps", {"targetPairingId": "test-pair", "query": "Xcode"})],
        )

    def test_list_apps_rejects_invalid_query_before_bridge(self):
        invalid_queries = ("x" * 121, "safe\x00query", "safe\x7fquery", "safe\x85query", 7)
        for query in invalid_queries:
            with self.subTest(query=repr(query)):
                bridge = FakeBridge()
                server = self._initialized_server(bridge)
                response = server.handle_message(
                    {
                        "jsonrpc": "2.0",
                        "id": "apps-invalid",
                        "method": "tools/call",
                        "params": {
                            "name": "peel_list_apps",
                            "arguments": {
                                "targetPairingId": "test-pair",
                                "query": query,
                            },
                        },
                    }
                )
                self.assertTrue(response["result"]["isError"])
                self.assertEqual(bridge.calls, [])

    def test_list_apps_accepts_query_at_character_and_utf8_bounds(self):
        query = "😀" * 120
        self.assertEqual(len(query.encode("utf-8")), 480)
        bridge = FakeBridge(result={"apps": [], "truncated": False})
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "apps-boundary",
                "method": "tools/call",
                "params": {
                    "name": "peel_list_apps",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "query": query,
                    },
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(bridge.calls[0][1]["query"], query)

    def test_launch_app_forwards_only_latest_opaque_id(self):
        result = {
            "status": "launched",
            "appId": "opaque-app-1",
            "processId": 123,
            "nextStep": "List windows, then present the matching current window.",
        }
        bridge = FakeBridge(result=result)
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "launch",
                "method": "tools/call",
                "params": {
                    "name": "peel_launch_app",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "appId": "opaque-app-1",
                    },
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            bridge.calls,
            [
                (
                    "launchApp",
                    {"targetPairingId": "test-pair", "appId": "opaque-app-1"},
                )
            ],
        )
        self.assertEqual(response["result"]["structuredContent"], result)

    def test_launch_app_rejects_raw_launch_inputs_before_bridge(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "launch-raw",
                "method": "tools/call",
                "params": {
                    "name": "peel_launch_app",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "appId": "opaque-app-1",
                        "bundleIdentifier": "com.example.App",
                        "path": "/Applications/App.app",
                        "arguments": ["--unsafe"],
                    },
                },
            }
        )
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(bridge.calls, [])

    def test_launch_app_rejects_invalid_opaque_id_before_bridge(self):
        invalid_ids = ("x" * 129, "😀" * 33, "opaque\x00app")
        for app_id in invalid_ids:
            with self.subTest(app_id=repr(app_id)):
                bridge = FakeBridge()
                server = self._initialized_server(bridge)
                response = server.handle_message(
                    {
                        "jsonrpc": "2.0",
                        "id": "launch-invalid",
                        "method": "tools/call",
                        "params": {
                            "name": "peel_launch_app",
                            "arguments": {
                                "targetPairingId": "test-pair",
                                "appId": app_id,
                            },
                        },
                    }
                )
                self.assertTrue(response["result"]["isError"])
                self.assertEqual(bridge.calls, [])

    def test_launch_app_preserves_native_catalog_errors(self):
        bridge = FakeBridge(error=BridgeError("app_not_listed", "refresh the app list"))
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "launch-stale",
                "method": "tools/call",
                "params": {
                    "name": "peel_launch_app",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "appId": "opaque-app-1",
                    },
                },
            }
        )
        self.assertTrue(response["result"]["isError"])
        self.assertIn("app_not_listed", response["result"]["content"][0]["text"])

    def test_present_window_forwards_only_named_native_params(self):
        bridge = FakeBridge(result={"accepted": True})
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {
                    "name": "peel_present_window",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "windowId": 4294967295,
                    },
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            bridge.calls,
            [
                (
                    "presentWindow",
                    {
                        "targetPairingId": "test-pair",
                        "windowId": 4294967295,
                    },
                )
            ],
        )

    def test_present_window_forwards_optional_plain_context(self):
        bridge = FakeBridge(result={"accepted": True})
        server = self._initialized_server(bridge)
        context = "Showing the current desktop.\nUse the window controls\twhen needed."
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "context",
                "method": "tools/call",
                "params": {
                    "name": "peel_present_window",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "windowId": 42,
                        "context": context,
                    },
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            bridge.calls,
            [
                (
                    "presentWindow",
                    {
                        "targetPairingId": "test-pair",
                        "windowId": 42,
                        "context": context,
                    },
                )
            ],
        )

    def test_present_window_rejects_untrusted_context_before_bridge(self):
        for context in ("x" * 1001, "safe\x00text", "safe\x7ftext"):
            with self.subTest(context=repr(context)):
                bridge = FakeBridge()
                server = self._initialized_server(bridge)
                response = server.handle_message(
                    {
                        "jsonrpc": "2.0",
                        "id": "context-invalid",
                        "method": "tools/call",
                        "params": {
                            "name": "peel_present_window",
                            "arguments": {
                                "targetPairingId": "test-pair",
                                "windowId": 42,
                                "context": context,
                            },
                        },
                    }
                )
                self.assertTrue(response["result"]["isError"])
                self.assertEqual(bridge.calls, [])

    def test_present_window_rejects_context_over_character_bound_before_bridge(self):
        context = "😀" * 1001
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "context-bytes",
                "method": "tools/call",
                "params": {
                    "name": "peel_present_window",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "windowId": 42,
                        "context": context,
                    },
                },
            }
        )
        self.assertTrue(response["result"]["isError"])
        self.assertIn("1000 characters", response["result"]["content"][0]["text"])
        self.assertEqual(bridge.calls, [])

    def test_present_window_accepts_context_at_character_and_utf8_bounds(self):
        context = "😀" * 1000
        bridge = FakeBridge(result={"accepted": True})
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": "context-boundary",
                "method": "tools/call",
                "params": {
                    "name": "peel_present_window",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "windowId": 42,
                        "context": context,
                    },
                },
            }
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            bridge.calls[0][1]["context"].encode("utf-8"),
            "😀".encode("utf-8") * 1000,
        )

    def test_unimplemented_presentation_title_is_rejected(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        response = server.handle_message({
            "jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": {"name": "peel_present_window", "arguments": {
                "targetPairingId": "test-pair", "windowId": 1, "title": "Unsupported"
            }},
        })
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(bridge.calls, [])

    def test_invalid_tool_args_do_not_reach_bridge(self):
        bridge = FakeBridge()
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "peel_notify",
                    "arguments": {
                        "targetPairingId": "test-pair",
                        "title": "x" * 121,
                        "message": "hello",
                    },
                },
            }
        )
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(bridge.calls, [])

    def test_native_service_error_is_tool_error(self):
        bridge = FakeBridge(error=BridgeError("bridge_unavailable", "service is absent"))
        server = self._initialized_server(bridge)
        response = server.handle_message(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {"name": "peel_list_devices", "arguments": {}},
            }
        )
        self.assertTrue(response["result"]["isError"])
        self.assertIn("bridge_unavailable", response["result"]["content"][0]["text"])

    def test_stdio_emits_only_json_rpc_lines_and_suppresses_notifications(self):
        bridge = FakeBridge(result={"devices": []})
        server = PeelMCPServer(bridge)
        requests = [
            {
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": "call", "method": "tools/call", "params": {"name": "peel_list_devices"}},
        ]
        input_stream = io.BytesIO(b"".join(_json_line(request) for request in requests))
        output_stream = io.BytesIO()
        self.assertEqual(run_stdio(server, input_stream, output_stream), 0)
        output_lines = output_stream.getvalue().splitlines()
        self.assertEqual(len(output_lines), 2)
        responses = [json.loads(line.decode("utf-8")) for line in output_lines]
        self.assertEqual([response["id"] for response in responses], ["init", "call"])
        self.assertEqual(responses[1]["result"]["isError"], False)


if __name__ == "__main__":
    unittest.main()
