import AppKit
import Foundation

nonisolated struct PeelAgentCatalogApplication: Equatable, Sendable {
    /// Random for one inventory generation. It is not a path or bundle ID.
    let id: String
    let bundleIdentifier: String
    let displayName: String
    let runningProcessIdentifier: Int32?
}

nonisolated struct PeelAgentAppInventory: Equatable, Sendable {
    let generation: UInt64
    let applications: [PeelAgentCatalogApplication]
    let isTruncated: Bool
    let inaccessibleLocationCount: Int
}

nonisolated enum PeelAgentAppInventoryError: Error, Equatable, Sendable {
    case launchInProgress
    case identifierGenerationFailed
    case deadlineExpired
    case cancelled
    /// Earlier off-main scans have not returned (for example, one filesystem
    /// read is stalled); no further scan is started until one does.
    case scanCapacityExhausted
}

nonisolated enum PeelAgentAppInventoryResult: Equatable, Sendable {
    case success(PeelAgentAppInventory)
    case failure(PeelAgentAppInventoryError)
}

nonisolated enum PeelAgentAppLaunchError: Error, Equatable, Sendable {
    case inventoryUnavailable
    case applicationIDNotInCurrentInventory
    case launchInProgress
    case deadlineExpired
    case deadlineTooFar
    case applicationIdentityChanged
    case cancelled
    case deadlineExceeded
    case workspaceFailure(String)
    case workspaceReturnedNoApplication
}

nonisolated enum PeelAgentAppLaunchResult: Equatable, Sendable {
    /// NSWorkspace reported an application. No Peel window is implied.
    case launched(applicationID: String, processIdentifier: Int32?)
    case failure(PeelAgentAppLaunchError)
}

/// Main-thread-owned inventory and launch authority for the local agent bridge.
///
/// Construction has no side effects. The caller must explicitly request an
/// inventory before any opaque application ID can be launched.
@MainActor
final class PeelAgentAppCatalog {
    nonisolated static let maximumApplications = 512
    nonisolated static let maximumFolderDepth = 2
    nonisolated static let maximumVisitedEntries = 8_192
    nonisolated static let maximumLaunchDurationNanoseconds: UInt64 =
        30_000_000_000

    typealias LaunchCompletion =
        @MainActor (PeelAgentAppLaunchResult) -> Void
    typealias InventoryCompletion =
        @MainActor (PeelAgentAppInventoryResult) -> Void

    nonisolated static let maximumOutstandingQueryScans = 3
    /// Kept back from the request deadline to publish on the main actor.
    nonisolated static let queryPublishMarginNanoseconds: UInt64 = 400_000_000
    private nonisolated static let queryScanQueue = DispatchQueue(
        label: "PeelAgentAppCatalog.query-scan",
        qos: .userInitiated,
        attributes: .concurrent
    )

    nonisolated struct RunningApplicationRecord: Sendable {
        let bundleURL: URL
        let bundleIdentifier: String?
        let processIdentifier: Int32
    }

    struct Dependencies {
        typealias WorkspaceCompletion =
            @Sendable (Int32?, String?) -> Void
        typealias WorkspaceOpen =
            @MainActor (URL, @escaping WorkspaceCompletion) -> Void
        typealias RunningApplications =
            @MainActor () -> [RunningApplicationRecord]
        typealias OpaqueIdentifierFactory = @MainActor () -> String
        typealias MonotonicClock = @MainActor () -> UInt64
        typealias DeadlineAction = @Sendable () -> Void
        typealias DeadlineScheduler =
            @MainActor (UInt64, @escaping DeadlineAction) -> Void

        let fileManager: FileManager
        let inventoryRoots: [URL]
        let runningApplications: RunningApplications
        let openApplication: WorkspaceOpen
        let makeOpaqueIdentifier: OpaqueIdentifierFactory
        let monotonicNow: MonotonicClock
        let scheduleDeadline: DeadlineScheduler
        /// Clock read by the off-main query scan for its own budget.
        var scanClock: @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
        /// Called off-main before each query-scan bundle inspection. Tests
        /// use it to observe order or stand in for a stalled metadata read.
        var willInspectApplication: @Sendable (URL) -> Void = { _ in }
    }

    private nonisolated final class FileIdentity: @unchecked Sendable {
        private let value:
            any NSCopying & NSSecureCoding & NSObjectProtocol

        init(_ value: any NSCopying & NSSecureCoding & NSObjectProtocol) {
            self.value = value
        }

        func matches(_ other: FileIdentity) -> Bool {
            value.isEqual(other.value)
        }
    }

    private nonisolated struct InspectedApplication: Sendable {
        let standardizedURL: URL
        let resolvedURL: URL
        let fileIdentity: FileIdentity
        let bundleIdentifier: String
        let displayName: String
        var runningProcessIdentifier: Int32?

        var identityKey: String {
            resolvedURL.path + "\u{0}" + bundleIdentifier
        }
    }

    private struct InventoryEntry {
        let advertised: PeelAgentCatalogApplication
        let inspected: InspectedApplication
        let inventoryGeneration: UInt64
    }

    private nonisolated struct ScanOutcome: Sendable {
        let applications: [InspectedApplication]
        let isTruncated: Bool
        let inaccessibleLocationCount: Int
    }

    private struct PendingLaunch {
        let operationGeneration: UInt64
        let inventoryGeneration: UInt64
        let applicationID: String
        let deadlineUptimeNanoseconds: UInt64
        let completion: LaunchCompletion
    }

    private let dependencies: Dependencies
    private var inventoryGeneration: UInt64 = 0
    private var entriesByID: [String: InventoryEntry] = [:]
    private var launchGeneration: UInt64 = 0
    private var pendingLaunch: PendingLaunch?

    private struct PendingQuery {
        let generation: UInt64
        let sink: ScanSink
        let budgetUptimeNanoseconds: UInt64
        let deadlineUptimeNanoseconds: UInt64
        let isCurrent: @MainActor () -> Bool
        let completion: InventoryCompletion
    }

    private var queryGeneration: UInt64 = 0
    private var pendingQuery: PendingQuery?
    /// Off-main scans not yet returned, including any stalled in one read.
    private(set) var outstandingQueryScans = 0

    init() {
        dependencies = Self.liveDependencies()
    }

    /// Internal dependency seam for synthetic tests. Production callers use init().
    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func inventory() -> PeelAgentAppInventoryResult {
        guard pendingLaunch == nil else {
            return .failure(.launchInProgress)
        }
        return publish(scanApplications())
    }

    /// Assigns fresh opaque IDs and makes them the only launchable ones.
    private func publish(_ outcome: ScanOutcome) -> PeelAgentAppInventoryResult {
        var candidateInventoryGeneration = inventoryGeneration
        let nextInventoryGeneration =
            nextNonzero(&candidateInventoryGeneration)
        let previousIdentifiers = Set(entriesByID.keys)
        var nextEntries: [String: InventoryEntry] = [:]
        nextEntries.reserveCapacity(outcome.applications.count)
        var advertised: [PeelAgentCatalogApplication] = []
        advertised.reserveCapacity(outcome.applications.count)

        for inspected in outcome.applications {
            var identifier: String?
            for _ in 0..<8 {
                let candidate = dependencies.makeOpaqueIdentifier()
                if Self.isValidOpaqueIdentifier(candidate),
                   nextEntries[candidate] == nil,
                   !previousIdentifiers.contains(candidate) {
                    identifier = candidate
                    break
                }
            }
            guard let identifier else {
                return .failure(.identifierGenerationFailed)
            }

            let application = PeelAgentCatalogApplication(
                id: identifier,
                bundleIdentifier: inspected.bundleIdentifier,
                displayName: inspected.displayName,
                runningProcessIdentifier:
                    inspected.runningProcessIdentifier
            )
            nextEntries[identifier] = InventoryEntry(
                advertised: application,
                inspected: inspected,
                inventoryGeneration: nextInventoryGeneration
            )
            advertised.append(application)
        }

        inventoryGeneration = nextInventoryGeneration
        entriesByID = nextEntries
        return .success(PeelAgentAppInventory(
            generation: nextInventoryGeneration,
            applications: advertised,
            isTruncated: outcome.isTruncated,
            inaccessibleLocationCount: outcome.inaccessibleLocationCount
        ))
    }

    /// Local-target inventory. Every filesystem and bundle read runs off the
    /// main actor; `query` only orders work so likely matches are inspected
    /// first. IDs are published on the main actor only for the newest query,
    /// only while `isCurrent()` holds and before the deadline. When the
    /// budget ends first, what was inspected is published as truncated.
    func inventory(
        query: String,
        deadlineUptimeNanoseconds: UInt64,
        isCurrent: @escaping @MainActor () -> Bool,
        completion: @escaping InventoryCompletion
    ) {
        guard pendingLaunch == nil else {
            completion(.failure(.launchInProgress))
            return
        }
        let now = dependencies.monotonicNow()
        guard deadlineUptimeNanoseconds > now else {
            completion(.failure(.deadlineExpired))
            return
        }
        guard outstandingQueryScans < Self.maximumOutstandingQueryScans else {
            completion(.failure(.scanCapacityExhausted))
            return
        }
        if let superseded = pendingQuery {
            pendingQuery = nil
            _ = superseded.sink.close(truncated: true)
            superseded.completion(.failure(.cancelled))
        }

        let remaining = deadlineUptimeNanoseconds - now
        let budget = remaining -
            min(Self.queryPublishMarginNanoseconds, remaining / 4)
        let budgetUptimeNanoseconds = now + budget
        let generation = nextNonzero(&queryGeneration)
        let sink = ScanSink()
        pendingQuery = PendingQuery(
            generation: generation,
            sink: sink,
            budgetUptimeNanoseconds: budgetUptimeNanoseconds,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            isCurrent: isCurrent,
            completion: completion
        )
        let request = ScanRequest(
            fileManager: dependencies.fileManager,
            roots: dependencies.inventoryRoots,
            running: dependencies.runningApplications(),
            query: query,
            budgetNanoseconds: budget,
            clock: dependencies.scanClock,
            willInspect: dependencies.willInspectApplication
        )
        outstandingQueryScans += 1
        dependencies.scheduleDeadline(budgetUptimeNanoseconds) {
            Task { @MainActor [self] in
                self.queryBudgetFired(generation: generation)
            }
        }
        Self.startScan(request, into: sink) {
            Task { @MainActor [self] in
                self.queryScanReturned(generation: generation)
            }
        }
    }

    /// Stop or revocation: a pending query completes as cancelled, every
    /// launchable ID is dropped, and a still-running scan can never publish.
    func cancelInventory() {
        entriesByID.removeAll()
        guard let pending = pendingQuery else { return }
        pendingQuery = nil
        _ = pending.sink.close(truncated: true)
        pending.completion(.failure(.cancelled))
    }

    private func queryBudgetFired(generation: UInt64) {
        guard let pending = pendingQuery,
              pending.generation == generation else {
            return
        }
        guard dependencies.monotonicNow() >=
                pending.budgetUptimeNanoseconds else {
            dependencies.scheduleDeadline(pending.budgetUptimeNanoseconds) {
                Task { @MainActor [self] in
                    self.queryBudgetFired(generation: generation)
                }
            }
            return
        }
        finishQuery(truncatedByBudget: true)
    }

    private func queryScanReturned(generation: UInt64) {
        outstandingQueryScans = max(0, outstandingQueryScans - 1)
        guard let pending = pendingQuery,
              pending.generation == generation else {
            return
        }
        finishQuery(truncatedByBudget: false)
    }

    private func finishQuery(truncatedByBudget: Bool) {
        guard let pending = pendingQuery else { return }
        pendingQuery = nil
        let outcome = pending.sink.close(truncated: truncatedByBudget)
        guard pendingLaunch == nil else {
            pending.completion(.failure(.launchInProgress))
            return
        }
        guard dependencies.monotonicNow() <
                pending.deadlineUptimeNanoseconds else {
            pending.completion(.failure(.deadlineExpired))
            return
        }
        guard pending.isCurrent() else {
            pending.completion(.failure(.cancelled))
            return
        }
        pending.completion(publish(outcome))
    }

    func launch(
        applicationID: String,
        deadlineUptimeNanoseconds: UInt64,
        completion: @escaping LaunchCompletion
    ) {
        guard pendingLaunch == nil else {
            completion(.failure(.launchInProgress))
            return
        }
        guard inventoryGeneration != 0 else {
            completion(.failure(.inventoryUnavailable))
            return
        }
        guard let entry = entriesByID[applicationID],
              entry.inventoryGeneration == inventoryGeneration else {
            completion(.failure(.applicationIDNotInCurrentInventory))
            return
        }

        let firstNow = dependencies.monotonicNow()
        guard deadlineUptimeNanoseconds > firstNow else {
            completion(.failure(.deadlineExpired))
            return
        }
        guard deadlineUptimeNanoseconds - firstNow <=
                Self.maximumLaunchDurationNanoseconds else {
            completion(.failure(.deadlineTooFar))
            return
        }

        guard let revalidated = Self.inspectApplication(
            at: entry.inspected.standardizedURL,
            runningProcessIdentifier:
                entry.inspected.runningProcessIdentifier
        ),
        revalidated.standardizedURL == entry.inspected.standardizedURL,
        revalidated.resolvedURL == entry.inspected.resolvedURL,
        revalidated.bundleIdentifier == entry.inspected.bundleIdentifier,
        revalidated.fileIdentity.matches(entry.inspected.fileIdentity) else {
            completion(.failure(.applicationIdentityChanged))
            return
        }

        guard dependencies.monotonicNow() < deadlineUptimeNanoseconds else {
            completion(.failure(.deadlineExpired))
            return
        }

        let operationGeneration = nextNonzero(&launchGeneration)
        pendingLaunch = PendingLaunch(
            operationGeneration: operationGeneration,
            inventoryGeneration: inventoryGeneration,
            applicationID: applicationID,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            completion: completion
        )

        dependencies.scheduleDeadline(deadlineUptimeNanoseconds) {
            Task { @MainActor [self] in
                self.deadlineFired(
                    operationGeneration: operationGeneration,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                )
            }
        }

        guard dependencies.monotonicNow() <
                deadlineUptimeNanoseconds else {
            finishLaunch(
                operationGeneration: operationGeneration,
                result: .failure(.deadlineExceeded)
            )
            return
        }
        dependencies.openApplication(
            revalidated.standardizedURL
        ) { processIdentifier, errorDescription in
            Task { @MainActor [self] in
                self.workspaceCompleted(
                    operationGeneration: operationGeneration,
                    processIdentifier: processIdentifier,
                    errorDescription: errorDescription
                )
            }
        }
    }

    /// Cancels catalog ownership of the request. NSWorkspace has no matching
    /// cancellation API, so this cannot undo an open request already submitted.
    @discardableResult
    func cancelLaunch() -> Bool {
        guard let pending = pendingLaunch else { return false }
        pendingLaunch = nil
        _ = nextNonzero(&launchGeneration)
        pending.completion(.failure(.cancelled))
        return true
    }

    private func deadlineFired(
        operationGeneration: UInt64,
        deadlineUptimeNanoseconds: UInt64
    ) {
        guard let pending = pendingLaunch,
              pending.operationGeneration == operationGeneration,
              pending.deadlineUptimeNanoseconds ==
                deadlineUptimeNanoseconds else {
            return
        }

        guard dependencies.monotonicNow() >=
                deadlineUptimeNanoseconds else {
            dependencies.scheduleDeadline(deadlineUptimeNanoseconds) {
                Task { @MainActor [self] in
                    self.deadlineFired(
                        operationGeneration: operationGeneration,
                        deadlineUptimeNanoseconds:
                            deadlineUptimeNanoseconds
                    )
                }
            }
            return
        }
        finishLaunch(
            operationGeneration: operationGeneration,
            result: .failure(.deadlineExceeded)
        )
    }

    private func workspaceCompleted(
        operationGeneration: UInt64,
        processIdentifier: Int32?,
        errorDescription: String?
    ) {
        guard let pending = pendingLaunch,
              pending.operationGeneration == operationGeneration else {
            return
        }
        guard dependencies.monotonicNow() <
                pending.deadlineUptimeNanoseconds else {
            finishLaunch(
                operationGeneration: operationGeneration,
                result: .failure(.deadlineExceeded)
            )
            return
        }

        if let errorDescription {
            finishLaunch(
                operationGeneration: operationGeneration,
                result: .failure(.workspaceFailure(
                    Self.safeErrorDescription(errorDescription)
                ))
            )
        } else if let processIdentifier, processIdentifier > 0 {
            finishLaunch(
                operationGeneration: operationGeneration,
                result: .launched(
                    applicationID: pending.applicationID,
                    processIdentifier: processIdentifier
                )
            )
        } else {
            finishLaunch(
                operationGeneration: operationGeneration,
                result: .failure(.workspaceReturnedNoApplication)
            )
        }
    }

    private func finishLaunch(
        operationGeneration: UInt64,
        result: PeelAgentAppLaunchResult
    ) {
        guard let pending = pendingLaunch,
              pending.operationGeneration == operationGeneration else {
            return
        }
        pendingLaunch = nil
        pending.completion(result)
    }

    private func scanApplications() -> ScanOutcome {
        var applicationsByIdentity: [String: InspectedApplication] = [:]
        applicationsByIdentity.reserveCapacity(Self.maximumApplications)
        var isTruncated = false
        var inaccessibleLocationCount = 0
        var visitedEntryCount = 0

        func add(_ application: InspectedApplication) {
            if var existing =
                applicationsByIdentity[application.identityKey] {
                if let candidatePID =
                    application.runningProcessIdentifier,
                   existing.runningProcessIdentifier == nil ||
                    candidatePID <
                        existing.runningProcessIdentifier! {
                    existing.runningProcessIdentifier = candidatePID
                    applicationsByIdentity[application.identityKey] =
                        existing
                }
                return
            }
            guard applicationsByIdentity.count <
                    Self.maximumApplications else {
                isTruncated = true
                return
            }
            applicationsByIdentity[application.identityKey] = application
        }

        let running = dependencies.runningApplications()
            .filter { $0.processIdentifier > 0 }
            .sorted {
                let lhsPath = $0.bundleURL.standardizedFileURL.path
                let rhsPath = $1.bundleURL.standardizedFileURL.path
                return lhsPath == rhsPath
                    ? $0.processIdentifier < $1.processIdentifier
                    : lhsPath < rhsPath
            }
        for runningApplication in running {
            guard visitedEntryCount < Self.maximumVisitedEntries else {
                isTruncated = true
                break
            }
            visitedEntryCount += 1
            guard let inspected = Self.inspectApplication(
                at: runningApplication.bundleURL,
                runningProcessIdentifier:
                    runningApplication.processIdentifier
            ),
            runningApplication.bundleIdentifier == nil ||
                runningApplication.bundleIdentifier ==
                    inspected.bundleIdentifier else {
                continue
            }
            add(inspected)
        }

        rootLoop: for root in dependencies.inventoryRoots {
            if applicationsByIdentity.count >= Self.maximumApplications ||
                visitedEntryCount >= Self.maximumVisitedEntries {
                isTruncated = true
                break
            }

            let standardizedRoot = root.standardizedFileURL
            guard standardizedRoot.isFileURL,
                  let rootValues = try? standardizedRoot.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true else {
                inaccessibleLocationCount += 1
                continue
            }

            var rootHadError = false
            guard let enumerator = dependencies.fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isApplicationKey,
                    .fileResourceIdentifierKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    rootHadError = true
                    return true
                }
            ) else {
                inaccessibleLocationCount += 1
                continue
            }

            let rootComponentCount = standardizedRoot.pathComponents.count
            while let item = enumerator.nextObject() as? URL {
                guard visitedEntryCount < Self.maximumVisitedEntries else {
                    isTruncated = true
                    break rootLoop
                }
                visitedEntryCount += 1

                let standardizedItem = item.standardizedFileURL
                let depth =
                    standardizedItem.pathComponents.count -
                    rootComponentCount
                guard depth > 0, depth <= Self.maximumFolderDepth else {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? standardizedItem.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .isApplicationKey
                    ]
                ) else {
                    rootHadError = true
                    enumerator.skipDescendants()
                    continue
                }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isApplication == true,
                   standardizedItem.pathExtension
                    .caseInsensitiveCompare("app") == .orderedSame {
                    if let inspected = Self.inspectApplication(
                        at: standardizedItem,
                        runningProcessIdentifier: nil
                    ) {
                        add(inspected)
                    }
                    enumerator.skipDescendants()
                    if applicationsByIdentity.count >=
                        Self.maximumApplications {
                        isTruncated = true
                        break rootLoop
                    }
                    continue
                }
                if values.isDirectory != true ||
                    depth >= Self.maximumFolderDepth {
                    enumerator.skipDescendants()
                }
            }
            if rootHadError {
                inaccessibleLocationCount += 1
            }
        }

        return ScanOutcome(
            applications: Self.sortedApplications(
                Array(applicationsByIdentity.values)
            ),
            isTruncated: isTruncated,
            inaccessibleLocationCount: inaccessibleLocationCount
        )
    }

    private nonisolated static func sortedApplications(
        _ applications: [InspectedApplication]
    ) -> [InspectedApplication] {
        applications.sorted {
            let lhsName = $0.displayName.lowercased()
            let rhsName = $1.displayName.lowercased()
            if lhsName != rhsName { return lhsName < rhsName }
            if $0.bundleIdentifier != $1.bundleIdentifier {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.resolvedURL.path < $1.resolvedURL.path
        }
    }

    // MARK: Off-main query scan

    private nonisolated struct ScanRequest: @unchecked Sendable {
        let fileManager: FileManager
        let roots: [URL]
        let running: [RunningApplicationRecord]
        let query: String
        let budgetNanoseconds: UInt64
        let clock: @Sendable () -> UInt64
        let willInspect: @Sendable (URL) -> Void
    }

    /// Lock-protected results of one query scan. Once closed (published,
    /// superseded or cancelled) it accepts nothing and the scan stops.
    private nonisolated final class ScanSink: @unchecked Sendable {
        private let lock = NSLock()
        private var applicationsByIdentity: [String: InspectedApplication] =
            [:]
        private var isTruncated = false
        private var inaccessibleLocationCount = 0
        private var isClosed = false

        var isOpen: Bool { lock.withLock { !isClosed } }

        /// False once closed or full; the scan stops on false.
        func add(_ application: InspectedApplication) -> Bool {
            lock.withLock { () -> Bool in
                guard !isClosed else { return false }
                if var existing =
                    applicationsByIdentity[application.identityKey] {
                    if let candidatePID =
                        application.runningProcessIdentifier,
                       existing.runningProcessIdentifier == nil ||
                        candidatePID <
                            existing.runningProcessIdentifier! {
                        existing.runningProcessIdentifier = candidatePID
                        applicationsByIdentity[application.identityKey] =
                            existing
                    }
                    return true
                }
                guard applicationsByIdentity.count <
                        PeelAgentAppCatalog.maximumApplications else {
                    isTruncated = true
                    return false
                }
                applicationsByIdentity[application.identityKey] = application
                return true
            }
        }

        func markTruncated() { lock.withLock { isTruncated = true } }

        func noteInaccessibleLocation() {
            lock.withLock { inaccessibleLocationCount += 1 }
        }

        func close(truncated: Bool) -> ScanOutcome {
            lock.withLock { () -> ScanOutcome in
                isClosed = true
                return ScanOutcome(
                    applications: PeelAgentAppCatalog.sortedApplications(
                        Array(applicationsByIdentity.values)
                    ),
                    isTruncated: isTruncated || truncated,
                    inaccessibleLocationCount: inaccessibleLocationCount
                )
            }
        }
    }

    private nonisolated static func startScan(
        _ request: ScanRequest,
        into sink: ScanSink,
        returned: @escaping @Sendable () -> Void
    ) {
        queryScanQueue.async {
            scan(request, into: sink)
            returned()
        }
    }

    /// Same roots, depth, symlink, package, background-only and entry limits
    /// as `scanApplications`. Order: running matches, top-level name matches,
    /// folder expansion, nested name matches, then everything else. Stops at
    /// its own budget, a full or closed sink, and reports truncation.
    private nonisolated static func scan(
        _ request: ScanRequest,
        into sink: ScanSink
    ) {
        let start = request.clock()
        var visitedEntryCount = 0
        func mayVisit() -> Bool {
            guard sink.isOpen else { return false }
            guard visitedEntryCount < maximumVisitedEntries,
                  request.clock() &- start < request.budgetNanoseconds else {
                sink.markTruncated()
                return false
            }
            visitedEntryCount += 1
            return true
        }
        func inspect(
            _ url: URL,
            runningProcessIdentifier: Int32? = nil,
            expectedBundleIdentifier: String? = nil
        ) -> Bool {
            guard mayVisit() else { return false }
            request.willInspect(url)
            guard let inspected = inspectApplication(
                at: url,
                runningProcessIdentifier: runningProcessIdentifier
            ),
            expectedBundleIdentifier == nil ||
                expectedBundleIdentifier == inspected.bundleIdentifier else {
                return sink.isOpen
            }
            return sink.add(inspected)
        }

        var terms: [String] = []
        if !request.query.isEmpty {
            terms.append(request.query)
            if let last = request.query.split(separator: ".").last,
               request.query.contains("."), !last.isEmpty {
                terms.append(String(last))
            }
        }
        func nameMatches(_ url: URL) -> Bool {
            let name = url.deletingPathExtension().lastPathComponent
            return terms.contains { name.localizedCaseInsensitiveContains($0) }
        }
        func isApplicationName(_ url: URL) -> Bool {
            url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }

        let running = request.running
            .filter { $0.processIdentifier > 0 }
            .sorted {
                let lhsPath = $0.bundleURL.standardizedFileURL.path
                let rhsPath = $1.bundleURL.standardizedFileURL.path
                return lhsPath == rhsPath
                    ? $0.processIdentifier < $1.processIdentifier
                    : lhsPath < rhsPath
            }
        func runningMatches(_ record: RunningApplicationRecord) -> Bool {
            nameMatches(record.bundleURL) ||
                terms.contains {
                    record.bundleIdentifier?
                        .localizedCaseInsensitiveContains($0) == true
                }
        }
        for record in running where runningMatches(record) {
            guard inspect(
                record.bundleURL,
                runningProcessIdentifier: record.processIdentifier,
                expectedBundleIdentifier: record.bundleIdentifier
            ) else { return }
        }

        var topApplications: [URL] = []
        var topFolders: [(root: Int, url: URL)] = []
        var rootsWithErrors = Set<Int>()
        func noteError(_ root: Int) {
            if rootsWithErrors.insert(root).inserted {
                sink.noteInaccessibleLocation()
            }
        }
        for (index, root) in request.roots.enumerated() {
            guard mayVisit() else { return }
            let standardizedRoot = root.standardizedFileURL
            guard standardizedRoot.isFileURL,
                  let rootValues = try? standardizedRoot.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true,
                  let contents = try? request.fileManager.contentsOfDirectory(
                    at: standardizedRoot,
                    includingPropertiesForKeys: [],
                    options: [.skipsHiddenFiles]
                  ) else {
                noteError(index)
                continue
            }
            for item in contents.sorted(by: { $0.path < $1.path }) {
                if isApplicationName(item) {
                    topApplications.append(item)
                } else {
                    topFolders.append((index, item))
                }
            }
        }

        for url in topApplications where nameMatches(url) {
            guard inspect(url) else { return }
        }

        var nestedApplications: [URL] = []
        for folder in topFolders {
            guard mayVisit() else { return }
            guard let values = try? folder.url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey
            ]) else {
                noteError(folder.root)
                continue
            }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  values.isPackage != true else {
                continue
            }
            guard let contents = try? request.fileManager.contentsOfDirectory(
                at: folder.url,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ) else {
                noteError(folder.root)
                continue
            }
            nestedApplications += contents
                .filter(isApplicationName)
                .sorted { $0.path < $1.path }
        }

        for url in nestedApplications where nameMatches(url) {
            guard inspect(url) else { return }
        }
        for record in running where !runningMatches(record) {
            guard inspect(
                record.bundleURL,
                runningProcessIdentifier: record.processIdentifier,
                expectedBundleIdentifier: record.bundleIdentifier
            ) else { return }
        }
        for url in topApplications + nestedApplications
        where !nameMatches(url) {
            guard inspect(url) else { return }
        }
    }

    private nonisolated static func inspectApplication(
        at url: URL,
        runningProcessIdentifier: Int32?
    ) -> InspectedApplication? {
        guard url.isFileURL else { return nil }
        var standardizedURL = url.standardizedFileURL
        standardizedURL.removeAllCachedResourceValues()
        guard standardizedURL.pathExtension
            .caseInsensitiveCompare("app") == .orderedSame,
        let values = try? standardizedURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isApplicationKey,
            .fileResourceIdentifierKey
        ]),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        values.isApplication == true,
        let rawIdentity = values.fileResourceIdentifier,
        let bundle = Bundle(url: standardizedURL),
        let bundleIdentifier = Self.safeBundleIdentifier(
            bundle.bundleIdentifier
        ),
        !Self.bundleIsBackgroundOnly(bundle) else {
            return nil
        }

        let resolvedURL = standardizedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let displayName = Self.safeDisplayName(
            (bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String) ??
            (bundle.object(
                forInfoDictionaryKey: "CFBundleName"
            ) as? String) ??
            standardizedURL.deletingPathExtension().lastPathComponent
        )
        guard !displayName.isEmpty else { return nil }

        return InspectedApplication(
            standardizedURL: standardizedURL,
            resolvedURL: resolvedURL,
            fileIdentity: FileIdentity(rawIdentity),
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            runningProcessIdentifier:
                runningProcessIdentifier.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private nonisolated static func bundleIsBackgroundOnly(_ bundle: Bundle) -> Bool {
        (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) ==
            true ||
        (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) ==
            true
    }

    private nonisolated static func safeBundleIdentifier(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= 255 else {
            return nil
        }
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                continue
            default:
                return nil
            }
        }
        return value
    }

    private nonisolated static func safeDisplayName(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(min(value.unicodeScalars.count, 256))
        for scalar in value.unicodeScalars.prefix(256) {
            if scalar.value < 0x20 || scalar.value == 0x7f {
                output.append(" ")
            } else {
                output.append(scalar)
            }
        }
        return String(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeErrorDescription(_ value: String) -> String {
        let result = safeDisplayName(value)
        return result.isEmpty ? "NSWorkspace failed to open the app." : result
    }

    private static func isValidOpaqueIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 45, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private func nextNonzero(_ value: inout UInt64) -> UInt64 {
        value &+= 1
        if value == 0 {
            value &+= 1
        }
        return value
    }

    private static func liveDependencies() -> Dependencies {
        let fileManager = FileManager.default
        return Dependencies(
            fileManager: fileManager,
            inventoryRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(
                    fileURLWithPath: "/System/Applications",
                    isDirectory: true
                ),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Applications",
                        isDirectory: true
                    )
            ],
            runningApplications: {
                NSWorkspace.shared.runningApplications.compactMap {
                    guard $0.activationPolicy == .regular,
                          let bundleURL = $0.bundleURL,
                          $0.processIdentifier > 0 else {
                        return nil
                    }
                    return RunningApplicationRecord(
                        bundleURL: bundleURL,
                        bundleIdentifier: $0.bundleIdentifier,
                        processIdentifier: $0.processIdentifier
                    )
                }
            },
            openApplication: { url, completion in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                configuration.allowsRunningApplicationSubstitution = false
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: configuration
                ) { application, error in
                    completion(
                        application?.processIdentifier,
                        error?.localizedDescription
                    )
                }
            },
            makeOpaqueIdentifier: {
                UUID().uuidString.lowercased()
            },
            monotonicNow: {
                DispatchTime.now().uptimeNanoseconds
            },
            scheduleDeadline: { deadline, action in
                DispatchQueue.main.asyncAfter(
                    deadline: DispatchTime(
                        uptimeNanoseconds: deadline
                    ),
                    execute: action
                )
            }
        )
    }
}
