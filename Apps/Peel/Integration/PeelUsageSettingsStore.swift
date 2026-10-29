import Foundation
import Observation

@MainActor
@Observable
final class PeelUsageSettingsStore {
    private(set) var snapshot: PeelUsageSettingsSnapshot?
    private(set) var isRefreshing = false
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    private(set) var detailsErrorMessage: String?

    let isPreview: Bool

    @ObservationIgnored private var cancellation: PeelUsageCancellation?
    @ObservationIgnored private var generation = UUID()

    init(isPreview: Bool = ProcessInfo.processInfo.arguments.contains("--peel-preview")) {
        self.isPreview = isPreview
    }

    var providers: [PeelUsageSettingsProvider] {
        self.snapshot?.providers ?? []
    }

    func refresh() {
        guard !self.isPreview, !self.isRefreshing, !self.isUpdating else { return }

        let executable = Self.helperURL()
        let requestID = UUID()
        let token = PeelUsageCancellation()
        self.generation = requestID
        self.cancellation = token
        self.isRefreshing = true
        self.errorMessage = nil
        self.detailsErrorMessage = nil

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.read(executable: executable, cancellation: token)
            }.value
            guard let self, self.generation == requestID else { return }
            self.cancellation = nil
            self.isRefreshing = false
            switch result {
            case let .success(readResult):
                self.snapshot = readResult.snapshot
                self.detailsErrorMessage = readResult.detailsError
            case let .failure(error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setProviderEnabled(
        providerID: String,
        enabled: Bool,
        onSuccess: @escaping @MainActor () -> Void = {})
    {
        guard !self.isPreview, !self.isRefreshing, !self.isUpdating else { return }
        guard let provider = self.providers.first(where: { $0.id == providerID }),
              provider.enabled != enabled else { return }

        let executable = Self.helperURL()
        let requestID = UUID()
        let token = PeelUsageCancellation()
        self.generation = requestID
        self.cancellation = token
        self.isUpdating = true
        self.errorMessage = nil

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.update(
                    executable: executable,
                    cancellation: token,
                    providerID: provider.id,
                    enabled: enabled)
            }.value
            guard let self, self.generation == requestID else { return }
            self.cancellation = nil
            self.isUpdating = false
            switch result {
            case .success:
                onSuccess()
                self.refresh()
            case let .failure(error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPendingWork() {
        self.cancellation?.cancel()
        self.cancellation = nil
        self.generation = UUID()
        self.isRefreshing = false
        self.isUpdating = false
    }

    private struct ReadResult: Sendable {
        let snapshot: PeelUsageSettingsSnapshot
        let detailsError: String?
    }

    nonisolated private static let settingsTimeout: TimeInterval = 10

    private nonisolated static func helperURL() -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI")
    }

    private nonisolated static func read(
        executable: URL,
        cancellation: PeelUsageCancellation) -> Result<ReadResult, Error>
    {
        Result {
            let statusesData = try PeelUsageCommand.run(
                executable: executable,
                cancellation: cancellation,
                arguments: ["config", "providers", "--format", "json", "--json-only"],
                timeout: self.settingsTimeout)
            let statuses = try PeelUsageSettingsParser.parseStatuses(statusesData)

            do {
                let dumpData = try PeelUsageCommand.run(
                    executable: executable,
                    cancellation: cancellation,
                    arguments: ["config", "dump", "--format", "json", "--json-only"],
                    timeout: self.settingsTimeout)
                let options = try PeelUsageSettingsParser.parseConfigurationDump(dumpData)
                return ReadResult(
                    snapshot: PeelUsageSettingsParser.merge(
                        statuses: statuses,
                        optionsByProvider: options),
                    detailsError: nil)
            } catch {
                // The provider list remains useful when a config dump is unavailable. Keep the
                // error visible so the page never implies that stored settings were inspected.
                return ReadResult(
                    snapshot: PeelUsageSettingsParser.merge(
                        statuses: statuses,
                        optionsByProvider: nil),
                    detailsError: "Stored option details unavailable: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func update(
        executable: URL,
        cancellation: PeelUsageCancellation,
        providerID: String,
        enabled: Bool) -> Result<Void, Error>
    {
        Result {
            let arguments = [
                "config",
                enabled ? "enable" : "disable",
                "--provider",
                providerID,
                "--format",
                "json",
                "--json-only",
            ]
            let data = try PeelUsageCommand.run(
                executable: executable,
                cancellation: cancellation,
                arguments: arguments,
                timeout: self.settingsTimeout)
            try PeelUsageSettingsParser.parseToggle(
                data,
                providerID: providerID,
                enabled: enabled)
        }
    }
}
