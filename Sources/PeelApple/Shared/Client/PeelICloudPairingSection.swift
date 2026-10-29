import SwiftUI

struct PeelICloudPairingSection: View {
    @EnvironmentObject private var browser: PeelClientBrowser

    var body: some View {
        PeelICloudPairingControls(client: browser.iCloudPairingClient)
            .onChange(of: browser.pairingStateVersion) { _, _ in
                browser.iCloudPairingClient.localPairingsChanged()
            }
    }
}

private struct PeelICloudPairingControls: View {
    @ObservedObject var client: PeelICloudPairingClient

    var body: some View {
        Section("iCloud Pairing") {
            Toggle("Pair my devices with iCloud", isOn: Binding(
                get: { client.isEnabled },
                set: { client.setEnabled($0) }
            ))
            .disabled(!client.isConfigured && !client.isEnabled)

            Text("Use the same iCloud Apple Account on your devices, turn on Passwords & Keychain sync, and enable iCloud Pairing on your Mac. New devices may need approval before Keychain data arrives. This uses the system iCloud account and iCloud Keychain, not Apple sign-in in Peel Pro.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !client.isConfigured {
                Text("iCloud Pairing is unavailable in this build. Use a pairing code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if client.isEnabled {
                HStack {
                    Button("Refresh") { client.refresh(automatically: false) }
                        .disabled(client.isBusy)
                    if client.isBusy {
                        ProgressView()
                        Button("Cancel") { client.pause() }
                    }
                }
                .buttonStyle(.bordered)

                Text(client.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(client.hosts) { host in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(host.displayName).font(.headline)
                        Text(host.detail).font(.footnote).foregroundStyle(.secondary)
                        if host.canPairAgain {
                            Button("Pair Again") { client.pairAgain(hostID: host.id) }
                                .disabled(client.isBusy)
                        }
                    }
                }

                Text("To reach a remote Mac, connect both devices to Tailscale or your private network. Pairing saves the Mac for later; choose when to connect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(client.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { client.refresh() }
    }
}
