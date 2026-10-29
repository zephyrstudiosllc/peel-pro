#!/usr/bin/env python3
"""Validate public monorepo source layout without builds or network access."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    "LICENSE", "THIRD_PARTY_NOTICES.md",
    "Sources/PeelHost/Peel-Host.xcodeproj/project.pbxproj",
    "Sources/PeelHost/Notices/WhichSpace-LICENSE.txt",
    "Sources/PeelApple/Peel.xcodeproj/project.pbxproj",
    "Sources/PeelApple/Shared/Client/Shell/Package.swift",
    "Sources/PeelApple/Shared/WatchCompanion/Package.swift",
    "Sources/PeelWindows/Peel.Windows.slnx",
    "Sources/SidePulse/LICENSE", "Sources/SidePulse/NOTICE",
    "Sources/CodexBar/Package.swift", "Sources/CodexBar/LICENSE",
    "Sources/CodexBar/Sources/CQuickJS/LICENSE",
    "Sources/CodexBar/docs/THIRD_PARTY_LICENSES.md",
    "Tools/PeelMCP/peel_mcp_server.py",
    "Apps/Peel/Integration/PeelUsageCommand.swift", "Integration/PeelUnifiedModel.swift",
]

def main():
    failures = []
    data = json.loads((ROOT / "components.json").read_text())
    if data.get("layout") != "monorepo":
        failures.append("components.json must describe a monorepo")
    seen = set()
    for component in data["components"]:
        relative = component["path"]
        path = ROOT / relative
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT) or relative in seen:
            failures.append("invalid or duplicate component path: " + relative)
        elif not path.is_dir():
            failures.append("missing component: " + relative)
        elif (path / ".git").exists():
            failures.append("nested Git metadata: " + relative)
        seen.add(relative)
    for relative in REQUIRED:
        if not (ROOT / relative).is_file():
            failures.append("missing source/license input: " + relative)
    if (ROOT / ".gitmodules").exists():
        failures.append("public source must not depend on private submodules")
    if (ROOT / ".git").exists():
        records = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "--stage", "-z"], text=True)
        for record in records.split(chr(0)):
            if record.startswith("160000 "):
                failures.append("Git submodule entry: " + record.split(chr(9), 1)[-1])
        names = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z"], text=True)
        for name in filter(None, names.split(chr(0))):
            path = ROOT / name
            if path.is_symlink() and not path.resolve().is_relative_to(ROOT):
                failures.append("symlink escapes repository: " + name)
    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    if failures:
        return 1
    print(f"OK: {len(seen)} in-tree components; source/notices present; no private submodules.")
    print("Source layout only; no build, runtime, signing or device claim.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
