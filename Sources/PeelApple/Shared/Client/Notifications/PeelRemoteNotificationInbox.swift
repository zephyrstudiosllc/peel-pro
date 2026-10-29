#if os(iOS) || os(visionOS)
import SwiftUI
import Combine

/// App-owned foreground state for admitted remote notifications.
///
/// The platform may suppress local notification banners while the app is
/// foregrounded, even when a global delegate chooses conservative presentation
/// options. The app can place `PeelRemoteNotificationBanner` over its existing
/// root view and
/// expose `PeelRemoteNotificationInboxView` from its normal navigation/settings
/// path. This store never opens a scene, URL, account flow, or external app.
@MainActor
public final class PeelRemoteNotificationInbox: ObservableObject {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let requestId: UUID
        public let sessionId: UUID
        public let title: String
        public let body: String
        public let receivedAt: Date
        public let expiresAt: TimeInterval

        public var id: String {
            "\(sessionId.uuidString).\(requestId.uuidString)"
        }

        public init(
            requestId: UUID,
            sessionId: UUID,
            title: String,
            body: String,
            receivedAt: Date,
            expiresAt: TimeInterval
        ) {
            self.requestId = requestId
            self.sessionId = sessionId
            self.title = title
            self.body = body
            self.receivedAt = receivedAt
            self.expiresAt = expiresAt
        }
    }

    /// UI history is intentionally shorter than the policy's 64-request
    /// dedupe window so an inbox sheet remains compact and bounded.
    public static let maximumEntries = 20

    @Published public private(set) var entries: [Entry] = []

    public init() {}

    public var latest: Entry? {
        entries.first
    }

    /// Record only a value returned by `PeelRemoteNotificationAdmission`.
    /// Repeated source IDs replace their previous in-app entry and cannot grow
    /// the inbox beyond the fixed 20-entry bound.
    @discardableResult
    public func insert(
        _ admission: PeelRemoteNotificationAdmission,
        receivedAt: Date = Date()
    ) -> Entry {
        let entry = Entry(
            requestId: admission.requestId,
            sessionId: admission.sessionId,
            title: admission.title,
            body: admission.body,
            receivedAt: receivedAt,
            expiresAt: admission.expiresAt
        )
        entries.removeAll { existing in
            existing.requestId == entry.requestId &&
            existing.sessionId == entry.sessionId
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        return entry
    }

    public func dismiss(requestId: UUID, sessionId: UUID) {
        entries.removeAll {
            $0.requestId == requestId && $0.sessionId == sessionId
        }
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}

public struct PeelRemoteNotificationBanner: View {
    @ObservedObject private var inbox: PeelRemoteNotificationInbox

    public init(inbox: PeelRemoteNotificationInbox) {
        _inbox = ObservedObject(wrappedValue: inbox)
    }

    public var body: some View {
        if let entry = inbox.latest {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(entry.body)
                        .font(.subheadline)
                        .lineLimit(4)
                }
                Spacer(minLength: 0)
                Button("Dismiss") {
                    inbox.dismiss(
                        requestId: entry.requestId,
                        sessionId: entry.sessionId
                    )
                }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.semibold))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.title). \(entry.body)")
        }
    }
}

/// Presented inside a caller-owned `NavigationStack` sheet. The view owns its
/// Done control through the environment dismiss action, so callers should not
/// add another one.
public struct PeelRemoteNotificationInboxView: View {
    @ObservedObject private var inbox: PeelRemoteNotificationInbox
    @Environment(\.dismiss) private var dismiss

    public init(inbox: PeelRemoteNotificationInbox) {
        _inbox = ObservedObject(wrappedValue: inbox)
    }

    public var body: some View {
        Group {
            if inbox.entries.isEmpty {
                // Outside the List so the empty state centers in the sheet
                // instead of sitting in the first row.
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell",
                    description: Text("Updates from approved AI actions on your connected computer appear here when AI notifications are allowed.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entryList
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
            if !inbox.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") {
                        inbox.clear()
                    }
                }
            }
        }
    }

    private var entryList: some View {
        List {
            ForEach(inbox.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(entry.receivedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.body)
                        .font(.body)
                        .multilineTextAlignment(.leading)
                    Button("Dismiss") {
                        inbox.dismiss(
                            requestId: entry.requestId,
                            sessionId: entry.sessionId
                        )
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
        }
    }
}
#endif
