//
//  GPUMetricsSampler.swift
//  Kill Switch
//

import Foundation
import IOKit
import Metal

/// Serializes and rate-limits GPU sampling.
///
/// Keep this actor outside the main actor (for example, call it from a utility
/// priority task). Repeated calls inside `minimumInterval` return the cached
/// immutable snapshot, preventing polling UI from multiplying IOKit work.
actor GPUMetricsSampler {
    static let recommendedMinimumInterval: TimeInterval = 5
    static let absoluteMinimumInterval: TimeInterval = 2

    private let minimumInterval: TimeInterval
    private var cachedSnapshot: GPUMetricsSnapshot?

    init(minimumInterval: TimeInterval = GPUMetricsSampler.recommendedMinimumInterval) {
        if minimumInterval.isFinite {
            self.minimumInterval = max(minimumInterval, Self.absoluteMinimumInterval)
        } else {
            self.minimumInterval = Self.recommendedMinimumInterval
        }
    }

    /// Returns a cached sample when called more frequently than the configured
    /// conservative interval.
    func sample() -> GPUMetricsSnapshot {
        let now = Date()

        if let cachedSnapshot {
            let sampleAge = now.timeIntervalSince(cachedSnapshot.sampledAt)
            if sampleAge >= 0, sampleAge < minimumInterval {
                return cachedSnapshot
            }
        }

        let snapshot = GPUHardwareReader.capture(at: now)
        cachedSnapshot = snapshot
        return snapshot
    }

    func invalidateCache() {
        cachedSnapshot = nil
    }
}

private nonisolated enum GPUHardwareReader {
    private static let maximumMetalDevices = 16
    private static let maximumPlausibleWorkingSetBytes: UInt64 =
        8 * 1_024 * 1_024 * 1_024 * 1_024 * 1_024

    static func capture(at sampledAt: Date) -> GPUMetricsSnapshot {
        let metal = readMetalCapabilities()
        let driver = GPURegistryReader.read(defaultMetalRegistryID: metal.defaultRegistryID)

        return GPUMetricsSnapshot(
            sampledAt: sampledAt,
            deviceName: metal.defaultDeviceName,
            availableDeviceNames: metal.deviceNames,
            utilizationPercent: driver.utilizationPercent,
            memoryUsedBytes: driver.memoryUsedBytes,
            memoryAllocatedBytes: driver.memoryAllocatedBytes,
            memoryLimitBytes: driver.memoryLimitBytes,
            recommendedWorkingSetLimitBytes: metal.recommendedWorkingSetLimitBytes,
            mediaEngines: driver.mediaEngines,
            driverMetricScope: driver.scope,
            exposedDriverStatisticKeys: driver.exposedKeys
        )
    }

    private static func readMetalCapabilities() -> MetalCapabilities {
        let defaultDevice = MTLCreateSystemDefaultDevice()
        var rawNames = MTLCopyAllDevices()
            .prefix(maximumMetalDevices)
            .map(\.name)
        if let defaultDevice {
            rawNames.append(defaultDevice.name)
        }
        let deviceNames = Array(
            Set(rawNames.compactMap(sanitizedDeviceName))
        ).sorted()

        let recommendedLimit = defaultDevice.flatMap { device -> UInt64? in
            let value = device.recommendedMaxWorkingSetSize
            return value > 0 && value <= maximumPlausibleWorkingSetBytes ? value : nil
        }
        let registryID = defaultDevice.flatMap { device -> UInt64? in
            device.registryID == 0 ? nil : device.registryID
        }

        return MetalCapabilities(
            defaultDeviceName: defaultDevice.flatMap { sanitizedDeviceName($0.name) },
            defaultRegistryID: registryID,
            deviceNames: deviceNames,
            recommendedWorkingSetLimitBytes: recommendedLimit
        )
    }

    private static func sanitizedDeviceName(_ value: String) -> String? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(160)

        return cleaned.isEmpty ? nil : String(cleaned)
    }
}

private nonisolated struct MetalCapabilities {
    let defaultDeviceName: String?
    let defaultRegistryID: UInt64?
    let deviceNames: [String]
    let recommendedWorkingSetLimitBytes: UInt64?
}

private nonisolated enum GPURegistryReader {
    private static let maximumServices = 16
    private static let maximumAncestorDepth = 8
    private static let maximumStatisticsPerService = 256
    private static let maximumStatisticKeyLength = 128
    private static let maximumPlausibleMemoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024 * 1_024 * 1_024

    static func read(defaultMetalRegistryID: UInt64?) -> DriverMetrics {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return .unavailable
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return .unavailable
        }
        defer { IOObjectRelease(iterator) }

        var readings: [RegistryReading] = []
        readings.reserveCapacity(2)

        for _ in 0..<maximumServices {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard let statistics = readPerformanceStatistics(from: service) else {
                continue
            }

            let reading = parseStatistics(
                statistics,
                lineageRegistryIDs: registryLineageIDs(for: service)
            )

            if reading.hasRecognizedMetric {
                readings.append(reading)
            }
        }

        guard !readings.isEmpty else {
            return .unavailable
        }

        if let defaultMetalRegistryID {
            let matchingReadings = readings.filter {
                $0.lineageRegistryIDs.contains(defaultMetalRegistryID)
            }

            if !matchingReadings.isEmpty {
                return combine(
                    matchingReadings,
                    scope: .defaultMetalDevice
                )
            }
        }

        if readings.count == 1 {
            return combine(readings, scope: .onlyRegistryDevice)
        }

        return combine(readings, scope: .multipleRegistryDevices)
    }

    private static func readPerformanceStatistics(
        from service: io_registry_entry_t
    ) -> [String: Any]? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        return property as? [String: Any]
    }

    private static func registryLineageIDs(
        for entry: io_registry_entry_t
    ) -> Set<UInt64> {
        var identifiers: Set<UInt64> = []
        var currentEntry = entry
        var ownsCurrentEntry = false

        defer {
            if ownsCurrentEntry {
                IOObjectRelease(currentEntry)
            }
        }

        for depth in 0...maximumAncestorDepth {
            var identifier: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(currentEntry, &identifier) == KERN_SUCCESS,
               identifier != 0 {
                identifiers.insert(identifier)
            }

            guard depth < maximumAncestorDepth else { break }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(
                currentEntry,
                kIOServicePlane,
                &parent
            ) == KERN_SUCCESS,
            parent != IO_OBJECT_NULL else {
                break
            }

            if ownsCurrentEntry {
                IOObjectRelease(currentEntry)
            }

            currentEntry = parent
            ownsCurrentEntry = true
        }

        return identifiers
    }

    private static func parseStatistics(
        _ statistics: [String: Any],
        lineageRegistryIDs: Set<UInt64>
    ) -> RegistryReading {
        var reading = RegistryReading(lineageRegistryIDs: lineageRegistryIDs)

        for (rawKey, rawValue) in statistics.prefix(maximumStatisticsPerService) {
            guard rawKey.count <= maximumStatisticKeyLength,
                  let numericValue = sanitizedNumber(rawValue) else {
                continue
            }

            let key = normalizedKey(rawKey)

            switch key {
            case "deviceutilization",
                 "deviceutilizationpercent",
                 "gpuutilization",
                 "gpuutilizationpercent",
                 "gpuactivity",
                 "gpuactivitypercent":
                guard isExplicitPercentageKey(rawKey),
                      let percent = sanitizedPercent(numericValue) else {
                    continue
                }
                reading.utilizationPercent = max(reading.utilizationPercent ?? 0, percent)
                reading.exposedKeys.insert(rawKey)

            case "encoderutilization",
                 "encoderutilizationpercent",
                 "encodeutilization",
                 "encodeutilizationpercent",
                 "videoencoderutilization",
                 "videoencoderutilizationpercent",
                 "videoencodeutilization",
                 "videoencodeutilizationpercent":
                guard isExplicitPercentageKey(rawKey),
                      let percent = sanitizedPercent(numericValue) else {
                    continue
                }
                reading.encodeUtilizationPercent = max(reading.encodeUtilizationPercent ?? 0, percent)
                reading.exposedKeys.insert(rawKey)

            case "decoderutilization",
                 "decoderutilizationpercent",
                 "decodeutilization",
                 "decodeutilizationpercent",
                 "videodecoderutilization",
                 "videodecoderutilizationpercent",
                 "videodecodeutilization",
                 "videodecodeutilizationpercent":
                guard isExplicitPercentageKey(rawKey),
                      let percent = sanitizedPercent(numericValue) else {
                    continue
                }
                reading.decodeUtilizationPercent = max(reading.decodeUtilizationPercent ?? 0, percent)
                reading.exposedKeys.insert(rawKey)

            case "inusesystemmemory",
                 "vramusedbytes",
                 "gpumemoryusedbytes",
                 "gartusedbytes":
                guard let bytes = sanitizedBytes(numericValue, multiplier: 1) else { continue }
                reading.memoryUsedBytes = max(reading.memoryUsedBytes ?? 0, bytes)
                reading.exposedKeys.insert(rawKey)

            case "allocsystemmemory",
                 "allocatedsystemmemory",
                 "vramallocatedbytes",
                 "gpumemoryallocatedbytes":
                guard let bytes = sanitizedBytes(numericValue, multiplier: 1) else { continue }
                reading.memoryAllocatedBytes = max(reading.memoryAllocatedBytes ?? 0, bytes)
                reading.exposedKeys.insert(rawKey)

            case "vramtotalbytes",
                 "gpumemorytotalbytes",
                 "vramlimitbytes",
                 "gpumemorylimitbytes":
                guard let bytes = sanitizedBytes(numericValue, multiplier: 1) else { continue }
                reading.memoryLimitBytes = max(reading.memoryLimitBytes ?? 0, bytes)
                reading.exposedKeys.insert(rawKey)

            case "vramtotalmb", "gpumemorytotalmb":
                guard let bytes = sanitizedBytes(
                    numericValue,
                    multiplier: 1_024 * 1_024
                ) else {
                    continue
                }
                reading.memoryLimitBytes = max(reading.memoryLimitBytes ?? 0, bytes)
                reading.exposedKeys.insert(rawKey)

            default:
                continue
            }
        }

        return reading
    }

    private static func normalizedKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isExplicitPercentageKey(_ key: String) -> Bool {
        key.contains("%") || key.localizedCaseInsensitiveContains("percent")
    }

    private static func sanitizedNumber(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }

        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func sanitizedPercent(_ value: Double) -> Double? {
        guard value >= 0, value <= 100 else { return nil }
        return value
    }

    private static func sanitizedBytes(
        _ value: Double,
        multiplier: UInt64
    ) -> UInt64? {
        guard value >= 0 else { return nil }

        let scaledValue = value * Double(multiplier)
        guard scaledValue.isFinite,
              scaledValue <= Double(maximumPlausibleMemoryBytes) else {
            return nil
        }

        return UInt64(scaledValue.rounded(.down))
    }

    private static func combine(
        _ readings: [RegistryReading],
        scope: GPUDriverMetricScope
    ) -> DriverMetrics {
        let utilization = readings.compactMap(\.utilizationPercent).max()
        let memoryUsed = readings.compactMap(\.memoryUsedBytes).max()
        let memoryAllocated = readings.compactMap(\.memoryAllocatedBytes).max()
        var memoryLimit = readings.compactMap(\.memoryLimitBytes).max()

        if let memoryUsed, let candidateLimit = memoryLimit, candidateLimit < memoryUsed {
            memoryLimit = nil
        }

        let encode = readings.compactMap(\.encodeUtilizationPercent).max()
        let decode = readings.compactMap(\.decodeUtilizationPercent).max()
        let exposedKeys = Array(
            readings.reduce(into: Set<String>()) { result, reading in
                result.formUnion(reading.exposedKeys)
            }
        ).sorted().prefix(64)

        return DriverMetrics(
            utilizationPercent: utilization,
            memoryUsedBytes: memoryUsed,
            memoryAllocatedBytes: memoryAllocated,
            memoryLimitBytes: memoryLimit,
            mediaEngines: MediaEngineMetrics(
                encodeUtilizationPercent: encode,
                decodeUtilizationPercent: decode
            ),
            scope: scope,
            exposedKeys: Array(exposedKeys)
        )
    }
}

private nonisolated struct RegistryReading {
    let lineageRegistryIDs: Set<UInt64>
    var utilizationPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryAllocatedBytes: UInt64?
    var memoryLimitBytes: UInt64?
    var encodeUtilizationPercent: Double?
    var decodeUtilizationPercent: Double?
    var exposedKeys: Set<String> = []

    var hasRecognizedMetric: Bool {
        utilizationPercent != nil
            || memoryUsedBytes != nil
            || memoryAllocatedBytes != nil
            || memoryLimitBytes != nil
            || encodeUtilizationPercent != nil
            || decodeUtilizationPercent != nil
    }
}

private nonisolated struct DriverMetrics {
    let utilizationPercent: Double?
    let memoryUsedBytes: UInt64?
    let memoryAllocatedBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let mediaEngines: MediaEngineMetrics
    let scope: GPUDriverMetricScope
    let exposedKeys: [String]

    static let unavailable = DriverMetrics(
        utilizationPercent: nil,
        memoryUsedBytes: nil,
        memoryAllocatedBytes: nil,
        memoryLimitBytes: nil,
        mediaEngines: .unavailable,
        scope: .unavailable,
        exposedKeys: []
    )
}
