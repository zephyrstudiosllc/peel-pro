//
//  MacMechanicUpdaterController.swift
//  Kill Switch
//
//  Created by Zach on 4/17/26.
//


import Foundation
import Combine
import Sparkle

@MainActor
final class MacMechanicUpdaterController: NSObject, ObservableObject {
    static let shared = MacMechanicUpdaterController()
    struct PendingUpdate: Identifiable, Equatable {
        let id: String
        let version: String
        let title: String
        let summary: String
    }

    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var automaticallyChecksForUpdates: Bool = false
    @Published private(set) var automaticallyDownloadsUpdates: Bool = false
    @Published private(set) var allowsAutomaticUpdates: Bool = false
    @Published var pendingUpdate: PendingUpdate?

    let updaterSettings: SPUUpdaterSettings

    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()

    var updater: SPUUpdater {
        updaterController.updater
    }

    private var cancellables = Set<AnyCancellable>()

    override init() {
        updaterSettings = SPUUpdaterSettings(hostBundle: .main)
        super.init()

        _ = updaterController
        bindState()
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterSettings.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updaterSettings.automaticallyChecksForUpdates
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        updaterSettings.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = updaterSettings.automaticallyDownloadsUpdates
    }

    func dismissPendingUpdate() {
        pendingUpdate = nil
    }

    func showPendingUpdateNow() {
        updater.checkForUpdates()
    }

    private func bindState() {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updaterSettings.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updaterSettings.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updaterSettings.allowsAutomaticUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        updaterSettings.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)

        updaterSettings.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.automaticallyDownloadsUpdates = value
            }
            .store(in: &cancellables)

        updaterSettings.publisher(for: \.allowsAutomaticUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.allowsAutomaticUpdates = value
            }
            .store(in: &cancellables)
    }

    private func makeSummary(from item: SUAppcastItem) -> String {
        let raw = item.itemDescription ?? ""
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let trimmed = stripped
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty
            ? "A new App Mechanic update is available."
            : trimmed
    }
}

// MARK: - SPUUpdaterDelegate

extension MacMechanicUpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingUpdate = PendingUpdate(
            id: item.versionString,
            version: item.displayVersionString,
            title: item.title ?? "App Mechanic Update",
            summary: makeSummary(from: item)
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Intentionally conservative. We do not clear a visible pending update here.
    }

    func updaterShouldPromptForPermission(toCheckForUpdates updater: SPUUpdater) -> Bool {
        false
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension MacMechanicUpdaterController: SPUStandardUserDriverDelegate {
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // User-initiated checks should still use Sparkle's standard UI.
        // Scheduled checks can be surfaced by our in-app banner instead.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }

        pendingUpdate = PendingUpdate(
            id: update.versionString,
            version: update.displayVersionString,
            title: update.title ?? "App Mechanic Update",
            summary: makeSummary(from: update)
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        if pendingUpdate?.id == update.versionString {
            pendingUpdate = nil
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdate = nil
    }
}
