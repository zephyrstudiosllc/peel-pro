//
//  PeelUpdaterController.swift
//  Peel-Host
//
//  Created by Zach on 3/13/26.
//


//
//  PeelUpdaterController.swift
//  Peel
//

import Foundation
import Combine
import AppKit
import Sparkle

@MainActor
final class PeelUpdaterController: NSObject, ObservableObject {
    struct PendingUpdate: Identifiable, Equatable {
        let id: String
        let version: String
        let title: String
        let summary: String
    }

    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var automaticallyChecksForUpdates: Bool = true
    @Published private(set) var automaticallyDownloadsUpdates: Bool = true
    @Published private(set) var allowsAutomaticUpdates: Bool = false
    @Published var pendingUpdate: PendingUpdate?

    private static let sparkleAutomaticChecksKey = "SUEnableAutomaticChecks"
    private static let sparkleAutomaticDownloadsKey = "SUAutomaticallyUpdate"

    private let manualDownloadURL = URL(string: "https://peelpro.app")!

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

    var automaticUpdatesEnabled: Bool {
        automaticallyChecksForUpdates && automaticallyDownloadsUpdates
    }

    var updateActionTitle: String {
        pendingUpdate == nil ? "Check for Updates…" : "Update Now…"
    }

    private var cancellables: Set<AnyCancellable> = []

    override init() {
        self.updaterSettings = SPUUpdaterSettings(hostBundle: .main)
        super.init()

#if PEEL_HOST_INTEGRATION
        if ProcessInfo.processInfo.arguments.contains("--peel-preview") { return }
#endif
        seedAutomaticUpdateDefaultsIfNeeded()

        _ = updaterController
        bindState()
        refreshStateFromSettings()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        performUpdateAction()
    }

    func checkForUpdatesInBackground() {
        guard updaterSettings.automaticallyChecksForUpdates else { return }
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    func openManualDownloadPage() {
        NSWorkspace.shared.open(manualDownloadURL)
    }

    func performUpdateAction() {
        guard updater.canCheckForUpdates else { return }
        pendingUpdate = nil
        updater.checkForUpdates()
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        updaterSettings.automaticallyChecksForUpdates = enabled
        updaterSettings.automaticallyDownloadsUpdates = enabled
        refreshStateFromSettings()
    }

    func setAutomaticDownloadsEnabled(_ enabled: Bool) {
        setAutomaticUpdatesEnabled(enabled)
    }

    func dismissPendingUpdate() {
        pendingUpdate = nil
    }

    func showPendingUpdateNow() {
        performUpdateAction()
    }

    private func seedAutomaticUpdateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Self.sparkleAutomaticChecksKey) == nil {
            updaterSettings.automaticallyChecksForUpdates = true
        }

        if defaults.object(forKey: Self.sparkleAutomaticDownloadsKey) == nil {
            updaterSettings.automaticallyDownloadsUpdates = true
        }
    }

    private func refreshStateFromSettings() {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updaterSettings.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updaterSettings.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updaterSettings.allowsAutomaticUpdates
    }

    private func bindState() {
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
            ? "A new Peel Pro update is available."
            : trimmed
    }
}

// MARK: - SPUUpdaterDelegate

extension PeelUpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        pendingUpdate = PendingUpdate(
            id: item.versionString,
            version: item.displayVersionString,
            title: item.title ?? "Peel Pro Update",
            summary: makeSummary(from: item)
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Clear only if the current pending update is stale or user initiated check found nothing.
        // Leaving this intentionally conservative.
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension PeelUpdaterController: SPUStandardUserDriverDelegate {
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // We handle scheduled update attention with a lightweight in-app banner.
        // The banner action hands off to Sparkle's standard updater flow.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }

        pendingUpdate = PendingUpdate(
            id: update.versionString,
            version: update.displayVersionString,
            title: update.title ?? "Peel Pro Update",
            summary: makeSummary(from: update)
        )
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        if pendingUpdate?.id == update.versionString {
            pendingUpdate = nil
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Do not clear pendingUpdate here.
        // Scheduled/background checks may finish right after we store the update.
        // The banner should remain visible until the user chooses to update.
    }
}
