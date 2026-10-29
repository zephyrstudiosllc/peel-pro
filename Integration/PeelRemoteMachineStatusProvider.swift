//
//  PeelRemoteMachineStatusProvider.swift
//  Host-side projection of existing cached unified-model values.
//
//  This provider does not start or refresh anything. It reads the one existing
//  SidePulse/usage/ProcessSampler/SystemMetricsStore graph on the main actor and
//  returns a bounded reply for the root-owned authenticated transport.
//

import Foundation

@MainActor
enum PeelRemoteMachineStatusProvider {
    /// Source-specific bounds keep one recently refreshed store from making
    /// older values look current in the single sampledAt field.
    static let cpuAndProcessMaximumAge: TimeInterval = 15
    static let gpuAndDiskMaximumAge: TimeInterval = 60
    static let batteryMaximumAge: TimeInterval = 60
    static let usageMaximumAge: TimeInterval = 10 * 60
    private static let usageNameMaximumUTF8Bytes = 256

    static func snapshot(
        requestId: String,
        model: PeelUnifiedModel,
        now: Date = Date()
    ) -> PeelMachineStatusMessage? {
        // Preview stores contain intentionally synthetic sample rows. Never
        // expose those rows as a remote machine-status reply.
        guard !model.isPreview,
              UUID(uuidString: requestId) != nil,
              now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= 0 else {
            return nil
        }

        let sampler = model.sampler
        let systemMetrics = model.systemMetrics
        let diskSnapshot = systemMetrics.diskSnapshot
        let gpuSnapshot = systemMetrics.gpuSnapshot
        var emittedSampleDates: [Date] = []

        let samplerSampledAt = freshDate(
            sampler.lastUpdated,
            now: now,
            maximumAge: Self.cpuAndProcessMaximumAge)
        let cpuFraction = samplerSampledAt != nil && sampler.hasSystemCPUSample
            ? fractionFromPercent(sampler.systemCPUPercent)
            : nil
        let memoryFraction = samplerSampledAt != nil && sampler.hasSystemMemorySample
            ? fractionFromPercent(sampler.systemMemoryUsedPercent)
            : nil
        let topApps = samplerSampledAt != nil
            ? makeTopApps(from: sampler.topApps)
            : []
        if (cpuFraction != nil || memoryFraction != nil || !topApps.isEmpty), let samplerSampledAt {
            emittedSampleDates.append(samplerSampledAt)
        }

        let storageFreeBytes: UInt64?
        let storageTotalBytes: UInt64?
        let diskSampledAt = freshDate(
            diskSnapshot?.sampledAt,
            now: now,
            maximumAge: Self.gpuAndDiskMaximumAge)
        if diskSampledAt != nil,
           let volume = diskSnapshot?.volume,
           diskSnapshot?.availability != .unavailable {
            storageFreeBytes = volume.freeBytes
            storageTotalBytes = volume.totalBytes
        } else {
            storageFreeBytes = nil
            storageTotalBytes = nil
        }
        if (storageFreeBytes != nil || storageTotalBytes != nil),
           let diskSampledAt {
            emittedSampleDates.append(diskSampledAt)
        }

        let gpuSampledAt = freshDate(
            gpuSnapshot?.sampledAt,
            now: now,
            maximumAge: Self.gpuAndDiskMaximumAge)
        let gpuFraction = gpuSampledAt == nil
            ? nil
            : gpuSnapshot.flatMap { fractionFromPercent($0.utilizationPercent) }
        if gpuFraction != nil, let gpuSampledAt {
            emittedSampleDates.append(gpuSampledAt)
        }

        let batterySampledAt = freshDate(
            model.sidePulse.batterySampledAt,
            now: now,
            maximumAge: Self.batteryMaximumAge)
        let batteryFraction = batterySampledAt == nil
            ? nil
            : fraction(model.sidePulse.batteryState?.chargeFraction)
        if batteryFraction != nil, let batterySampledAt {
            emittedSampleDates.append(batterySampledAt)
        }

        let usageProjection = makeUsage(
            from: model.usage.providers,
            snapshot: model.usage.snapshot,
            now: now)
        emittedSampleDates.append(contentsOf: usageProjection.sampledDates)
        let usage = usageProjection.values

        // A reply timestamp describes the oldest emitted cached source. Do
        // not use the current clock or a newer source to make an older field
        // look fresh.
        guard let sampledAt = oldestEpoch(emittedSampleDates) else {
            return nil
        }

        let hasCachedValue = cpuFraction != nil || memoryFraction != nil
            || storageFreeBytes != nil
            || batteryFraction != nil
            || gpuFraction != nil
            || !topApps.isEmpty
            || !usage.isEmpty

        let localStatus = hasCachedValue ? "Available" : "Unavailable"
        let hostName = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName

        return try? PeelMachineStatusMessage(
            requestId: requestId,
            sampledAt: sampledAt,
            hostName: hostName,
            cpuFraction: cpuFraction,
            memoryFraction: memoryFraction,
            // App Mechanic currently exposes memory as a percentage only;
            // leave byte fields nil until the host has measured both values.
            memoryUsedBytes: nil,
            memoryTotalBytes: nil,
            storageFreeBytes: storageFreeBytes,
            storageTotalBytes: storageTotalBytes,
            batteryFraction: batteryFraction,
            // No existing unified-model network counter is available here.
            networkReceiveBytesPerSecond: nil,
            networkSendBytesPerSecond: nil,
            gpuFraction: gpuFraction,
            topApps: topApps,
            usage: usage,
            localStatus: localStatus)
    }

    private static func fraction(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              (0...1).contains(value) else {
            return nil
        }
        return value
    }

    private static func fractionFromPercent(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              (0...100).contains(value) else {
            return nil
        }
        return fraction(value / 100)
    }

    private static func freshDate(
        _ date: Date?,
        now: Date,
        maximumAge: TimeInterval
    ) -> Date? {
        guard let date,
              maximumAge.isFinite,
              maximumAge >= 0 else {
            return nil
        }
        let age = now.timeIntervalSince(date)
        let epoch = date.timeIntervalSince1970
        guard age.isFinite,
              age >= 0,
              age <= maximumAge,
              epoch.isFinite,
              epoch >= 0 else {
            return nil
        }
        return date
    }

    private static func oldestEpoch(_ dates: [Date]) -> Double? {
        dates
            .compactMap { date -> Double? in
                let value = date.timeIntervalSince1970
                guard value.isFinite, value >= 0 else { return nil }
                return value
            }
            .min()
    }

    private static func makeTopApps(
        from samples: [ProcessSample]
    ) -> [PeelMachineStatusApp] {
        samples.prefix(PeelMachineStatusValidation.maxTopApps).compactMap { sample in
            guard let memoryBytes = memoryBytes(fromMegabytes: sample.memoryMB) else {
                return nil
            }
            return try? PeelMachineStatusApp(
                displayName: sample.appName,
                pid: Int32(sample.pid),
                cpuPercent: sample.cpu,
                memoryBytes: memoryBytes)
        }
    }

    private static func memoryBytes(fromMegabytes value: Double) -> UInt64? {
        guard value.isFinite, value >= 0 else { return nil }
        let bytes = value * 1_048_576
        guard bytes.isFinite, bytes < Double(UInt64.max) else { return nil }
        return UInt64(bytes.rounded(.towardZero))
    }

    private static func makeUsage(
        from providers: [PeelUsageProvider],
        snapshot: PeelUsageSnapshot?,
        now: Date
    ) -> (values: [PeelMachineStatusUsage], sampledDates: [Date]) {
        // The usage store keeps the previous snapshot after a failed refresh.
        // Respect the producer's own stale-after deadline before projecting
        // those cached rows to another device.
        guard snapshot?.isFresh(at: now) ?? true else {
            return ([], [])
        }

        var values: [PeelMachineStatusUsage] = []
        var sampledDates: [Date] = []
        values.reserveCapacity(PeelMachineStatusValidation.maxUsageEntries)
        sampledDates.reserveCapacity(PeelMachineStatusValidation.maxUsageEntries)

        for provider in providers {
            guard values.count < PeelMachineStatusValidation.maxUsageEntries else {
                break
            }
            // `PeelUsageStore.providers` normally filters this already. Keep
            // the projection defensive because this boundary owns the remote
            // representation and must never expose disabled or failed rows.
            guard provider.enabled, provider.error == nil else { continue }

            let sourceDate = [snapshot?.generatedAt, provider.updatedAt]
                .compactMap { $0 }
                .min()
            guard let sampledAt = freshDate(
                sourceDate,
                now: now,
                maximumAge: Self.usageMaximumAge) else {
                continue
            }

            for window in provider.windows {
                guard values.count < PeelMachineStatusValidation.maxUsageEntries else {
                    break
                }
                guard let providerName = usageName(provider: provider, window: window) else {
                    continue
                }
                let resetAt = window.resetAt.flatMap { date -> Double? in
                    let value = date.timeIntervalSince1970
                    return value.isFinite && value >= 0 ? value : nil
                }
                // A window may legitimately have no percentage yet. Keep the
                // row with a nil value so the client can show "Unavailable"
                // rather than turning an unknown allowance into zero.
                guard let value = try? PeelMachineStatusUsage(
                    providerName: providerName,
                    usedPercent: window.normalizedUsedPercent,
                    resetAt: resetAt) else {
                    continue
                }
                values.append(value)
                sampledDates.append(sampledAt)
            }
        }
        return (values, sampledDates)
    }

    private static func usageName(
        provider: PeelUsageProvider,
        window: PeelUsageWindow
    ) -> String? {
        let providerName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowName = [window.label, window.kind]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !providerName.isEmpty,
              !windowName.isEmpty,
              providerName.utf8.count <= Self.usageNameMaximumUTF8Bytes,
              windowName.utf8.count <= Self.usageNameMaximumUTF8Bytes else {
            return nil
        }

        let name = providerName + " · " + windowName
        return try? PeelMachineStatusValidation.text(
            name,
            field: "providerName",
            maximumUTF8Bytes: Self.usageNameMaximumUTF8Bytes)
    }
}
