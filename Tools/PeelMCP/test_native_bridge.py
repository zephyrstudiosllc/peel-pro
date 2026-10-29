"""Real Swift-to-Python transport check; isolated sockets, no running Host required."""

import pathlib
import platform
import select
import subprocess
import tempfile
import unittest

from peel_mcp_server import BridgeClient, BridgeError


@unittest.skipUnless(platform.system() == "Darwin", "requires the native macOS transport")
class NativeBridgeInteropTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tools = pathlib.Path(__file__).resolve().parent
        source = tools.parents[1] / "Sources/PeelHost/Peel-Host/AgentBridge/PeelLocalAgentServer.swift"
        if not source.exists():
            raise unittest.SkipTest("initialize the PeelHost component first")
        cls.temp = tempfile.TemporaryDirectory(prefix="peel-interop-")
        cls.addClassCleanup(cls.temp.cleanup)
        root = pathlib.Path(cls.temp.name).resolve()
        binary = root / "fixture"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
            "-default-isolation", "MainActor", "-strict-concurrency=complete",
            "-warnings-as-errors", str(source), str(tools / "NativeBridgeFixture.swift"),
            "-o", str(binary),
        ], check=True, timeout=120, capture_output=True, text=True)
        cls.socket_path = root / "bridge" / "bridge.sock"
        cls.process = subprocess.Popen(
            [str(binary), str(cls.socket_path)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        cls.addClassCleanup(cls.stop_fixture)
        ready, _, _ = select.select([cls.process.stdout], [], [], 10)
        if not ready or cls.process.stdout.readline().strip() != "READY":
            raise RuntimeError("Native fixture did not become ready")

    @classmethod
    def stop_fixture(cls):
        if cls.process.poll() is None:
            try:
                cls.process.communicate("stop\n", timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.communicate()
        if cls.process.returncode != 0:
            raise RuntimeError(f"Native fixture exited {cls.process.returncode}")

    def test_python_lowercase_ids_correlate_with_native_success(self):
        params = {"targetPairingId": "synthetic-pair", "windowId": 42}
        result = BridgeClient(self.socket_path).request("presentWindow", params)
        self.assertEqual(result, {"method": "presentWindow", "params": params})

    def test_python_receives_native_correlated_error(self):
        with self.assertRaises(BridgeError) as result:
            BridgeClient(self.socket_path).request("notify", {})
        self.assertEqual(result.exception.code, "unsupported")

    def test_native_transports_manual_control_methods_without_paid_substitution(self):
        for method in ("inspectWindow", "controlWindow"):
            params = {"targetPairingId": "fixture", "windowId": 42,
                "windowToken": "frozen-fixture-token", "inspectionId": "inspection-fixture", "action": "click", "x": 0.2, "y": 0.3}
            result = BridgeClient(self.socket_path).request(method, params)
            self.assertEqual(result, {"method": method, "params": params})

    def test_native_accepts_diagnostics_method(self):
        result = BridgeClient(self.socket_path).request("getStreamDiagnostics", {})
        self.assertEqual(result, {"method": "getStreamDiagnostics", "params": {}})


if __name__ == "__main__":
    unittest.main()
