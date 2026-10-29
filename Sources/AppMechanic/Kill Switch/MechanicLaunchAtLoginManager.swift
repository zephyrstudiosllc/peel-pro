//
//  MechanicLaunchAtLoginManager.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//

import Foundation
import ServiceManagement
import Combine

@MainActor
final class MechanicLaunchAtLoginManager: ObservableObject {
    @Published var isEnabled = false
    @Published var requiresApproval = false
    @Published var errorMessage: String?

    init() {
        refreshStatus()
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

            refreshStatus()
            errorMessage = nil
        } catch {
            refreshStatus()
            errorMessage = error.localizedDescription
        }
    }

    func registerIfNeeded() {
        guard SMAppService.mainApp.status != .enabled else {
            refreshStatus()
            return
        }

        setEnabled(true)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshStatus() {
        let status = SMAppService.mainApp.status

        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false

        case .requiresApproval:
            isEnabled = false
            requiresApproval = true

        case .notFound, .notRegistered:
            isEnabled = false
            requiresApproval = false

        @unknown default:
            isEnabled = false
            requiresApproval = false
        }
    }

    var statusMessage: String {
        if isEnabled {
            return "App Mechanic will open automatically when you sign in."
        }

        if requiresApproval {
            return "macOS needs approval before App Mechanic can open automatically at login."
        }

        return "App Mechanic is not currently set to open at login."
    }
}
