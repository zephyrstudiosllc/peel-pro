#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
HARNESS_ROOT=${SCRIPT_DIR:h}
HOST_APP=${PEEL_HOST_APP:-/Applications/Peel Pro.app}
TOKEN=${PEEL_E2E_TOKEN:-PEEL_E2E_ONBOARD_IPAD_SIM}
SIMULATOR_UDID=${PEEL_SIMULATOR_UDID:-}

if [[ -z "$SIMULATOR_UDID" ]]; then
    SIMULATOR_UDID=$(xcrun simctl list devices booted -j | jq -r '
        [.devices[][] | select(.state == "Booted" and (.name | startswith("iPad")))]
        | first
        | .udid // empty
    ')
fi

if [[ -z "$SIMULATOR_UDID" ]]; then
    print -u2 "run-mac-ipad-e2e: boot an onboard iPad Simulator first"
    exit 69
fi

if [[ ! -d "$HOST_APP" ]]; then
    print -u2 "run-mac-ipad-e2e: Host app not found at $HOST_APP"
    exit 66
fi

if ! pgrep -x TextEdit >/dev/null; then
    print -u2 "run-mac-ipad-e2e: open a writable TextEdit document before running"
    exit 69
fi

if pgrep -f '/Peel Pro[^/]*/Contents/MacOS/Peel Pro$' >/dev/null; then
    print -u2 "run-mac-ipad-e2e: quit every running Peel Pro before running"
    exit 70
fi

HOST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HOST_APP/Contents/Info.plist")
CLIENT_CONTAINER=$(xcrun simctl get_app_container "$SIMULATOR_UDID" com.zephyrstudiosllc.Peel app)
CLIENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CLIENT_CONTAINER/Info.plist")
EVIDENCE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peel-mac-ipad-e2e.XXXXXX")
RESULT_BUNDLE="$EVIDENCE_DIR/PeelUITestHarness.xcresult"
HOST_LOG="$EVIDENCE_DIR/host.log"
TEST_LOG="$EVIDENCE_DIR/xcodebuild.log"
SCREENSHOT="$EVIDENCE_DIR/simulator.png"
ASSERT_TOOL="$EVIDENCE_DIR/AssertTextEditContains"

cleanup() {
    if [[ -n "${HOST_PID:-}" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
        kill -TERM "$HOST_PID"
        wait "$HOST_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

codesign --verify --deep --strict "$HOST_APP"
xcrun swiftc "$HARNESS_ROOT/Tools/AssertTextEditContains.swift" -o "$ASSERT_TOOL"

env NSUnbufferedIO=YES "$HOST_APP/Contents/MacOS/Peel Pro" >"$HOST_LOG" 2>&1 &
HOST_PID=$!
sleep 2

print "run-mac-ipad-e2e: Host build $HOST_BUILD, client build $CLIENT_BUILD"
print "run-mac-ipad-e2e: simulator $SIMULATOR_UDID"
print "run-mac-ipad-e2e: evidence $EVIDENCE_DIR"

PEEL_E2E_TOKEN="$TOKEN" xcodebuild \
    -project "$HARNESS_ROOT/PeelUITestHarness.xcodeproj" \
    -scheme PeelUITestHarness \
    -destination "id=$SIMULATOR_UDID" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:PeelUITestHarnessUITests/PeelUITestHarnessUITests/testRemoteTextInputWithoutSimulatorFocusSteal \
    -resultBundlePath "$RESULT_BUNDLE" \
    test | tee "$TEST_LOG"

"$ASSERT_TOOL" "$TOKEN"

if rg -q 'could not fetch AX windows|input rejected|InputRejected' "$HOST_LOG"; then
    print -u2 "run-mac-ipad-e2e: Host logged an AX or input rejection"
    exit 1
fi

xcrun simctl io "$SIMULATOR_UDID" screenshot "$SCREENSHOT"
print "run-mac-ipad-e2e: PASS"
