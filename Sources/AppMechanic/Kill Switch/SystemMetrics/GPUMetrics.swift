//
//  GPUMetrics.swift
//  Kill Switch
//

import Foundation

/// Describes how optional IORegistry statistics were associated with a Metal
/// device. The scope is useful when presenting multi-GPU results.
nonisolated enum GPUDriverMetricScope: String, Sendable, Equatable {
    case unavailable
    case defaultMetalDevice
    case onlyRegistryDevice
    case multipleRegistryDevices

    var description: String {
        switch self {
        case .unavailable:
            return "No recognizable GPU driver statistics are available."
        case .defaultMetalDevice:
            return "Driver statistics were matched to the default Metal GPU."
        case .onlyRegistryDevice:
            return "Driver statistics came from the only GPU registry entry that exposed them."
        case .multipleRegistryDevices:
            return "Multiple GPU registry entries exposed statistics; percentages represent the busiest exposed device, not an aggregate."
        }
    }
}

/// A lightweight, immutable GPU sample that is safe to move across concurrency
/// domains.
///
/// All driver-derived values are optional by design. IORegistry statistic keys
/// are driver implementation details and are not present on every Mac or OS
/// release. Callers should render `nil` as unavailable, never as zero.
nonisolated struct GPUMetricsSnapshot: Sendable, Equatable {
    let sampledAt: Date

    /// The default Metal device's public display name.
    let deviceName: String?

    /// Public Metal device names visible to this process.
    let availableDeviceNames: [String]

    /// Overall device utilization from a recognizable driver statistic.
    let utilizationPercent: Double?

    /// Driver-reported GPU-addressable memory currently in use.
    let memoryUsedBytes: UInt64?

    /// Driver-reported memory currently allocated for GPU use. This is not
    /// necessarily a fixed hardware capacity.
    let memoryAllocatedBytes: UInt64?

    /// A driver-reported fixed memory capacity or limit, when one is exposed.
    let memoryLimitBytes: UInt64?

    /// Metal's recommended maximum working-set size for this process. This is a
    /// capability hint, not system-wide GPU memory usage.
    let recommendedWorkingSetLimitBytes: UInt64?

    let mediaEngines: MediaEngineMetrics
    let driverMetricScope: GPUDriverMetricScope

    /// Exact recognized statistic labels used for this sample. This makes
    /// driver-dependent behavior diagnosable without retaining the registry.
    let exposedDriverStatisticKeys: [String]

    var capabilityText: String {
        var details: [String] = []

        if let deviceName {
            details.append("Metal GPU: \(deviceName).")
        } else {
            details.append("No Metal GPU is available to this process.")
        }

        if utilizationPercent != nil {
            details.append("Overall GPU activity is exposed by the driver.")
        } else {
            details.append("Overall GPU activity is not exposed by the driver.")
        }

        switch (memoryUsedBytes, memoryAllocatedBytes, memoryLimitBytes) {
        case (.some, .some, .some):
            details.append("Driver memory use, allocation, and a memory limit are available.")
        case (.some, _, .some):
            details.append("Driver memory use and a memory limit are available.")
        case (.some, .some, .none):
            details.append("Driver memory use and allocation are available, but a fixed memory limit is not.")
        case (.some, .none, .none):
            details.append("Driver memory use is available, but a fixed memory limit is not.")
        case (.none, .some, .some):
            details.append("Driver memory allocation and a memory limit are available, but in-use memory is not.")
        case (.none, .some, .none):
            details.append("Driver memory allocation is available, but in-use memory and a fixed limit are not.")
        case (.none, .none, .some):
            details.append("A driver memory limit is available, but in-use memory is not.")
        case (.none, .none, .none):
            if recommendedWorkingSetLimitBytes != nil {
                details.append("Only Metal's per-process recommended working-set limit is available for memory.")
            } else {
                details.append("GPU memory statistics are not exposed.")
            }
        }

        details.append(mediaEngines.availabilityText)
        return details.joined(separator: " ")
    }
}
