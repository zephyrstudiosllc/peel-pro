import SwiftUI
import PeelShellCore
import PeelShellUI

/// Development entry only. This deliberately does not make a commercial tier decision.
enum PeelShellPreviewPolicy {
    static var isEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }
}

#if DEBUG
/// Read-only adapter from saved Peel pairing metadata. Names never select a machine or SSH endpoint.
struct PeelShellPreviewView: View {
    @ObservedObject var pairingStore: PeelPairingStore

    var body: some View {
        List {
            Section {
                Text("Development preview. Choose a paired computer, then enter its SSH address and verify its host key. SSH must already be available on that computer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Choose a machine") {
                if pairingStore.paired.isEmpty {
                    Text("Pair a computer in Peel Pro before opening Shell Preview.")
                }
                ForEach(pairingStore.paired) { peer in
                    if let hostID = peer.stableHostId.flatMap(UUID.init(uuidString:)) {
                        NavigationLink {
                            PeelSelectedMachineShellPreview(pairingStore: pairingStore,
                                                            pairingID: peer.id, hostID: hostID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(peer.displayName, systemImage: "desktopcomputer")
                                Text(hostID.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("shell-preview-machine-\(hostID.uuidString)")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(peer.displayName)
                            Text("A stable machine ID is unavailable. Connect or pair this computer again before using Shell Preview.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Shell Preview")
    }
}

private struct PeelSelectedMachineShellPreview: View {
    @ObservedObject var pairingStore: PeelPairingStore
    let pairingID: String
    let hostID: UUID
    @State private var trustStore: FileSSHTrustStore?
    @State private var storeError: String?

    private var selectedPeer: PeelPairedPeer? {
        pairingStore.paired.first {
            $0.id == pairingID && $0.stableHostId.flatMap(UUID.init(uuidString:)) == hostID
        }
    }

    var body: some View {
        Group {
            if let peer = selectedPeer {
                if let trustStore {
                    PeelShellView(
                        target: PeelShellTarget(hostID: hostID, displayName: peer.displayName,
                                                endpoint: SSHEndpoint(host: "", username: "")),
                        trustStore: trustStore,
                        title: "Shell Preview"
                    )
                    .id(pairingID + ":" + hostID.uuidString)
                } else if let storeError {
                    ContentUnavailableView("SSH trust storage unavailable", systemImage: "exclamationmark.lock",
                                           description: Text(storeError))
                } else {
                    ProgressView("Preparing Shell Preview…")
                }
            } else {
                // Removing/replacing the exact pairing removes the shell view, which disconnects its PTY.
                ContentUnavailableView("Machine pairing changed", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Return to the machine list and select a current pairing."))
            }
        }
        .navigationTitle("Shell Preview")
        .task {
            guard trustStore == nil, storeError == nil else { return }
            do { trustStore = try FileSSHTrustStore.defaultStore() }
            catch { storeError = error.localizedDescription }
        }
    }
}
#endif
