#!/usr/bin/env python3
"""Check opt-in aggregate diagnostics against real input execution; never post events."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
host = here.parent.parent / "Peel-Host"
existing = (here / "InputLifetimeChecks.swift").read_text()
stubs = existing[:existing.index("@main\nstruct InputLifetimeChecks")]
fixture = r'''
@main
struct InputDiagnosticChecks {
    static func main() async throws {
        let focus = AccessibilityManager()
        var posted = 0
        let input = InputSynthesizer(accessibility: focus, eventSink: { _, _ in posted += 1 })
        input.isRemoteControlAllowed = { true }
        input.isControlGenerationCurrent = { $0 == 9 }
        input.activeWindowProvider = { 111 }
        func submit(_ text: String, generation: UInt64 = 9) {
            input.withReceivedControlGeneration(generation) {
                let message = KeyboardTextMessage(text: text, windowId: 111)
                input.noteDecodedKeyboardText(message)
                input.handleKeyboardText(message)
            }
        }
        submit("A😀") // Two Unicode scalars, three UTF-16 units, four posted events.
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(posted == 4)
        focus.holdFocus = true
        focus.ready = false
        for _ in 0..<3 { submit("DO_NOT_LOG_THIS_TEXT") }
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(focus.completions.count == 1)
        input.resetSessionState(reason: .clientHidden)
        submit("STALE_DO_NOT_LOG", generation: 10)
        focus.ready = true
        focus.completeFocus()
        try await Task.sleep(nanoseconds: 350_000_000)
        precondition(posted == 4, "Diagnostic bookkeeping cannot admit cancelled/stale input")
        print("InputDiagnosticChecks: PASS (4 captured events; no native input posted)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="peel-input-diagnostic-checks-") as temporary:
    folder = Path(temporary)
    swift = folder / "Checks.swift"
    swift.write_text(stubs + fixture)
    binary = folder / "checks"
    sources = [host / "PeelSharedMessages.swift", host / "PeelStreamDiagnosticsMessages.swift",
               host / "PeelHost/PeelPointerInput.swift", host / "PeelHost/PeelKeyboardEventFactory.swift",
               host / "PeelHost/InputSynthesizer.swift", swift]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
                    *map(str, sources), "-o", str(binary)], check=True)
    for enabled in (False, True):
        env = os.environ.copy()
        env.pop("PEEL_INPUT_DIAGNOSTICS", None)
        if enabled:
            env["PEEL_INPUT_DIAGNOSTICS"] = "1"
        result = subprocess.run([str(binary)], env=env, text=True, capture_output=True, check=True)
        assert "DO_NOT_LOG" not in result.stdout and "😀" not in result.stdout
        rows = [json.loads(line.removeprefix("PeelInputDiag ")) for line in result.stdout.splitlines()
                if line.startswith("PeelInputDiag ")]
        if not enabled:
            assert not rows, "Default-off execution must produce no diagnostic records"
        else:
            snapshots = {(row["windowId"], row["controlGeneration"]): row["counts"]
                         for row in rows if row["event"] == "counts"}
            assert snapshots[("111", "9")] == {
                "decodedTextMessages": 4, "decodedTextScalars": 62,
                "admittedTextMessages": 4, "admittedTextScalars": 62,
                "enqueuedTextMessages": 4, "enqueuedTextScalars": 62,
                "postedUnicodeDown": 2, "postedUnicodeUp": 2,
                "cancelledQueuedOperations": 2, "cancelledActiveOperations": 1,
            }, snapshots
            assert snapshots[("111", "10")] == {"decodedTextMessages": 1, "decodedTextScalars": 16}, snapshots
            resets = [row for row in rows if row["event"] == "reset"]
            assert len(resets) == 1 and resets[0]["reason"] == "clientHidden"
            assert resets[0]["pendingOperations"] == 2 and resets[0]["activeOperations"] == 1
        print(json.dumps({"diagnosticsEnabled": enabled, "passed": True, "records": rows}, sort_keys=True))
