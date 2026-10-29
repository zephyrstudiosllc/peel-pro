#!/bin/sh
set -eu

# Typechecks the real CoreAudio backend with its controller and messages
# (no binary, no device access). The behaviour harness uses a fake instead.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOST_DIR="$SCRIPT_DIR/../../Peel-Host"

xcrun swiftc \
  -typecheck \
  -swift-version 5 \
  -warnings-as-errors \
  -default-isolation MainActor \
  -strict-concurrency=complete \
  "$HOST_DIR/PeelSourceMediaMessages.swift" \
  "$HOST_DIR/PeelHost/PeelSourceMediaController.swift" \
  "$HOST_DIR/PeelHost/PeelSourceVolume.swift" \
  "$SCRIPT_DIR/PeelSourceVolumeTypecheckStub.swift"
