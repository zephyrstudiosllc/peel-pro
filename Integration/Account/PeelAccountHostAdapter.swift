import Foundation
import SwiftUI

@MainActor
enum PeelAccountHostAdapter {
    static func start(model: PeelUnifiedModel) {
        let account = PeelAccountController.shared
        account.localDeviceName = Host.current().localizedName ?? "Peel Pro on Mac"
        account.localPlatform = .mac
        account.agentSnapshotProvider = { [weak store = model.sidePulse, weak account] in
            guard let store, let account else { return [] }
            // Read the live Agent Hub snapshot, not hidden/cleared notch rows.
            return store.agents.prefix(PeelCloudDeviceMetadata.maximumAgents).map {
                PeelCloudAgentDigest.snapshot(localID: $0.id, deviceID: account.deviceID,
                    provider: $0.provider.rawValue, state: $0.state.rawValue, updatedAt: $0.updatedAt)
            }
        }
        account.startAutomaticSync(isForeground: true)
    }

    static func configure(model: PeelUnifiedModel, host: PeelHost) {
        PeelAccountController.shared.localDiscoveryID = host.stableHostIdentifier
    }
}

struct PeelHostAccountSection: View {
    @Environment(PeelUnifiedModel.self) private var model

    var body: some View {
        Section("Optional Apple Account & iCloud") {
            DisclosureGroup("Apple Account & Device Sync") {
                PeelAccountView(locallyTrustedDiscoveryIDs: model.accountLocallyTrustedDiscoveryIDs,
                                openAgentHub: { model.open(.agents) })
            }
        }
    }
}
