//
//  SystemMetricsStore.swift
//  Kill Switch
//

import Foundation
import Combine

@MainActor
final class SystemMetricsStore: ObservableObject {
    @Published private(set) var diskSnapshot: DiskMetricsSnapshot?
    @Published private(set) var gpuSnapshot: GPUMetricsSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastSampleDuration: TimeInterval?

    private let worker = SystemMetricsWorker()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryPressureState: MemoryPressureState = .normal
    private var lastDiskAttempt: Date?
    private var consecutiveDiskFailures = 0

    init() {
#if PEEL_HOST_INTEGRATION
        if ProcessInfo.processInfo.arguments.contains("--peel-preview") { return }
#endif
        startMemoryPressureMonitoring()
        refresh()
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        memoryPressureSource?.cancel()
    }

    var cadenceDescription: String {
        let gpuSeconds = Int(preferredGPUInterval)
        let diskSeconds = Int(preferredDiskInterval)
        return "GPU updates about every \(gpuSeconds)s; disk updates about every \(diskSeconds)s."
    }

    func refresh() {
        refresh(forceDisk: false)
    }

    func refreshAll() {
        refresh(forceDisk: true)
    }

    private func refresh(forceDisk: Bool) {
        guard !isRefreshing else { return }

        timer?.invalidate()
        timer = nil
        isRefreshing = true

        let now = Date()
        let shouldSampleDisk = forceDisk || (lastDiskAttempt.map {
            now.timeIntervalSince($0) >= preferredDiskInterval
        } ?? true)
        if shouldSampleDisk {
            lastDiskAttempt = now
        }

        let worker = self.worker
        refreshTask = Task(priority: .utility) { [weak self] in
            let startedAt = Date()
            let result = await worker.sample(includeDisk: shouldSampleDisk)
            let duration = max(Date().timeIntervalSince(startedAt), 0)

            guard !Task.isCancelled, let self else { return }
            self.apply(result, duration: duration)
        }
    }

    private func apply(
        _ result: SystemMetricsWorkerResult,
        duration: TimeInterval
    ) {
        if let diskSnapshot = result.disk {
            self.diskSnapshot = diskSnapshot

            if diskSnapshot.availability == .unavailable {
                consecutiveDiskFailures = min(consecutiveDiskFailures + 1, 8)
            } else {
                consecutiveDiskFailures = 0
            }
        }

        gpuSnapshot = result.gpu
        lastSampleDuration = duration.isFinite ? duration : nil
        isRefreshing = false
        refreshTask = nil
        scheduleNextRefresh()
    }

    private func scheduleNextRefresh() {
        guard timer == nil, refreshTask == nil else { return }

        let interval = preferredGPUInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.refresh()
            }
        }
        timer?.tolerance = interval * 0.25
    }

    private var preferredGPUInterval: TimeInterval {
        let processInfo = ProcessInfo.processInfo

        if processInfo.thermalState == .critical || memoryPressureState == .critical {
            return 30
        }

        if processInfo.isLowPowerModeEnabled
            || processInfo.thermalState == .serious
            || memoryPressureState == .warning
            || (lastSampleDuration ?? 0) > 0.5
            || consecutiveDiskFailures >= 2 {
            return 15
        }

        return GPUMetricsSampler.recommendedMinimumInterval
    }

    private var preferredDiskInterval: TimeInterval {
        preferredGPUInterval > GPUMetricsSampler.recommendedMinimumInterval ? 60 : 30
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )

        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            self?.memoryPressureState = MemoryPressureState(event: event)
        }

        source.resume()
        memoryPressureSource = source
    }
}

private actor SystemMetricsWorker {
    private var diskSampler = DiskMetricsSampler()
    private let gpuSampler = GPUMetricsSampler()

    func sample(includeDisk: Bool) async -> SystemMetricsWorkerResult {
        let disk = includeDisk ? diskSampler.sample() : nil
        let gpu = await gpuSampler.sample()
        return SystemMetricsWorkerResult(disk: disk, gpu: gpu)
    }
}

private nonisolated struct SystemMetricsWorkerResult: Sendable {
    let disk: DiskMetricsSnapshot?
    let gpu: GPUMetricsSnapshot
}
