#!/usr/bin/env python3
"""Regenerate the app resource from the reviewed, verbatim license files."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
resource = root / "Sources/PeelShellUI/Resources/ThirdPartyNotices.txt"
parts = ["Peel manual shell — open-source notices\n\n"
         "Adapted from OrcheSSHtra (Conductor), commit 7add890ce1897a75f23ba8da41f1c83e1dcf1179.\n"
         "Dependency revisions are recorded in dependency-pins.json.\n"]
for notice in sorted((root / "Notices").glob("*.txt")):
    parts.append("\n" + "=" * 72 + "\n" + notice.name + "\n" + "=" * 72 + "\n\n" + notice.read_text())
resource.parent.mkdir(parents=True, exist_ok=True)
resource.write_text("\n".join(parts))
