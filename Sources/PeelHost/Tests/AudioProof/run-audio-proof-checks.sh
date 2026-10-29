#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
binary=$(mktemp "${TMPDIR:-/tmp}/peel-audio-proof.XXXXXX")
trap 'rm -f "$binary"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    "$repo_dir/Peel-Host/PeelSharedMessages.swift" \
    "$repo_dir/Tests/AudioProof/PeelAudioProofAdmissionChecks.swift" -o "$binary"
"$binary"
