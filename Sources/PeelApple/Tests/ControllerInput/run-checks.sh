#!/bin/sh
# Game controller policy checks. Root owns running these; nothing here needs a
# controller, device, scene, socket or host.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APPLE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TEMP_BINARY=$(mktemp "${TMPDIR:-/tmp}/peel-controller-policy.XXXXXX")
trap 'rm -f "$TEMP_BINARY"' EXIT HUP INT TERM

xcrun swiftc \
  -swift-version 5 \
  -default-isolation MainActor \
  -strict-concurrency=complete \
  -parse-as-library \
  "$APPLE_DIR/Shared/Client/PeelGameControllerPolicy.swift" \
  "$SCRIPT_DIR/PeelGameControllerPolicyChecks.swift" \
  -o "$TEMP_BINARY"
"$TEMP_BINARY"

# Source regressions: keyed controller targets never use the selected-session
# fallback, and the Vision-only adapter is not duplicated.
fail=0
if grep -n 'browser.session(for: $0) }) ?? browser.selectedSession' "$APPLE_DIR/Peel/PeeledWindowView.swift"; then
  echo "FAIL: Vision controller target falls back to the selected session" >&2
  fail=1
fi
for view in "$APPLE_DIR/Peel/PeeledWindowView.swift" "$APPLE_DIR/Peel-iPad/iPadPeeledWindowView.swift"; do
  if ! grep -q 'PeelControllerSessionResolution.owningSession' "$view"; then
    echo "FAIL: $view does not resolve the controller session by exact host key" >&2
    fail=1
  fi
done
ADAPTER="$APPLE_DIR/Shared/Client/PeelGameControllerInput.swift"
# Callbacks go only through the generation-token relay; window readiness uses the
# session's exact window-instance identity.
for needle in 'relay.post(token, button, pressed: pressed)' 'policy.callbackChanged(token' \
  'session.currentWindowInstanceMatches(window)' 'syncCallbackRegistrations()'; do
  if ! grep -qF "$needle" "$ADAPTER"; then
    echo "FAIL: adapter is missing: $needle" >&2
    fail=1
  fi
done
if grep -n 'policy.pressChanged\|deliverOnMain' "$ADAPTER"; then
  echo "FAIL: adapter bypasses the callback registration token" >&2
  fail=1
fi
# The guide revokes input inside its button action; event routing follows the
# published routing owner; Vision gives up input as immersive opening starts.
if ! grep -A3 'Revoke controller output before the guide is shown' "$ADAPTER" | grep -q 'input.suspendForHelp(suspensionID)'; then
  echo "FAIL: help button does not suspend controller input in its action" >&2
  fail=1
fi
for view in "$APPLE_DIR/Peel/PeeledWindowView.swift" "$APPLE_DIR/Peel-iPad/iPadPeeledWindowView.swift"; do
  if ! grep -q 'isEnabled: gameControllerInput.routingOwnerID == gameControllerOwnerID &&' "$view"; then
    echo "FAIL: $view enables GCEventInteraction without routing eligibility" >&2
    fail=1
  fi
done
if ! grep -A2 'isOpeningImmersive = true' "$APPLE_DIR/Peel/PeeledWindowView.swift" | grep -q 'gameControllerInput.release(owner: gameControllerOwnerID)'; then
  echo "FAIL: Vision keeps controller input while immersive opening starts" >&2
  fail=1
fi
if [ -e "$APPLE_DIR/Peel/PeelVisionGameControllerInput.swift" ]; then
  echo "FAIL: old Vision-only controller adapter still present" >&2
  fail=1
fi
[ "$fail" -eq 0 ] && echo "Controller source checks passed"
exit "$fail"
