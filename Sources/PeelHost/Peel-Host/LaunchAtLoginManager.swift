import Foundation
import ServiceManagement
import Combine
import AppKit

@MainActor
final class LaunchAtLoginManager: ObservableObject {

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()
    private var liveRefreshCancellable: AnyCancellable?

    init() {
        refresh()

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    func refresh() {
        let actualState = SMAppService.mainApp.status == .enabled

        if isEnabled != actualState {
            isEnabled = actualState
        }
    }

    func startLiveRefresh() {
        refresh()

        liveRefreshCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
    }

    func stopLiveRefresh() {
        liveRefreshCancellable?.cancel()
        liveRefreshCancellable = nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }

            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }
}
