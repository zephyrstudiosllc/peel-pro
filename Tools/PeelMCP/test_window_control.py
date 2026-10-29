import base64
import math
import unittest
import uuid
import peel_mcp_server as m


class WindowControlAdapterChecks(unittest.TestCase):
    def setUp(self):
        self.base = {"targetPairingId": "paired-fixture", "windowId": 42, "windowToken": str(uuid.uuid4())}
        self.control = {**self.base, "inspectionId": str(uuid.uuid4())}

    def test_exact_actions_forward_to_native_without_translation(self):
        examples = [
            {"action": "click", "x": 0.2, "y": 0.8, "button": "right"},
            {"action": "type", "text": "Hello 👋"},
            {"action": "key", "key": "a", "modifiers": ["command", "shift"]},
            {"action": "key", "key": "enter"},
            {"action": "scroll", "deltaX": -12, "deltaY": 100},
            {"action": "drag", "x": 0, "y": 0.2, "toX": 0.8, "toY": 0.9},
        ]
        self.assertEqual(m._native_call_for_tool("peel_inspect_window", m._validate_arguments("peel_inspect_window", self.base)), ("inspectWindow", self.base))
        for example in examples:
            args = {**self.control, **example}
            self.assertEqual(m._native_call_for_tool("peel_control_window", m._validate_arguments("peel_control_window", args)), ("controlWindow", args))

    def test_malformed_mistargeting_unbounded_and_cross_action_fields_fail(self):
        valid = {**self.control, "action": "click", "x": 0.2, "y": 0.4}
        invalid = [
            {"windowId": True}, {"windowId": 0}, {"windowId": -1}, {"windowId": 2**32},
            {"windowToken": "guess"}, {"inspectionId": "guess"}, {"targetPairingId": "x" * 257},
            {"targetPairingId": "\ud800"}, {"x": float("nan")}, {"x": float("inf")}, {"y": -0.001},
            {"x": True}, {"x": 1.001}, {"button": "middle"}, {"button": []},
            {"path": "/tmp/app"}, {"shell": "echo no"}, {"text": "unexpected"},
            {"action": "mouseDown"}, {"action": "mouseUp"}, {"action": "activate"},
        ]
        for change in invalid:
            with self.subTest(change=change), self.assertRaises(m.ToolArgumentError):
                m._validate_arguments("peel_control_window", {**valid, **change})
        for args in ({**self.base, "inspectionId": self.control["inspectionId"]}, {**self.base, "x": 0.2}):
            with self.assertRaises(m.ToolArgumentError): m._validate_arguments("peel_inspect_window", args)

    def test_text_key_scroll_drag_boundaries(self):
        cases = [
            {"action": "type", "text": ""}, {"action": "type", "text": "x" * 513},
            {"action": "type", "text": "😀" * 257}, {"action": "type", "text": "x\n"},
            {"action": "type", "text": "x\t"}, {"action": "type", "text": "x\x00"},
            {"action": "type", "text": "\udfff"}, {"action": "key", "key": "A"},
            {"action": "key", "key": "command"}, {"action": "key", "key": "a", "modifiers": ["command", "command"]},
            {"action": "key", "key": "a", "modifiers": ["command", []]},
            {"action": "key", "key": "enter", "text": "x"},
            {"action": "scroll", "deltaX": 0, "deltaY": 0},
            {"action": "scroll", "deltaX": 1201, "deltaY": 2},
            {"action": "scroll", "deltaX": 0, "deltaY": True},
            {"action": "drag", "x": 0.2, "y": 0.3, "toX": 0.9},
            {"action": "drag", "x": 0.2, "y": 0.3, "toX": 0.9, "toY": 1.01},
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(m.ToolArgumentError):
                m._validate_arguments("peel_control_window", {**self.control, **case})
        for text in ("x" * 512, "😀" * 256):
            self.assertEqual(m._validate_arguments("peel_control_window", {**self.control, "action": "type", "text": text})["text"], text)

    def test_capture_is_native_mcp_image_and_metadata_does_not_duplicate_pixels(self):
        jpeg = base64.b64encode(b"\xff\xd8\xfffixture").decode()
        result = m._tool_success({"status": "captured", "mimeType": "image/jpeg", "imageBase64": jpeg, "inspectionId": self.control["inspectionId"]})
        self.assertEqual(result["content"][1], {"type": "image", "mimeType": "image/jpeg", "data": jpeg})
        self.assertNotIn("imageBase64", result["structuredContent"])
        self.assertNotIn(jpeg, result["content"][0]["text"])
        for value in ("not-base64!", base64.b64encode(b"wrong-type").decode(), jpeg * 30000):
            with self.assertRaises(m.BridgeError): m._tool_success({"imageBase64": value, "mimeType": "image/jpeg"})

    def test_catalog_keeps_effects_explicit_and_legacy_commerce_separate(self):
        tools = {tool["name"]: tool for tool in m.TOOL_DEFINITIONS}
        self.assertEqual(len(tools), 9)
        self.assertTrue(tools["peel_inspect_window"]["annotations"]["readOnlyHint"])
        self.assertFalse(tools["peel_control_window"]["annotations"]["readOnlyHint"])
        self.assertFalse(tools["peel_control_window"]["annotations"]["idempotentHint"])
        self.assertIn("single-use", tools["peel_control_window"]["description"])
        self.assertIn("Spatial", tools["peel_inspect_window"]["description"])
        self.assertIn("presentWindow", m._BRIDGE_METHODS)
        self.assertIn("inspectWindow", m._BRIDGE_METHODS)
        self.assertIn("controlWindow", m._BRIDGE_METHODS)


if __name__ == "__main__": unittest.main()
