#!/usr/bin/env python3
"""Compile the actual iPad scene/capture ownership bodies with deterministic UI stubs."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "Peel-iPad/iPadPeeledWindowView.swift").read_text()

def block(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "")

view_source, capture_source = source.split("private struct KeyCaptureTextView:", 1)
view = "\n".join(block(view_source, signature) for signature in [
    "    private var isKeyboardSceneEligible:", "    private var isKeyboardInputOwner:",
    "    private func refreshKeyboardInputOwnership(", "    private func refreshExternalInputState(",
    "    private func setSoftwareKeyboardActive(", "    private func handleKeyboardFocusChanged(",
    "    private func requestFocusForPresentedWindow("
])
capture = "\n".join(block(capture_source, signature) for signature in [
    "        private var hasKeyboardInputOwnership:", "        override var canBecomeFirstResponder:",
    "        override func didMoveToWindow(", "        private func refreshKeyboardInputOwnership(",
    "        func stopManagingFocus(", "        func applyFocus(",
    "        private func scheduleFocusRetry(", "        private func cancelFocusRetries(",
    "        override func becomeFirstResponder(", "        override func resignFirstResponder(",
    "        override func pressesBegan(", "        private func handleHardwareKey(",
    "        private func sendHardwareKey(", "        private func keyboardCommands(",
    "        override func insertText(", "        override func deleteBackward(",
    "        private func emitTextToHost(", "        private func flushPendingComposedText("
])
production = view + "\n" + capture
fixture = (Path(__file__).parent / "Checks.swift").read_text()

def unit(view_body, capture_body):
    return (fixture.replace("// VIEW METHODS", view_body).replace("// CAPTURE METHODS", capture_body)
            .replace("DispatchQueue.main", "Scheduler.main")
            .replace("DispatchWorkItem", "WorkItem").replace(".now()", "Scheduler.now"))

variants = [("current", view, capture, True)]
if "--verify-focus-regression" in sys.argv:
    variants += [
        ("focus-without-workspace-admission", view.replace(
            "guard workspaceAllowsInput, workspaceIsVisible, workspaceInputAdmission() else { return }", ""
        ), capture, False),
    ]
if "--verify-regression" in sys.argv:
    variants += [
        ("passive-workspace-pane", view.replace("workspaceAllowsInput, workspaceIsVisible,", "workspaceIsVisible,"), capture, False),
        ("hidden-workspace-pane", view.replace("workspaceAllowsInput, workspaceIsVisible,", "workspaceAllowsInput,"), capture, False),
        ("global-device-claim", view.replace("autoEnableKeyboard && isKeyboardInputOwner &&", "autoEnableKeyboard &&"), capture, False),
        ("scene-without-key", view.replace("currentScene.windows.contains(where: { $0.isKeyWindow })", "true"), capture, False),
        ("scene-without-native-state", view.replace("currentScene.activationState == .foregroundActive &&", "true &&"), capture, False),
        ("late-focus-callback", view.replace("guard isKeyboardInputOwner else { return }", ""), capture, False),
        ("queued-focus-without-owner", view, capture.replace("self.requestedKeyboardFocus, self.hasKeyboardInputOwnership else { return }", "self.requestedKeyboardFocus else { return }", 1), False),
        ("retry-without-owner", view, capture.replace("self.requestedKeyboardFocus, self.hasKeyboardInputOwnership,", "self.requestedKeyboardFocus,"), False),
        ("direct-focus-without-owner", view, capture.replace("override var canBecomeFirstResponder: Bool { hasKeyboardInputOwnership }", "override var canBecomeFirstResponder: Bool { true }"), False),
        ("resign-erases-intent", view, capture.replace("if isSuspendingInputOwnership {", "if false {"), False),
        ("late-composition-without-owner", view, capture.replace("guard hasKeyboardInputOwnership, !pendingComposedText.isEmpty", "guard !pendingComposedText.isEmpty").replace("guard hasKeyboardInputOwnership else {\n                pendingComposedText += text\n                return\n            }", ""), False),
        ("dismantle-keeps-retry", view, capture.replace("requestedKeyboardFocus = false\n            sceneInputOwner = { false }", "requestedKeyboardFocus = true\n            sceneInputOwner = { true }").replace("focusRequestGeneration += 1\n            cancelFocusRetries()", "// retired cleanup removed"), False),
        ("cached-owner", view, capture.replace("sceneInputOwner = isInputOwner", "let cachedOwner = isInputOwner(); sceneInputOwner = { cachedOwner }"), False),
        ("focus-success-loses-composition", view, capture.replace("if didBecome, !pendingComposedText.isEmpty {\n                scheduleComposedTextFlush()\n            }", ""), False),
        ("late-direct-key-dispatch", view, capture.replace("guard hasKeyboardInputOwnership else { return }", "").replace("guard hasKeyboardInputOwnership else { return false }", ""), False),
    ]

failed = False
with tempfile.TemporaryDirectory(prefix="peel-keyboard-ownership-") as tmp:
    for name, v, c, expected in variants:
        if name != "current" and v == view and c == capture:
            raise RuntimeError(f"Mutation did not alter source: {name}")
        swift = Path(tmp) / (name + ".swift")
        executable = Path(tmp) / name
        compiled = unit(v, c)
        swift.write_text(compiled)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(swift), "-o", str(executable)], check=True, timeout=60)
        result = subprocess.run([str(executable)], timeout=15)
        matched = (result.returncode == 0) == expected
        failed |= not matched
        print(json.dumps({"variant": name, "expectedOutcomeMatched": matched,
                          "exitCode": result.returncode,
                          "productionTransitionsSHA256": hashlib.sha256(production.encode()).hexdigest(),
                          "compiledUnitSHA256": hashlib.sha256(compiled.encode()).hexdigest()}), flush=True)
sys.exit(1 if failed else 0)
