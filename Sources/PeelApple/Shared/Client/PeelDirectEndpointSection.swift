//
//  PeelDirectEndpointSection.swift
//  Peel
//

import SwiftUI

struct PeelDirectEndpointSection: View {
    @EnvironmentObject private var browser: PeelClientBrowser

    private var clientProductName: String {
#if os(visionOS)
        return "Peel Pro"
#elseif os(iOS)
        return "Peel Pro"
#else
        return "Peel Pro"
#endif
    }

    var body: some View {
        Section("Connect by Address") {
            Text("Use an address for a computer that is already paired and reachable on your private network or VPN. \(clientProductName) does not provide an internet relay.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("On a Mac, turn on Direct Connections in Peel Pro's sharing settings to keep a fixed port, then copy it here.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if browser.pairingStore.paired.isEmpty {
                Text("Pair a computer first, then save its reachable address here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browser.pairingStore.paired) { peer in
                    PeelDirectEndpointRow(
                        peer: peer,
                        record: browser.directEndpointRecord(for: peer.id)
                    )
                }
            }
        }
    }
}

private struct PeelDirectEndpointRow: View {
    @EnvironmentObject private var browser: PeelClientBrowser

    let peer: PeelPairedPeer
    let record: PeelDirectEndpointRecord?

    private var clientProductName: String {
#if os(visionOS)
        return "Peel Pro"
#elseif os(iOS)
        return "Peel Pro"
#else
        return "Peel Pro"
#endif
    }

    @State private var host: String
    @State private var port: String
    @State private var message: String?

    init(peer: PeelPairedPeer, record: PeelDirectEndpointRecord?) {
        self.peer = peer
        self.record = record
        _host = State(initialValue: record?.endpoint.host ?? "")
        _port = State(initialValue: record.map { String($0.endpoint.port) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(peer.displayName)
                .font(.headline)

            TextField("Host name or IP address", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Port", text: $port)

            HStack {
                Button(record == nil ? "Save Address" : "Update Address") {
                    save()
                }
                .buttonStyle(.borderedProminent)

                if record != nil {
                    Button("Connect by Address") {
                        if browser.connectToDirectEndpoint(for: peer.id) {
                            message = "Connecting by address…"
                        } else {
                            message = browser.status
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Remove", role: .destructive) {
                        let result = browser.removeDirectEndpoint(for: peer.id)
                        message = result.userMessage
                    }
                    .buttonStyle(.bordered)
                }
            }

            if record == nil, peer.tlsPSKOrder == nil {
                Text("Connect to this computer once on the local network so \(clientProductName) can learn its TLS compatibility before saving a direct address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if browser.isConnectedToDirectEndpoint(for: peer.id) {
                Label("Connected by address", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        guard let portValue = UInt16(port),
              let endpoint = PeelDirectEndpoint(host: host, port: portValue) else {
            message = PeelDirectEndpointMutationResult.invalidEndpoint.userMessage
            return
        }

        let result = browser.saveDirectEndpoint(for: peer.id, endpoint: endpoint)
        message = result.userMessage
    }
}
