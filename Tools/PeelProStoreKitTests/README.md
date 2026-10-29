# Peel Pro native StoreKit validation

Run from the composition root, with Xcode, XcodeGen and the iOS 27.0 runtime:

```sh
python3 Tools/PeelProStoreKitTests/run-tests.py
```

The coordinator schedules simulator creation/build/runtime work. Run only when
the assigned simulator lane is available. `--prepare-only` generates the project and
source-hash manifest without creating, booting or running a simulator. Other
installed runtimes can be selected with `--runtime` and `--device-type`.

The runner creates one fresh, uniquely named simulator, an inert fixture app
with a separate bundle ID, and a native XCTest bundle. It freezes unchanged
production `PeelStore`, capability/subscription/legacy policies, the exact
runtime gate extracted from `PeelSharedMessages`, actual product configuration,
and actual configured subscription IDs. The manifest records all source hashes.
Nothing is injected into a shipping application or personal device. StoreKit
must report the `.xcode` environment. No real account credentials or charges are used. The local service supplies
signed transactions. A diagnosed Xcode CLI failure can route PurchaseAction to
unauthenticated sandbox; do not sign in to work around this. Tests never
clear/reset transaction history. The simulator is shut down after the run; it
may be retired after preserving evidence if disk space is low.

The default seven-phase purchase-action suite attempts:

1. Actual StoreKit product loading, USD prices, types, Family Sharing metadata,
   common subscription group/level, monthly/yearly periods, free access and
   first/second flat window / second/third Vision policy boundaries. A simulated
   cancelled purchase grants nothing.
2. The production monthly purchase method unlocks every Pro feature. Cancelling
   auto-renew preserves already-paid access, restore keeps it, and refund
   removes it.
3. The production annual purchase method unlocks the same Pro capabilities;
   forced expiration removes access and restore cannot revive it.
4. A verified local lifetime transaction dated one year ago unlocks the entire
   new Pro set, with no date cutoff. Trying to subscribe when lifetime-owned
   produces no new transaction.
5. A new process restores lifetime ownership from the production cache, then
   verified restore succeeds. A real StoreKit refund update clears cached and
   runtime access without a manually requested refresh.
6. Another new process preserves revocation; restore cannot resurrect it. A
   separate new purchase through the production lifetime method grants Pro and
   survives restoration of history containing the old refund.
7. Refund that synthetic lifetime purchase through StoreKit, verify free access,
   then require the real Ask to Buy pending/declined path to grant nothing.
   This negative scenario is last and does not contaminate the positive chain.

Each phase requires its predecessor's persisted completion marker. A failure
stops later dependent phases. Logs, `.xcresult` bundles and the manifest live
under `.build/pro-storekit-<id>/`; failed checks remain failures. Tests use a
bounded predicate wait for asynchronous StoreKit state, never replace the real
store with fabricated entitlement state, and assert Debug has no paid bypass.
The runner checks the named test, exactly-one-test summary, completion marker
and exit status; `verify-results.py RUN_DIRECTORY` independently audits them.
The simulator is explicitly booted once; the test host is relaunched per phase.
Purchases use the real SwiftUI `PurchaseAction` captured by the fixture's normal
root view, matching the shipping paywall's API path.

`retry-phase-zero.py ORIGINAL_RUN` is a narrowly scoped diagnostic retry for an
initial-phase failure. It retains all failed evidence, reuses that exact owned
simulator and frozen production snapshot, and resets no defaults or StoreKit
history. The actual initial test still requires phase zero and empty purchase
history. Screenshot rendering occurs after purchase interactions, because
the purchase context should remain intact. A later fresh run timed out before
any rendering, disproving the earlier claim that controller replacement alone
explained the failure.

When xcodebuild purchase completion is blocked by local-service routing, run the
separate lifecycle suite:

```sh
python3 Tools/PeelProStoreKitTests/run-tests.py --lifecycle-only
# For an already-owned, failed initial phase with empty history:
python3 Tools/PeelProStoreKitTests/retry-phase-zero.py RUN_DIRECTORY --lifecycle-only
```

This mode runs six phases. Phase 1 tests catalog and free policy only. Phases
2, 3 and 6 use `SKTestSession.buyProduct` to create actual signed Xcode purchases;
all grants, expiration, refund, persisted cache and restore assertions still
exercise the unchanged production store. It does not test completion of the
production purchase action or Ask to Buy. The independent audit reports
`purchaseActionCompletionValidated: false` even if every lifecycle test passes.
The original purchase-action failure remains a failure in its own evidence.

Native service logs from the 28d8 run show Xcode catalog/entitlement requests,
then PurchaseAction entering sandbox authentication with no active account.
[Apple's DTS discussion](https://developer.apple.com/forums/thread/826971)
reports a related xcodebuild StoreKit configuration regression. This supports
an environment-routing diagnosis, not proof of the exact upstream cause or a
successful fix. No StoreKit credentials were provided.

The initial combined lifecycle run's annual scenario failed: requesting yearly
returned the refunded monthly transaction, whose original expiry was still in
the future. No active yearly entitlement was observed. Different-duration,
same-level changes are [scheduled crossgrades](https://developer.apple.com/app-store/subscriptions/);
the exact cause of this refunded-fixture behavior was not established. Do not
report the failed immediate-yearly assumption as a product defect or a yearly
pass. A future isolated annual scenario should explicitly end the synthetic
monthly period before testing a new yearly grant.

`continue-lifetime.py FAILED_LIFECYCLE_RUN` separately validates three lifetime
scenarios after that precise failure. It verifies the recorded earlier monthly
pass, actual persisted marker 2, revoked signed monthly transaction, and a free
production baseline. It then checks historical lifetime purchase, process
relaunch/restore/refund, and another relaunch/new lifetime grant. It resets no
history. The audit labels this `signed-lifetime-lifecycle`; it cannot turn the
failed annual or PurchaseAction checks into passes.

This validates local StoreKit Testing, not App Store Connect activation, live
cross-platform/family purchases, purchase-sheet UI, subscription/lifetime
double-billing disclosure UI, provider/cloud services, real offline networking,
or actual grace-period delivery. The local Family Sharing flag is catalog
metadata, not evidence that Apple family member transactions were delivered.
Pure policy tests separately cover rejected/unverified input and grace bounds.

Observed Xcode test-service limitation: after a declined Ask to Buy transaction,
a later process launch returned the same transaction as both failed in
`SKTestSession` history and verified, unrevoked and active in
`Transaction.currentEntitlements`. Production correctly honored the verified
StoreKit evidence. An earlier native phase passed immediate pending/declined denial;
cross-launch declined-purchase behavior needs App Store sandbox acceptance. The
failed diagnostic run is retained, not reclassified as a product pass.

Primary API references: [StoreKit Test](https://developer.apple.com/documentation/storekittest),
[SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession).
The installed Xcode SDK headers and Swift interfaces supply the exact APIs used.
