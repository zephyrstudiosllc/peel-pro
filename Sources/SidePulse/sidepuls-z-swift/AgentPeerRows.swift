import SwiftUI

/// Small device tag. The label comes from the authenticated pairing record
/// (or "This Mac") and is display-only.
struct AgentOwnerBadge: View {
    let label: String
    var isLocal = false
    var dark = false

    var body: some View {
        Label(label, systemImage: isLocal ? "laptopcomputer" : "desktopcomputer")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(dark ? AnyShapeStyle(Color.white.opacity(0.75)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .background((dark ? Color.white : Color.primary).opacity(0.1), in: .capsule)
            .accessibilityLabel(isLocal ? "On this Mac" : "On \(label)")
    }
}

/// Paired-Mac row in the notch. Mirrors the local notch row and adds the
/// owner tag, freshness, the honest action and the last result.
struct NotchIslandRemoteAgentRow: View {
    let row: RemoteAgentRow
    let color: Color
    let feedback: AgentActivationFeedback?
    let action: () -> Void

    @State private var isHovered = false

    init(row: RemoteAgentRow, color: Color, feedback: AgentActivationFeedback?, action: @escaping () -> Void) {
        self.row = row
        self.color = color
        self.feedback = feedback
        self.action = action
    }

    private var detail: String {
        if let feedback { return feedback.message }
        if let freshness = row.freshness.label { return "\(row.ownerLabel) · \(freshness)" }
        let base = row.toolName ?? row.providerTitle
        return "\(row.ownerLabel) · \(base)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(row.freshness.isLive ? 1 : 0.4))
                    .frame(width: 4, height: 14)

                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(row.freshness.isLive ? 0.94 : 0.6))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Text(row.stateTitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)

                Image(systemName: feedback?.isPending == true ? "hourglass"
                      : (row.canRequestActivation ? "arrow.up.right" : "eye"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.82 : 0.4))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(feedback?.isPending == true)
        .background(color.opacity(isHovered ? 0.19 : 0.075), in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(isHovered ? 0.16 : 0.04), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .help(row.canRequestActivation ? "\(row.actionTitle) on \(row.ownerLabel)" : row.actionTitle)
        .accessibilityLabel("\(row.name) on \(row.ownerLabel)")
        .accessibilityValue("\(row.stateTitle), \(row.actionTitle)")
    }
}

/// Agent Hub row for a paired Mac's session.
struct RemoteAgentTimelineRow: View {
    let row: RemoteAgentRow
    let profile: LightingProfile
    let feedback: AgentActivationFeedback?

    private var color: Color {
        Color(hex: AgentStatePresentation.rowColorHex(for: row.state, profile: profile))
    }

    var body: some View {
        HStack(spacing: 15) {
            VStack(alignment: .trailing, spacing: 3) {
                AgentOwnerBadge(label: row.ownerLabel)
                Text(row.providerTitle.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 92, alignment: .trailing)

            Image(systemName: row.stateSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.13), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !row.project.isEmpty {
                        Text(row.project)
                        Text("·")
                    }
                    Text(row.stateTitle)
                    Text("·")
                    Text(row.updatedAt.formatted(.relative(presentation: .named)))
                        .monospacedDigit()
                    if let freshness = row.freshness.label {
                        Text("·")
                        Text(freshness)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let feedback {
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(feedback.outcome?.isSuccess == false ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(row.actionTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(row.canRequestActivation ? color : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background((row.canRequestActivation ? color : Color.secondary).opacity(0.1), in: .capsule)
        }
        .padding(14)
        .opacity(row.freshness.isLive ? 1 : 0.7)
        .contentShape(.rect)
        .glassEffect(.regular.tint(color.opacity(0.05)).interactive(row.canRequestActivation),
                     in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name) on \(row.ownerLabel), \(row.stateTitle)")
        .accessibilityHint(row.actionTitle)
    }
}

/// Hub section for one paired Mac.
struct RemoteAgentOwnerHeader: View {
    let label: String
    let rows: [RemoteAgentRow]

    var body: some View {
        HStack(spacing: 8) {
            AgentOwnerBadge(label: label)
            Text("\(rows.count) SESSION\(rows.count == 1 ? "" : "S")")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if let freshness = rows.first?.freshness.label {
                Text("· \(freshness)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

/// Paired-Mac agent sharing switches. Independent of LED sharing/following.
struct PeerAgentSharingSettings: Equatable, Sendable {
    var sharesAgents: Bool
    var receivesAgents: Bool
    var allowsPeerActivation: Bool
    var sharesUsage: Bool
}

struct PeerAgentLinkSummary: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var status: String
    var isProblem: Bool
    /// What this Mac currently holds from that Mac. Nil shows status only.
    var receipt: PeerAgentReceipt? = nil
}

/// Received agent snapshot and usage summary for one paired Mac. Dates are
/// this Mac's receipt times and only change when a new payload is accepted;
/// counts describe the received payload, not the rows shown.
struct PeerAgentReceipt: Equatable, Sendable {
    /// Nil: no agent snapshot is currently held from that Mac.
    var snapshotReceivedAt: Date?
    var sessionsInSnapshot = 0
    /// Sessions that Mac had but could not fit in the snapshot.
    var sessionsNotIncluded = 0
    /// Snapshot sessions already listed for This Mac (shown once).
    var sessionsAlsoLocal = 0
    var connection: RemoteAgentFreshness?
    /// Nil: no usage summary is currently held from that Mac.
    var usageReceivedAt: Date?
    var usageRowsIncluded = 0
    var usageRowsNotIncluded = 0

    private var isPrevious: Bool { connection.map { !$0.isLive } ?? false }

    var snapshotText: String {
        guard let snapshotReceivedAt else { return "No current agent snapshot" }
        let received = snapshotReceivedAt.formatted(.relative(presentation: .named))
        var parts = ["\(isPrevious ? "Previous agent snapshot" : "Agent snapshot") received here \(received)",
                     "\(sessionsInSnapshot) session\(sessionsInSnapshot == 1 ? "" : "s") in snapshot"]
        if sessionsNotIncluded > 0 { parts.append("\(sessionsNotIncluded) more not included") }
        if sessionsAlsoLocal > 0 { parts.append("\(sessionsAlsoLocal) also on This Mac (shown once)") }
        if let freshness = connection?.label { parts.append(freshness) }
        return parts.joined(separator: " · ")
    }

    var usageText: String {
        guard let usageReceivedAt else { return "No current usage summary" }
        let received = usageReceivedAt.formatted(.relative(presentation: .named))
        var parts = ["\(isPrevious ? "Previous usage summary" : "Usage summary") received here \(received)"]
        if usageRowsIncluded == 0 && usageRowsNotIncluded == 0 { parts.append("no usage rows included") }
        if usageRowsNotIncluded > 0 { parts.append("\(usageRowsNotIncluded) more not included") }
        return parts.joined(separator: " · ")
    }
}

/// Compact Agent Hub panel: what this Mac shares with paired Macs and the
/// state of each paired Mac's link. Shown only inside Peel Host.
struct PeerAgentSharingPanel: View {
    let settings: PeerAgentSharingSettings
    let links: [PeerAgentLinkSummary]
    let update: (PeerAgentSharingSettings) -> Void

    @State private var expanded = false

    init(settings: PeerAgentSharingSettings, links: [PeerAgentLinkSummary],
         update: @escaping (PeerAgentSharingSettings) -> Void) {
        self.settings = settings
        self.links = links
        self.update = update
    }

    private func binding(_ keyPath: WritableKeyPath<PeerAgentSharingSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            var next = settings
            next[keyPath: keyPath] = value
            update(next)
        })
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Share this Mac's agent sessions with paired Macs", isOn: binding(\.sharesAgents))
                Toggle("Allow paired Macs to open this Mac's sessions", isOn: binding(\.allowsPeerActivation))
                    .disabled(!settings.sharesAgents)
                Toggle("Share usage limits with paired Macs", isOn: binding(\.sharesUsage))
                    .disabled(!settings.sharesAgents)
                Toggle("Show paired Macs' agent sessions here", isOn: binding(\.receivesAgents))
                Text("Uses your existing Peel pairings. Titles, project folder names and states are shared; paths, messages and transcripts are not. Light sharing and following are separate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(links) { link in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            AgentOwnerBadge(label: link.label)
                            Text(link.status)
                                .font(.caption)
                                .foregroundStyle(link.isProblem ? Color.orange : Color.secondary)
                        }
                        if let receipt = link.receipt {
                            // Re-renders the ages only; the receipt dates are fixed.
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(receipt.snapshotText)
                                    Text(receipt.usageText)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Text("Paired Macs").font(.subheadline.weight(.semibold))
                if links.contains(where: \.isProblem) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("A paired Mac needs attention")
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let live = links.filter { $0.status.hasPrefix("Sharing agents") }.count
        if !settings.sharesAgents && !settings.receivesAgents { return "Agent sharing off" }
        return live == 0 ? "No paired Mac connected" : "\(live) connected"
    }
}

/// One owner-tagged usage line from a paired Mac (quota, observed tokens or
/// a note). Values are never added across Macs.
struct RemoteUsageLine: Identifiable, Equatable, Sendable {
    let id: String
    var ownerHostID: String
    var ownerLabel: String
    var title: String
    var detail: String
    var ageText: String?
    var isProblem: Bool
    var isObserved: Bool
}

struct RemoteUsageLineView: View {
    let line: RemoteUsageLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: line.isObserved ? "number" : (line.isProblem ? "exclamationmark.circle" : "gauge.with.dots.needle.50percent"))
                .font(.caption2)
                .foregroundStyle(line.isProblem ? Color.orange : Color.secondary)
            Text(line.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let ageText = line.ageText {
                Text(ageText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
