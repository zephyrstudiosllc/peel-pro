#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MESSAGES_FILE="$SCRIPT_DIR/../../Peel-Host/PeelSourceMediaMessages.swift"
CONTROLLER_FILE="$SCRIPT_DIR/../../Peel-Host/PeelHost/PeelSourceMediaController.swift"
HARNESS_FILE="$SCRIPT_DIR/PeelSourceMediaHarness.swift"
TEMP_BINARY=$(mktemp "${TMPDIR:-/tmp}/peel-source-media-tests.XXXXXX")
trap 'rm -f "$TEMP_BINARY"' EXIT HUP INT TERM

xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -default-isolation MainActor \
  -strict-concurrency=complete \
  -parse-as-library \
  "$MESSAGES_FILE" \
  "$CONTROLLER_FILE" \
  "$HARNESS_FILE" \
  -o "$TEMP_BINARY"
"$TEMP_BINARY"
