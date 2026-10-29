// Sign in with Apple entry for Mac pairing pages (opens System Settings only), the
// always-visible reminder that sign-in is optional and codes work across accounts, and
// read-only iCloud account status under a collapsed disclosure.
import AppKit
import CloudKit
import Combine
import Security
import SwiftUI

/// What macOS reports for this Mac's iCloud Apple Account. `.signedIn` means only
/// that an iCloud account is present: it does not prove Passwords & Keychain sync
/// is on and is not an Apple sign-in to Peel Pro. Nothing else (pairing toggles,
/// local profiles, ubiquity tokens, configuration or failed reads) maps to `.notSignedIn`.
enum PeelPairingAccountState: Equatable {
    case checking
    case signedIn
    case notSignedIn
    case restricted
    case temporarilyUnavailable
    case unknown
    case timedOut
    case failed
    case notSupported

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .signedIn
        case .noAccount: self = .notSignedIn
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .unknown
        @unknown default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .signedIn: "Signed in to iCloud"
        case .notSignedIn: "Not signed in to iCloud"
        case .restricted: "Restricted on this Mac"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        case .unknown: "Status unknown"
        case .timedOut: "No answer from iCloud yet"
        case .failed: "Couldn't check"
        case .notSupported: "Not checked in this copy of Peel Pro"
        }
    }

    var detail: String? {
        switch self {
        case .checking: nil
        case .signedIn: "Optional iCloud auto-pairing also needs Passwords & Keychain on."
        case .notSignedIn: "Optional iCloud auto-pairing needs this Mac signed in to iCloud in System Settings."
        case .restricted: "macOS limits iCloud access on this Mac."
        case .temporarilyUnavailable: "Check Apple Account in System Settings, then refresh."
        case .unknown: "macOS couldn't determine this Mac's iCloud account status."
        case .timedOut: "macOS didn't report the iCloud account status in time. Try Refresh."
        case .failed: "Peel Pro couldn't read the iCloud account status. This doesn't mean you're signed out."
        case .notSupported: "This copy can't read iCloud account status. That doesn't mean you're signed out."
        }
    }

    var symbol: String {
        switch self {
        case .checking: "icloud"
        case .signedIn: "checkmark.icloud"
        case .notSignedIn: "person.crop.circle.badge.xmark"
        case .restricted, .temporarilyUnavailable: "exclamationmark.icloud"
        case .unknown, .timedOut, .failed, .notSupported: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .signedIn: .green
        case .notSignedIn, .restricted, .temporarilyUnavailable: .orange
        default: .secondary
        }
    }
}

/// One `CKContainer.accountStatus()` read for Peel's existing container. No user
/// record, database, Keychain or pairing access.
struct PeelPairingAccountProbe {
    static let containerIdentifier = "iCloud.com.zephyrstudiosllc.Peel"
    static let containersKey = "com.apple.developer.icloud-container-identifiers"
    static let servicesKey = "com.apple.developer.icloud-services"

    let read: () async throws -> CKAccountStatus

    /// Nil in previews and when the running process's entitlements do not carry the
    /// exact CloudKit container; then CloudKit is never touched.
    static let live: PeelPairingAccountProbe? = {
        let process = ProcessInfo.processInfo
        guard !process.arguments.contains("--peel-preview"),
              process.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              let task = SecTaskCreateFromSelf(nil) else { return nil }
        let entitlements = [containersKey, servicesKey].reduce(into: [String: Any]()) { values, key in
            values[key] = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        }
        guard entitlementsAllowAccountStatus(entitlements) else { return nil }
        let container = CKContainer(identifier: containerIdentifier)
        return PeelPairingAccountProbe { try await container.accountStatus() }
    }()

    static func entitlementsAllowAccountStatus(_ entitlements: [String: Any],
                                               containerIdentifier: String = containerIdentifier) -> Bool {
        let containers = entitlements[containersKey] as? [String] ?? []
        let services = entitlements[servicesKey] as? [String] ?? []
        return containers.contains(containerIdentifier) && services.contains("CloudKit")
    }
}

/// Owns at most one live account read. Each appear, Refresh or account change starts a
/// new generation; answers from older generations, or after the page closes, are dropped.
/// A request made while a read is still running waits for it, then reads once more.
@MainActor
final class PeelPairingAccountMonitor: ObservableObject {
    enum Request { case appear, refresh, accountChanged, foreground }

    @Published private(set) var state: PeelPairingAccountState
    let canCheck: Bool
    private let probe: PeelPairingAccountProbe?
    private let timeout: Duration
    private var generation = 0
    private var readInFlight = false
    private var isVisible = false
    private var lastChecked: Date?
    private var timeoutTask: Task<Void, Never>?

    init(probe: PeelPairingAccountProbe?, timeout: Duration = .seconds(8)) {
        self.probe = probe
        self.timeout = timeout
        canCheck = probe != nil
        state = probe == nil ? .notSupported : .checking
    }

    func appear() {
        isVisible = true
        request(.appear)
    }

    func disappear() {
        isVisible = false
        generation += 1
        timeoutTask?.cancel()
    }

    func request(_ request: Request) {
        guard probe != nil, isVisible else { return }
        if request == .foreground {
            // App activation only refreshes a settled, older answer.
            guard !readInFlight, state != .checking,
                  lastChecked.map({ Date.now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        }
        generation += 1
        state = .checking
        startTimeout()
        if !readInFlight { startRead() }
    }

    private func startRead() {
        guard let probe else { return }
        readInFlight = true
        let readGeneration = generation
        Task { [weak self] in
            let result: PeelPairingAccountState
            do { result = PeelPairingAccountState(try await probe.read()) } catch { result = .failed }
            self?.finishRead(result, generation: readGeneration)
        }
    }

    private func finishRead(_ result: PeelPairingAccountState, generation readGeneration: Int) {
        readInFlight = false
        guard isVisible else { return }
        guard readGeneration == generation else {
            // A newer request arrived during this read; answer it with one fresh read.
            startRead()
            return
        }
        // Same generation: still the current question, even if it arrived after the timeout.
        timeoutTask?.cancel()
        state = result
        lastChecked = .now
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let timeoutGeneration = generation
        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.generation == timeoutGeneration,
                  self.state == .checking else { return }
            self.state = .timedOut
        }
    }
}

/// Sign in with Apple entry for Mac pairing pages, the optional-sign-in reminder, then the
/// read-only account status in a collapsed disclosure. The button only opens the system
/// Apple Account pane; Peel Pro has no in-app Apple sign-in and never signs in, reads
/// credentials or changes pairing here. Status checks only while visible: on appear,
/// Refresh, account change, or app activation.
@MainActor
struct PeelPairingAccountNotice: View {
    static let signInLabel = "Sign in with Apple"
    static let signInCaption = "Continues in System Settings."
    static let streamlineCopy = "Sign in with Apple to streamline pairing your devices."
    static let optionalCopy = "Sign-in is completely optional. Your devices can use different Apple IDs, or none, and still connect with a pairing code."
    static let openFailedCopy = "Couldn't open System Settings. Open it from the Apple menu and choose the sign-in item at the top of the sidebar."
    /// The Apple Account pane in System Settings (AppleIDSettings extension).
    static let appleAccountSettingsURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!

    @StateObject private var monitor: PeelPairingAccountMonitor
    @State private var openFailed = false
    private let openAppleAccountSettings: @MainActor () -> Bool

    private static func openSystemAppleSettings() -> Bool {
        let workspace = NSWorkspace.shared
        if workspace.open(appleAccountSettingsURL) { return true }
        guard let settings = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            return false
        }
        return workspace.open(settings)
    }

    init(probe: PeelPairingAccountProbe? = PeelPairingAccountProbe.live,
         openAppleAccountSettings: @escaping @MainActor () -> Bool = {
             PeelPairingAccountNotice.openSystemAppleSettings()
         }) {
        _monitor = StateObject(wrappedValue: PeelPairingAccountMonitor(probe: probe))
        self.openAppleAccountSettings = openAppleAccountSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                openFailed = !openAppleAccountSettings()
            } label: {
                Label(Self.signInLabel, systemImage: "apple.logo")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Open Apple Account in System Settings")
            Text(Self.signInCaption).font(.caption).foregroundStyle(.secondary)
            if openFailed {
                Label(Self.openFailedCopy, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.streamlineCopy).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.optionalCopy).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Apple pairing details") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: monitor.state.symbol).foregroundStyle(monitor.state.tint)
                        Text("\(Text("This Mac:").bold()) \(monitor.state.title)")
                        Spacer(minLength: 4)
                        if monitor.canCheck {
                            Button("Refresh", systemImage: "arrow.clockwise") { monitor.request(.refresh) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .help("Check this Mac's iCloud account status again")
                        }
                    }
                    .font(.callout)
                    if let detail = monitor.state.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { monitor.appear() }
        .onDisappear { monitor.disappear() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged).receive(on: RunLoop.main)) { _ in
            monitor.request(.accountChanged)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            monitor.request(.foreground)
        }
    }
}
