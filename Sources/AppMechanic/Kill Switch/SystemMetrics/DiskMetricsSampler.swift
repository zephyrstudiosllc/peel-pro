//
//  DiskMetricsSampler.swift
//  Kill Switch
//

import Foundation
import IOKit

/// Stateful sampler with no timer or subprocesses of its own.
///
/// Keep one instance on a single utility-priority task. A 5–30 second cadence is
/// intentionally recommended so this monitor does not become a source of load.
nonisolated struct DiskMetricsSampler: Sendable {
    static let defaultSamplingInterval: TimeInterval = 10
    static let samplingIntervalRange: ClosedRange<TimeInterval> = 5...30

    private static let maximumDriverCount = 64
    private static let maximumMediaChildrenPerDriver = 16
    private static let maximumParentDepth = 8
    private static let maximumRateIntervals = 192
    private static let longestRateWindow: TimeInterval = 15 * 60

    private let rootURL: URL
    private var previousIO: PreviousIO?
    private var writeRateIntervals: [WriteRateInterval] = []

    init(rootURL: URL = URL(fileURLWithPath: "/", isDirectory: true)) {
        self.rootURL = rootURL.standardizedFileURL
    }

    static func clampedSamplingInterval(_ proposedInterval: TimeInterval) -> TimeInterval {
        guard proposedInterval.isFinite else { return defaultSamplingInterval }
        return min(max(proposedInterval, samplingIntervalRange.lowerBound), samplingIntervalRange.upperBound)
    }

    /// Samples capacity and I/O counters once. The first valid I/O sample has nil rates.
    mutating func sample() -> DiskMetricsSnapshot {
        let sampledAt = Date()
        let uptime = ProcessInfo.processInfo.systemUptime

        let capacityResult = Self.readCapacity(at: rootURL)
        let ioResult = Self.readPhysicalIOCounters()

        let volume: DiskVolumeCapacity?
        let capacityIssue: String?
        switch capacityResult {
        case .success(let capacity):
            volume = capacity
            capacityIssue = nil
        case .failure(let error):
            volume = nil
            capacityIssue = error.localizedDescription
        }

        let io: DiskIOStatistics?
        var ioIssue: String?
        switch ioResult {
        case .success(let current):
            let rates = rates(for: current, at: uptime)
            let rateWindows = writeRateWindows(at: uptime)
            io = DiskIOStatistics(
                cumulativeReadBytes: current.totalReadBytes,
                cumulativeWriteBytes: current.totalWriteBytes,
                readBytesPerSecond: rates.read,
                writeBytesPerSecond: rates.write,
                writeBytesPerSecond5Minutes: rateWindows.fiveMinutes,
                writeBytesPerSecond15Minutes: rateWindows.fifteenMinutes,
                rateInterval: rates.interval,
                deviceCount: current.devices.count,
                source: current.source
            )
            ioIssue = current.source == .dominantWritableFallback
                ? "Physical storage identity was incomplete; using the dominant writable block device."
                : nil
            previousIO = PreviousIO(uptime: uptime, devices: current.devices)
        case .failure(let error):
            io = nil
            ioIssue = error.localizedDescription
            // Do not compute a later rate across a missing sample.
            previousIO = nil
            writeRateIntervals.removeAll(keepingCapacity: true)
        }

        let issues = [capacityIssue, ioIssue].compactMap { $0 }
        let availability: DiskMetricsAvailability
        switch (volume, io, issues.isEmpty) {
        case (.some, .some, true):
            availability = .available
        case (.none, .none, _):
            availability = .unavailable
        default:
            availability = .partial
        }

        return DiskMetricsSnapshot(
            sampledAt: sampledAt,
            volume: volume,
            io: io,
            availability: availability,
            errorDescription: issues.isEmpty ? nil : issues.joined(separator: " ")
        )
    }

    mutating func resetRates() {
        previousIO = nil
        writeRateIntervals.removeAll(keepingCapacity: true)
    }

    private mutating func rates(
        for current: RawIOSample,
        at uptime: TimeInterval
    ) -> (read: Double?, write: Double?, interval: TimeInterval?) {
        guard let previousIO else { return (nil, nil, nil) }

        let elapsed = uptime - previousIO.uptime
        guard elapsed.isFinite, elapsed > 0 else { return (nil, nil, nil) }
        guard current.devices.keys.count == previousIO.devices.keys.count,
              current.devices.keys.allSatisfy({ previousIO.devices[$0] != nil }) else {
            // Device attach/detach changes the aggregate baseline.
            writeRateIntervals.removeAll(keepingCapacity: true)
            return (nil, nil, nil)
        }

        var readDelta: UInt64 = 0
        var writeDelta: UInt64 = 0
        var readIsValid = true
        var writeIsValid = true

        for (identifier, counters) in current.devices {
            guard let previous = previousIO.devices[identifier] else { continue }

            if counters.readBytes >= previous.readBytes {
                readDelta = Self.saturatingAdd(readDelta, counters.readBytes - previous.readBytes)
            } else {
                // A lower counter means reset or wrap; suppress this rate interval.
                readIsValid = false
            }

            if counters.writeBytes >= previous.writeBytes {
                writeDelta = Self.saturatingAdd(writeDelta, counters.writeBytes - previous.writeBytes)
            } else {
                writeIsValid = false
            }
        }

        let readRate = readIsValid ? Self.sanitizedRate(bytes: readDelta, elapsed: elapsed) : nil
        let writeRate = writeIsValid ? Self.sanitizedRate(bytes: writeDelta, elapsed: elapsed) : nil

        if writeRate != nil {
            writeRateIntervals.append(
                WriteRateInterval(
                    endUptime: uptime,
                    duration: elapsed,
                    writeBytes: writeDelta
                )
            )
            pruneWriteRateIntervals(at: uptime)
        } else {
            writeRateIntervals.removeAll(keepingCapacity: true)
        }

        return (readRate, writeRate, readRate == nil && writeRate == nil ? nil : elapsed)
    }

    private mutating func pruneWriteRateIntervals(at uptime: TimeInterval) {
        let oldestUsefulEnd = uptime - Self.longestRateWindow
        writeRateIntervals.removeAll { interval in
            interval.endUptime <= oldestUsefulEnd
        }
        if writeRateIntervals.count > Self.maximumRateIntervals {
            writeRateIntervals.removeFirst(
                writeRateIntervals.count - Self.maximumRateIntervals
            )
        }
    }

    private func writeRateWindows(
        at uptime: TimeInterval
    ) -> (fiveMinutes: Double?, fifteenMinutes: Double?) {
        (
            averageWriteRate(over: 5 * 60, at: uptime),
            averageWriteRate(over: 15 * 60, at: uptime)
        )
    }

    private func averageWriteRate(
        over window: TimeInterval,
        at uptime: TimeInterval
    ) -> Double? {
        guard window > 0, uptime.isFinite else { return nil }
        let windowStart = uptime - window
        var coveredDuration: TimeInterval = 0
        var coveredBytes = 0.0

        for interval in writeRateIntervals {
            guard interval.duration.isFinite, interval.duration > 0 else { continue }
            let intervalStart = interval.endUptime - interval.duration
            let overlapStart = max(intervalStart, windowStart)
            let overlapEnd = min(interval.endUptime, uptime)
            let overlap = overlapEnd - overlapStart
            guard overlap > 0 else { continue }

            coveredDuration += overlap
            coveredBytes += Double(interval.writeBytes) * (overlap / interval.duration)
        }

        guard coveredDuration >= window * 0.8 else { return nil }
        let rate = coveredBytes / coveredDuration
        return rate.isFinite && rate >= 0 ? rate : nil
    }

    private static func readCapacity(at url: URL) -> Result<DiskVolumeCapacity, DiskSamplingError> {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeLocalizedNameKey
            ])

            if let total = values.volumeTotalCapacity,
               let free = values.volumeAvailableCapacity,
               total >= 0,
               free >= 0 {
                guard total > 0 else { return .failure(.capacityUnavailable) }
                return .success(
                    capacity(
                        displayName: displayName(values.volumeLocalizedName, at: url),
                        mountPath: url.path,
                        totalBytes: UInt64(total),
                        freeBytes: UInt64(free)
                    )
                )
            }
        } catch {
            // FileManager below is a public-API fallback for filesystems that omit URL values.
        }

        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            guard let total = unsignedInteger(attributes[.systemSize]),
                  let free = unsignedInteger(attributes[.systemFreeSize]) else {
                return .failure(.capacityUnavailable)
            }
            guard total > 0 else { return .failure(.capacityUnavailable) }
            let localizedName = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
            return .success(
                capacity(
                    displayName: displayName(localizedName, at: url),
                    mountPath: url.path,
                    totalBytes: total,
                    freeBytes: free
                )
            )
        } catch {
            return .failure(.capacityReadFailed(error.localizedDescription))
        }
    }

    private static func capacity(
        displayName: String,
        mountPath: String,
        totalBytes: UInt64,
        freeBytes: UInt64
    ) -> DiskVolumeCapacity {
        let clampedFree = min(freeBytes, totalBytes)
        let used = totalBytes - clampedFree
        let percent = min(max((Double(used) / Double(totalBytes)) * 100, 0), 100)

        return DiskVolumeCapacity(
            displayName: displayName,
            mountPath: mountPath,
            totalBytes: totalBytes,
            usedBytes: used,
            freeBytes: clampedFree,
            usedPercent: percent.isFinite ? percent : 0
        )
    }

    private static func displayName(_ localizedName: String?, at url: URL) -> String {
        let trimmedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let fallbackName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? "Startup Disk" : fallbackName
    }

    private static func readPhysicalIOCounters() -> Result<RawIOSample, DiskSamplingError> {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            return .failure(.registryMatchingUnavailable)
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            if iterator != IO_OBJECT_NULL {
                IOObjectRelease(iterator)
            }
            return .failure(.registryReadFailed(result))
        }
        defer { IOObjectRelease(iterator) }

        var physical: [RawDevice] = []
        var fallback: [RawDevice] = []
        var examined = 0

        while examined < maximumDriverCount {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            examined += 1

            autoreleasepool {
                defer { IOObjectRelease(service) }
                guard let counters = counters(for: service),
                      let media = wholeMediaDetails(for: service) else {
                    return
                }

                let identifier = registryIdentifier(for: service)
                let device = RawDevice(
                    identifier: identifier,
                    counters: counters,
                    mediaSize: media.size
                )

                switch storageIdentity(for: service) {
                case .physical:
                    physical.append(device)
                case .unknown where media.isWritable:
                    fallback.append(device)
                case .virtual, .unknown:
                    break
                }
            }
        }

        if !physical.isEmpty {
            return .success(rawSample(from: physical, source: .physicalDevices))
        }

        // Older/third-party drivers may omit interconnect identity. In that case,
        // use only one dominant writable whole-media device to avoid disk images.
        if let dominant = fallback.max(by: { lhs, rhs in
            let lhsTraffic = saturatingAdd(lhs.counters.readBytes, lhs.counters.writeBytes)
            let rhsTraffic = saturatingAdd(rhs.counters.readBytes, rhs.counters.writeBytes)
            return lhsTraffic == rhsTraffic ? lhs.mediaSize < rhs.mediaSize : lhsTraffic < rhsTraffic
        }) {
            return .success(rawSample(from: [dominant], source: .dominantWritableFallback))
        }

        return .failure(.ioCountersUnavailable)
    }

    private static func counters(for service: io_registry_entry_t) -> DeviceCounters? {
        guard let statistics = property("Statistics", on: service) as? [String: Any],
              let readBytes = unsignedInteger(statistics["Bytes (Read)"]),
              let writeBytes = unsignedInteger(statistics["Bytes (Write)"]) else {
            return nil
        }
        return DeviceCounters(readBytes: readBytes, writeBytes: writeBytes)
    }

    private static func wholeMediaDetails(
        for service: io_registry_entry_t
    ) -> (isWritable: Bool, size: UInt64)? {
        var iterator: io_iterator_t = 0
        let result = IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator)
        guard result == KERN_SUCCESS else {
            if iterator != IO_OBJECT_NULL {
                IOObjectRelease(iterator)
            }
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var examined = 0
        var largest: (isWritable: Bool, size: UInt64)?
        while examined < maximumMediaChildrenPerDriver {
            let child = IOIteratorNext(iterator)
            guard child != IO_OBJECT_NULL else { break }
            examined += 1
            defer { IOObjectRelease(child) }

            guard IOObjectConformsTo(child, "IOMedia") != 0,
                  boolean(property("Whole", on: child)) == true,
                  let size = unsignedInteger(property("Size", on: child)),
                  size > 0 else {
                continue
            }

            let candidate = (isWritable: boolean(property("Writable", on: child)) == true, size: size)
            if largest == nil || candidate.size > largest!.size {
                largest = candidate
            }
        }
        return largest
    }

    private static func storageIdentity(for service: io_registry_entry_t) -> StorageIdentity {
        var current = service
        var retainedCurrent: io_registry_entry_t = IO_OBJECT_NULL
        defer {
            if retainedCurrent != IO_OBJECT_NULL {
                IOObjectRelease(retainedCurrent)
            }
        }

        for _ in 0..<maximumParentDepth {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard result == KERN_SUCCESS else {
                if parent != IO_OBJECT_NULL {
                    IOObjectRelease(parent)
                }
                break
            }

            if retainedCurrent != IO_OBJECT_NULL {
                IOObjectRelease(retainedCurrent)
            }
            retainedCurrent = parent
            current = parent

            if let characteristics = property("Protocol Characteristics", on: current) as? [String: Any],
               let interconnect = characteristics["Physical Interconnect"] as? String {
                let normalized = interconnect.lowercased()
                if normalized.contains("virtual")
                    || normalized.contains("disk image")
                    || normalized.contains("file")
                    || normalized.contains("ram") {
                    return .virtual
                }
                if !normalized.isEmpty {
                    return .physical
                }
            }

            if let characteristics = property("Device Characteristics", on: current) as? [String: Any],
               let mediumType = characteristics["Medium Type"] as? String {
                let normalized = mediumType.lowercased()
                if normalized.contains("solid state")
                    || normalized.contains("rotational")
                    || normalized.contains("hard disk") {
                    return .physical
                }
            }
        }
        return .unknown
    }

    private static func property(_ key: String, on entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func registryIdentifier(for service: io_registry_entry_t) -> UInt64 {
        var identifier: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS {
            return identifier
        }
        // IDs are expected to be available; this still keeps one failed-ID device stable per run.
        return UInt64(service)
    }

    private static func rawSample(
        from rawDevices: [RawDevice],
        source: DiskIOStatistics.Source
    ) -> RawIOSample {
        var devices: [UInt64: DeviceCounters] = [:]
        for device in rawDevices {
            devices[device.identifier] = device.counters
        }
        return RawIOSample(devices: devices, source: source)
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue >= 0, doubleValue <= Double(UInt64.max) else {
            return nil
        }
        return number.uint64Value
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func sanitizedRate(bytes: UInt64, elapsed: TimeInterval) -> Double? {
        let rate = Double(bytes) / elapsed
        guard rate.isFinite, rate >= 0 else { return nil }
        return rate
    }
}

private extension DiskMetricsSampler {
    nonisolated struct DeviceCounters: Sendable, Equatable {
        let readBytes: UInt64
        let writeBytes: UInt64
    }

    nonisolated struct RawDevice {
        let identifier: UInt64
        let counters: DeviceCounters
        let mediaSize: UInt64
    }

    nonisolated struct RawIOSample {
        let devices: [UInt64: DeviceCounters]
        let source: DiskIOStatistics.Source

        var totalReadBytes: UInt64 {
            devices.values.reduce(0) { DiskMetricsSampler.saturatingAdd($0, $1.readBytes) }
        }

        var totalWriteBytes: UInt64 {
            devices.values.reduce(0) { DiskMetricsSampler.saturatingAdd($0, $1.writeBytes) }
        }
    }

    nonisolated struct PreviousIO: Sendable {
        let uptime: TimeInterval
        let devices: [UInt64: DeviceCounters]
    }

    nonisolated struct WriteRateInterval: Sendable {
        let endUptime: TimeInterval
        let duration: TimeInterval
        let writeBytes: UInt64
    }

    nonisolated enum StorageIdentity {
        case physical
        case virtual
        case unknown
    }

    nonisolated enum DiskSamplingError: LocalizedError {
        case capacityUnavailable
        case capacityReadFailed(String)
        case registryMatchingUnavailable
        case registryReadFailed(kern_return_t)
        case ioCountersUnavailable

        var errorDescription: String? {
            switch self {
            case .capacityUnavailable:
                return "Root-volume capacity is unavailable."
            case .capacityReadFailed(let description):
                return "Could not read root-volume capacity: \(description)"
            case .registryMatchingUnavailable:
                return "Could not create the block-storage registry query."
            case .registryReadFailed(let code):
                return "Could not read block-storage counters (IOKit error \(code))."
            case .ioCountersUnavailable:
                return "Physical block-storage counters are unavailable."
            }
        }
    }
}
