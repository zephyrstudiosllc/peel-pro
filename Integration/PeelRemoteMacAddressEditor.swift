//
//  PeelRemoteMacAddressEditor.swift
//  Peel Host
//
//  Explicit editor for a credential-free address belonging to an existing
//  pairing. Persistence belongs to the injected save callback.
//

import SwiftUI

struct PeelRemoteMacAddressEditor: View {
    private let editingRecordID: UUID?
    private let pairedPeers: [PeelPairedPeer]
    private let onSave: (PeelRemoteMacAddressRecord) throws -> Void
    private let onCompletion: () -> Void

    @State private var selectedPairingID: String
    @State private var displayName: String
    @State private var host: String
    @State private var port: String
    @State private var message: String?

    init(
        record: PeelRemoteMacAddressRecord? = nil,
        pairedPeers: [PeelPairedPeer],
        onSave: @escaping (PeelRemoteMacAddressRecord) throws -> Void,
        onCompletion: @escaping () -> Void
    ) {
        self.editingRecordID = record?.id
        self.pairedPeers = pairedPeers
        self.onSave = onSave
        self.onCompletion = onCompletion
        _selectedPairingID = State(initialValue: record?.pairingID ?? pairedPeers.first?.id ?? "")
        _displayName = State(initialValue: record?.displayName ?? pairedPeers.first?.displayName ?? "")
        _host = State(initialValue: record?.host ?? "")
        _port = State(initialValue: record.map { String($0.port) } ?? "")
    }

    private var sortedPeers: [PeelPairedPeer] {
        pairedPeers.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var canSave: Bool {
        !pairedPeers.isEmpty && !selectedPairingID.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Computer") {
                    if sortedPeers.isEmpty {
                        Text("Pair a computer before saving a direct address.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Computer", selection: $selectedPairingID) {
                            ForEach(sortedPeers) { peer in
                                Text(peer.displayName.isEmpty ? "Paired Computer" : peer.displayName)
                                    .tag(peer.id)
                            }
                        }
                    }

                    Text("Use an address reachable on your private network or VPN. Peel Pro connects directly; it is not an internet relay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Address") {
                    Text("Enter the address and listening port shown in Peel Pro on the other computer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Host name, IP address, or Tailscale name", text: $host)
                        .textFieldStyle(.roundedBorder)

                    TextField("Port (1–65535)", text: $port)
                        .textFieldStyle(.roundedBorder)

                    TextField("Display name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editingRecordID == nil ? "Add Computer Address" : "Edit Computer Address")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCompletion)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private func save() {
        guard let peer = pairedPeers.first(where: { $0.id == selectedPairingID }) else {
            message = "Choose an existing paired computer."
            return
        }

        guard let portValue = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = PeelRemoteMacAddressValidationError.invalidPort.localizedDescription
            return
        }

        do {
            let record = try PeelRemoteMacAddressRecord(
                id: editingRecordID ?? UUID(),
                pairingID: peer.id,
                displayName: displayName,
                host: host,
                port: portValue)
            try onSave(record)
            onCompletion()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
