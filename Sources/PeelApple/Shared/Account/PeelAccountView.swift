import SwiftUI
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct PeelAccountView: View {
    @StateObject private var account: PeelAccountController
    var locallyTrustedDiscoveryIDs: Set<String> = []
    var openAgentHub: (() -> Void)?

    init(account: PeelAccountController? = nil, locallyTrustedDiscoveryIDs: Set<String> = [],
         openAgentHub: (() -> Void)? = nil) {
        _account = StateObject(wrappedValue: account ?? .shared)
        self.locallyTrustedDiscoveryIDs = locallyTrustedDiscoveryIDs
        self.openAgentHub = openAgentHub
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use Peel Pro without an account").font(.headline)
            Text("Nearby discovery and manual PIN pairing stay available. Apple sign-in and iCloud metadata sync are optional. Apple sign-in never pairs or connects devices; optional iCloud Pairing is a separate setting.")
                .font(.caption).foregroundStyle(.secondary)

            localIdentitySection
            Text(account.identityStatus).font(.caption).foregroundStyle(.secondary)
            PeelCompanyAccountView(local: account)
            Divider()
            Toggle("Sync device and agent status with iCloud", isOn: Binding(
                get: { account.syncEnabled || account.isEnablingSync },
                set: { enabled in Task { await account.setSyncEnabled(enabled) } }
            ))
            .disabled(!account.cloudConfigured)
            Text("Uses the system iCloud account, independently of Apple sign-in. Sync shares device labels and bounded agent provider/status summaries. Pairing keys, PINs, messages, task titles, paths and screens stay out of this metadata sync.")
                .font(.caption).foregroundStyle(.secondary)
            Text(account.cloudStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh iCloud", systemImage: "arrow.clockwise") {
                    Task { await account.checkAppleCredential(); await account.refreshCloud() }
                }
                .disabled(!account.syncEnabled || account.isBusy)
                if let openAgentHub { Button("Open Local Agent Hub", action: openAgentHub) }
                if account.isBusy { ProgressView().controlSize(.small) }
            }
            if let date = account.lastSyncedAt {
                Text("Last sync: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(account.devices.prefix(32))) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(device.displayName, systemImage: symbol(device.platform))
                        Spacer()
                        Text(disposition(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !device.agents.isEmpty {
                        Text(device.agents.prefix(4).map { "\($0.provider) · \(stateName($0.state))" }.joined(separator: "  •  "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }
            if account.syncEnabled {
                Button("Remove This Device from iCloud", role: .destructive) {
                    Task { await account.removeThisDeviceFromCloud() }
                }
                .disabled(account.isBusy)
                Text("Sync refreshes automatically while Peel Pro is running on Mac, or in the foreground on iPhone, iPad and Vision Pro. Pair locally to connect. Turning sync off stops updates; entries stop appearing within 30 days. Expired metadata may remain in your private iCloud data.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var localIdentitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let profile = account.profile {
                Label("Apple profile on this device", systemImage: "person.crop.circle.badge.checkmark")
                if let email = profile.email {
                    Text(email).font(.caption).textSelection(.enabled)
                    Text(profile.usesPrivateRelay ? "Local Apple Private Relay address" : "Email in this device's local Apple profile")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Sign Out on This Device", role: .destructive) { account.signOut() }
                Text("Sign-out clears local Apple and company credentials and stops this device's metadata sync. Pairings and system iCloud remain available.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if account.nativeAppleSignInConfigured && !account.company.isConfigured {
#if os(iOS) || os(visionOS)
                PeelCompanyNativeAppleButton(type: .signIn, enabled: true) { window in
                    Task { await account.signInLocallyWithApple(using: PeelCompanyNativeAuthorizer(anchor: window)) }
                }.frame(maxWidth: 320).frame(height: 44)
#endif
                Text("This Apple profile stays on this device. A company account is not created by this local-only flow.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !account.nativeAppleSignInConfigured {
#if os(macOS)
                Text("Apple sign-in is unavailable in this Mac edition. Private iCloud sync is independent.")
#else
                Text("Apple sign-in is not available in this build yet. You can use Peel without an account.")
#endif
            }
        }
    }

    private func disposition(_ device: PeelCloudDeviceMetadata) -> String {
        if device.id == account.deviceID { return "This device" }
        if let discoveryID = device.discoveryID,
           locallyTrustedDiscoveryIDs.contains(where: { UUID(uuidString: $0)?.uuidString == discoveryID }) { return "Paired locally" }
        return "Pair to connect"
    }
    private func symbol(_ platform: PeelCloudDeviceMetadata.Platform) -> String {
        switch platform { case .mac: "desktopcomputer"; case .iPhone: "iphone"; case .iPad: "ipad"; case .vision: "visionpro" }
    }
    private func stateName(_ state: String) -> String {
        switch state { case "toolRunning": "Using tool"; case "waiting": "Needs attention"; default: state.capitalized }
    }
}
