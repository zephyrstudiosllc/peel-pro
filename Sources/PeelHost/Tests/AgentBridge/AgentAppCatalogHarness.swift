import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure(message: message)
    }
}

@MainActor
private final class FakeEnvironment {
    var now: UInt64 = 1_000
    var inventoryCallCount = 0
    var nextIdentifier = 0
    var runningApplications:
        [PeelAgentAppCatalog.RunningApplicationRecord] = []
    var openedURLs: [URL] = []
    var workspaceCompletions:
        [PeelAgentAppCatalog.Dependencies.WorkspaceCompletion] = []
    var deadlineActions:
        [PeelAgentAppCatalog.Dependencies.DeadlineAction] = []

    func dependencies(
        fileManager: FileManager,
        roots: [URL]
    ) -> PeelAgentAppCatalog.Dependencies {
        PeelAgentAppCatalog.Dependencies(
            fileManager: fileManager,
            inventoryRoots: roots,
            runningApplications: {
                self.inventoryCallCount += 1
                return self.runningApplications
            },
            openApplication: { url, completion in
                self.openedURLs.append(url)
                self.workspaceCompletions.append(completion)
            },
            makeOpaqueIdentifier: {
                self.nextIdentifier += 1
                return "fixture-\(self.nextIdentifier)"
            },
            monotonicNow: {
                self.now
            },
            scheduleDeadline: { _, action in
                self.deadlineActions.append(action)
            }
        )
    }
}

private func createFixtureApplication(
    fileManager: FileManager,
    at url: URL,
    bundleIdentifier: String,
    displayName: String,
    backgroundOnly: Bool = false
) throws {
    let contents = url.appendingPathComponent(
        "Contents",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: contents,
        withIntermediateDirectories: true
    )
    var propertyList: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleName": displayName,
        "CFBundleDisplayName": displayName,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1"
    ]
    if backgroundOnly {
        propertyList["LSUIElement"] = true
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .xml,
        options: 0
    )
    try data.write(
        to: contents.appendingPathComponent("Info.plist"),
        options: .atomic
    )
}

private func successfulInventory(
    _ result: PeelAgentAppInventoryResult
) throws -> PeelAgentAppInventory {
    switch result {
    case .success(let inventory):
        return inventory
    case .failure(let error):
        throw TestFailure(
            message: "inventory failed unexpectedly: \(error)"
        )
    }
}

@MainActor
private func settleMainActor() async {
    await Task.yield()
    await Task.yield()
}

@MainActor
private func testInventoryBoundsAndNoInitializationScan() throws -> (
    PeelAgentAppCatalog,
    FakeEnvironment,
    PeelAgentAppInventory,
    URL
) {
    let fileManager = FileManager.default
    let temporary = fileManager.temporaryDirectory.appendingPathComponent(
        "peel-agent-app-catalog-\(UUID().uuidString)",
        isDirectory: true
    )
    let root = temporary.appendingPathComponent("Root", isDirectory: true)
    let outside = temporary.appendingPathComponent(
        "Outside",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: outside,
        withIntermediateDirectories: true
    )

    let direct = root.appendingPathComponent(
        "Direct.app",
        isDirectory: true
    )
    let nested = root
        .appendingPathComponent("Group", isDirectory: true)
        .appendingPathComponent("Nested.app", isDirectory: true)
    let tooDeep = root
        .appendingPathComponent("One", isDirectory: true)
        .appendingPathComponent("Two", isDirectory: true)
        .appendingPathComponent("TooDeep.app", isDirectory: true)
    let background = root.appendingPathComponent(
        "Background.app",
        isDirectory: true
    )
    let runningOnly = outside.appendingPathComponent(
        "RunningOnly.app",
        isDirectory: true
    )
    let symlinkTarget = outside.appendingPathComponent(
        "SymlinkTarget",
        isDirectory: true
    )
    let symlinkOnly = symlinkTarget.appendingPathComponent(
        "SymlinkOnly.app",
        isDirectory: true
    )

    try createFixtureApplication(
        fileManager: fileManager,
        at: direct,
        bundleIdentifier: "test.peel.Direct",
        displayName: "Direct"
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: nested,
        bundleIdentifier: "test.peel.Nested",
        displayName: "Nested"
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: tooDeep,
        bundleIdentifier: "test.peel.TooDeep",
        displayName: "Too Deep"
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: background,
        bundleIdentifier: "test.peel.Background",
        displayName: "Background",
        backgroundOnly: true
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: runningOnly,
        bundleIdentifier: "test.peel.RunningOnly",
        displayName: "Running Only"
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: symlinkOnly,
        bundleIdentifier: "test.peel.SymlinkOnly",
        displayName: "Symlink Only"
    )
    try fileManager.createSymbolicLink(
        at: root.appendingPathComponent("Linked", isDirectory: true),
        withDestinationURL: symlinkTarget
    )

    let environment = FakeEnvironment()
    environment.runningApplications = [
        .init(
            bundleURL: direct,
            bundleIdentifier: "test.peel.Direct",
            processIdentifier: 111
        ),
        .init(
            bundleURL: runningOnly,
            bundleIdentifier: "test.peel.RunningOnly",
            processIdentifier: 222
        )
    ]
    let catalog = PeelAgentAppCatalog(
        dependencies: environment.dependencies(
            fileManager: fileManager,
            roots: [root]
        )
    )
    try expect(
        environment.inventoryCallCount == 0,
        "init must not scan"
    )

    let inventory = try successfulInventory(catalog.inventory())
    try expect(
        environment.inventoryCallCount == 1,
        "explicit inventory must scan once"
    )
    try expect(
        inventory.applications.count == 3,
        "only direct, depth-two, and running-only apps should appear"
    )
    let byBundleID = Dictionary(
        uniqueKeysWithValues: inventory.applications.map {
            ($0.bundleIdentifier, $0)
        }
    )
    try expect(
        byBundleID["test.peel.Direct"]?.runningProcessIdentifier == 111,
        "running PID must merge into installed app"
    )
    try expect(
        byBundleID["test.peel.RunningOnly"]?
            .runningProcessIdentifier == 222,
        "known running bundle URL may contribute an app"
    )
    try expect(
        byBundleID["test.peel.Nested"] != nil,
        "depth-two app must appear"
    )
    try expect(
        byBundleID["test.peel.TooDeep"] == nil &&
        byBundleID["test.peel.SymlinkOnly"] == nil &&
        byBundleID["test.peel.Background"] == nil,
        "deep, symlink-recursed, and background-only apps must be absent"
    )
    try expect(
        inventory.applications.allSatisfy {
            $0.id.hasPrefix("fixture-") &&
            !$0.id.contains($0.bundleIdentifier)
        },
        "inventory IDs must be opaque"
    )
    return (catalog, environment, inventory, temporary)
}

@MainActor
private func testLaunchCompletionAndCurrentInventory() async throws {
    let (catalog, environment, inventory, temporary) =
        try testInventoryBoundsAndNoInitializationScan()
    defer {
        try? FileManager.default.removeItem(at: temporary)
    }
    guard let application = inventory.applications.first(where: {
        $0.bundleIdentifier == "test.peel.Direct"
    }) else {
        throw TestFailure(message: "missing direct fixture")
    }

    var results: [PeelAgentAppLaunchResult] = []
    catalog.launch(
        applicationID: application.id,
        deadlineUptimeNanoseconds: 2_000
    ) {
        results.append($0)
    }
    try expect(
        environment.openedURLs.count == 1,
        "accepted launch must invoke only the fake opener"
    )
    try expect(
        results.isEmpty,
        "workspace completion must remain asynchronous"
    )
    environment.workspaceCompletions[0](333, nil)
    await settleMainActor()
    try expect(
        results == [.launched(
            applicationID: application.id,
            processIdentifier: 333
        )],
        "fake workspace success must complete once"
    )

    let replacementInventory =
        try successfulInventory(catalog.inventory())
    try expect(
        replacementInventory.generation != inventory.generation,
        "inventory generation must advance"
    )
    var staleResult: PeelAgentAppLaunchResult?
    catalog.launch(
        applicationID: application.id,
        deadlineUptimeNanoseconds: 2_000
    ) {
        staleResult = $0
    }
    try expect(
        staleResult == .failure(
            .applicationIDNotInCurrentInventory
        ),
        "old inventory ID must be rejected"
    )
}

@MainActor
private func testIdentityCancellationDeadlineAndSingleFlight()
async throws {
    let (catalog, environment, inventory, temporary) =
        try testInventoryBoundsAndNoInitializationScan()
    defer {
        try? FileManager.default.removeItem(at: temporary)
    }
    guard let direct = inventory.applications.first(where: {
        $0.bundleIdentifier == "test.peel.Direct"
    }) else {
        throw TestFailure(message: "missing direct fixture")
    }

    var firstResults: [PeelAgentAppLaunchResult] = []
    catalog.launch(
        applicationID: direct.id,
        deadlineUptimeNanoseconds: 2_000
    ) {
        firstResults.append($0)
    }
    var busyResult: PeelAgentAppLaunchResult?
    catalog.launch(
        applicationID: direct.id,
        deadlineUptimeNanoseconds: 2_000
    ) {
        busyResult = $0
    }
    try expect(
        busyResult == .failure(.launchInProgress),
        "second launch must be rejected"
    )
    try expect(catalog.cancelLaunch(), "pending launch must cancel")
    try expect(
        firstResults == [.failure(.cancelled)],
        "cancel must complete exactly once"
    )
    environment.workspaceCompletions[0](444, nil)
    await settleMainActor()
    try expect(
        firstResults == [.failure(.cancelled)],
        "late workspace completion must be generation-stale"
    )

    guard let current = try successfulInventory(
        catalog.inventory()
    ).applications.first(where: {
        $0.bundleIdentifier == "test.peel.Direct"
    }) else {
        throw TestFailure(message: "missing refreshed direct fixture")
    }
    var deadlineResults: [PeelAgentAppLaunchResult] = []
    catalog.launch(
        applicationID: current.id,
        deadlineUptimeNanoseconds: 2_000
    ) {
        deadlineResults.append($0)
    }
    environment.now = 2_000
    environment.deadlineActions.last?()
    await settleMainActor()
    try expect(
        deadlineResults == [.failure(.deadlineExceeded)],
        "original monotonic deadline must win"
    )
    environment.workspaceCompletions.last?(555, nil)
    await settleMainActor()
    try expect(
        deadlineResults.count == 1,
        "late completion after deadline must be ignored"
    )

    let directURL = temporary
        .appendingPathComponent("Root", isDirectory: true)
        .appendingPathComponent("Direct.app", isDirectory: true)
    try FileManager.default.removeItem(at: directURL)
    try createFixtureApplication(
        fileManager: .default,
        at: directURL,
        bundleIdentifier: "test.peel.Direct",
        displayName: "Replacement"
    )
    guard let identityEntry = try successfulInventory(
        catalog.inventory()
    ).applications.first(where: {
        $0.bundleIdentifier == "test.peel.Direct"
    }) else {
        throw TestFailure(message: "missing identity fixture")
    }
    try FileManager.default.removeItem(at: directURL)
    try createFixtureApplication(
        fileManager: .default,
        at: directURL,
        bundleIdentifier: "test.peel.Direct",
        displayName: "Changed Again"
    )
    let openerCount = environment.openedURLs.count
    var identityResult: PeelAgentAppLaunchResult?
    environment.now = 3_000
    catalog.launch(
        applicationID: identityEntry.id,
        deadlineUptimeNanoseconds: 4_000
    ) {
        identityResult = $0
    }
    try expect(
        identityResult == .failure(.applicationIdentityChanged),
        "replaced bundle inode must fail revalidation"
    )
    try expect(
        environment.openedURLs.count == openerCount,
        "identity failure must not reach even the fake opener"
    )
}

/// Stands in for a metadata read that stalls off the main actor. Records the
/// inspection order; blocks inspecting "Aaa Slow.app" while `blocking`.
private nonisolated final class InspectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var blocking = false
    let reachedSlow = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var order: [String] { lock.withLock { recorded } }
    func setBlocking(_ value: Bool) { lock.withLock { blocking = value } }

    func willInspect(_ url: URL) {
        let name = url.lastPathComponent
        let block = lock.withLock { () -> Bool in
            recorded.append(name)
            return blocking && name == "Aaa Slow.app"
        }
        if block {
            reachedSlow.signal()
            release.wait()
        }
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw TestFailure(message: "condition not reached")
}

@MainActor
private func makeQueryFixture() throws -> (
    PeelAgentAppCatalog, FakeEnvironment, InspectionGate, URL
) {
    let fileManager = FileManager.default
    let temporary = fileManager.temporaryDirectory.appendingPathComponent(
        "peel-agent-app-query-\(UUID().uuidString)",
        isDirectory: true
    )
    let root = temporary.appendingPathComponent("Root", isDirectory: true)
    // Sorted first, so an unprioritized scan would stall before Settings.
    try createFixtureApplication(
        fileManager: fileManager,
        at: root.appendingPathComponent("Aaa Slow.app", isDirectory: true),
        bundleIdentifier: "test.peel.Slow",
        displayName: "Slow"
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: root.appendingPathComponent("System Settings.app", isDirectory: true),
        bundleIdentifier: "test.peel.Settings",
        displayName: "System Settings"
    )
    try createFixtureApplication(
        fileManager: fileManager,
        at: root
            .appendingPathComponent("Utilities", isDirectory: true)
            .appendingPathComponent("Terminal.app", isDirectory: true),
        bundleIdentifier: "test.peel.Terminal",
        displayName: "Terminal"
    )
    let environment = FakeEnvironment()
    let gate = InspectionGate()
    var dependencies = environment.dependencies(
        fileManager: fileManager,
        roots: [root]
    )
    dependencies.willInspectApplication = { gate.willInspect($0) }
    return (
        PeelAgentAppCatalog(dependencies: dependencies),
        environment, gate, temporary
    )
}

/// Request deadline three seconds after the fake now; budget ends 400 ms early.
private let queryDeadline: UInt64 = 1_000 + 3_000_000_000
private let queryBudgetEnd: UInt64 = queryDeadline - 400_000_000

@MainActor
private func testColdQueryOffMainAndStalledUnrelatedBundle() async throws {
    let (catalog, environment, gate, temporary) = try makeQueryFixture()
    defer { try? FileManager.default.removeItem(at: temporary) }

    // Cold, unblocked: the whole root completes and is not truncated.
    var cold: [PeelAgentAppInventoryResult] = []
    catalog.inventory(
        query: "",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { cold.append($0) }
    try expect(cold.isEmpty, "query results must not be published synchronously")
    try await waitUntil { !cold.isEmpty }
    let full = try successfulInventory(cold[0])
    try expect(
        !full.isTruncated &&
        Set(full.applications.map(\.bundleIdentifier)) ==
            ["test.peel.Slow", "test.peel.Settings", "test.peel.Terminal"],
        "cold query must complete with every app, including nested ones"
    )
    try await waitUntil { catalog.outstandingQueryScans == 0 }

    // Stalled unrelated bundle: the matching app is still inspected first
    // and published at the budget, honestly truncated.
    gate.setBlocking(true)
    var results: [PeelAgentAppInventoryResult] = []
    catalog.inventory(
        query: "Settings",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { results.append($0) }
    try expect(
        gate.reachedSlow.wait(timeout: .now() + 5) == .success,
        "scan must reach the stalled bundle off the main actor"
    )
    let settingsIndex = gate.order.lastIndex(of: "System Settings.app")
    let slowIndex = gate.order.lastIndex(of: "Aaa Slow.app")
    try expect(
        settingsIndex != nil && slowIndex != nil && settingsIndex! < slowIndex!,
        "a matching name must be inspected before an unrelated bundle"
    )
    try expect(results.isEmpty, "nothing publishes before the budget")
    environment.now = queryBudgetEnd
    environment.deadlineActions.last?()
    await settleMainActor()
    try expect(results.count == 1, "budget must publish exactly once")
    let partial = try successfulInventory(results[0])
    try expect(
        partial.isTruncated &&
        partial.applications.map(\.bundleIdentifier) == ["test.peel.Settings"],
        "budget publication must be truncated and hold only inspected apps"
    )
    try expect(
        partial.generation != full.generation,
        "a published query advances the generation"
    )

    // Only the published ID launches, still with identity revalidation.
    var launchResult: PeelAgentAppLaunchResult?
    catalog.launch(
        applicationID: full.applications[0].id,
        deadlineUptimeNanoseconds: queryDeadline
    ) { launchResult = $0 }
    try expect(
        launchResult == .failure(.applicationIDNotInCurrentInventory),
        "IDs from the superseded inventory must not launch"
    )
    catalog.launch(
        applicationID: partial.applications[0].id,
        deadlineUptimeNanoseconds: queryDeadline
    ) { launchResult = $0 }
    try expect(
        environment.openedURLs.last?.lastPathComponent == "System Settings.app",
        "the published Settings ID must reach the opener"
    )
    environment.workspaceCompletions.last?(777, nil)
    await settleMainActor()

    // The stalled scan returns late; it must not publish anything.
    gate.release.signal()
    try await waitUntil { catalog.outstandingQueryScans == 0 }
    try expect(results.count == 1, "a late scan must not publish again")
}

@MainActor
private func testQueryStaleGrantCancelSupersedeAndCapacity() async throws {
    let (catalog, environment, gate, temporary) = try makeQueryFixture()
    defer { try? FileManager.default.removeItem(at: temporary) }

    var expired: PeelAgentAppInventoryResult?
    catalog.inventory(
        query: "",
        deadlineUptimeNanoseconds: environment.now,
        isCurrent: { true }
    ) { expired = $0 }
    try expect(
        expired == .failure(.deadlineExpired) &&
        catalog.outstandingQueryScans == 0,
        "an expired request must not start a scan"
    )

    var listed: [PeelAgentAppInventoryResult] = []
    catalog.inventory(
        query: "",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { listed.append($0) }
    try await waitUntil { !listed.isEmpty }
    let earlier = try successfulInventory(listed[0])
    try await waitUntil { catalog.outstandingQueryScans == 0 }

    // Grant lost before the budget: no IDs are published.
    gate.setBlocking(true)
    var current = true
    var stale: [PeelAgentAppInventoryResult] = []
    catalog.inventory(
        query: "Settings",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { current }
    ) { stale.append($0) }
    try expect(gate.reachedSlow.wait(timeout: .now() + 5) == .success, "stall 1")
    current = false
    environment.now = queryBudgetEnd
    environment.deadlineActions.last?()
    await settleMainActor()
    try expect(stale == [.failure(.cancelled)], "a stale grant must not publish")

    // A newer query supersedes an older one; Stop cancels and drops IDs.
    environment.now = 1_000
    var older: [PeelAgentAppInventoryResult] = []
    var newer: [PeelAgentAppInventoryResult] = []
    catalog.inventory(
        query: "Settings",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { older.append($0) }
    try expect(gate.reachedSlow.wait(timeout: .now() + 5) == .success, "stall 2")
    catalog.inventory(
        query: "Settings",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { newer.append($0) }
    try expect(older == [.failure(.cancelled)], "a newer query supersedes")
    try expect(gate.reachedSlow.wait(timeout: .now() + 5) == .success, "stall 3")
    try expect(
        catalog.outstandingQueryScans ==
            PeelAgentAppCatalog.maximumOutstandingQueryScans,
        "three stalled scans are outstanding"
    )
    var refused: PeelAgentAppInventoryResult?
    catalog.inventory(
        query: "Settings",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { refused = $0 }
    try expect(
        refused == .failure(.scanCapacityExhausted) && newer.isEmpty,
        "stalled scans bound new work without disturbing the pending query"
    )
    catalog.cancelInventory()
    try expect(newer == [.failure(.cancelled)], "Stop cancels the pending query")
    var afterStop: PeelAgentAppLaunchResult?
    catalog.launch(
        applicationID: earlier.applications[0].id,
        deadlineUptimeNanoseconds: queryDeadline
    ) { afterStop = $0 }
    try expect(
        afterStop == .failure(.applicationIDNotInCurrentInventory),
        "Stop must drop every launchable ID"
    )

    for _ in 0..<3 { gate.release.signal() }
    try await waitUntil { catalog.outstandingQueryScans == 0 }
    environment.deadlineActions.forEach { $0() }
    await settleMainActor()
    try expect(
        stale.count == 1 && older.count == 1 && newer.count == 1 &&
        environment.openedURLs.isEmpty,
        "late scans and timers must not publish or launch"
    )
}

/// Each read advances one second, so a scan exhausts its own budget.
private nonisolated final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
        lock.withLock { () -> UInt64 in value += 1_000_000_000; return value }
    }
}

@MainActor
private func testQueryScanBudgetIsHonest() async throws {
    let (_, environment, gate, temporary) = try makeQueryFixture()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let ticks = Ticks()
    var dependencies = environment.dependencies(
        fileManager: .default,
        roots: [temporary.appendingPathComponent("Root", isDirectory: true)]
    )
    dependencies.willInspectApplication = { gate.willInspect($0) }
    dependencies.scanClock = { ticks.next() }
    let catalog = PeelAgentAppCatalog(dependencies: dependencies)
    var results: [PeelAgentAppInventoryResult] = []
    catalog.inventory(
        query: "Settings",
        deadlineUptimeNanoseconds: queryDeadline,
        isCurrent: { true }
    ) { results.append($0) }
    try await waitUntil { !results.isEmpty }
    let inventory = try successfulInventory(results[0])
    try expect(
        inventory.isTruncated && inventory.applications.count < 3,
        "a scan stopped by its own budget must report truncation"
    )
}

@main
struct AgentAppCatalogHarness {
    @MainActor
    static func main() async {
        do {
            try await testLaunchCompletionAndCurrentInventory()
            try await testIdentityCancellationDeadlineAndSingleFlight()
            try await testColdQueryOffMainAndStalledUnrelatedBundle()
            try await testQueryStaleGrantCancelSupersedeAndCapacity()
            try await testQueryScanBudgetIsHonest()
            print("PeelAgentAppCatalog tests passed")
        } catch {
            fputs(
                "PeelAgentAppCatalog tests failed: \(error)\n",
                stderr
            )
            exit(1)
        }
    }
}
