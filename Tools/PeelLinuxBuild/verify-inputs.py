#!/usr/bin/env python3
from pathlib import Path, PurePosixPath
import hashlib, json
root = Path(__file__).resolve().parent
pins = json.loads((root / "SOURCE-MANIFEST.json").read_text())
for name, expected in pins.items():
    relative = PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit("Unsafe source path")
    path = root / "source" / name
    if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit("Source pin mismatch: " + name)
print(f"Verified {len(pins)} exact source inputs; no native execution implied.")
