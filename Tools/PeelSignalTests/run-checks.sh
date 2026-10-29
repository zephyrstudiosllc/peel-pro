#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-signal-checks.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
 "$workspace_dir/Integration/PeelTrustedSidePulseContract.swift" \
 "$script_dir/PeelTrustedSidePulseContractChecks.swift" -o "$work_dir/checks"
"$work_dir/checks"
