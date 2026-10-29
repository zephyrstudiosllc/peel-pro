#!/bin/sh
set -eu

staging_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
workspace_dir=$(CDPATH= cd -- "$staging_dir/../.." && pwd)
packet_file="$staging_dir/Shared/All/PeelAudioPacket.swift"
helper_file="$staging_dir/Shared/Client/Audio/PeelAudioPlaybackPrimitives.swift"
capture_helper_file="$staging_dir/Shared/Client/Audio/PeelAudioMicrophoneCapturePrimitives.swift"
harness_file="$staging_dir/Tests/AudioPlayback/PeelAudioPlaybackHarness.swift"
output_file="$staging_dir/Tests/AudioPlayback/.peel-audio-playback-tests"

trap 'rm -f "$output_file"' EXIT
swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -default-isolation MainActor \
  "$packet_file" \
  "$helper_file" \
  "$capture_helper_file" \
  "$harness_file" \
  -o "$output_file"
"$output_file"
