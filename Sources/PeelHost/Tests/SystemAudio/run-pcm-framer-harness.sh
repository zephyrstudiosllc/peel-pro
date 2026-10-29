#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peel-system-audio.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

swiftc \
  "${REPO_ROOT}/Peel-Host/Audio/PeelPCMChunkFramer.swift" \
  "${SCRIPT_DIR}/PCMFramerHarness.swift" \
  -o "${BUILD_DIR}/pcm-framer-harness"

"${BUILD_DIR}/pcm-framer-harness" "${SCRIPT_DIR}/Fixtures"
