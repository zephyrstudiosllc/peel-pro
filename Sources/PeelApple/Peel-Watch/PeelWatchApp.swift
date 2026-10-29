import SwiftUI

@main
struct PeelWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: PeelCompanionModel

    init() {
        let companion = PeelCompanionModel.shared
        _model = StateObject(wrappedValue: companion)
    }

    var body: some Scene {
        WindowGroup {
            PeelWatchHome(model: model)
                .preferredColorScheme(.dark)
                .tint(.orange)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        model.watchDidBecomeInactive()
                        Task { await PeelWatchCloudClient.shared.stop() }
                    }
                }
        }
    }
}
