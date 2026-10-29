"""Structural guard; real release-simulator acceptance remains a separate check."""
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "Sources" / "PeelApple"
for relative in ("Peel-iPad/iPadContentView.swift", "Peel/ContentView/ContentView.swift"):
    source = (root / relative).read_text()
    for purchase_readiness in ("hasResolvedAccessState", "isLoadingProducts"):
        assert purchase_readiness not in source, (
            f"Free streaming surface must not wait on commerce: {relative}: {purchase_readiness}"
        )

purchase_ui = (root / "Shared/Client/PaywallView.swift").read_text()
assert "hasResolvedAccessState" in purchase_ui, "Keep ownership-loading feedback in purchase UI"
assert "Checking purchases" in purchase_ui
print("Free startup source boundary: passed (commerce readiness stays in purchase UI)")
