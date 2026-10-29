import Foundation

@main
struct UsageHistoryChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keyA = "sha256:" + String(repeating: "a", count: 64)
        let keyB = "sha256:" + String(repeating: "b", count: 64)
        let reset = now.addingTimeInterval(7200)
        func provider(_ used: Double, date: Date, key: String? = keyA,
                      resetAt: Date? = reset, source: String = "oauth") -> PeelUsageProvider {
            PeelUsageProvider(id: "fixture", name: "Fixture", enabled: true, source: source,
                identity: PeelUsageIdentity(accountEmail: "redacted@example.test", plan: "Plan", accountKey: key),
                windows: [PeelUsageWindow(kind: "session", label: "Session", usedPercent: used, resetAt: resetAt)],
                updatedAt: date, allowanceUpdatedAt: date)
        }
        func snapshot(_ p: PeelUsageProvider, generated: Date? = nil) -> PeelUsageSnapshot {
            PeelUsageSnapshot(generatedAt: generated ?? p.updatedAt!, staleAfterSeconds: 180, providers: [p])
        }
        let p = provider(20, date: now)
        let id = PeelUsageHistory.key(provider: p, window: p.windows[0])!
        require(PeelUsageHistory.key(provider: provider(20, date: now, key: nil), window: p.windows[0]) == nil,
                "A redacted display email is not an account identity")
        require(PeelUsageHistory.key(provider: provider(20, date: now, key: keyB), window: p.windows[0]) != id,
                "Same-domain accounts must not share history")
        require(PeelUsageHistory.key(provider: provider(20, date: now, source: "browser"), window: p.windows[0]) != id,
                "Sources must not share history")
        require(PeelUsageHistory.key(provider: p, window: .init(kind: "weekly", label: "Weekly")) != id,
                "Allowance windows must not share history")

        var history = PeelUsageHistory()
        for minute in 0...60 {
            let date = now.addingTimeInterval(Double(minute - 60) * 60)
            history.record(snapshot(provider(20 + Double(minute) / 30, date: date)), receivedAt: date)
        }
        let complete = history.observation(for: id, from: now.addingTimeInterval(-3600), to: now)
        require(complete.isComplete && abs((complete.percentagePoints ?? -1) - 2) < 0.00001,
                "A continuously observed hour must report two percentage points")
        require(history.hours(for: id, endingAt: now).count == 24, "24 hourly bars")
        let copy = history
        history.record(snapshot(provider(99, date: now.addingTimeInterval(-10))), receivedAt: now)
        require(history == copy, "Out-of-order cached reading cannot amend history")
        history.record(snapshot(provider(99, date: now.addingTimeInterval(10))), receivedAt: now)
        require(history == copy, "Future readings cannot fabricate coverage")
        history.record(snapshot(provider(99, date: now.addingTimeInterval(-3600))), receivedAt: now)
        require(history == copy, "Stale provider readings cannot fabricate coverage")
        history.record(snapshot(provider(99, date: now.addingTimeInterval(60)),
                                generated: now.addingTimeInterval(-3600)), receivedAt: now.addingTimeInterval(60))
        require(history == copy, "Stale root snapshots cannot fabricate coverage")

        var gap = PeelUsageHistory()
        gap.record(snapshot(provider(10, date: now.addingTimeInterval(-3600))), receivedAt: now.addingTimeInterval(-3600))
        gap.record(snapshot(provider(90, date: now)), receivedAt: now)
        require(gap.observation(for: id, from: now.addingTimeInterval(-3600), to: now).percentagePoints == nil,
                "An hour-long gap cannot become an 80-point bar")
        var restarted = PeelUsageHistory()
        restarted.record(snapshot(provider(90, date: now.addingTimeInterval(-60), resetAt: now.addingTimeInterval(-30))),
                         receivedAt: now.addingTimeInterval(-60))
        restarted.record(snapshot(provider(95, date: now)), receivedAt: now)
        require(restarted.observation(for: id, from: now.addingTimeInterval(-3600), to: now).percentagePoints == nil,
                "Even an increasing value across a reset must not be counted")
        var correction = PeelUsageHistory()
        correction.record(snapshot(provider(50, date: now.addingTimeInterval(-120))), receivedAt: now.addingTimeInterval(-120))
        correction.record(snapshot(provider(40, date: now.addingTimeInterval(-60))), receivedAt: now.addingTimeInterval(-60))
        correction.record(snapshot(provider(42, date: now)), receivedAt: now)
        let corrected = correction.observation(for: id, from: now.addingTimeInterval(-3600), to: now)
        require(corrected.percentagePoints == 2 && !corrected.isComplete, "Downward correction breaks continuity")
        var unknownCycle = PeelUsageHistory()
        unknownCycle.record(snapshot(provider(5, date: now.addingTimeInterval(-60), resetAt: nil)),
                            receivedAt: now.addingTimeInterval(-60))
        unknownCycle.record(snapshot(provider(6, date: now, resetAt: nil)), receivedAt: now)
        let unknown = unknownCycle.observation(for: id, from: now.addingTimeInterval(-3600), to: now)
        require(unknown.percentagePoints == 1 && !unknown.isComplete, "Missing reset metadata yields observed lower bound")
        let unknownAccount = provider(25, date: now.addingTimeInterval(60), key: keyB)
        history.record(snapshot(unknownAccount), receivedAt: now.addingTimeInterval(60))
        let otherID = PeelUsageHistory.key(provider: unknownAccount, window: unknownAccount.windows[0])!
        require(history.observation(for: otherID, from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60)).percentagePoints == nil,
                "Switching accounts requires a fresh baseline")
        let account = PeelUsageAccount(id: "source:account-b", label: "Account B", active: true,
            identity: PeelUsageIdentity(accountKey: keyA))
        require(PeelUsageHistory.key(provider: p, window: p.windows[0], account: account) != id,
                "Explicit account rows retain their own source identity")

        let reusedSlot = PeelUsageAccount(id: account.id, label: "Account C", active: true,
            identity: PeelUsageIdentity(accountKey: keyB))
        require(PeelUsageHistory.key(provider: p, window: p.windows[0], account: account) !=
                PeelUsageHistory.key(provider: p, window: p.windows[0], account: reusedSlot),
                "Reused source slot cannot inherit another owner's history")
        let missingOwner = PeelUsageAccount(id: account.id, label: "Account", active: true)
        require(PeelUsageHistory.key(provider: p, window: p.windows[0], account: missingOwner) == nil,
                "Source slot alone is not account ownership")
        let freshStatus = PeelUsageProvider(id: p.id, name: p.name, enabled: true, source: p.source,
            identity: p.identity, windows: p.windows, updatedAt: now,
            allowanceUpdatedAt: now.addingTimeInterval(-3600))
        var staleAllowances = PeelUsageHistory()
        staleAllowances.record(snapshot(freshStatus), receivedAt: now)
        require(staleAllowances.series.isEmpty, "Fresh status or cost cannot freshen stale allowances")
        let timestampJSON = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "generatedAt": ISO8601DateFormatter().string(from: now), "staleAfterSeconds": 180,
            "providers": [["id": p.id, "name": p.name, "enabled": true, "source": "oauth",
                           "updatedAt": ISO8601DateFormatter().string(from: now),
                           "allowanceUpdatedAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600)),
                           "identity": ["accountKey": keyA],
                           "windows": [["kind": "session", "label": "Session", "usedPercent": 20]]]]
        ])
        let decodedStale = try PeelUsageSnapshotParser.parse(timestampJSON)
        require(decodedStale.providers.first?.allowanceUpdatedAt == now.addingTimeInterval(-3600),
                "Allowance-specific ISO8601 timestamp survives actual snapshot parsing")
        staleAllowances.record(decodedStale, receivedAt: now)
        require(staleAllowances.series.isEmpty, "Parsed fresh aggregate timestamp cannot freshen stale allowance")
        let oldHelper = PeelUsageProvider(id: p.id, name: p.name, enabled: true, source: p.source,
            identity: p.identity, windows: p.windows, updatedAt: now)
        staleAllowances.record(snapshot(oldHelper), receivedAt: now)
        require(staleAllowances.series.isEmpty, "Missing allowance timestamp cannot borrow aggregate freshness")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        try history.save(to: file)
        let reloaded = try PeelUsageHistory.load(from: file, now: now.addingTimeInterval(60))
        require(reloaded == history, "Samples survive restart")
        let saved = try String(contentsOf: file, encoding: .utf8)
        require(!saved.contains("example.test") && !saved.contains("account-b") && !saved.contains(keyA),
                "Persistent history must contain no raw account identity")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "History file is private")
        var expired = reloaded
        expired.prune(at: now.addingTimeInterval(PeelUsageHistory.retention + 120))
        require(expired.series.isEmpty, "Old samples expire")
        try Data("{bad-json".utf8).write(to: file)
        do {
            _ = try PeelUsageHistory.load(from: file, now: now)
            fatalError("Corrupt history must surface a read failure")
        } catch {}
        let oversizedSeries: [[String: Any]] = (0..<70).map { index in
            let samples: [[String: Any]] = (0..<1600).map { sample in
                ["date": now.addingTimeInterval(-Double(1600 - sample) * 60).timeIntervalSinceReferenceDate,
                 "used": Double(sample % 100), "resetAt": reset.timeIntervalSinceReferenceDate]
            }
            return ["id": String(format: "%064x", index), "samples": samples]
        }
        let oversizedData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "series": oversizedSeries])
        var bounded = try JSONDecoder().decode(PeelUsageHistory.self, from: oversizedData)
        bounded.prune(at: now)
        require(bounded.series.count <= 64 && bounded.series.allSatisfy { $0.samples.count <= 1500 } &&
                bounded.series.reduce(0, { $0 + $1.samples.count }) <= PeelUsageHistory.maximumSamples,
                "Persisted retention bounds apply to all loaded series and total samples")
        let identityData = Data("{\"accountEmail\":\"redacted@example.test\",\"accountKey\":\"\(keyA)\"}".utf8)
        let decodedIdentity = try JSONDecoder().decode(PeelUsageIdentity.self, from: identityData)
        require(decodedIdentity.accountKey == keyA, "Additive helper identity survives snapshot decoding")
        let legacyIdentity = try JSONDecoder().decode(PeelUsageIdentity.self,
            from: Data("{\"accountEmail\":\"redacted@example.test\"}".utf8))
        require(legacyIdentity.accountKey == nil, "Old helpers remain compatible without invented account ownership")
        print("Usage history checks passed: identity, sampled deltas, resets, staleness, gaps, account changes, persistence, privacy and retention")
    }
}
