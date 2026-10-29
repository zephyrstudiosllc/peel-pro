"""Source guard for scene launch coverage; this does not simulate restoration."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2] / "Sources" / "PeelApple"
scene = re.compile(r'\b(?:WindowGroup|Window|ImmersiveSpace)\([^\n]*\)\s*\{')
startup = re.compile(r'\.task\s*\{\s*await store\.start\(\)')
checked = 0
for relative in ("Peel-iPad/Peel_iPadApp.swift", "Peel/PeelApp.swift"):
    source = (root / relative).read_text()
    # Mask strings/comments so braces in those cannot affect scope extraction.
    masked = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                    lambda match: " " * len(match.group()), source)
    entries = list(scene.finditer(source))
    assert entries, f"No scene entries detected: {relative}"
    for entry in entries:
        depth = 1
        end = entry.end()
        while depth and end < len(masked):
            depth += (masked[end] == "{") - (masked[end] == "}")
            end += 1
        assert depth == 0, f"Unbalanced scene: {relative}: {entry.group()}"
        body = source[entry.end():end]
        assert startup.search(body), f"Scene must start commerce independently: {relative}: {entry.group()}"
        assert "hasResolvedAccessState" not in body, f"Scene must not wait for commerce: {relative}"
        checked += 1
print(f"Scene startup source boundary: passed ({checked} Apple scene entries)")
