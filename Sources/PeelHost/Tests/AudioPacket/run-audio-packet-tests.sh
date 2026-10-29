#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_FILE="$SCRIPT_DIR/../../Peel-Host/Audio/PeelAudioPacket.swift"
HARNESS_FILE="$SCRIPT_DIR/PeelAudioPacketHarness.swift"
TEMP_BINARY=$(mktemp "${TMPDIR:-/tmp}/peel-audio-packet-tests.XXXXXX")
trap 'rm -f "$TEMP_BINARY"' EXIT HUP INT TERM

xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -default-isolation MainActor \
  -strict-concurrency=complete \
  -parse-as-library \
  "$SOURCE_FILE" \
  "$HARNESS_FILE" \
  -o "$TEMP_BINARY"
"$TEMP_BINARY"
