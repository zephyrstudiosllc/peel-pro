#!/usr/bin/env python3
"""Exercise real private-source lifetime/cleanup and reject focused regressions.

All events go to the existing test sink. No native events are posted.
"""
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
host = here.parent.parent / "Peel-Host"
source = (host / "PeelHost/InputSynthesizer.swift").read_text()
checks = (here / "InputLifetimeChecks.swift").read_text().replace("precondition(", "require(")
# Expected negative checks exit normally instead of creating crash reports.
checks += '''
func require(_ condition: @autoclosure () -> Bool,
             _ message: @autoclosure () -> String = "",
             file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        print("EXPECTED-CHECK-FAILURE at \\(line): \\(message())")
        exit(1)
    }
}
'''

variants = [
    ("current", None, None, None),
    ("shared-hid-source", "private let unicodeEventSource = CGEventSource(stateID: .privateState)",
     "private let unicodeEventSource = CGEventSource(stateID: .hidSystemState)",
     "Unicode must use an independent private source"),
    ("new-source-per-scalar", "PeelKeyboardEventFactory.unicodeEvents(for: scalar, source: source)",
     "PeelKeyboardEventFactory.unicodeEvents(for: scalar, source: CGEventSource(stateID: .privateState))",
     "Disabled-session cleanup must release interrupted text using its exact private source"),
    ("wrong-cleanup-source", "CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)",
     "CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)",
     "Disabled-session cleanup must release interrupted text using its exact private source"),
    ("missing-unicode-held-state", "heldUnicodeKey = true", "heldUnicodeKey = false",
     "Text bursts must stop and release their admitted down when network identity changes"),
    ("hardware-zero-alias", "beforePost: { self.heldUnicodeKey = false }",
     "beforePost: { self.heldUnicodeKey = false; self.heldKeyCodes.remove(0) }",
     "Unicode completion or cancellation must not erase hardware key-zero cleanup"),
]

with tempfile.TemporaryDirectory(prefix="peel-private-source-checks-") as temporary:
    folder = Path(temporary)
    test_file = folder / "Checks.swift"
    test_file.write_text(checks)
    for name, old, new, expected in variants:
        mutated = source
        if old is not None:
            assert source.count(old) == 1, (name, "mutation must match exactly once")
            mutated = source.replace(old, new)
            # A deliberately ignored retained source is part of these mutants.
            if name == "new-source-per-scalar":
                mutated = mutated.replace("guard let source = self.unicodeEventSource,", "guard let _ = self.unicodeEventSource,")
            elif name == "wrong-cleanup-source":
                mutated = mutated.replace("if let source = unicodeEventSource,", "if let _ = unicodeEventSource,")
        synth_file = folder / "InputSynthesizer.swift"
        synth_file.write_text(mutated)
        binary = folder / name
        sources = [host / "PeelSharedMessages.swift", host / "PeelStreamDiagnosticsMessages.swift",
                   host / "PeelHost/PeelPointerInput.swift", host / "PeelHost/PeelKeyboardEventFactory.swift",
                   synth_file, test_file]
        compile_result = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
            *map(str, sources), "-o", str(binary)], text=True, capture_output=True)
        assert compile_result.returncode == 0, (name, compile_result.stderr)
        result = subprocess.run([str(binary)], text=True, capture_output=True)
        if expected is None:
            assert result.returncode == 0, (name, result.stdout, result.stderr)
        else:
            assert result.returncode == 1 and expected in result.stdout, (name, result.stdout, result.stderr)
        print(f"{name}: PASS (expected outcome)", flush=True)
print("Private source checks: PASS (current + 5 focused negative variants; no events posted)")
