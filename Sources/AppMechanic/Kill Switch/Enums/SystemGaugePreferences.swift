//
//  SystemGaugePreferences.swift
//  Kill Switch
//

import Foundation

nonisolated enum SystemGaugeMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cpu
    case memory
    case disk
    case gpu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu:
            return "CPU"
        case .memory:
            return "RAM pressure"
        case .disk:
            return "Disk"
        case .gpu:
            return "GPU"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu:
            return "cpu"
        case .memory:
            return "memorychip"
        case .disk:
            return "internaldrive"
        case .gpu:
            return "display"
        }
    }

    fileprivate var bit: Int {
        switch self {
        case .cpu:
            return 1 << 0
        case .memory:
            return 1 << 1
        case .disk:
            return 1 << 2
        case .gpu:
            return 1 << 3
        }
    }
}

nonisolated enum SystemGaugeSelection {
    static let allMask = SystemGaugeMetric.allCases.reduce(0) { $0 | $1.bit }
    static let defaultMask = allMask

    static func metrics(in mask: Int) -> [SystemGaugeMetric] {
        SystemGaugeMetric.allCases.filter { contains($0, in: mask) }
    }

    static func contains(_ metric: SystemGaugeMetric, in mask: Int) -> Bool {
        mask & metric.bit != 0
    }

    static func setting(
        _ metric: SystemGaugeMetric,
        enabled: Bool,
        in mask: Int
    ) -> Int {
        enabled ? (mask | metric.bit) : (mask & ~metric.bit)
    }
}

nonisolated enum PopupGaugeDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case individual
    case combinedAverage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .individual:
            return "Individual Gauges"
        case .combinedAverage:
            return "Combined Average"
        }
    }
}

nonisolated enum TopAppMenuBarPresentation: String, CaseIterable, Identifiable, Sendable {
    case off
    case name
    case icon
    case iconAndName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .name:
            return "Name"
        case .icon:
            return "Icon"
        case .iconAndName:
            return "Icon + Name"
        }
    }

    var showsIcon: Bool {
        self == .icon || self == .iconAndName
    }

    var showsName: Bool {
        self == .name || self == .iconAndName
    }
}
