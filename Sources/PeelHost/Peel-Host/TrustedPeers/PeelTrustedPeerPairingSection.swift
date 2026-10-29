//
//  PeelTrustedPeerPairingSection.swift
//  Peel-Host
//

import SwiftUI

/// A deliberately explicit UI for pairing this Mac with another Peel Host.
/// Discovery is passive; the user must select a peer and enter its current PIN.
struct PeelTrustedPeerPairingSection: View {
    @ObservedObject var controller: PeelTrustedPeerPairingController
    @State private var pin = ""
    @State private var confirmForget: PeelPairedPeer?

    init(controller: PeelTrustedPeerPairingController) {
        self.controller = controller
    }

    var body: some View {
        Section("Pair With Another Computer") {
            Text("Select the other computer and enter the six-digit PIN shown in its Peel Pro. Pairing never starts automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Six-digit PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
                .frame(maxWidth: 180)

            if controller.discoveredPeers.isEmpty {
                Label("Looking for computers running Peel Pro on the local network…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.discoveredPeers) { service in
                    HStack(alignment: .center, spacing: 12) {
                        Text(service.serviceName)
                            .font(.headline)

                        Spacer(minLength: 8)

                        Button(controller.pendingServiceID == service.id ? "Pairing…" : "Pair") {
                            _ = controller.beginPairing(remote: service, pin: pin)
                        }
                        .disabled(controller.isPairing || controller.retryingSavedPairingID != nil || !isValidPIN)
                    }
                }
            }

            if controller.isPairing {
                Button("Cancel Pairing", role: .cancel) {
                    controller.cancelPairing()
                }
            }

            if !controller.pairingStatus.isEmpty {
                Text(controller.pairingStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if controller.pairedPeers.isEmpty {
                Text("No paired devices yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Paired devices")
                    .font(.headline)

                ForEach(controller.pairedPeers) { peer in
                    HStack(alignment: .center, spacing: 12) {
                        Text(peer.displayName)
                            .font(.body)

                        Spacer(minLength: 8)

                        if controller.canRetrySavedConnection(pairingID: peer.id) {
                            Button("Retry saved connection") {
                                controller.retrySavedConnection(pairingID: peer.id)
                            }
                            .disabled(controller.isPairing || controller.retryingSavedPairingID != nil)
                        }

                        Button("Unpair", role: .destructive) {
                            confirmForget = peer
                        }
                    }
                }
            }
        }
        .onAppear {
            controller.startDiscovery()
        }
        .onDisappear {
            if controller.isPairing {
                controller.cancelPairing()
            }
            controller.stopDiscovery()
        }
        .alert("Unpair device?", isPresented: Binding(
            get: { confirmForget != nil },
            set: { if !$0 { confirmForget = nil } }
        )) {
            Button("Unpair", role: .destructive) {
                if let peer = confirmForget {
                    _ = controller.forgetPeer(pairingID: peer.id)
                }
                confirmForget = nil
            }
            Button("Cancel", role: .cancel) {
                confirmForget = nil
            }
        } message: {
            if let peer = confirmForget {
                Text("This will revoke access for “\(peer.displayName)”. If it’s currently connected, it will be disconnected immediately.")
            } else {
                Text("")
            }
        }
    }

    private var isValidPIN: Bool {
        pin.count == 6 && pin.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
    }
}
