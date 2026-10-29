import Foundation

enum NearbyMirroringMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case shareThisMac
    case followNearbyMac
    case allMacs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .shareThisMac: "Share This Mac"
        case .followNearbyMac: "Follow Nearby Mac"
        case .allMacs: "All Macs"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Use only this Mac. SidePulse does not advertise or browse on the local network."
        case .shareThisMac:
            "Keep showing this Mac locally and make its light signal available to nearby Macs."
        case .followNearbyMac:
            "Show one selected nearby Mac only while this Mac has no local agent activity."
        case .allMacs:
            "Share this Mac and use the highest-priority nearby signal only while this Mac is idle."
        }
    }

    var sharesLocalSignal: Bool {
        self == .shareThisMac || self == .allMacs
    }

    var receivesNearbySignals: Bool {
        self == .followNearbyMac || self == .allMacs
    }
}

enum SidePulseSignalSource: Codable, Equatable, Hashable, Sendable {
    case thisMac
    case nearbyMac(String)
    case allMacs

    var needsNearbySignals: Bool {
        switch self {
        case .thisMac: false
        case .nearbyMac, .allMacs: true
        }
    }

    var selectedPeerID: String? {
        guard case .nearbyMac(let peerID) = self else { return nil }
        return peerID
    }
}

struct NearbySignalServiceConfiguration: Equatable, Sendable {
    var sharesLocalSignal: Bool
    var discoversPeers: Bool
    var followedPeerIDs: Set<String>
    var followsAllPeers: Bool

    static let localOnly = NearbySignalServiceConfiguration(
        sharesLocalSignal: false,
        discoversPeers: false,
        followedPeerIDs: [],
        followsAllPeers: false
    )

    var receivesNearbySignals: Bool {
        followsAllPeers || !followedPeerIDs.isEmpty
    }
}

struct NearbySignalServiceSnapshot: Equatable, Sendable {
    var listenerReady: Bool
    var browserReady: Bool
    var discoveredPeerIDs: Set<String>
    var readyOutboundPeerIDs: Set<String>
    var inboundReceiverCount: Int
    /// In-process only; never encoded. Defaults keep older initializers valid.
    var startup: NearbySignalStartupAvailability = .notStarted

    static let localOnly = NearbySignalServiceSnapshot(
        listenerReady: false,
        browserReady: false,
        discoveredPeerIDs: [],
        readyOutboundPeerIDs: [],
        inboundReceiverCount: 0
    )
}

/// Which local network components the current configuration requests.
nonisolated enum NearbySignalStartupScope: Equatable, Sendable {
    case listenAndBrowse
    case listenOnly
    case browseOnly
}

/// The last component/phase problem reported by the current service. No
/// error text, domain or code is retained.
nonisolated enum NearbySignalStartupFailure: Equatable, Sendable {
    case listenerCreate
    case listenerFailed
    case listenerWaiting
    case browserFailed
    case browserWaiting

    nonisolated enum Component: Equatable, Sendable { case listener, browser }

    var component: Component {
        switch self {
        case .listenerCreate, .listenerFailed, .listenerWaiting: .listener
        case .browserFailed, .browserWaiting: .browser
        }
    }
}

/// Local startup state of the cross-device signal service. `localReady`
/// describes this Mac's own listener/browser only: it never means a paired
/// computer was found, authenticated or sent data.
nonisolated enum NearbySignalStartupAvailability: Equatable, Sendable {
    case notStarted
    case identityUnavailable
    case disabled
    case noUsablePairedTrust(pairedKeyUnavailable: Bool)
    case preparing(NearbySignalStartupScope)
    case localReady(NearbySignalStartupScope)
    case failed(NearbySignalStartupFailure)

    var code: NearbySignalStartupCode {
        switch self {
        case .notStarted: .notStarted
        case .identityUnavailable: .identityUnavailable
        case .disabled: .disabled
        case .noUsablePairedTrust(let keyUnavailable): keyUnavailable ? .noUsableTrustKeyUnavailable : .noUsableTrust
        case .preparing(.listenAndBrowse): .preparingListenAndBrowse
        case .preparing(.listenOnly): .preparingListen
        case .preparing(.browseOnly): .preparingBrowse
        case .localReady(.listenAndBrowse): .localReadyListenAndBrowse
        case .localReady(.listenOnly): .localReadyListen
        case .localReady(.browseOnly): .localReadyBrowse
        case .failed(.listenerCreate): .failedListenerCreate
        case .failed(.listenerFailed): .failedListener
        case .failed(.listenerWaiting): .waitingListener
        case .failed(.browserFailed): .failedBrowser
        case .failed(.browserWaiting): .waitingBrowser
        }
    }
}

/// Fixed public diagnostic codes. These are the only values that may be logged.
nonisolated enum NearbySignalStartupCode: String, CaseIterable, Sendable {
    case notStarted = "not-started"
    case identityUnavailable = "identity-unavailable"
    case disabled = "disabled"
    case noUsableTrust = "no-usable-trust"
    case noUsableTrustKeyUnavailable = "no-usable-trust.key-unavailable"
    case preparingListenAndBrowse = "preparing.listen-browse"
    case preparingListen = "preparing.listen"
    case preparingBrowse = "preparing.browse"
    case localReadyListenAndBrowse = "local-ready.listen-browse"
    case localReadyListen = "local-ready.listen"
    case localReadyBrowse = "local-ready.browse"
    case failedListenerCreate = "failed.listener.create"
    case failedListener = "failed.listener"
    case waitingListener = "waiting.listener"
    case failedBrowser = "failed.browser"
    case waitingBrowser = "waiting.browser"
}

/// The service's existing gates, read at publication time.
nonisolated struct NearbySignalStartupGates: Equatable, Sendable {
    var listens: Bool
    var browses: Bool
    var usableTrust: Bool
    var keyUnavailable: Bool
    var listenerReady: Bool
    var browserReady: Bool
}

/// Retains the current generation's startup problems so a later generic
/// publication cannot erase them. Listener and browser problems are kept
/// independently. They survive only the service's own scheduled retry; any
/// other restart or stop clears both, and only a ready transition of the same
/// component in the current generation clears that component's problem.
nonisolated struct NearbySignalStartupTracker: Equatable, Sendable {
    private(set) var generation: UUID?
    private var listenerFailure: NearbySignalStartupFailure?
    private var browserFailure: NearbySignalStartupFailure?
    private var carriesFailure = false

    /// The reported problem; a listener problem takes precedence.
    var failure: NearbySignalStartupFailure? { listenerFailure ?? browserFailure }

    mutating func begin(_ generation: UUID) {
        self.generation = generation
        if carriesFailure {
            carriesFailure = false
        } else {
            listenerFailure = nil
            browserFailure = nil
        }
    }

    mutating func markRetry() {
        carriesFailure = true
    }

    mutating func record(_ failure: NearbySignalStartupFailure, generation: UUID) {
        guard generation == self.generation else { return }
        switch failure.component {
        case .listener: listenerFailure = failure
        case .browser: browserFailure = failure
        }
    }

    mutating func recordReady(_ component: NearbySignalStartupFailure.Component, generation: UUID) {
        guard generation == self.generation else { return }
        switch component {
        case .listener: listenerFailure = nil
        case .browser: browserFailure = nil
        }
    }

    func availability(_ gates: NearbySignalStartupGates) -> NearbySignalStartupAvailability {
        guard gates.listens || gates.browses else { return .disabled }
        guard gates.usableTrust else {
            return .noUsablePairedTrust(pairedKeyUnavailable: gates.keyUnavailable)
        }
        if let failure { return .failed(failure) }
        let scope: NearbySignalStartupScope = gates.listens
            ? (gates.browses ? .listenAndBrowse : .listenOnly)
            : .browseOnly
        let ready = (!gates.listens || gates.listenerReady) && (!gates.browses || gates.browserReady)
        return ready ? .localReady(scope) : .preparing(scope)
    }
}

/// Install-scoped de-duplication for startup log events. Each service
/// install begins a new token; events from older installs are rejected and
/// only a changed code for the current install is admitted.
nonisolated final class NearbySignalStartupLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var install: UUID?
    private var lastCode: NearbySignalStartupCode?

    init() {}

    func beginInstall() -> UUID {
        let token = UUID()
        lock.withLock {
            install = token
            lastCode = nil
        }
        return token
    }

    func admit(_ availability: NearbySignalStartupAvailability, install token: UUID) -> NearbySignalStartupCode? {
        let code = availability.code
        return lock.withLock {
            guard install == token, lastCode != code else { return nil }
            lastCode = code
            return code
        }
    }
}

struct NearbySignalPeer: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
}

struct NearbySignalFrame: Codable, Equatable, Sendable {
    static let protocolVersion = 1
    static let maximumProgramBytes = 512
    static let maximumProgramLines = 20
    private static let allowedEasings: Set<String> = [
        "linear",
        "ease",
        "ease-in",
        "ease-out",
        "ease-in-out",
        "cosine",
        "pulse",
        "none",
    ]

    var version = protocolVersion
    var sourceNodeID: String
    var sequence: UInt64
    var generatedAt: Date
    var sentAt: Date
    var programStartedAt: Date
    var aggregateState: AgentState
    var hasVisibleActivity: Bool
    var proProgram: String
    var dotProgram: String

    func program(for kind: SidePulseDeviceKind) -> String {
        switch kind {
        case .pro: proProgram
        case .dot: dotProgram
        }
    }

    func validated() throws -> NearbySignalFrame {
        guard version == Self.protocolVersion else {
            throw NearbySignalFrameError.unsupportedVersion(version)
        }
        guard UUID(uuidString: sourceNodeID) != nil else {
            throw NearbySignalFrameError.invalidNodeIdentifier
        }
        try Self.validate(program: proProgram, label: "Pro")
        try Self.validate(program: dotProgram, label: "Dot")
        return self
    }

    private static func validate(program: String, label: String) throws {
        let bytes = program.utf8.count
        guard bytes > 0, bytes <= maximumProgramBytes else {
            throw NearbySignalFrameError.invalidProgramSize(label: label, bytes: bytes)
        }
        let lines = program.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        guard lines.count > 0, lines.count <= maximumProgramLines else {
            throw NearbySignalFrameError.invalidProgramLines(label: label, lines: lines.count)
        }

        for (offset, line) in lines.enumerated() {
            guard isValidProgramLine(line) else {
                throw NearbySignalFrameError.invalidProgramSyntax(
                    label: label,
                    line: offset + 1
                )
            }
        }
    }

    private static func isValidProgramLine(_ line: Substring) -> Bool {
        if line == "off" || line == "repeat" {
            return true
        }

        if line.hasPrefix("brightness ") {
            let value = line.dropFirst("brightness ".count)
            return isUnsignedInteger(value, maximum: 255)
        }

        return isValidStepLine(line)
    }

    private static func isValidStepLine(_ line: Substring) -> Bool {
        let rawSegments = line.split(separator: ";", omittingEmptySubsequences: false)
        guard !rawSegments.isEmpty,
              rawSegments.allSatisfy({ !$0.isEmpty })
        else { return false }

        let tokenLists = rawSegments.compactMap { splitTokens($0) }
        guard tokenLists.count == rawSegments.count,
              let first = tokenLists.first?.first
        else { return false }

        // LEDFirmwareProgram also supports a whole-array color (with optional
        // timing) and a space-separated color list. Keep those renderer forms
        // valid here as well so a locally generated program is never dropped.
        if isColor(first) {
            guard rawSegments.count == 1 else { return false }
            if tokenLists[0].count == 1 {
                return true
            }
            if tokenLists[0].allSatisfy({ token in isColor(token) }) {
                return tokenLists[0].count >= 2 && tokenLists[0].count <= 8
            }
            return isValidTiming(Array(tokenLists[0].dropFirst()))
        }

        return tokenLists.allSatisfy { tokens in isValidAssignment(tokens) }
    }

    private static func splitTokens(_ segment: Substring) -> [Substring]? {
        let tokens = segment.split(separator: " ", omittingEmptySubsequences: false)
        guard !tokens.isEmpty, tokens.allSatisfy({ !$0.isEmpty }) else { return nil }
        return tokens
    }

    private static func isValidAssignment(_ tokens: [Substring]) -> Bool {
        guard let first = tokens.first else { return false }
        if first == "off" {
            return isValidTiming(Array(tokens.dropFirst()))
        }

        guard isIndexedColor(first) else { return false }
        return isValidTiming(Array(tokens.dropFirst()))
    }

    private static func isValidTiming(_ tokens: [Substring]) -> Bool {
        // Untimed assignments are the compiler's static form. Timed
        // assignments always carry exactly one duration and one easing, with
        // an optional second duration used as the delay.
        guard tokens.isEmpty || tokens.count == 2 || tokens.count == 3 else {
            return false
        }
        guard !tokens.isEmpty,
              isDuration(tokens[0]),
              allowedEasings.contains(String(tokens[1]))
        else {
            return tokens.isEmpty
        }
        return tokens.count == 2 || isDuration(tokens[2])
    }

    private static func isIndexedColor(_ token: Substring) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count == 9,
              (0x30...0x37).contains(bytes[0]),
              bytes[1] == 0x3A,
              bytes[2] == 0x23
        else { return false }
        return bytes.dropFirst(3).allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
    }

    private static func isColor(_ token: Substring) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count == 7, bytes[0] == 0x23 else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
    }

    private static func isUnsignedInteger(
        _ token: Substring,
        maximum: Int? = nil
    ) -> Bool {
        let bytes = Array(token.utf8)
        guard !bytes.isEmpty,
              bytes.allSatisfy({ (0x30...0x39).contains($0) }),
              bytes.count == 1 || bytes[0] != 0x30,
              let value = Int(String(token))
        else { return false }
        return maximum.map { value <= $0 } ?? true
    }

    private static func isDuration(_ token: Substring) -> Bool {
        let bytes = Array(token.utf8)
        if bytes.count > 2, bytes.suffix(2).elementsEqual([0x6D, 0x73]) {
            let magnitude = token.dropLast(2)
            return isUnsignedInteger(magnitude) && String(magnitude) != "0"
        }

        guard bytes.count > 1, bytes.last == 0x73 else { return false }
        let magnitude = token.dropLast()
        let components = magnitude.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              !components.isEmpty,
              isUnsignedInteger(components[0])
        else { return false }

        if components.count == 2 {
            let fraction = components[1]
            guard fraction.count <= 2,
                  !fraction.isEmpty,
                  Array(fraction.utf8).allSatisfy({ (0x30...0x39).contains($0) })
            else { return false }
        }

        let magnitudeString = String(magnitude)
        return magnitudeString != "0"
            && magnitudeString != "0.0"
            && magnitudeString != "0.00"
    }
}

enum NearbySignalFrameError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidNodeIdentifier
    case invalidProgramSize(label: String, bytes: Int)
    case invalidProgramLines(label: String, lines: Int)
    case invalidProgramSyntax(label: String, line: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Nearby signal protocol version \(version) is not supported."
        case .invalidNodeIdentifier:
            "The nearby signal has an invalid source identifier."
        case .invalidProgramSize(let label, let bytes):
            "The nearby \(label) program is \(bytes) bytes; the supported range is 1–\(NearbySignalFrame.maximumProgramBytes)."
        case .invalidProgramLines(let label, let lines):
            "The nearby \(label) program has \(lines) lines; the supported range is 1–\(NearbySignalFrame.maximumProgramLines)."
        case .invalidProgramSyntax(let label, let line):
            "The nearby \(label) program has invalid syntax on line \(line)."
        }
    }
}

struct ReceivedNearbySignal: Equatable, Sendable {
    var peerID: String
    var frame: NearbySignalFrame
    var receivedAt: Date

    func isFresh(at date: Date, timeout: TimeInterval = NearbySignalRouter.staleAfter) -> Bool {
        date.timeIntervalSince(receivedAt) <= timeout
    }

    var localClockOrigin: Date {
        let elapsedAtSend = max(0, frame.sentAt.timeIntervalSince(frame.programStartedAt))
        return receivedAt.addingTimeInterval(-elapsedAtSend)
    }
}

struct RoutedNearbySignal: Equatable, Sendable {
    var frame: NearbySignalFrame
    var clockOrigin: Date
    var isRemote: Bool
}

enum NearbySignalRouter {
    static let staleAfter: TimeInterval = 3.5

    static func route(
        source: SidePulseSignalSource,
        localFrame: NearbySignalFrame,
        receivedSignals: [String: ReceivedNearbySignal],
        now: Date = .now
    ) -> RoutedNearbySignal? {
        switch source {
        case .thisMac:
            return localRoute(localFrame)
        case .nearbyMac(let selectedPeerID):
            // A SidePulse belongs to the Mac it is physically attached to.
            // Nearby mirroring is a fallback, never a competitor for active
            // local agent state (including alerts waiting for acknowledgement).
            if localFrame.hasVisibleActivity {
                return localRoute(localFrame)
            }
            guard let signal = receivedSignals[selectedPeerID],
                  signal.frame.sourceNodeID != localFrame.sourceNodeID,
                  signal.frame.hasVisibleActivity,
                  signal.isFresh(at: now)
            else {
                return nil
            }
            return RoutedNearbySignal(
                frame: signal.frame,
                clockOrigin: signal.localClockOrigin,
                isRemote: true
            )
        case .allMacs:
            if localFrame.hasVisibleActivity {
                return localRoute(localFrame)
            }

            let candidates = receivedSignals.values.compactMap { signal -> RoutedNearbySignal? in
                guard signal.frame.sourceNodeID != localFrame.sourceNodeID,
                      signal.frame.hasVisibleActivity,
                      signal.isFresh(at: now)
                else { return nil }
                return RoutedNearbySignal(
                    frame: signal.frame,
                    clockOrigin: signal.localClockOrigin,
                    isRemote: true
                )
            }

            return candidates.min { lhs, rhs in
                if lhs.frame.aggregateState.priority != rhs.frame.aggregateState.priority {
                    return lhs.frame.aggregateState.priority < rhs.frame.aggregateState.priority
                }
                if lhs.clockOrigin != rhs.clockOrigin {
                    return lhs.clockOrigin > rhs.clockOrigin
                }
                return lhs.frame.sourceNodeID < rhs.frame.sourceNodeID
            }
        }
    }

    static func route(
        mode: NearbyMirroringMode,
        selectedPeerID: String?,
        localFrame: NearbySignalFrame,
        receivedSignals: [String: ReceivedNearbySignal],
        now: Date = .now
    ) -> RoutedNearbySignal? {
        switch mode {
        case .off, .shareThisMac:
            return localRoute(localFrame)
        case .followNearbyMac:
            if localFrame.hasVisibleActivity {
                return localRoute(localFrame)
            }
            guard let selectedPeerID else { return nil }
            return route(
                source: .nearbyMac(selectedPeerID),
                localFrame: localFrame,
                receivedSignals: receivedSignals,
                now: now
            )
        case .allMacs:
            return route(
                source: .allMacs,
                localFrame: localFrame,
                receivedSignals: receivedSignals,
                now: now
            )
        }
    }

    private static func localRoute(_ frame: NearbySignalFrame) -> RoutedNearbySignal {
        RoutedNearbySignal(
            frame: frame,
            clockOrigin: frame.programStartedAt,
            isRemote: false
        )
    }

}

struct NearbySignalStreamDecoder: Sendable {
    static let maximumLineBytes = 4_096

    private var buffer = Data()

    mutating func append(_ data: Data) -> [NearbySignalFrame] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        guard buffer.count <= Self.maximumLineBytes else {
            buffer.removeAll(keepingCapacity: true)
            return []
        }

        var frames = [NearbySignalFrame]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  line.count <= Self.maximumLineBytes,
                  let frame = try? JSONDecoder().decode(NearbySignalFrame.self, from: Data(line)),
                  let validated = try? frame.validated()
            else { continue }
            frames.append(validated)
        }
        return frames
    }
}
