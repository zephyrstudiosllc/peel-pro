#!/usr/bin/env python3
"""Run production Host trust-policy checks without live credentials or networking."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="peel-icloud-host-tests-") as temporary:
    executable = pathlib.Path(temporary) / "checks"
    sources = [root / "Peel-Host" / name for name in (
        "PeelTLS.swift", "PeelICloudPairing.swift", "PeelICloudHostPairingController.swift")]
    subprocess.run(["swiftc", *map(str, sources), str(pathlib.Path(__file__).with_name("main.swift")),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
