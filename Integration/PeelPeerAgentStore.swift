import Foundation
import Observation

/// Host-owned paired-Mac agent state: viewer inventory, pending activation
/// requests, link status and the projection into SidePulse's Hub/notch.
///
/// Routing authority is always the authenticated owner host ID carried by
/// the transport event. Labels are display-only.
@MainActor
@Observable
final class PeelPeerAgentStore {
    private(set) var links: [UUID: PeelPeerLinkStatus] = [:]
    private(set) var labels: [UUID: String] = [:]
    /// Latest usage summary per owner (bounded wire DTO). The usage lane owns
    /// its final presentation; this store only keeps the validated value.
    private(set) var usageByOwner: [UUID: PeelPeerUsageSummary] = [:]

    @ObservationIgnored private var inventory = PeelPeerAgentInventory()
    @ObservationIgnored private var ledger = PeelPeerActivationLedger()
    @ObservationIgnored private var activationAccepted: Set<UUID> = []
    @ObservationIgnored private weak var service: PeelTrustedSidePulseService?
    @ObservationIgnored private weak var sidePulse: CommandCenterStore?
    @ObservationIgnored private weak var usage: PeelUsageStore?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var localCloudTaskIDs: Set<String> = []

    func attach(service: PeelTrustedSidePulseService, sidePulse: CommandCenterStore, usage: PeelUsageStore) {
        self.service = service
        self.sidePulse = sidePulse
        self.usage = usage
        sidePulse.requestRemoteActivation = { [weak self] row in self?.activate(row) }
        if timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            timer.tolerance = 0.25
            self.timer = timer
        }
    }

    /// Local cloud tasks, so the same cloud task from a paired Mac is not
    /// listed twice. Compared only through pair-scoped tags.
    func updateLocalCloudTasks(_ ids: Set<String>) {
        guard ids != localCloudTaskIDs else { return }
        localCloudTaskIDs = ids
        project()
    }

    func handle(_ event: PeelPeerAgentServiceEvent) {
        let now = Date.now
        switch event {
        case .trust(let labels):
            self.labels = labels
            let trusted = Set(labels.keys)
            inventory.retainOnly(trustedHostIDs: trusted)
            for id in trusted { inventory.relabel(hostID: id, label: labels[id] ?? "Paired Mac") }
            usageByOwner = usageByOwner.filter { trusted.contains($0.key) }
            for (key, outcome) in ledger.revoke(keepingOwners: trusted) { report(key, outcome) }
        case .links(let links, let accepted):
            self.links = links
            activationAccepted = accepted
        case .socketClosed(let hostID, let socketID):
            inventory.socketClosed(hostID: hostID, socketID: socketID, now: now)
            for (key, outcome) in ledger.socketClosed(socketID) { report(key, outcome) }
        case .message(let hostID, let label, let socketID, let message):
            // Messages only come from a trusted socket; labels are refreshed
            // from the authenticated pairing record, never from the payload.
            let result: PeelPeerAgentInventory.ApplyResult
            switch message {
            case .snapshot(let snapshot):
                result = inventory.applySnapshot(snapshot, hostID: hostID, label: label, socketID: socketID, now: now)
            case .keepalive(let keepalive):
                result = inventory.applyKeepalive(keepalive, hostID: hostID, socketID: socketID, now: now)
            case .usage(let usage):
                result = inventory.applyUsage(usage, hostID: hostID, socketID: socketID, now: now)
                if result == .applied { usageByOwner[hostID] = usage }
            case .activateResult(let reply):
                if let resolved = ledger.resolve(requestID: reply.requestId, socketID: socketID,
                                                 outcome: reply.outcome) {
                    report(resolved.0, resolved.1, appLabel: reply.appLabel)
                }
                result = .unchanged
            case .activate:
                result = .unchanged // never accepted on the viewer side
            }
            if case .violation = result {
                // Inconsistent owner epoch/revision: close that socket. Its
                // rows turn "reconnecting" and a fresh socket must resend a
                // full snapshot before they are live again.
                inventory.socketClosed(hostID: hostID, socketID: socketID, now: now)
                for (key, outcome) in ledger.socketClosed(socketID) { report(key, outcome) }
                service?.closeAgentSocket(socketID)
            }
        }
        project()
    }

    private func activate(_ row: RemoteAgentRow) {
        guard let ownerID = UUID(uuidString: row.ownerHostID),
              let model = inventory.rows().first(where: { $0.key.rowID == row.id }) else {
            sidePulse?.showActivationFeedback(rowID: row.id, outcome: .sessionEnded, owner: row.ownerLabel, appLabel: nil)
            return
        }
        guard case .live = model.connection, let service else {
            sidePulse?.showActivationFeedback(rowID: row.id, outcome: .ownerOffline, owner: model.ownerLabel, appLabel: nil)
            return
        }
        // Refuse before writing anything: one pending request per row and a
        // small global bound. Nothing is ever retried automatically.
        guard !ledger.pendingKeys.contains(model.key),
              ledger.pending.count < PeelPeerActivationLedger.maximumPending else {
            report(model.key, .rateLimited)
            return
        }
        // The ledger records which socket must deliver the single result.
        let requestID = UUID()
        switch service.sendActivation(hostID: ownerID, token: model.key.token, bootEpoch: model.bootEpoch,
                                      bindingRevision: model.session.bindingRevision, requestID: requestID) {
        case .sent(let socketID):
            _ = ledger.begin(key: model.key, socketID: socketID, now: .now, requestID: requestID)
        case .ownerOffline:
            report(model.key, .ownerOffline)
        case .peerTooOld:
            report(model.key, .peerTooOld)
        case .notAllowed:
            report(model.key, .notAllowed)
        }
    }

    private func tick() {
        let now = Date.now
        var changed = inventory.tick(now: now)
        for (key, outcome) in ledger.expire(now: now) {
            report(key, outcome)
            changed = true
        }
        if changed { project() }
    }

    private func report(_ key: PeelPeerAgentKey, _ outcome: PeelPeerActivationOutcome, appLabel: String? = nil) {
        let owner = labels[key.ownerHostID] ?? inventory.owners[key.ownerHostID]?.label ?? "Paired Mac"
        let local = AgentActivationOutcome(rawValue: outcome.rawValue) ?? .unknownResult
        sidePulse?.showActivationFeedback(rowID: key.rowID, outcome: local, owner: owner, appLabel: appLabel)
    }

    /// Pushes current rows into SidePulse. Duplicate cloud tasks are hidden.
    private func project() {
        guard let sidePulse else { return }
        let service = self.service
        let localTagsByOwner: [UUID: Set<String>] = Dictionary(uniqueKeysWithValues: inventory.owners.keys.map { id in
            guard let key = service?.pairKey(for: id) else { return (id, Set<String>()) }
            return (id, Set(localCloudTaskIDs.map {
                PeelPeerAgentToken.pairTag(pairKey: key, domain: PeelPeerAgentOwnerState.cloudTagDomain, value: $0)
            }))
        })
        let isLocalCloudTask: (UUID, String) -> Bool = { hostID, tag in localTagsByOwner[hostID]?.contains(tag) ?? false }
        let rows = inventory.rows(isLocalCloudTask: isLocalCloudTask)
            .filter { !$0.duplicatesLocalCloudTask }
            .map { model in Self.row(model, ownerAcceptsActivation: activationAccepted.contains(model.key.ownerHostID)) }
        if sidePulse.remoteAgentRows != rows { sidePulse.remoteAgentRows = rows }
        let links = linkSummaries(isLocalCloudTask: isLocalCloudTask)
        if sidePulse.peerAgentLinks != links { sidePulse.peerAgentLinks = links }
        let usageLines = remoteUsageLines(now: .now)
        if sidePulse.remoteUsageLines != usageLines { sidePulse.remoteUsageLines = usageLines }
    }

    static func row(_ model: PeelPeerAgentRowModel, ownerAcceptsActivation: Bool) -> RemoteAgentRow {
        let provider = AgentProvider(rawValue: model.session.provider) ?? .unknown
        let state: AgentState? = model.session.state == .unknown
            ? nil : AgentState(rawValue: model.session.state.rawValue)
        let freshness = Self.freshness(model.connection)
        let activation = AgentActivationSupport(rawValue: model.session.activation.rawValue) ?? .unavailable
        return RemoteAgentRow(
            id: model.key.rowID,
            ownerHostID: model.key.ownerHostID.uuidString,
            ownerLabel: model.ownerLabel,
            provider: provider,
            providerTitle: provider == .unknown ? "Agent" : provider.title,
            name: model.session.title,
            project: model.session.project,
            state: state,
            toolName: model.session.tool,
            updatedAt: model.estimatedUpdatedAt,
            isAlert: model.session.alert,
            activation: activation,
            unavailableReason: model.session.reason,
            freshness: freshness,
            ownerAcceptsActivation: ownerAcceptsActivation)
    }

    static func freshness(_ connection: PeelPeerOwnerConnection) -> RemoteAgentFreshness {
        switch connection {
        case .live: .live
        case .reconnecting(let since): .reconnecting(since: since)
        case .offline(let since): .offline(since: since)
        }
    }

    /// Receipt facts for one link, from accepted inventory data only. A live
    /// link without a retained snapshot reports "no current snapshot";
    /// other link states without one show only their status.
    static func receipt(_ receipt: PeelPeerAgentInventory.OwnerReceipt?, linkIsLive: Bool) -> PeerAgentReceipt? {
        guard let receipt else { return linkIsLive ? PeerAgentReceipt() : nil }
        return PeerAgentReceipt(
            snapshotReceivedAt: receipt.snapshotReceivedAt,
            sessionsInSnapshot: receipt.sessionsInSnapshot,
            sessionsNotIncluded: receipt.sessionsNotIncluded,
            sessionsAlsoLocal: receipt.sessionsAlsoLocal,
            connection: freshness(receipt.connection),
            usageReceivedAt: receipt.usageReceivedAt,
            usageRowsIncluded: receipt.usageRowsIncluded,
            usageRowsNotIncluded: receipt.usageRowsNotIncluded)
    }

    /// Owner-tagged usage lines plus "hooks not set up" notes. Same-account
    /// quotas collapse only on a real pair-scoped tag match; nothing is summed.
    private func remoteUsageLines(now: Date) -> [RemoteUsageLine] {
        var output: [RemoteUsageLine] = []
        for (hostID, owner) in inventory.owners.sorted(by: { $0.value.label < $1.value.label }) {
            let live = owner.connection == .live
            for integration in owner.integrations where integration.state == .needsSetup {
                output.append(RemoteUsageLine(
                    id: "\(hostID.uuidString):hooks:\(integration.provider)", ownerHostID: hostID.uuidString,
                    ownerLabel: owner.label, title: "\(integration.provider.capitalized) not reporting",
                    detail: "\(integration.provider.capitalized) Code hooks aren't set up on \(owner.label); its sessions won't appear",
                    ageText: nil, isProblem: true, isObserved: false))
            }
            guard let summary = owner.usage, let receivedAt = owner.usageReceivedAt else { continue }
            var tags = Set<String>()
            if let key = service?.pairKey(for: hostID), let usage {
                for provider in usage.providers {
                    if let tag = PeelPeerUsageProjection.localAccountTag(
                        provider: provider.id, accountKey: provider.identity?.accountKey, pairKey: key) {
                        tags.insert(tag)
                    }
                }
            }
            let lines = PeelPeerUsagePresentation.lines(ownerHostID: hostID, ownerLabel: owner.label, summary: summary,
                                                        receivedAt: receivedAt, live: live,
                                                        localAccountTags: tags, now: now)
            for (index, line) in lines.enumerated() {
                output.append(RemoteUsageLine(
                    id: "\(hostID.uuidString):usage:\(index):\(line.provider)", ownerHostID: hostID.uuidString,
                    ownerLabel: owner.label, title: line.title, detail: line.detail,
                    ageText: line.age.map { PeelUsageFormatting.age($0) + " old" },
                    isProblem: line.isProblem, isObserved: line.kind == .observed))
            }
        }
        return output
    }

    private func linkSummaries(isLocalCloudTask: (UUID, String) -> Bool) -> [PeerAgentLinkSummary] {
        links.map { id, status in
            let label = labels[id] ?? inventory.owners[id]?.label ?? "Paired Mac"
            let (text, problem): (String, Bool) = switch status {
            case .live: (activationAccepted.contains(id) ? "Sharing agents" : "Sharing agents · opening off", false)
            case .connecting: ("Connecting…", false)
            case .notDiscovered: ("Not found on this network", false)
            case .legacyPeer: ("Update Peel on this Mac to share agents", true)
            case .ownerNotSharing: ("Not sharing its agents", false)
            case .keyUnavailable: ("Pairing key unavailable here — reconnect once from Remote Desktop", true)
            }
            let receipt = Self.receipt(inventory.receipt(for: id, isLocalCloudTask: isLocalCloudTask),
                                       linkIsLive: status == .live)
            return PeerAgentLinkSummary(id: id.uuidString, label: label, status: text, isProblem: problem,
                                        receipt: receipt)
        }.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }
}
