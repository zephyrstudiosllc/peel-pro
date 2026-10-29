import AppKit
import SwiftUI

struct PeelDirectConnectionSection: View {
    @ObservedObject var host: PeelHost
    @State private var expanded = false
    private let externalExpanded: Binding<Bool>?
    @State private var portText = ""
    @State private var message: String?

    init(host: PeelHost, isExpanded: Binding<Bool>? = nil) {
        self.host = host
        self.externalExpanded = isExpanded
    }

    private var expandedBinding: Binding<Bool> {
        externalExpanded ?? $expanded
    }

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save a fixed port before adding this Mac's private-network or VPN address on your paired device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(host.listeningPort.map { "Listening on port \(String($0))" } ?? "Not listening")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    if let port = host.listeningPort {
                        Button("Copy Port") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(port), forType: .string)
                        }
                    }
                }

                HStack {
                    TextField("Fixed port (1–65535)", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 190)
                    Button("Apply & Reconnect") {
                        guard let port = PeelDirectConnectionSettings.parsePort(portText) else {
                            message = "Enter a port from 1 to 65535."
                            return
                        }
                        host.setPreferredListeningPort(port)
                        message = "Fixed port saved. Reconnect your paired devices."
                    }
                    .disabled(PeelDirectConnectionSettings.parsePort(portText) == nil)
                }

                HStack {
                    if let port = host.listeningPort, host.preferredListeningPort != port {
                        Button("Keep Current Port") {
                            portText = String(port)
                            host.setPreferredListeningPort(port)
                            message = "Current port saved. Reconnect your paired devices."
                        }
                    }
                    if host.preferredListeningPort != nil {
                        Button("Use Automatic Port") {
                            host.setPreferredListeningPort(nil)
                            portText = ""
                            message = "Automatic port restored. Update any saved addresses before reconnecting."
                        }
                    }
                }

                Text(host.preferredListeningPort.map { "Fixed port: \(String($0))" } ?? "Automatic port: may change when Peel Pro restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Applying a port disconnects the current session. Pair on the local network first; saved addresses use that same pairing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Direct Connections", systemImage: "network")
                .font(.headline)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            portText = (host.preferredListeningPort ?? host.listeningPort).map(String.init) ?? ""
        }
    }
}
