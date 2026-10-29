import CryptoKit
import Foundation

/// Local observations, not billing records. No emails, credentials or raw provider payloads are persisted.
nonisolated struct PeelUsageHistory: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        let date: Date
        let used: Double
        let resetAt: Date?
    }

    struct Series: Codable, Equatable, Sendable {
        let id: String
        var samples: [Sample]
    }

    struct Hour: Identifiable, Equatable, Sendable {
        let start: Date
        let end: Date
        let percentagePoints: Double?
        let isComplete: Bool
        var id: Date { start }
    }

    private(set) var schemaVersion = 1
    private(set) var series: [Series] = []
    static let retention: TimeInterval = 48 * 3600
    static let maximumGap: TimeInterval = 10 * 60
    static let maximumSamples = 12_000
    static let maximumFileBytes = 4 * 1024 * 1024

    static func key(provider: PeelUsageProvider, window: PeelUsageWindow,
                    account: PeelUsageAccount? = nil) -> String? {
        guard let source = provider.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !source.isEmpty, source != "unknown", source.utf8.count <= 256,
              provider.id.utf8.count <= 128, window.kind.utf8.count <= 128 else { return nil }
        let identity = account == nil ? provider.identity : account?.identity
        let accountScope: String
        if let account {
            guard !account.id.isEmpty, account.id.utf8.count <= 512,
                  let key = identity?.accountKey, key.hasPrefix("sha256:"), key.count == 71,
                  key.dropFirst(7).allSatisfy({ $0.isHexDigit }) else { return nil }
            // Source slots may be reused. Require the separately supplied owner fingerprint too.
            accountScope = "source-account:" + account.id + ":" + key
        } else {
            guard let key = identity?.accountKey, key.hasPrefix("sha256:"), key.count == 71,
                  key.dropFirst(7).allSatisfy({ $0.isHexDigit }) else { return nil }
            accountScope = key
        }
        // JSON avoids ambiguous delimiter composition. Plan changes begin a separate allowance history.
        let components = [provider.id, source, accountScope, window.kind, identity?.plan ?? ""]
        guard let data = try? JSONEncoder().encode(components) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    mutating func record(_ snapshot: PeelUsageSnapshot, receivedAt now: Date) -> Bool {
        let previous = self
        prune(at: now)
        guard snapshot.generatedAt <= now.addingTimeInterval(5), !snapshot.isStale(at: now) else {
            return self != previous
        }
        let freshness = min(max(TimeInterval(snapshot.staleAfterSeconds), 1), Self.maximumGap)
        for provider in snapshot.providers where provider.enabled {
            if provider.error == nil {
                record(provider: provider, account: nil, windows: provider.windows,
                       updatedAt: provider.allowanceUpdatedAt, now: now, freshness: freshness)
            }
            for account in provider.accounts ?? [] where account.error == nil {
                record(provider: provider, account: account, windows: account.windows,
                       updatedAt: account.updatedAt, now: now, freshness: freshness)
            }
        }
        prune(at: now)
        return self != previous
    }

    private mutating func record(provider: PeelUsageProvider, account: PeelUsageAccount?,
                                 windows: [PeelUsageWindow], updatedAt: Date?, now: Date,
                                 freshness: TimeInterval) {
        guard let date = updatedAt, date <= now.addingTimeInterval(5),
              now.timeIntervalSince(date) < freshness else { return }
        for window in windows where !window.idle {
            guard let used = window.normalizedUsedPercent, used.isFinite, (0...100).contains(used),
                  let key = Self.key(provider: provider, window: window, account: account) else { continue }
            let sample = Sample(date: date, used: used, resetAt: window.resetAt)
            if let index = series.firstIndex(where: { $0.id == key }) {
                if let last = series[index].samples.last {
                    // Never let cached or out-of-order snapshots appear to create fresh coverage.
                    guard date.timeIntervalSince(last.date) >= 30 else { continue }
                }
                series[index].samples.append(sample)
            } else {
                series.append(Series(id: key, samples: [sample]))
            }
        }
    }

    func hours(for key: String, endingAt now: Date, count: Int = 24) -> [Hour] {
        (0..<min(max(count, 1), 48)).reversed().map { offset in
            let end = now.addingTimeInterval(-Double(offset) * 3600)
            return observation(for: key, from: end.addingTimeInterval(-3600), to: end)
        }
    }

    func observation(for key: String, from start: Date, to end: Date) -> Hour {
        let samples = series.first(where: { $0.id == key })?.samples ?? []
        var points = 0.0
        var coverage = 0.0
        var intervals = 0
        var interrupted = false
        var first: Date?
        var last: Date?
        for (before, after) in zip(samples, samples.dropFirst()) {
            guard after.date > start, before.date < end else { continue }
            // An interval spanning a chart boundary cannot tell us which hour consumed the allowance.
            guard before.date >= start, after.date <= end else { continue }
            let duration = after.date.timeIntervalSince(before.date)
            let sameReset: Bool
            switch (before.resetAt, after.resetAt) {
            case (.some(let previous), .some(let current)):
                sameReset = abs(previous.timeIntervalSince(current)) <= 120 && previous > after.date
            case (nil, nil):
                sameReset = true
                interrupted = true // No cycle evidence: the observed delta remains a lower bound.
            default:
                sameReset = false
            }
            guard duration > 0, duration <= Self.maximumGap, sameReset, after.used >= before.used else {
                interrupted = true
                continue
            }
            points += after.used - before.used
            coverage += duration
            intervals += 1
            first = first ?? before.date
            last = after.date
        }
        let complete = !interrupted && intervals > 0 && coverage >= end.timeIntervalSince(start) - 360 &&
            first.map { $0.timeIntervalSince(start) <= 180 } == true &&
            last.map { end.timeIntervalSince($0) <= 180 } == true
        return Hour(start: start, end: end, percentagePoints: intervals == 0 ? nil : points,
                    isComplete: complete)
    }

    mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var seen = Set<String>()
        series = series.filter { item in
            item.id.count == 64 && item.id.allSatisfy(\.isHexDigit) && seen.insert(item.id).inserted
        }.compactMap { item in
            var last = Date.distantPast
            let valid = item.samples.sorted { $0.date < $1.date }.filter { sample in
                guard sample.date > last, sample.date >= cutoff, sample.date <= now.addingTimeInterval(5),
                      sample.used.isFinite, (0...100).contains(sample.used),
                      sample.resetAt?.timeIntervalSince1970.isFinite != false else { return false }
                last = sample.date
                return true
            }
            return valid.isEmpty ? nil : Series(id: item.id, samples: Array(valid.suffix(1500)))
        }.sorted { ($0.samples.last?.date ?? .distantPast) > ($1.samples.last?.date ?? .distantPast) }
        series = Array(series.prefix(64))
        var remaining = Self.maximumSamples
        series = series.compactMap { item in
            guard remaining > 0 else { return nil }
            let retained = Array(item.samples.suffix(remaining))
            remaining -= retained.count
            return Series(id: item.id, samples: retained)
        }
    }

    static func load(from url: URL, now: Date = .now) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumFileBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        var history = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard history.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        history.prune(at: now)
        return history
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
