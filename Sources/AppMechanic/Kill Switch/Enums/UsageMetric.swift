//
//  UsageMetric.swift
//  Kill Switch
//
//  Created by Zach on 4/16/26.
//


//
//  UsageMetric.swift
//  Kill Switch
//

import Foundation

enum UsageMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"

    var id: String { rawValue }

    var psSortKey: String {
        switch self {
        case .cpu:
            return "%cpu"
        case .memory:
            return "rss"
        }
    }

    var displayName: String { rawValue }
}