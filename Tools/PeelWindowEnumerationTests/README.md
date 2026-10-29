# AX identity-map regression

Run `python3 Tools/PeelWindowEnumerationTests/run-checks.py`. Use `--source` to
run the same fixture against a saved WindowEnumerator baseline. The runner
extracts all four actual identity-collection/attribute/filter methods and the
existing exact-focus CG identity resolver unchanged, and compiles them with
controlled AX replies under strict Swift 6 checking. Native AX calls are stubbed.

Unknown and partial IDs are distinct from a known empty eligible-window list.
A complete map continues to reject nonmembers and minimized IDs. An empty or
minimized-only AX window list still rejects every candidate. AX read failure
keeps the existing fallback, and invalid/duplicate/boundary IDs are covered.
The old source compiles but fails unknown/partial/out-of-range cases.
The primary resolver must preserve exact ID filtering even when AXWindowNumber
is absent. Zero/failed primary results fall back to the attribute; only failure
of both resolvers creates an incomplete map. No new private system API is added:
enumeration reuses the resolver that exact input focus already uses.
Zero is never a valid CG window ID in either resolver. Failed or zero primary
results paired with a zero attribute retain the unknown-map fallback.

The fallback only defers to the existing CG window layer/application, scope,
sharing, alpha, bounds/size and visible-pixel filters; those filters are unchanged
and not mocked by this fixture. Runtime stage-count and owned-window acceptance
are separate evidence. Tests access no real app, screenshot, input or permission.
