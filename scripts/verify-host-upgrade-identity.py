#!/usr/bin/env python3
"""Read-only upgrade identity check; does not inspect Keychain items or permissions.

Passing proves the candidate satisfies a hash-anchored working app's designated
requirement. It does not prove Keychain authorization or replace package/profile,
notarization, normal startup, or device acceptance checks.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def public_command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Code signature or upgrade identity verification failed")
    return result.stdout + "\n" + result.stderr


def executable_digest(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError("App must be an existing real bundle directory")
    info_path = app / "Contents/Info.plist"
    if info_path.is_symlink():
        raise ValueError("App Info.plist must not be a symlink")
    info = plistlib.loads(info_path.read_bytes())
    name = info.get("CFBundleExecutable", "")
    if not isinstance(name, str) or not name or name in (".", "..") or "/" in name:
        raise ValueError("Invalid app executable name")
    executable = app / "Contents/MacOS" / name
    if executable.is_symlink() or not executable.is_file():
        raise ValueError("App executable must be a regular file")
    return hashlib.sha256(executable.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-app", type=Path, required=True)
    parser.add_argument("--candidate-app", type=Path, required=True)
    parser.add_argument("--previous-executable-sha256", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.previous_executable_sha256):
        raise ValueError("Expected working-app executable SHA256 is required")
    if not args.previous_app.is_absolute() or not args.candidate_app.is_absolute():
        raise ValueError("Use absolute app paths")
    if not args.receipt.is_absolute() or args.receipt.exists() or args.receipt.is_symlink():
        raise ValueError("Receipt must be an absent absolute path")

    baseline_digest = executable_digest(args.previous_app)
    if baseline_digest != args.previous_executable_sha256.lower():
        raise ValueError("Working-app executable does not match the selected baseline")
    candidate_digest = executable_digest(args.candidate_app)
    for app in (args.previous_app, args.candidate_app):
        public_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    output = public_command(["/usr/bin/codesign", "-d", "-r-", str(args.previous_app)])
    requirements = [line.removeprefix("designated => ") for line in output.splitlines()
                    if line.startswith("designated => ")]
    if len(requirements) != 1 or not requirements[0].strip():
        raise ValueError("Working-app designated requirement is unavailable or ambiguous")
    # Pass the exact existing requirement to Apple's verifier as one argument.
    # Never construct or assign a replacement designated requirement to either app.
    public_command(["/usr/bin/codesign", "--verify", "--strict", "-R",
                    "=" + requirements[0], str(args.candidate_app)])
    receipt = {
        "status": "PASS upgrade designated-requirement compatibility",
        "previousApp": str(args.previous_app),
        "candidateApp": str(args.candidate_app),
        "previousExecutableSHA256": baseline_digest,
        "candidateExecutableSHA256": candidate_digest,
        "previousDesignatedRequirement": requirements[0],
        "limits": "Read-only signature check; no Keychain access/ACL inspection, startup or device acceptance",
    }
    with args.receipt.open("x") as stream:
        json.dump(receipt, stream, indent=2)
        stream.write("\n")
    print(receipt["status"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        print("GATE: " + str(error), file=sys.stderr)
        sys.exit(2)
