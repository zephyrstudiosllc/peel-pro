#!/usr/bin/env python3
"""Build only; never launch, install or authorize the visible fixture."""
import argparse
from pathlib import Path
import plistlib
import subprocess
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True, help='New absent .app path in a temporary/validation folder')
a = p.parse_args()
app = a.output.expanduser().resolve()
if app.exists() or app.suffix != '.app': p.error('output must be a new absent .app path')
(app / 'Contents/MacOS').mkdir(parents=True)
info = {'CFBundleIdentifier': 'org.peel.fixture.agent-control', 'CFBundleName': 'Peel Agent Control Fixture',
        'CFBundleExecutable': 'Fixture', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication', 'LSMinimumSystemVersion': '14.0'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-strict-concurrency=complete', '-warnings-as-errors', str(Path(__file__).with_name('VisibleFixture.swift')),
    '-o', str(app / 'Contents/MacOS/Fixture')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
print('Built only. Parent review/authorization required before launch and real input acceptance.')
