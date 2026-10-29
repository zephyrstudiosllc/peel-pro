//
//  Kill_SwitchApp.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//


import SwiftUI
import AppKit
import Sparkle
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let reopenControlPanelNotification = Notification.Name("ReopenControlPanelNotification")
    static weak var controlPanelWindow: NSWindow?
    static weak var processSampler: ProcessSampler?
    static var isOpeningControlPanel = false

    func applicationWillTerminate(_ notification: Notification) {
        Self.processSampler?.resumeAllHeldForTermination()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)

        if let existingWindow = Self.controlPanelWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            return false
        }

        guard Self.isOpeningControlPanel == false else {
            return false
        }

        Self.isOpeningControlPanel = true
        NotificationCenter.default.post(name: Self.reopenControlPanelNotification, object: nil)
        return false
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

final class MenuBarGaugeImageCache {
    private var cachedBucket: Int?
    private var cachedImage: NSImage?

    func image(for progress: Double) -> NSImage {
        let clampedProgress = min(max(progress, 0), 1)
        let bucket = Int((clampedProgress * 50).rounded())

        if cachedBucket == bucket, let cachedImage {
            return cachedImage
        }

        let bucketedProgress = Double(bucket) / 50.0
        let renderer = ImageRenderer(
            content: MenuBarGaugeIcon(progress: bucketedProgress)
        )
        renderer.proposedSize = .init(width: 18, height: 18)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true

        cachedBucket = bucket
        cachedImage = image
        return image
    }
}

#if !PEEL_HOST_INTEGRATION
@main
struct Kill_SwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sampler: ProcessSampler
    @StateObject private var systemMetrics = SystemMetricsStore()
    @AppStorage("prefersDockIconHidden") private var prefersDockIconHidden = true
    @AppStorage("showsTopAppInMenuBar") private var showsTopAppInMenuBar = true
    @AppStorage("launchAtLoginDesired") private var launchAtLoginDesired = true
    @AppStorage("hasShownFirstLaunchWindow") private var hasShownFirstLaunchWindow = false
    
    private let menuBarGaugeImageCache = MenuBarGaugeImageCache()
    private let updaterController: SPUStandardUpdaterController

    init() {
        let processSampler = ProcessSampler()
        _sampler = StateObject(wrappedValue: processSampler)
        AppDelegate.processSampler = processSampler

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
        if UserDefaults.standard.object(forKey: "launchAtLoginDesired") == nil {

            UserDefaults.standard.set(true, forKey: "launchAtLoginDesired")

        }

        let defaults = UserDefaults.standard
        let statusItemRollbackVersionKey = "statusItemRollbackVersion"
        if defaults.integer(forKey: statusItemRollbackVersionKey) < 1 {
            let presentationRawValue = defaults.string(
                forKey: "menuBarTopAppPresentation"
            )
            let presentation = presentationRawValue
                .flatMap(TopAppMenuBarPresentation.init(rawValue:))

            if let presentation {
                defaults.set(
                    presentation.showsName,
                    forKey: "showsTopAppInMenuBar"
                )
            } else if defaults.object(forKey: "showsTopAppInMenuBar") == nil {
                defaults.set(true, forKey: "showsTopAppInMenuBar")
            }

            defaults.set(1, forKey: statusItemRollbackVersionKey)
        }

        if UserDefaults.standard.bool(forKey: "launchAtLoginDesired") {

            Task { @MainActor in

                MechanicLaunchAtLoginManager().registerIfNeeded()

            }

        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(sampler)
                .environmentObject(systemMetrics)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: menuBarGaugeImage)
                    .renderingMode(.template)

                if showsTopAppInMenuBar {
                    Text(menuBarTitle)
                        .lineLimit(1)
                }
            }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("App Mechanic", id: "control-panel") {
            SettingsWindowView()
                .environmentObject(sampler)
                .environmentObject(systemMetrics)
                .background(ControlPanelWindowReader())
                .onAppear {
                    hasShownFirstLaunchWindow = true
                }
        }
        .defaultSize(width: 360, height: 280)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    private var menuBarTitle: String {
        if let topApp = sampler.topApp {
            return shortMenuBarName(for: topApp.appName)
        }

        if let error = sampler.lastError, !error.isEmpty {
            return "Error"
        }

        return "Idle"
    }
    
    private var menuBarGaugeProgress: Double {
        let clampedPercent = min(max(sampler.currentMetricLoadPercent, 0), 100)
        return clampedPercent / 100
    }

    private var menuBarGaugeImage: NSImage {
        menuBarGaugeImageCache.image(for: menuBarGaugeProgress)
    }

    private func shortMenuBarName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return "Unknown" }

        if trimmed.count <= 14 {
            return trimmed
        }

        return String(trimmed.prefix(14)) + "…"
    }
}

#endif

private struct MenuBarContentView: View {
    @EnvironmentObject private var sampler: ProcessSampler
    @EnvironmentObject private var systemMetrics: SystemMetricsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MechanicMenuContentView()
            .environmentObject(sampler)
            .environmentObject(systemMetrics)
            .background(FirstLaunchWindowOpener())
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.reopenControlPanelNotification)) { _ in
                if AppDelegate.controlPanelWindow == nil {
                    openWindow(id: "control-panel")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window == AppDelegate.controlPanelWindow else { return }

                AppDelegate.controlPanelWindow = nil
                AppDelegate.isOpeningControlPanel = false
            }
    }
}

private struct FirstLaunchWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasShownFirstLaunchWindow") private var hasShownFirstLaunchWindow = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                guard hasShownFirstLaunchWindow == false else { return }

                hasShownFirstLaunchWindow = true
                openWindow(id: "control-panel")

                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

private struct ControlPanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                AppDelegate.controlPanelWindow = window
                AppDelegate.isOpeningControlPanel = false
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                AppDelegate.controlPanelWindow = window
                AppDelegate.isOpeningControlPanel = false
            }
        }
    }
}
private struct MenuBarGaugeIcon: View {
    let progress: Double

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var needleAngle: Angle {
        .degrees(-120 + (240 * clampedProgress))
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.17, to: 0.83)
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(90))

            Circle()
                .trim(from: 0.17, to: 0.17 + (0.66 * clampedProgress))
                .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(90))

            Capsule()
                .fill(.white)
                .frame(width: 1.4, height: 5.0)
                .offset(y: -1.5)
                .rotationEffect(needleAngle)

            Circle()
                .fill(.white)
                .frame(width: 2.6, height: 2.6)
        }

        .padding(1)
        .background(Color.clear)
        .compositingGroup()
        .accessibilityHidden(true)
    }
}
