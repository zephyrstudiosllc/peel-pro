#!/usr/bin/env python3
"""Compile the production content-free receipt and exercise sample boundaries."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = (root / 'Shared/Client/PeelStreamDetailsView.swift').read_text()
marker = 'nonisolated struct PeelStreamDetailsReceipt:'
if source.count(marker) != 1:
    raise SystemExit('Receipt source boundary must be unique')
unit = 'import Foundation\n' + source[source.index(marker):] + '\n' + (root / 'Tools/PeelStreamDetailsTests/StreamDetailsReceiptChecks.swift').read_text()
with tempfile.TemporaryDirectory(prefix='peel-stream-receipt-') as directory:
    path = pathlib.Path(directory)
    (path / 'Checks.swift').write_text(unit)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                    '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-warnings-as-errors',
                    str(root / 'Shared/All/PeelStreamDiagnosticsMessages.swift'), str(path / 'Checks.swift'),
                    '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
