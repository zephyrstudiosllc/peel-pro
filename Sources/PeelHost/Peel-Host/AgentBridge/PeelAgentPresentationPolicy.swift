import Foundation

nonisolated struct PeelAgentPresentationScope: Hashable, Sendable {
    let pairingID: String
    let generation: UInt64
}

nonisolated struct PeelAgentWindowInstanceFingerprint: Equatable, Sendable {
    let windowID: UInt32
    let ownerProcessID: Int32?
    let appBundleIdentifier: String?
    let appName: String
    let title: String
    let width: Int
    let height: Int
    let appLaunchTimeBitPattern: UInt64?
    let isDisplay: Bool
    let displayID: UInt32?

    var hasDurableIdentity: Bool {
        if isDisplay { return displayID != nil }
        return ownerProcessID != nil && appBundleIdentifier != nil && appLaunchTimeBitPattern != nil
    }

    init(
        windowID: UInt32,
        ownerProcessID: Int32?,
        appBundleIdentifier: String?,
        appName: String,
        title: String,
        width: Int,
        height: Int,
        appLaunchTimeIntervalSince1970: TimeInterval?,
        isDisplay: Bool,
        displayID: UInt32?
    ) {
        self.windowID = windowID
        self.ownerProcessID = ownerProcessID
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.title = title
        self.width = width
        self.height = height
        self.appLaunchTimeBitPattern = appLaunchTimeIntervalSince1970.flatMap {
            $0.isFinite && $0 > 0 ? $0.bitPattern : nil
        }
        self.isDisplay = isDisplay
        self.displayID = displayID
    }
}

nonisolated struct PeelAgentAdvertisedWindowInventory: Sendable {
    static let maximumWindows = 128

    private var scope: PeelAgentPresentationScope?
    private var instancesByWindowID: [UInt32: PeelAgentWindowInstanceFingerprint] = [:]

    var count: Int {
        instancesByWindowID.count
    }

    mutating func replace(
        scope: PeelAgentPresentationScope,
        instances: [PeelAgentWindowInstanceFingerprint]
    ) {
        self.scope = scope
        instancesByWindowID.removeAll(keepingCapacity: true)
        for instance in instances.prefix(Self.maximumWindows) {
            instancesByWindowID[instance.windowID] = instance
        }
    }

    func advertisedInstance(
        windowID: UInt32,
        scope requestedScope: PeelAgentPresentationScope
    ) -> PeelAgentWindowInstanceFingerprint? {
        guard scope == requestedScope else { return nil }
        return instancesByWindowID[windowID]
    }

    mutating func clear() {
        scope = nil
        instancesByWindowID.removeAll(keepingCapacity: false)
    }
}

nonisolated struct PeelAgentPendingPresentation: Equatable, Sendable {
    let requestID: UUID
    let scope: PeelAgentPresentationScope
    let deadlineUptimeNanoseconds: UInt64
}

nonisolated enum PeelAgentPendingPresentationTakeResult: Equatable, Sendable {
    case matched(PeelAgentPendingPresentation)
    case expired(PeelAgentPendingPresentation)
    case generationMismatch
    case missing
}

nonisolated struct PeelAgentPendingPresentationTracker: Sendable {
    static let maximumPending = 4

    private var pendingByRequestID: [UUID: PeelAgentPendingPresentation] = [:]

    var count: Int {
        pendingByRequestID.count
    }

    var earliestDeadlineUptimeNanoseconds: UInt64? {
        pendingByRequestID.values
            .map(\.deadlineUptimeNanoseconds)
            .min()
    }

    func pending(
        requestID: UUID
    ) -> PeelAgentPendingPresentation? {
        pendingByRequestID[requestID]
    }

    mutating func insert(
        _ pending: PeelAgentPendingPresentation,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard pending.deadlineUptimeNanoseconds > nowUptimeNanoseconds,
              pendingByRequestID.count < Self.maximumPending,
              pendingByRequestID[pending.requestID] == nil else {
            return false
        }
        pendingByRequestID[pending.requestID] = pending
        return true
    }

    mutating func take(
        requestID: UUID,
        generation: UInt64,
        nowUptimeNanoseconds: UInt64
    ) -> PeelAgentPendingPresentationTakeResult {
        guard let pending = pendingByRequestID[requestID] else {
            return .missing
        }
        guard pending.scope.generation == generation else {
            return .generationMismatch
        }

        pendingByRequestID.removeValue(forKey: requestID)
        guard pending.deadlineUptimeNanoseconds > nowUptimeNanoseconds else {
            return .expired(pending)
        }
        return .matched(pending)
    }

    mutating func remove(
        requestID: UUID
    ) -> PeelAgentPendingPresentation? {
        pendingByRequestID.removeValue(forKey: requestID)
    }

    mutating func removeExpired(
        nowUptimeNanoseconds: UInt64
    ) -> [PeelAgentPendingPresentation] {
        let expired = pendingByRequestID.values.filter {
            $0.deadlineUptimeNanoseconds <= nowUptimeNanoseconds
        }
        for pending in expired {
            pendingByRequestID.removeValue(forKey: pending.requestID)
        }
        return expired
    }

    mutating func removeAll() -> [PeelAgentPendingPresentation] {
        let removed = Array(pendingByRequestID.values)
        pendingByRequestID.removeAll(keepingCapacity: false)
        return removed
    }
}
