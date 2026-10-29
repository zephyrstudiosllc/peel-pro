#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
sources = [root / path for path in (
    "Sources/PeelHost/Peel-Host/PeelTLS.swift",
    "Sources/PeelHost/Peel-Host/PeelICloudPairing.swift",
    "Sources/PeelApple/Shared/All/PeelICloudEnrollmentTransport.swift",
    "Integration/PeelRemoteMacAddressStore.swift",
    "Integration/PeelICloudMacPairingController.swift",
)]
with tempfile.TemporaryDirectory(prefix="peel-icloud-mac-tests-") as temporary:
    executable = pathlib.Path(temporary) / "checks"
    subprocess.run(["swiftc", "-parse-as-library", *map(str, sources),
                    str(pathlib.Path(__file__).with_name("main.swift")), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
