"""Absolute-path entry for an isolated Python process."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from peel_commerce.worker import main

raise SystemExit(main())
