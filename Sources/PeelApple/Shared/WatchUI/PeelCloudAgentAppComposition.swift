#if os(iOS)
import Foundation
import UIKit

/// Runtime registration remains mandatory. Startup never starts provider OAuth
/// or grants a restored account authority from saved metadata.
@MainActor
enum PeelCloudAgentAppComposition {
    enum State { case requiresConfiguration, installed }
    private static var startup: Task<State, Never>?
    private static var foregroundResume: (id: UUID, task: Task<Void, Never>)?
    @discardableResult static func start() async -> State {
        if let startup { return await startup.value }
        let task = Task { @MainActor in
            let service = PeelCloudAgentPhoneService.shared
            do {
                let watch = PeelCloudAgentWatchEnrollmentBridge()
                let connector = try PeelCloudAgentNativeBrokerConnector(watch: watch) { [weak service] response, enrollment in
                    guard let service else { throw CancellationError() }
                    try await service.authorizeExistingAgent(response, enrollment: enrollment)
                }
                await service.installBrokerConnector(connector)
                return State.installed
            } catch { service.requireBrokerSetup(); return State.requiresConfiguration }
        }
        startup = task
        return await task.value
    }
    static func resumeForeground() async {
        guard UIApplication.shared.applicationState == .active else { return }
        if let current = foregroundResume { await current.task.value; return }
        guard case .installed = await start(), UIApplication.shared.applicationState == .active else { return }
        // Another scene may have started a resume while startup was suspended.
        if let current = foregroundResume { await current.task.value; return }
        let id = UUID()
        let task = Task { @MainActor in
            guard UIApplication.shared.applicationState == .active else { return }
            await PeelCloudAgentPhoneService.shared.resumeConnections()
        }
        foregroundResume = (id, task)
        await task.value
        if foregroundResume?.id == id { foregroundResume = nil }
    }
}
#endif
