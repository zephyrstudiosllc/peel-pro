#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
driver_dir="$(cd -- "${script_dir}/.." && pwd)"
core_dir="$(cd -- "${driver_dir}/../Core" && pwd)"
build_dir="${TMPDIR:-/tmp}/peel-remote-microphone-driver-tests"
compiler="${CC:-cc}"

mkdir -p "${build_dir}"

"${compiler}" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -pedantic \
    -I"${core_dir}" \
    -I"${driver_dir}" \
    "${core_dir}/PeelAudioRing.c" \
    "${driver_dir}/PeelRemoteMicrophoneIO.c" \
    "${script_dir}/PeelRemoteMicrophoneIOTests.c" \
    -lm \
    -o "${build_dir}/PeelRemoteMicrophoneIOTests"

"${build_dir}/PeelRemoteMicrophoneIOTests"

"${compiler}" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -pedantic \
    -I"${driver_dir}" \
    "${driver_dir}/ProducerProtocol.c" \
    "${script_dir}/ProducerProtocolTests.c" \
    -o "${build_dir}/ProducerProtocolTests"

"${build_dir}/ProducerProtocolTests"

"${compiler}" \
    -std=c11 \
    -Wall \
    -Wextra \
    -Werror \
    -pedantic \
    -I"${driver_dir}" \
    -I"${core_dir}" \
    "${core_dir}/PeelAudioRing.c" \
    "${driver_dir}/ProducerLifecycle.c" \
    "${script_dir}/ProducerLifecycleTests.c" \
    -o "${build_dir}/ProducerLifecycleTests"

"${build_dir}/ProducerLifecycleTests"
