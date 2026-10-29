#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
component_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-sandbox-migration.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

swiftc -swift-version 5 \
  "$component_dir/Peel-Host/Integration/PeelHostSandboxPreferenceMigration.swift" \
  "$script_dir/PeelSandboxPreferenceMigrationModelFixture.swift" \
  "$script_dir/SandboxPreferenceMigrationChecks.swift" \
  -o "$work_dir/migration-checks"
"$work_dir/migration-checks"
