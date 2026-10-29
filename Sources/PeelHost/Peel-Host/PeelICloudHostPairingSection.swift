import SwiftUI

struct PeelICloudHostPairingSection: View {
    @ObservedObject var controller: PeelICloudHostPairingController
    @State private var expanded = false
    @State private var endpointText = ""
    @State private var portText = ""
    @State private var confirmRotation = false
    @State private var showsConnectionDetails = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Pair my Apple devices with iCloud", isOn: Binding(
                    get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                    .disabled(!controller.isConfigured && !controller.isEnabled)
                Text("Optional convenience: devices using the same Apple Account with Passwords & Keychain enabled can pair automatically. Devices on different Apple Accounts, or none, can always pair with this Mac's 6-digit code. Turn on iCloud Pairing in Peel Pro on each device; new devices may need approval before their keys arrive. This uses the system iCloud account and iCloud Keychain, not Apple sign-in in Peel Pro.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("For access away from home, connect both devices to Tailscale. Pairing saves this Mac; you choose when to connect.")
                    .font(.caption).foregroundStyle(.secondary)

                Text(controller.isConfigured ? controller.status : PeelICloudPairingError.unavailable.localizedDescription)
                    .font(.callout).accessibilityLabel("iCloud pairing status: \(controller.status)")

                HStack {
                    Text("\(controller.cloudDeviceCount) account-paired device\(controller.cloudDeviceCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh", action: controller.refreshRegistration)
                        .disabled(!controller.isConfigured || !controller.isEnabled)
                }
                Text("Turning this off stops new automatic pairings. Existing devices keep access until you remove their pairing.")
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup("Connection & Recovery", isExpanded: $showsConnectionDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Tailscale address (automatic if blank)", text: $endpointText)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Pairing port", text: $portText)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                            Button("Save & Retry") { _ = controller.saveEndpoint(endpointText, portText: portText) }
                                .disabled(!controller.isConfigured)
                        }
                        if !controller.endpoint.isEmpty {
                            Text("\(controller.endpoint) · Pairing port \(String(controller.pairingPort))")
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                        Text("A custom pairing port must differ from the connection port in Direct Connections. Keep a fixed connection port there for reliable saved addresses.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Reset iCloud Pairing…", role: .destructive) { confirmRotation = true }
                            .disabled(!controller.isEnabled)
                        Text("For a lost device, remove it from your Apple Account and Tailscale, then reset its Peel access here. Signing out can leave saved keys behind. Before changing this Mac's Apple Account or owner, turn off iCloud Pairing and remove its existing device pairings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
                Text("Before changing accounts or ownership on a shared Mac, turn this off and revoke account devices. An account-change notification pauses enrollment when available; it cannot detect every Keychain account change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            Label("iCloud Pairing", systemImage: "icloud")
                .font(.headline)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            endpointText = controller.manualEndpoint
            portText = String(controller.pairingPort)
        }
        .confirmationDialog("Reset iCloud Pairing?", isPresented: $confirmRotation, titleVisibility: .visible) {
            Button("Reset & Remove iCloud Pairings", role: .destructive) { controller.rotateAndRevokeAccountDevices() }
        } message: {
            Text("Removes this Mac's iCloud device pairings and replaces its shared key. Code pairings stay available. Devices still approved for your iCloud Keychain can pair again after sync; previously removed installations stay blocked.")
        }
    }
}
