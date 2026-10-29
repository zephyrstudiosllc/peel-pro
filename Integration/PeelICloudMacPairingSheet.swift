import SwiftUI

struct PeelICloudMacPairingSheet: View {
    @ObservedObject var controller: PeelICloudMacPairingController
    let onDone: () -> Void
    var onPairWithCode: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Apple pairing", systemImage: "apple.logo").font(.title2.bold())
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PeelPairingAccountNotice()
                    if let onPairWithCode {
                        Button("Use a Pairing Code…", systemImage: "number", action: onPairWithCode)
                            .help("Show this Mac's 6-digit code, or enter the code shown on your other Mac. No Apple Account needed.")
                    }
                    Divider()
                    Toggle("Pair my Macs automatically", isOn: Binding(
                        get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                        .disabled(!controller.isConfigured && !controller.isEnabled)
                    Text("Works only between Macs signed in to the same Apple ID, each with Passwords & Keychain on. On the Mac you want to view, also turn on iCloud Pairing in Remote Desktop › Share This Mac. Keychain sync may take time. Other Macs can always pair with a code.")
                    Text("For access away from home, connect both Macs to Tailscale and allow the connection in your tailnet. This does not configure Tailscale.")
                    Text(controller.isConfigured ? controller.status : PeelICloudPairingError.unavailable.localizedDescription)
                        .font(.callout).accessibilityLabel("Account pairing status: \(controller.status)")
                    HStack {
                        if controller.isBusy { ProgressView().controlSize(.small) }
                        Button("Refresh Macs") { controller.refresh() }
                            .disabled(!controller.isEnabled || controller.isBusy || !controller.isConfigured)
                    }
                    ForEach(controller.hosts) { host in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(host.displayName).font(.headline)
                            Text(host.detail).font(.callout).foregroundStyle(.secondary)
                            if host.canPairAgain {
                                Button("Pair Again") { controller.pairAgain(hostID: host.id) }
                                    .disabled(!controller.isEnabled || controller.isBusy)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Pairing saves a separate key and private address for each Mac. It does not connect, choose a desktop, enable input, or interrupt a session. Choose a saved address in Remote Desktop › Connect when you want to connect.")
                    Text("Turning this off keeps existing pairings. Forget a pairing in Remote Desktop › Share This Mac to remove its local access. Removed or revoked Macs stay out of automatic enrollment, even when their account key changes; Pair Again is an explicit retry.")
                    Text("Signing out of iCloud may leave cached keys. Revoke access on the remote Host before account or ownership changes. Account-change notifications pause enrollment when available and do not detect every Keychain change.")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 620, minHeight: 380, idealHeight: 560, maxHeight: 700)
        .onAppear { controller.refresh(automatically: true) }
    }
}
