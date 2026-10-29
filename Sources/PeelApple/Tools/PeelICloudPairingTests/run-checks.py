#!/usr/bin/env python3
"""Compile actual shared code with fake Keychain operations; no account access."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='peel-icloud-checks-') as temp:
    binary = Path(temp) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    str(root / 'Shared/All/PeelTLS.swift'),
                    str(root / 'Shared/All/PeelICloudPairing.swift'),
                    str(root / 'Shared/All/PeelICloudEnrollmentTransport.swift'),
                    str(Path(__file__).with_name('Checks.swift')), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
