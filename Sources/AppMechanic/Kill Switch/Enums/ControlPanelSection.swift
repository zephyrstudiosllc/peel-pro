//
//  ControlPanelSection.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//

import Foundation

enum ControlPanelSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case alerts
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .alerts:
            return "Alerts"
        case .settings:
            return "Settings"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "house"
        case .alerts:
            return "bell.badge"
        case .settings:
            return "gearshape"
        case .about:
            return "info.circle"
        }
    }

    static let overviewSections: [ControlPanelSection] = [
        .home
    ]

    static let utilitySections: [ControlPanelSection] = [
        .alerts
    ]

    static let applicationSections: [ControlPanelSection] = [
        .settings, .about
    ]
}
