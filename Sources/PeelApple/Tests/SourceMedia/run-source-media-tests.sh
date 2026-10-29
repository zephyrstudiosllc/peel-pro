#!/bin/sh
# Source-media client checks. Root owns running these; nothing here opens a
# socket, touches audio or needs a device.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APPLE_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TEMP_BINARY=$(mktemp "${TMPDIR:-/tmp}/peel-source-media-client.XXXXXX")
trap 'rm -f "$TEMP_BINARY"' EXIT HUP INT TERM

xcrun swiftc \
  -swift-version 5 \
  -default-isolation MainActor \
  -strict-concurrency=complete \
  -parse-as-library \
  "$APPLE_DIR/Shared/All/PeelSourceMediaMessages.swift" \
  "$APPLE_DIR/Shared/Client/PeelSourceMediaController.swift" \
  "$SCRIPT_DIR/PeelSourceMediaClientHarness.swift" \
  -o "$TEMP_BINARY"
"$TEMP_BINARY"
python3 -I "$SCRIPT_DIR/check-routing.py" --source-root "$APPLE_DIR"
