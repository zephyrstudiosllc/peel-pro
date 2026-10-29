#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CORE_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peel-audio-ring.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

CC=${CC:-cc}

"$CC" \
    -std=c11 \
    -pedantic \
    -Wall \
    -Wextra \
    -Werror \
    -DPEEL_AUDIO_RING_TESTING=1 \
    -I"$CORE_DIR" \
    "$CORE_DIR/PeelAudioRing.c" \
    "$SCRIPT_DIR/PeelAudioRingTests.c" \
    -pthread \
    -o "$BUILD_DIR/PeelAudioRingTests"

"$BUILD_DIR/PeelAudioRingTests"
