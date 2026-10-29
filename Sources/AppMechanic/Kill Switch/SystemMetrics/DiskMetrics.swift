//
//  DiskMetrics.swift
//  Kill Switch
//

import Foundation

/// Whether all requested disk values were available for this sample.
nonisolated enum DiskMetricsAvailability: Sendable, Equatable {
    case available
    case partial
    case unavailable
}

/// Capacity of the volume containing the configured root URL.
nonisolated struct DiskVolumeCapacity: Sendable, Equatable {
    let displayName: String
    let mountPath: String
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let usedPercent: Double
}

/// Best-effort physical block-storage counters and rates.
nonisolated struct DiskIOStatistics: Sendable, Equatable {
    nonisolated enum Source: Sendable, Equatable {
        /// Every included registry driver advertised a non-virtual physical interconnect.
        case physicalDevices

        /// Registry identity was incomplete, so one dominant writable device was used.
        case dominantWritableFallback
    }

    let cumulativeReadBytes: UInt64
    let cumulativeWriteBytes: UInt64
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let writeBytesPerSecond5Minutes: Double?
    let writeBytesPerSecond15Minutes: Double?
    let rateInterval: TimeInterval?
    let deviceCount: Int
    let source: Source
}

/// One cheap, synchronous disk sample. Call from a utility-priority task.
nonisolated struct DiskMetricsSnapshot: Sendable, Equatable {
    let sampledAt: Date
    let volume: DiskVolumeCapacity?
    let io: DiskIOStatistics?
    let availability: DiskMetricsAvailability

    /// Nil when the sample is fully available; safe to display or log otherwise.
    let errorDescription: String?
}
