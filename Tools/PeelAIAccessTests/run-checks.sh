#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_file="$workspace_dir/Sources/PeelApple/Shared/All/PeelSharedMessages.swift"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-ai-access-checks.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

SOURCE_FILE="$source_file" OUTPUT_FILE="$work_dir/PeelAIFeatureAccess.swift" \
python3 - <<'PY'
from pathlib import Path
import os

source = Path(os.environ["SOURCE_FILE"]).read_text()
def declaration(marker):
    if source.count(marker) != 1:
        raise SystemExit(f"expected exactly one {marker} in {os.environ['SOURCE_FILE']}")
    start = source.index(marker)
    open_brace = source.index("{", start)
    depth = 0
    for index in range(open_brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated declaration: {marker}")

blocks = [declaration("nonisolated enum PeelAIFeatureAccess {"),
          declaration("nonisolated enum PeelManualAgentControl {")]
Path(os.environ["OUTPUT_FILE"]).write_text("import Foundation\n\n" + "\n\n".join(blocks) + "\n")
PY

swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$work_dir/PeelAIFeatureAccess.swift" \
    "$script_dir/PeelAIFeatureAccessChecks.swift" \
    -o "$work_dir/release-checks"
"$work_dir/release-checks"

swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -DDEBUG \
    "$work_dir/PeelAIFeatureAccess.swift" \
    "$script_dir/PeelAIFeatureAccessChecks.swift" \
    -o "$work_dir/debug-checks"
"$work_dir/debug-checks"
