#!/usr/bin/env python3
"""Compile actual input transitions with a virtual scheduler; never post input."""
from pathlib import Path
import subprocess
import sys
import tempfile

here = Path(__file__).resolve().parent
host = here.parent.parent / "Peel-Host"
source = (host / "PeelHost/InputSynthesizer.swift").read_text()
existing = (here / "InputLifetimeChecks.swift").read_text()
checks = existing[:existing.index("@main\nstruct InputLifetimeChecks")] + (here / "TextPacingChecks.swift").read_text()
variants = [
    ("current", None, None, None),
    ("zero-interval", "private static let textEventInterval: TimeInterval = 0.001",
     "private static let textEventInterval: TimeInterval = 0", "no early key up"),
    ("finish-before-final-gap", "later { emit(from: index + 1) }",
     "if index + 1 == scalars.count { completion() } else { later { emit(from: index + 1) } }",
     "final gap retains operation across messages"),
    ("skip-focus-check", "self.accessibility.isWindowReadyForInput(windowId: windowId,\n                        interactionPoint: self.authoritativeInputPoint(for: windowId))",
     "true", "focus loss prohibits later down"),
    ("stale-callback-resets-current", "if activeInput?.id == generation.operation {\n                retireFailedInput(generation: generation, reason: .inputGenerationChanged)\n            }",
     "resetSessionState(reason: .inputGenerationChanged)", "old callback cannot reset replacement"),
    ("fixed-text-deadline", "10 + Double(scalarCount) * 2 * textEventInterval", "10",
     "full admitted ASCII has bounded pacing budget"),
    ("missing-unicode-held-state", "beforePost: { self.heldUnicodeKey = true }", "beforePost: {}",
     "hardware-zero and Unicode cleanup retain distinct sources"),
    ("held-state-after-sink", "beforePost: { self.heldUnicodeKey = true }", "beforePost: {}",
     "reentrant reset sees admitted held down"),
]
if "--tap-only" in sys.argv:
    variants = [variants[0],
        ("wrong-Unicode-tap", "private static let unicodeEventTap: CGEventTapLocation = .cgSessionEventTap",
         "private static let unicodeEventTap: CGEventTapLocation = .cghidEventTap",
         "ordinary Unicode halves use session tap"),
        ("wrong-cleanup-tap", "eventSink(event, Self.unicodeEventTap)", "eventSink(event, .cghidEventTap)",
         "all Unicode cleanup uses session tap and controls retain HID tap")]
with tempfile.TemporaryDirectory(prefix="peel-text-pacing-") as temporary:
    folder = Path(temporary)
    test_file = folder / "Checks.swift"
    test_file.write_text(checks)
    for name, old, new, expected in variants:
        mutated = source
        if old is not None:
            assert source.count(old) == 1, (name, "mutation must match once")
            mutated = source.replace(old, new)
            if name == "held-state-after-sink":
                old_record = "self.recordInputDiagnostic(.postedUnicodeDown, windowId: windowId, control: generation.control)"
                assert mutated.count(old_record) == 1
                mutated = mutated.replace(old_record, "self.heldUnicodeKey = true\n                " + old_record)
        synth = folder / "InputSynthesizer.swift"
        synth.write_text(mutated)
        binary = folder / name
        sources = [host / "PeelSharedMessages.swift", host / "PeelStreamDiagnosticsMessages.swift",
                   host / "PeelHost/PeelPointerInput.swift", host / "PeelHost/PeelKeyboardEventFactory.swift", synth, test_file]
        build = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            "-default-isolation", "MainActor", "-strict-concurrency=complete", "-warnings-as-errors",
            *map(str, sources), "-o", str(binary)], text=True, capture_output=True)
        assert build.returncode == 0, (name, build.stderr)
        result = subprocess.run([str(binary)], text=True, capture_output=True)
        if expected is None:
            assert result.returncode == 0, (name, result.stdout, result.stderr)
        else:
            assert result.returncode == 1 and expected in result.stdout, (name, result.stdout, result.stderr)
        print(f"{name}: PASS (expected outcome)", flush=True)
print(f"Pacing checks: PASS (current + {len(variants) - 1} negative variants; no events posted)")
