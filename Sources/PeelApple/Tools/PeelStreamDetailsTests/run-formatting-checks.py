#!/usr/bin/env python3
"""Compile the actual SwiftUI row value expression and its production formatter."""
import argparse
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=pathlib.Path, default=ROOT / "Shared/Client/PeelStreamDetailsView.swift")
args = parser.parse_args()
source = args.source.read_text()
matches = re.findall(r'^[ \t]*detail\("Decoder frame drops", (.+), id: "decoderDrops"\)$', source, re.MULTILINE)
if len(matches) != 1:
    raise SystemExit("Decoder drop display row changed; review the exact-expression extraction")
marker = "nonisolated enum PeelStreamDetailsFormatting {"
if source.count(marker) > 1:
    raise SystemExit("Formatter boundary is ambiguous")
formatter = source[source.index(marker):] if marker in source else ""
fixture = ROOT / "Tools/PeelStreamDetailsTests/StreamDetailsFormattingChecks.swift"
unit = "import Foundation\n" + formatter + "\nfunc actualDecoderDropRow(_ metric: FixtureMetric) -> String {\n    " + matches[0] + "\n}\n" + fixture.read_text()
with tempfile.TemporaryDirectory(prefix="peel-stream-details-") as directory:
    path = pathlib.Path(directory)
    (path / "Checks.swift").write_text(unit)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-strict-concurrency=complete", "-warnings-as-errors",
                    str(ROOT / "Shared/All/PeelStreamDiagnosticsMessages.swift"), str(path / "Checks.swift"),
                    "-o", str(path / "checks")], check=True)
    subprocess.run([str(path / "checks")], check=True)
