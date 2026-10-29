#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-machine-status.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
swiftc -swift-version 6 -strict-concurrency=complete \
  "$component_dir/Peel-Host/PeelMachineStatusMessages.swift" \
  "$script_dir/MachineStatusMessageChecks.swift" -o "$work_dir/message-checks"
"$work_dir/message-checks"
