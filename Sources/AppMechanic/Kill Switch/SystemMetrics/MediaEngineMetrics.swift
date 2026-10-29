//
//  MediaEngineMetrics.swift
//  Kill Switch
//

import Foundation

/// Opportunistic media-engine activity reported by the GPU driver.
///
/// A missing value means the driver did not publish a recognizable numeric
/// statistic. It must not be displayed as zero.
nonisolated struct MediaEngineMetrics: Sendable, Equatable {
    let encodeUtilizationPercent: Double?
    let decodeUtilizationPercent: Double?

    static let unavailable = MediaEngineMetrics(
        encodeUtilizationPercent: nil,
        decodeUtilizationPercent: nil
    )

    var hasAnyAvailableMetric: Bool {
        encodeUtilizationPercent != nil || decodeUtilizationPercent != nil
    }

    var availabilityText: String {
        switch (encodeUtilizationPercent, decodeUtilizationPercent) {
        case (.some, .some):
            return "The GPU driver exposes separate video encode and decode activity."
        case (.some, .none):
            return "The GPU driver exposes video encode activity, but not separate decode activity."
        case (.none, .some):
            return "The GPU driver exposes video decode activity, but not separate encode activity."
        case (.none, .none):
            return "Separate video encode and decode activity is not exposed by this GPU driver."
        }
    }
}
