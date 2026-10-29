# Disposable Xcode StoreKit lifecycle test

Run from the workspace root with Xcode, the iOS 27.0 simulator runtime, XcodeGen and
Python 3 available:

```sh
python3 Tools/PeelPurchaseTests/XcodeHarness/run-xcode-tests.py
```

The runner creates a new iPhone 17e simulator with a random name and UUID. It
never accepts an existing device, clones one, or installs a daily Peel build.
It generates a separate application-hosted XCTest project under an ignored
`.build/storekit-xctest-<random>/` directory. The real
`Sources/PeelApple/Shared/Client/PeelLegacyPurchasePolicy.swift` is referenced
directly and its source hash is recorded in the manifest. No release Xcode
project or source is changed.

The only product is `dev.peel.disposable.fixture.lifetime`, defined locally in
`LocalPurchases.storekit`; its nominal fixture price is not Peel pricing. Both
app and test bundles use dedicated `dev.peel.disposable.storekit.*` identifiers.
The tests require the exact generated simulator UUID, disposable name prefix,
expected app bundle and `.xcode` StoreKit transaction environment. No Apple
Account, production product, sandbox account, receipt upload or real charge is
used. No `clearTransactions` or environment reset API is called.

The runner builds once with two jobs and disables parallel tests. Three distinct
`xcodebuild test-without-building` invocations, with explicit fixture-host
termination between them, exercise actual process relaunches:

1. Start transaction observation before purchase as a positive notification
   control. Create a local test purchase; require verified `Transaction.latest`, matching
   `currentEntitlements`, actual reducer grant and persisted record.
2. Start observation before restore or current-entitlement queries. Reload the
   record in a new process; call local `AppStore.sync` and preserve
   the purchase; refund through `SKTestSession`; require verified
   `Transaction.updates`, empty current entitlements and revoked latest result;
   deny the old grant and stale pre-refund replay; persist revocation.
3. Reload revocation in a new process; restore cannot resurrect it; make a
   distinct new verified local purchase and grant it; replaying the old refund
   must preserve that distinct purchase.

Each phase produces a log and `.xcresult`; `manifest.json` records the simulator,
source hash and completed phases. The simulator is shut down at the end and is
retained for inspection. Generated outputs are local artifacts, not repository
source. A failed phase normally stops the run. If a purchase/refund update
delivery check fails but the same phase independently verifies the latest
transaction and persists the expected grant/revocation, the runner continues
the restart checks while retaining the delivery failure and a failing overall
exit status. Per-event diagnostics include verification status, fixture product,
transaction ID, environment and revocation status; they omit receipts and JWS
payloads. The runner never substitutes fabricated transactions or pure policy
results for StoreKit evidence.

This is local StoreKit Testing in Xcode, not App Store sandbox or backend
acceptance. It does not cover live delivery timing, customer account switching,
Family Sharing, production receipts, connectivity failures, trial duration,
renewal/grace behavior or the entire `PeelStore` UI adapter.

Apple references: [StoreKit Test](https://developer.apple.com/documentation/storekittest),
[StoreKit testing setup](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode),
[SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession),
[XCTest targets](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project).
