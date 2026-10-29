import Foundation

// Pure fixtures for the paired-Mac agent contract. Synthetic keys only; no
// Keychain, socket, process, account or transcript is touched.

@main
enum PeelPeerAgentChecks {
    static let pairKeyAB = Data(repeating: 0x5A, count: 32)
    static let pairKeyAC = Data(repeating: 0x6B, count: 32)
    static let ownerA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let ownerB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        try testRedactionAndBounds()
        try testStrictDecoding()
        testTokens()
        testOwnerRevisions()
        testActivationGuard()
        testInventoryEpochsAndRevisions()
        testInventoryFreshnessAndRevocation()
        testDuplicateIDsAcrossOwners()
        testReceiptStatus()
        testLedgerExactlyOnce()
        try testUsageProjection()
        testUsagePresentation()
        testWriterFairness()
        print("Peel peer agent checks passed")
    }

    // MARK: Fixtures

    static func local(_ id: String, provider: String = "claude", title: String = "Fix login",
                      project: String = "Peel", state: PeelPeerAgentState = .working,
                      at date: Date = t0, activation: PeelPeerActivationSupport = .exactSession,
                      cloudTaskID: String? = nil) -> PeelPeerAgentLocalSession {
        PeelPeerAgentLocalSession(localID: id, provider: provider, title: title, project: project, state: state,
                                  tool: "Bash", updatedAt: date, alert: state == .waiting, activation: activation,
                                  reason: nil, cloudTaskID: cloudTaskID)
    }

    static func snapshot(_ owner: inout PeelPeerAgentOwnerState, _ sessions: [PeelPeerAgentLocalSession],
                         now: Date = t0) -> PeelPeerAgentSnapshot {
        owner.update(sessions)
        return owner.snapshot(now: now, pairKey: pairKeyAB)
    }

    static func expectThrow(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure("Expected rejection: \(label)")
        } catch {}
    }

    // MARK: Serialization

    static func testRedactionAndBounds() throws {
        var owner = PeelPeerAgentOwnerState()
        let sentinel = local("claude:session:SECRET-SESSION-ID",
                             title: "Line one\nline two\u{0}\u{202E}rtl",
                             project: "/Users/developer/Private/ClientProject")
        let snap = snapshot(&owner, [sentinel])
        let json = String(decoding: try PeelPeerAgentWire.encode(snap), as: UTF8.self)
        // JSONEncoder escapes "/" as "\/", so check path components, not slashes.
        for leaked in ["Users", "zach", "Private", "SECRET-SESSION-ID", "\\n", "\\u0000"] {
            precondition(!json.contains(leaked), "Wire snapshot leaked \(leaked)")
        }
        precondition(snap.sessions[0].project == "ClientProject", "Only a basename crosses the wire")
        precondition(snap.sessions[0].title == "Line one line two rtl")
        // The DTO has no field that could carry these at all.
        for field in ["cwd", "message", "openURL", "url", "path", "pid", "tty", "command", "account"] {
            precondition(!json.contains("\"\(field)\""), "Unexpected wire field \(field)")
        }

        // Count and byte bounds; rows are dropped (lowest priority first),
        // never truncated mid-field, and the truncation is reported.
        let many = (0..<40).map { index in
            local("claude:session:\(index)", title: String(repeating: "\"é", count: 200),
                  project: String(repeating: "p", count: 300),
                  state: index == 39 ? .waiting : .working, at: t0.addingTimeInterval(Double(index)))
        }
        var big = PeelPeerAgentOwnerState()
        let bounded = snapshot(&big, many)
        let encoded = try PeelPeerAgentWire.encode(bounded)
        precondition(encoded.count <= PeelPeerAgentLimits.snapshotBudgetBytes)
        precondition(bounded.sessions.count <= PeelPeerAgentLimits.maximumSessions)
        precondition(bounded.sessions.count + bounded.truncated == 40)
        precondition(bounded.sessions.first?.state == .waiting, "Attention rows survive the bound first")
        for session in bounded.sessions {
            precondition(session.title.utf8.count <= PeelPeerAgentLimits.titleBytes)
            precondition(session.project.utf8.count <= PeelPeerAgentLimits.projectBytes)
        }
        guard case .snapshot(let decoded) = try PeelPeerAgentWire.decode(encoded) else { preconditionFailure() }
        precondition(decoded == bounded)
    }

    static func testStrictDecoding() throws {
        var owner = PeelPeerAgentOwnerState()
        let valid = snapshot(&owner, [local("a"), local("b")])

        func mutated(_ change: (inout PeelPeerAgentSnapshot) -> Void) -> Data {
            var copy = valid
            change(&copy)
            return try! JSONEncoder().encode(copy)
        }
        expectThrow("too many sessions") {
            _ = try PeelPeerAgentWire.decode(mutated { snap in
                snap.sessions = Array(repeating: snap.sessions[0], count: 25).enumerated().map { index, session in
                    var copy = session
                    copy.token = String(repeating: "A", count: 21) + String("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { $0 }[index])
                    return copy
                }
            })
        }
        expectThrow("duplicate token") {
            _ = try PeelPeerAgentWire.decode(mutated { $0.sessions[1].token = $0.sessions[0].token })
        }
        expectThrow("bad token") { _ = try PeelPeerAgentWire.decode(mutated { $0.sessions[0].token = "../../etc" }) }
        expectThrow("control characters") {
            _ = try PeelPeerAgentWire.decode(mutated { $0.sessions[0].title = "a\nb" })
        }
        expectThrow("oversized title") {
            _ = try PeelPeerAgentWire.decode(mutated { $0.sessions[0].title = String(repeating: "x", count: 97) })
        }
        expectThrow("path-like provider") {
            _ = try PeelPeerAgentWire.decode(mutated { $0.sessions[0].provider = "codex://threads" })
        }
        expectThrow("negative age") { _ = try PeelPeerAgentWire.decode(mutated { $0.sessions[0].ageSeconds = -1 }) }
        expectThrow("version") { _ = try PeelPeerAgentWire.decode(mutated { $0.v = 2 }) }
        expectThrow("unknown type") { _ = try PeelPeerAgentWire.decode(Data(#"{"type":"peelRunCommand"}"#.utf8)) }
        expectThrow("oversized line") {
            _ = try PeelPeerAgentWire.decode(Data(repeating: 0x20, count: PeelPeerAgentLimits.maximumLineBytes + 1))
        }

        // Forward compatibility: unknown enum values degrade, they don't throw.
        var json = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"working\"", with: "\"thinkingHarder\"")
            .replacingOccurrences(of: "\"exactSession\"", with: "\"teleport\"")
        guard case .snapshot(let future) = try PeelPeerAgentWire.decode(Data(json.utf8)) else { preconditionFailure() }
        precondition(future.sessions.allSatisfy { $0.state == .unknown && $0.activation == .unavailable })

        // Activation requests accept no destination of any kind.
        let request = PeelPeerAgentActivate(requestId: UUID(), token: valid.sessions[0].token,
                                            bootEpoch: valid.bootEpoch, revision: valid.revision)
        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        guard case .activate = try PeelPeerAgentWire.decode(Data(requestJSON.utf8)) else { preconditionFailure() }
        for smuggled in [#","url":"file:///tmp/x""#, #","command":"rm -rf ~""#, #","path":"/bin/sh""#,
                         #","ownerHostId":"AAAAAAAA-0000-4000-8000-000000000001""#, #","pid":42"#] {
            let hostile = requestJSON.dropLast() + smuggled + "}"
            expectThrow("smuggled \(smuggled)") { _ = try PeelPeerAgentWire.decode(Data(hostile.utf8)) }
        }

        // A peer can never claim a viewer-only outcome.
        let fake = #"{"type":"peelAgentActivateResult","requestId":"\#(UUID().uuidString)","outcome":"timedOut"}"#
        expectThrow("viewer-only outcome") { _ = try PeelPeerAgentWire.decode(Data(fake.utf8)) }
        let newer = #"{"type":"peelAgentActivateResult","requestId":"\#(UUID().uuidString)","outcome":"hologram"}"#
        guard case .activateResult(let result) = try PeelPeerAgentWire.decode(Data(newer.utf8)) else { preconditionFailure() }
        precondition(result.outcome == .unknownResult)
    }

    // MARK: Owner side

    static func testTokens() {
        let secret = Data(repeating: 1, count: 32)
        let a = PeelPeerAgentToken.derive(secret: secret, provider: "codex", localID: "codex:session:1")
        precondition(a == PeelPeerAgentToken.derive(secret: secret, provider: "codex", localID: "codex:session:1"))
        precondition(a != PeelPeerAgentToken.derive(secret: secret, provider: "claude", localID: "codex:session:1"))
        precondition(a != PeelPeerAgentToken.derive(secret: Data(repeating: 2, count: 32), provider: "codex",
                                                     localID: "codex:session:1"),
                     "A restarted owner (new secret) mints new tokens")
        precondition(PeelPeerAgentText.isToken(a) && !a.contains("session"))
    }

    static func testOwnerRevisions() {
        var owner = PeelPeerAgentOwnerState()
        precondition(owner.update([local("a"), local("b")]) && owner.revision == 1)
        precondition(!owner.update([local("a"), local("b")]) && owner.revision == 1, "Unchanged inventory keeps its revision")
        let tokenA = owner.token(provider: "claude", localID: "a")
        let revA = owner.snapshot(now: t0, pairKey: nil).sessions.first { $0.token == tokenA }!.bindingRevision
        precondition(owner.check(token: tokenA, bindingRevision: revA) == .current(localID: "a"))
        precondition(owner.check(token: tokenA, bindingRevision: revA + 1) == .bindingChanged, "Future revision refused")

        // An unrelated row changing does not invalidate A's click…
        precondition(owner.update([local("a"), local("b", title: "Renamed"), local("c")]))
        precondition(owner.check(token: tokenA, bindingRevision: revA) == .current(localID: "a"))
        // …but A's own binding changing (new process/TTY/destination) does.
        var rebound = local("a")
        rebound.bindingKey = "b:401.2000.1|t:5"
        owner.update([rebound, local("b", title: "Renamed"), local("c")])
        precondition(owner.check(token: tokenA, bindingRevision: revA) == .bindingChanged)
        owner.update([local("b")])
        precondition(owner.check(token: tokenA, bindingRevision: revA) == .notOffered, "Ended targets are not offered")
        precondition(owner.update([local("c", provider: "../x")]) && owner.sessionCount == 0,
                     "Invalid provider identifiers never enter the projection")

        // Rows dropped by the 24-row bound are never actionable.
        var many = PeelPeerAgentOwnerState()
        many.update((0..<30).map { local("s\($0)", at: t0.addingTimeInterval(Double($0))) })
        let offered = Set(many.snapshot(now: t0, pairKey: nil).sessions.map(\.token))
        let dropped = many.token(provider: "claude", localID: "s0")
        precondition(!offered.contains(dropped) && many.check(token: dropped, bindingRevision: 1) == .notOffered)
    }

    static func request(_ owner: PeelPeerAgentOwnerState, _ localID: String, id: UUID = UUID(),
                        token: String? = nil, revision: UInt64? = nil) -> PeelPeerAgentActivate {
        let tok = token ?? owner.token(provider: "claude", localID: localID)
        let rev = revision ?? owner.snapshot(now: t0, pairKey: nil).sessions.first { $0.token == tok }?.bindingRevision ?? 1
        return PeelPeerAgentActivate(requestId: id, token: tok, bootEpoch: owner.bootEpoch, revision: rev)
    }

    static func testActivationGuard() {
        var owner = PeelPeerAgentOwnerState()
        owner.update([local("a"), local("b")])
        var admission = PeelPeerActivationGuard()
        let first = request(owner, "a")
        precondition(admission.admit(first, owner: owner, now: t0) == .execute(localID: "a"))
        precondition(admission.admit(first, owner: owner, now: t0) == .inFlight, "Duplicate while running is silent")
        var mutated = first
        mutated.token = owner.token(provider: "claude", localID: "b")
        precondition(admission.admit(mutated, owner: owner, now: t0) == .refuse(.requestConflict),
                     "Same ID with a changed payload is refused, not joined")
        precondition(admission.complete(first.requestId, outcome: .focusedExactSession, now: t0))
        precondition(!admission.complete(first.requestId, outcome: .launchFailed, now: t0), "Exactly one result")

        // Review fixture: valid A, then 64+ invalid IDs, then replay A < 120 s.
        var clock = t0.addingTimeInterval(1)
        for _ in 0..<200 {
            let junk = PeelPeerAgentActivate(requestId: UUID(), token: String(repeating: "Z", count: 22),
                                             bootEpoch: owner.bootEpoch, revision: 1)
            _ = admission.admit(junk, owner: owner, now: clock)
            clock = clock.addingTimeInterval(0.5)
        }
        precondition(clock.timeIntervalSince(t0) < 120)
        precondition(admission.admit(first, owner: owner, now: clock) == .replay(.focusedExactSession),
                     "Invalid traffic can never evict an unexpired ID; replay never re-executes")
        precondition(admission.rememberedCount <= PeelPeerActivationGuard.capacity)

        // Unsuccessful requests are rate-bounded too.
        var limiter = PeelPeerActivationGuard()
        let later = t0.addingTimeInterval(500)
        func junk() -> PeelPeerAgentActivate {
            PeelPeerAgentActivate(requestId: UUID(), token: String(repeating: "Y", count: 22),
                                  bootEpoch: owner.bootEpoch, revision: 1)
        }
        precondition(limiter.admit(junk(), owner: owner, now: later) == .reject(.sessionEnded))
        precondition(limiter.admit(junk(), owner: owner, now: later) == .reject(.sessionEnded))
        precondition(limiter.admit(junk(), owner: owner, now: later) == .refuse(.rateLimited))
        let stale = PeelPeerAgentActivate(requestId: UUID(), token: first.token, bootEpoch: UUID(), revision: 1)
        precondition(limiter.admit(stale, owner: owner, now: later.addingTimeInterval(1.1)) == .reject(.staleEpoch))
        let future = request(owner, "a", revision: 999)
        precondition(limiter.admit(future, owner: owner, now: later.addingTimeInterval(1.2)) == .reject(.targetChanged))

        // The guard belongs to the authenticated peer, not a socket: the same
        // instance continues across a reconnect, so replay still holds.
        let afterReconnect = later.addingTimeInterval(30)
        precondition(limiter.admit(future, owner: owner, now: afterReconnect) == .replay(.targetChanged))
        // Expired entries are released only after the retention window.
        precondition(admission.admit(first, owner: owner, now: t0.addingTimeInterval(400)) == .execute(localID: "a"))
    }

    // MARK: Viewer side

    static func testInventoryEpochsAndRevisions() {
        var owner = PeelPeerAgentOwnerState()
        var inventory = PeelPeerAgentInventory()
        let socket1 = UUID()
        let s1 = snapshot(&owner, [local("a"), local("b")])
        precondition(inventory.applySnapshot(s1, hostID: ownerA, label: "MacBook", socketID: socket1, now: t0) == .applied)
        precondition(inventory.applySnapshot(s1, hostID: ownerA, label: "MacBook", socketID: socket1, now: t0) == .unchanged)
        let s2 = snapshot(&owner, [local("a")])
        precondition(inventory.applySnapshot(s2, hostID: ownerA, label: "MacBook", socketID: socket1, now: t0) == .applied)
        precondition(inventory.rows().count == 1, "A missing token is a removed session, not Done")
        if case .violation = inventory.applySnapshot(s1, hostID: ownerA, label: "MacBook", socketID: socket1, now: t0) {} else {
            preconditionFailure("Revision regression on a socket is a violation")
        }
        var restarted = PeelPeerAgentOwnerState()
        let other = snapshot(&restarted, [local("z")])
        if case .violation = inventory.applySnapshot(other, hostID: ownerA, label: "MacBook", socketID: socket1, now: t0) {} else {
            preconditionFailure("Epoch change inside one socket is a violation")
        }
        // A stale replay on a NEW socket with the same epoch is rejected…
        let socket2 = UUID()
        if case .violation = inventory.applySnapshot(s1, hostID: ownerA, label: "MacBook", socketID: socket2, now: t0) {} else {
            preconditionFailure("Lower revision of the same boot epoch on a new socket is a replay")
        }
        // …but a restarted owner (new epoch) on a new socket replaces state.
        precondition(inventory.applySnapshot(other, hostID: ownerA, label: "MacBook", socketID: socket2, now: t0) == .applied)
        precondition(inventory.rows().map(\.session.token) == other.sessions.map(\.token))

        let goodKeepalive = PeelPeerAgentKeepalive(bootEpoch: other.bootEpoch, revision: other.revision)
        precondition(inventory.applyKeepalive(goodKeepalive, hostID: ownerA, socketID: socket2, now: t0) == .unchanged)
        if case .violation = inventory.applyKeepalive(PeelPeerAgentKeepalive(bootEpoch: other.bootEpoch, revision: 99),
                                                       hostID: ownerA, socketID: socket2, now: t0) {} else {
            preconditionFailure("Keepalive must match the applied snapshot")
        }
        precondition(inventory.applyKeepalive(goodKeepalive, hostID: ownerA, socketID: socket1, now: t0) == .unchanged,
                     "Late messages from a replaced socket are ignored")
    }

    static func testInventoryFreshnessAndRevocation() {
        var owner = PeelPeerAgentOwnerState()
        var inventory = PeelPeerAgentInventory()
        let socket = UUID()
        let snap = snapshot(&owner, [local("a", state: .working, at: t0.addingTimeInterval(-30))])
        _ = inventory.applySnapshot(snap, hostID: ownerA, label: "MacBook", socketID: socket, now: t0)
        let row = inventory.rows()[0]
        precondition(abs(row.estimatedUpdatedAt.timeIntervalSince(t0.addingTimeInterval(-30))) < 0.001,
                     "Owner ages map onto the viewer clock; skew between Macs does not matter")

        precondition(inventory.tick(now: t0.addingTimeInterval(16)), "Silence beyond 15 s is reconnecting")
        precondition(inventory.rows()[0].connection == .reconnecting(since: t0))
        precondition(inventory.rows()[0].session.state == .working, "Disconnect never turns a session Done")
        _ = inventory.applySnapshot(snap, hostID: ownerA, label: "MacBook", socketID: socket, now: t0.addingTimeInterval(17))
        precondition(inventory.rows()[0].connection == .live)

        precondition(inventory.socketClosed(hostID: ownerA, socketID: socket, now: t0.addingTimeInterval(20)))
        precondition(!inventory.socketClosed(hostID: ownerA, socketID: UUID(), now: t0), "Only the owner's own socket")
        inventory.tick(now: t0.addingTimeInterval(20 + 61))
        precondition(inventory.rows()[0].connection == .offline(since: t0.addingTimeInterval(20)))
        inventory.tick(now: t0.addingTimeInterval(20 + 61 + 15 * 60))
        precondition(inventory.rows().isEmpty, "Offline rows are retained for 15 minutes only")

        _ = inventory.applySnapshot(snap, hostID: ownerA, label: "MacBook", socketID: UUID(), now: t0)
        let key = inventory.rows()[0].key
        inventory.relabel(hostID: ownerA, label: "Renamed Mac")
        precondition(inventory.rows()[0].key == key && inventory.rows()[0].ownerLabel == "Renamed Mac",
                     "Renaming changes the label only, never the routing key")
        precondition(inventory.retainOnly(trustedHostIDs: [ownerB]) && inventory.rows().isEmpty,
                     "Revocation removes the owner's rows immediately")
    }

    static func testDuplicateIDsAcrossOwners() {
        var ownerOne = PeelPeerAgentOwnerState()
        var ownerTwo = PeelPeerAgentOwnerState()
        let same = local("claude:session:shared-id")
        var inventory = PeelPeerAgentInventory()
        let first = snapshot(&ownerOne, [same])
        var second = snapshot(&ownerTwo, [same])
        // Even an identical token from two owners stays two rows.
        second.sessions[0].token = first.sessions[0].token
        _ = inventory.applySnapshot(first, hostID: ownerA, label: "Mini", socketID: UUID(), now: t0)
        _ = inventory.applySnapshot(second, hostID: ownerB, label: "MacBook", socketID: UUID(), now: t0)
        let rows = inventory.rows()
        precondition(rows.count == 2 && Set(rows.map(\.key.rowID)).count == 2)
        precondition(rows.allSatisfy { $0.key.rowID.hasPrefix("peer:") },
                     "Remote row IDs are namespaced away from every local AgentSession.id")

        var cloudOwner = PeelPeerAgentOwnerState()
        cloudOwner.update([local("codex:cloud:task-9", provider: "codex", cloudTaskID: "task-9")])
        let cloud = cloudOwner.snapshot(now: t0, pairKey: pairKeyAB)
        var cloudInventory = PeelPeerAgentInventory()
        _ = cloudInventory.applySnapshot(cloud, hostID: ownerA, label: "MacBook", socketID: UUID(), now: t0)
        let localTag = PeelPeerAgentToken.pairTag(pairKey: pairKeyAB, domain: PeelPeerAgentOwnerState.cloudTagDomain,
                                                  value: "task-9")
        precondition(cloudInventory.rows { _, tag in tag == localTag }.first?.duplicatesLocalCloudTask == true)
        let otherPairTag = PeelPeerAgentToken.pairTag(pairKey: pairKeyAC, domain: PeelPeerAgentOwnerState.cloudTagDomain,
                                                      value: "task-9")
        precondition(otherPairTag != localTag, "Tags are pair-scoped")
    }

    static func testReceiptStatus() {
        // Nothing applied: no receipt, and a keepalive cannot create one.
        var inventory = PeelPeerAgentInventory()
        precondition(inventory.receipt(for: ownerA) == nil)
        let stray = PeelPeerAgentKeepalive(bootEpoch: UUID(), revision: 0)
        precondition(inventory.applyKeepalive(stray, hostID: ownerA, socketID: UUID(), now: t0) == .unchanged)
        precondition(inventory.receipt(for: ownerA) == nil, "A keepalive is not a snapshot receipt")

        // A valid empty snapshot is a receipt with zero sessions, not absence.
        var emptyOwner = PeelPeerAgentOwnerState()
        let empty = snapshot(&emptyOwner, [])
        let socket = UUID()
        precondition(inventory.applySnapshot(empty, hostID: ownerA, label: "MacBook", socketID: socket, now: t0) == .applied)
        guard let received = inventory.receipt(for: ownerA) else { preconditionFailure("Empty snapshot was accepted") }
        precondition(received.snapshotReceivedAt == t0 && received.sessionsInSnapshot == 0)
        precondition(received.sessionsNotIncluded == 0 && received.sessionsAlsoLocal == 0)
        precondition(received.connection == .live)
        precondition(received.usageReceivedAt == nil && received.usageRowsIncluded == 0 && received.usageRowsNotIncluded == 0,
                     "No usage summary until one is accepted")

        // A valid empty usage summary is received; nothing omitted.
        let emptyUsage = PeelPeerUsageSummary(bootEpoch: empty.bootEpoch, revision: 1, quotas: [], observed: [])
        precondition(inventory.applyUsage(emptyUsage, hostID: ownerA, socketID: socket, now: t0) == .applied)
        let withUsage = inventory.receipt(for: ownerA)
        precondition(withUsage?.usageReceivedAt == t0 && withUsage?.usageRowsIncluded == 0
                     && withUsage?.usageRowsNotIncluded == 0)

        // Keepalives refresh the link, never either receipt date.
        let keepalive = PeelPeerAgentKeepalive(bootEpoch: empty.bootEpoch, revision: empty.revision)
        _ = inventory.applyKeepalive(keepalive, hostID: ownerA, socketID: socket, now: t0.addingTimeInterval(10))
        precondition(inventory.receipt(for: ownerA)?.snapshotReceivedAt == t0)
        precondition(inventory.receipt(for: ownerA)?.usageReceivedAt == t0)
        precondition(!inventory.tick(now: t0.addingTimeInterval(20)), "Silence counts from the keepalive")
        precondition(inventory.receipt(for: ownerA)?.connection == .live)

        // Reconnecting and offline keep the previous receipt and its dates.
        precondition(inventory.tick(now: t0.addingTimeInterval(26)))
        let reconnecting = inventory.receipt(for: ownerA)
        precondition(reconnecting?.connection == .reconnecting(since: t0.addingTimeInterval(10)))
        precondition(reconnecting?.snapshotReceivedAt == t0 && reconnecting?.usageReceivedAt == t0)
        precondition(inventory.tick(now: t0.addingTimeInterval(71)))
        let offline = inventory.receipt(for: ownerA)
        precondition(offline?.connection == .offline(since: t0.addingTimeInterval(10)))
        precondition(offline?.snapshotReceivedAt == t0 && offline?.usageReceivedAt == t0)
        precondition(inventory.tick(now: t0.addingTimeInterval(10 + 15 * 60 + 1)))
        precondition(inventory.receipt(for: ownerA) == nil, "Expired offline owners hold no current snapshot")

        // Nonempty snapshot that did not fit: included and not-included stay separate.
        var bigOwner = PeelPeerAgentOwnerState()
        let big = snapshot(&bigOwner, (0..<30).map { local("claude:session:\($0)") })
        let bigSocket = UUID()
        _ = inventory.applySnapshot(big, hostID: ownerB, label: "Mini", socketID: bigSocket, now: t0)
        guard let bigReceipt = inventory.receipt(for: ownerB) else { preconditionFailure() }
        precondition(bigReceipt.sessionsInSnapshot == big.sessions.count && bigReceipt.sessionsInSnapshot > 0)
        precondition(bigReceipt.sessionsNotIncluded > 0 && bigReceipt.sessionsInSnapshot + bigReceipt.sessionsNotIncluded == 30)

        // Usage with omitted rows is not "empty"; counts stay separate.
        let quota = PeelPeerQuota(provider: "claude", name: "Claude", status: .ok, windows: [],
                                  ageSeconds: nil, plan: nil, accountTag: nil)
        let partialUsage = PeelPeerUsageSummary(bootEpoch: big.bootEpoch, revision: 1, quotas: [quota], observed: [],
                                                omittedQuotas: 2, omittedObserved: 1)
        precondition(inventory.applyUsage(partialUsage, hostID: ownerB, socketID: bigSocket, now: t0.addingTimeInterval(5)) == .applied)
        let partial = inventory.receipt(for: ownerB)
        precondition(partial?.usageReceivedAt == t0.addingTimeInterval(5))
        precondition(partial?.usageRowsIncluded == 1 && partial?.usageRowsNotIncluded == 3)

        // A closed socket keeps both dates; a restarted owner clears usage.
        precondition(inventory.socketClosed(hostID: ownerB, socketID: bigSocket, now: t0.addingTimeInterval(8)))
        let closed = inventory.receipt(for: ownerB)
        precondition(closed?.connection == .reconnecting(since: t0.addingTimeInterval(8)))
        precondition(closed?.snapshotReceivedAt == t0 && closed?.usageReceivedAt == t0.addingTimeInterval(5))
        var restarted = PeelPeerAgentOwnerState()
        let fresh = snapshot(&restarted, [local("claude:session:new")])
        _ = inventory.applySnapshot(fresh, hostID: ownerB, label: "Mini", socketID: UUID(), now: t0.addingTimeInterval(9))
        let afterRestart = inventory.receipt(for: ownerB)
        precondition(afterRestart?.snapshotReceivedAt == t0.addingTimeInterval(9) && afterRestart?.sessionsInSnapshot == 1)
        precondition(afterRestart?.usageReceivedAt == nil && afterRestart?.usageRowsIncluded == 0
                     && afterRestart?.usageRowsNotIncluded == 0, "A new boot epoch clears the previous usage summary")

        // Duplicate local cloud task: counted separately, received count unchanged.
        var cloudOwner = PeelPeerAgentOwnerState()
        cloudOwner.update([local("codex:cloud:task-9", provider: "codex", cloudTaskID: "task-9"), local("claude:session:x")])
        let cloud = cloudOwner.snapshot(now: t0, pairKey: pairKeyAB)
        var cloudInventory = PeelPeerAgentInventory()
        _ = cloudInventory.applySnapshot(cloud, hostID: ownerA, label: "MacBook", socketID: UUID(), now: t0)
        let localTag = PeelPeerAgentToken.pairTag(pairKey: pairKeyAB, domain: PeelPeerAgentOwnerState.cloudTagDomain,
                                                  value: "task-9")
        let isLocal: (UUID, String) -> Bool = { _, tag in tag == localTag }
        let deduped = cloudInventory.receipt(for: ownerA, isLocalCloudTask: isLocal)
        precondition(deduped?.sessionsInSnapshot == 2 && deduped?.sessionsAlsoLocal == 1)
        precondition(cloudInventory.rows(isLocalCloudTask: isLocal).filter(\.duplicatesLocalCloudTask).count == 1,
                     "Receipt uses the same duplicate rule as the projected rows")
        precondition(cloudInventory.receipt(for: ownerA)?.sessionsAlsoLocal == 0)

        // Revocation removes the receipt immediately.
        precondition(cloudInventory.retainOnly(trustedHostIDs: [ownerB]))
        precondition(cloudInventory.receipt(for: ownerA) == nil)
    }

    static func testLedgerExactlyOnce() {
        var ledger = PeelPeerActivationLedger()
        let key = PeelPeerAgentKey(ownerHostID: ownerA, provider: "claude", token: String(repeating: "A", count: 22))
        let socket = UUID()
        guard case .success(let request) = ledger.begin(key: key, socketID: socket, now: t0) else { preconditionFailure() }
        precondition(ledger.begin(key: key, socketID: socket, now: t0) == .failure(.alreadyPending),
                     "A second click never sends a second request")
        precondition(ledger.resolve(requestID: request, socketID: UUID(), outcome: .focusedExactSession) == nil,
                     "Results only count from the socket that carried the request")
        precondition(ledger.resolve(requestID: request, socketID: socket, outcome: .timedOut) == nil,
                     "A peer cannot claim a viewer-only outcome")
        precondition(ledger.resolve(requestID: request, socketID: socket, outcome: .exactSessionRequested)?.1
                        == .exactSessionRequested)
        precondition(ledger.resolve(requestID: request, socketID: socket, outcome: .launchFailed) == nil,
                     "Only the first result is accepted")

        guard case .success = ledger.begin(key: key, socketID: socket, now: t0) else { preconditionFailure() }
        precondition(ledger.expire(now: t0.addingTimeInterval(24)).isEmpty)
        precondition(ledger.expire(now: t0.addingTimeInterval(25)).map { $0.1 } == [.timedOut], "No automatic retry")

        guard case .success = ledger.begin(key: key, socketID: socket, now: t0) else { preconditionFailure() }
        precondition(ledger.socketClosed(socket).map { $0.1 } == [.timedOut], "Written but unconfirmed is not 'offline'")
        guard case .success = ledger.begin(key: key, socketID: socket, now: t0) else { preconditionFailure() }
        precondition(ledger.revoke(keepingOwners: [ownerB]).map { $0.1 } == [.revoked])

        for index in 0..<4 {
            let other = PeelPeerAgentKey(ownerHostID: ownerA, provider: "codex", token: String(repeating: "B", count: 21) + "\(index)")
            guard case .success = ledger.begin(key: other, socketID: socket, now: t0) else { preconditionFailure() }
        }
        let fifth = PeelPeerAgentKey(ownerHostID: ownerA, provider: "codex", token: String(repeating: "C", count: 22))
        precondition(ledger.begin(key: fifth, socketID: socket, now: t0) == .failure(.tooManyPending))
    }

    // MARK: Usage

    static func testUsageProjection() throws {
        let quota = PeelPeerUsageLocalInput.Quota(
            provider: "claude", name: "Claude", status: .ok,
            windows: [PeelPeerUsageWindow(kind: "session", label: "5h", usedPercent: 140, resetAt: 1_800_000_100),
                      PeelPeerUsageWindow(kind: "weekly", label: "Week", usedPercent: nil, resetAt: nil),
                      PeelPeerUsageWindow(kind: "opus", label: "Opus", usedPercent: 12, resetAt: nil),
                      PeelPeerUsageWindow(kind: "extra", label: "Extra", usedPercent: 1, resetAt: nil)],
            sampledAt: t0.addingTimeInterval(-30), plan: "Max", accountKey: "sha256:account-one")
        let observed = PeelPeerObservedUsage(provider: "claude", period: .history, days: 30, inputTokens: 10,
                                             models: [PeelPeerObservedModel(id: "claude-opus-5-5", totalTokens: nil,
                                                                            priceKnown: false)],
                                             provenance: "listPriceEstimate", coverageEstablished: false)
        let input = PeelPeerUsageLocalInput(quotas: [quota], observed: [.init(usage: observed, sampledAt: t0.addingTimeInterval(-5))])
        let summary = PeelPeerUsageProjection.summary(input, pairKey: pairKeyAB, bootEpoch: UUID(), revision: 1, now: t0)
        let json = String(decoding: try PeelPeerAgentWire.encode(summary), as: UTF8.self)
        precondition(!json.contains("account-one") && !json.contains("sha256"), "Raw account keys never cross the wire")
        let claude = summary.quotas[0]
        precondition(claude.windows.count == 3 && claude.windows[0].usedPercent == 100, "Bounded and clamped")
        precondition(claude.windows[1].usedPercent == nil, "Unknown stays unknown, never zero")
        precondition(summary.observed[0].outputTokens == nil && summary.observed[0].days == 30)
        precondition(abs((summary.observed[0].ageSeconds ?? 0) - 5) < 0.001, "Observed age is its own, not the quota's")

        // Same account on two Macs ⇒ same pair tag (collapse, never sum); other
        // account/pairing ⇒ different; nil/redacted ⇒ never collapses.
        let tag = claude.accountTag
        precondition(tag == PeelPeerUsageProjection.localAccountTag(provider: "claude", accountKey: "sha256:account-one", pairKey: pairKeyAB))
        precondition(tag != PeelPeerUsageProjection.localAccountTag(provider: "claude", accountKey: "sha256:account-two", pairKey: pairKeyAB))
        precondition(tag != PeelPeerUsageProjection.localAccountTag(provider: "claude", accountKey: "sha256:account-one", pairKey: pairKeyAC))
        precondition(PeelPeerUsageProjection.localAccountTag(provider: "claude", accountKey: nil, pairKey: pairKeyAB) == nil)
        precondition(PeelPeerUsageProjection.localAccountTag(provider: "claude", accountKey: "redacted@x", pairKey: pairKeyAB) == nil)

        guard case .usage(let decoded) = try PeelPeerAgentWire.decode(Data(json.utf8)) else { preconditionFailure() }
        precondition(decoded == summary)
        var tooMany = summary
        tooMany.quotas = Array(repeating: summary.quotas[0], count: 17)
        expectThrow("too many quotas") { _ = try PeelPeerAgentWire.decode(try JSONEncoder().encode(tooMany)) }

        // Byte budget: every field at maximum with escaping multibyte text.
        let nasty = String(repeating: "\"é\\", count: 40)
        let maxQuotas = (0..<20).map { index in
            PeelPeerUsageLocalInput.Quota(provider: "p\(index)", name: nasty, status: .ok, reason: "timed_out",
                windows: (0..<3).map { PeelPeerUsageWindow(kind: "k\($0)", label: nasty, usedPercent: 33.3333, resetAt: 1.5e9) },
                sampledAt: t0, plan: nasty, accountKey: "k\(index)")
        }
        let maxObserved = (0..<6).map { index in
            PeelPeerUsageLocalInput.Observed(usage: PeelPeerObservedUsage(
                provider: "claude", period: index.isMultiple(of: 2) ? .today : .history, days: index.isMultiple(of: 2) ? 1 : 30,
                inputTokens: Int(Int32.max), outputTokens: Int(Int32.max), totalTokens: Int(Int32.max),
                models: (0..<7).map { PeelPeerObservedModel(id: nasty + "\($0)", totalTokens: Int(Int32.max), priceKnown: true) },
                estimatedCostUSD: 123456.789, provenance: "listPriceEstimate", coverageEstablished: true), sampledAt: t0)
        }
        let bounded = PeelPeerUsageProjection.summary(.init(quotas: maxQuotas, observed: maxObserved), pairKey: pairKeyAB,
                                                      bootEpoch: UUID(), revision: UInt64.max, now: t0)
        let boundedData = try PeelPeerAgentWire.encode(bounded)
        precondition(boundedData.count <= PeelPeerUsageSummary.budgetBytes, "Never exceeds the line budget")
        precondition(!bounded.quotas.isEmpty, "Useful data survives instead of the whole summary vanishing")
        precondition(bounded.quotas.count + bounded.omittedQuotas == 20, "Every omitted quota is counted")
        precondition(bounded.observed.count + bounded.omittedObserved == 6, "Every omitted observation is counted")
        guard case .usage = try PeelPeerAgentWire.decode(boundedData) else { preconditionFailure() }

        // Viewer epoch/revision rules for usage.
        var inventory = PeelPeerAgentInventory()
        var owner = PeelPeerAgentOwnerState()
        let snap = snapshot(&owner, [local("a")])
        let socket = UUID()
        _ = inventory.applySnapshot(snap, hostID: ownerA, label: "MacBook", socketID: socket, now: t0)
        let fromOtherBoot = PeelPeerUsageProjection.summary(input, pairKey: pairKeyAB, bootEpoch: UUID(), revision: 1, now: t0)
        if case .violation = inventory.applyUsage(fromOtherBoot, hostID: ownerA, socketID: socket, now: t0) {} else {
            preconditionFailure("Usage from another boot epoch is rejected")
        }
        let current = PeelPeerUsageProjection.summary(input, pairKey: pairKeyAB, bootEpoch: snap.bootEpoch, revision: 2, now: t0)
        precondition(inventory.applyUsage(current, hostID: ownerA, socketID: socket, now: t0) == .applied)
        let older = PeelPeerUsageProjection.summary(input, pairKey: pairKeyAB, bootEpoch: snap.bootEpoch, revision: 1, now: t0)
        if case .violation = inventory.applyUsage(older, hostID: ownerA, socketID: socket, now: t0) {} else {
            preconditionFailure("Usage revision regression is rejected")
        }
        let keepalive = PeelPeerAgentKeepalive(bootEpoch: snap.bootEpoch, revision: snap.revision)
        _ = inventory.applyKeepalive(keepalive, hostID: ownerA, socketID: socket, now: t0.addingTimeInterval(600))
        precondition(inventory.owners[ownerA]?.usageReceivedAt == t0, "Keepalives never freshen usage")
    }

    /// Mini (healthy Claude) seen from MacBook (Claude sign-in needed), and the reverse.
    static func testUsagePresentation() {
        let miniClaude = PeelPeerQuota(provider: "claude", name: "Claude", status: .ok,
                                       windows: [PeelPeerUsageWindow(kind: "session", label: "5h", usedPercent: 40, resetAt: nil)],
                                       ageSeconds: 9, plan: "Max",
                                       accountTag: PeelPeerUsageProjection.localAccountTag(provider: "claude", accountKey: "acct-1", pairKey: pairKeyAB))
        let macBookClaude = PeelPeerQuota(provider: "claude", name: "Claude", status: .authNeeded, reason: "silent_auth_blocked",
                                          windows: [], ageSeconds: nil, plan: nil, accountTag: nil)
        let fromMini = PeelPeerUsageSummary(bootEpoch: UUID(), revision: 1, quotas: [miniClaude], observed: [])
        let fromMacBook = PeelPeerUsageSummary(bootEpoch: UUID(), revision: 1, quotas: [macBookClaude], observed: [
            PeelPeerObservedUsage(provider: "claude", period: .today, days: 1, totalTokens: nil, ageSeconds: 60)])

        // MacBook viewing mini: different/unknown local account ⇒ separate owner-labeled row.
        let separate = PeelPeerUsagePresentation.lines(ownerHostID: ownerA, ownerLabel: "Mini", summary: fromMini,
                                                       receivedAt: t0, live: true, localAccountTags: [], now: t0.addingTimeInterval(10))
        precondition(separate.count == 1 && separate[0].detail == "5h · 40% used" && separate[0].ownerLabel == "Mini")
        precondition(abs((separate[0].age ?? 0) - 19) < 0.001, "Producer age plus transit, never reset by receipt")
        // Same account (real tag match) ⇒ collapsed into one note; never added.
        let tag = miniClaude.accountTag!
        let collapsed = PeelPeerUsagePresentation.lines(ownerHostID: ownerA, ownerLabel: "Mini", summary: fromMini,
                                                        receivedAt: t0, live: true, localAccountTags: [tag], now: t0)
        precondition(collapsed.count == 1 && collapsed[0].kind == .note)
        // Mini viewing MacBook: auth needed shown truthfully; unknown tokens stay unknown.
        let auth = PeelPeerUsagePresentation.lines(ownerHostID: ownerB, ownerLabel: "MacBook", summary: fromMacBook,
                                                   receivedAt: t0, live: true, localAccountTags: [tag], now: t0)
        precondition(auth[0].isProblem && auth[0].detail.contains("Sign-in needed"), "nil tag never collapses")
        precondition(auth[1].kind == .observed && auth[1].detail.contains("tokens unknown"))
        // Disconnected owner ⇒ previous reading, not current.
        let offline = PeelPeerUsagePresentation.lines(ownerHostID: ownerA, ownerLabel: "Mini", summary: fromMini,
                                                      receivedAt: t0, live: false, localAccountTags: [], now: t0)
        precondition(offline[0].detail.hasSuffix("previous reading"))
    }

    // MARK: Writer turns

    /// One owner socket, simulated in milliseconds with the service's gates:
    /// LED frames at most every 500 ms (local frame updates every 100 ms),
    /// agent snapshots at most every 250 ms, keepalive after 5 s, usage on a
    /// new revision, a 1 s tick, and a write completion `latency` after each
    /// write. Every writer-free moment goes through `PeelPeerWriterTurns`.
    struct WriterRun {
        var frames: [Int] = [], agentWrites: [Int] = [], usageWrites: [Int] = []
    }

    static func runWriter(agentChangeEvery: Int?, usageBumpAt: Int, latency: Int = 30,
                          duration: Int = 30_000) -> WriterRun {
        var run = WriterRun()
        var last: PeelPeerWriterLane?
        var busyUntil: Int?
        var lastFrame: Int?, lastAgent = Int.min / 2
        var agentRevision = 1, sentAgentRevision: Int?
        var usageRevision = 1, sentUsageRevision: Int?, lastUsage = Int.min / 2
        for now in 0...duration {
            if let agentChangeEvery, now > 0, now % agentChangeEvery == 0 { agentRevision += 1 }
            if now == usageBumpAt { usageRevision += 1 }
            var writerFree = false
            if let until = busyUntil, now >= until { busyUntil = nil; writerFree = true }   // completion
            if now % 100 == 0 || now % 1000 == 0 || now % 250 == 0 { writerFree = true }    // frame, tick, flush
            guard writerFree, busyUntil == nil else { continue }
            let lane = PeelPeerWriterTurns.next(after: last) { lane in
                switch lane {
                case .frame:
                    guard lastFrame.map({ now - $0 >= 500 }) ?? true else { return false }
                    lastFrame = now; run.frames.append(now)
                case .agents:
                    if sentAgentRevision != agentRevision {
                        guard now - lastAgent >= 250 else { return false }
                        sentAgentRevision = agentRevision
                    } else if now - lastAgent < 5_000 { return false }
                    lastAgent = now; run.agentWrites.append(now)
                case .usage:
                    guard sentAgentRevision != nil, sentUsageRevision != usageRevision,
                          sentUsageRevision == nil || now - lastUsage >= 30_000 else { return false }
                    sentUsageRevision = usageRevision; lastUsage = now; run.usageWrites.append(now)
                }
                return true
            }
            if let lane { last = lane; busyUntil = now + latency }
        }
        return run
    }

    static func maxGap(_ times: [Int], end: Int) -> Int {
        zip(times, times.dropFirst() + [end]).map { $1 - $0 }.max() ?? end
    }

    static func testWriterFairness() {
        // Steady agents while LED frames are always due: the keepalive must
        // still reach the viewer well inside its 15 s socket / freshness
        // window, and LED frames keep their full 2 Hz rate.
        let steady = runWriter(agentChangeEvery: nil, usageBumpAt: 12_000, duration: 70_000)
        precondition(!steady.agentWrites.isEmpty && steady.agentWrites[0] < 1_000, "First snapshot is prompt")
        precondition(maxGap(steady.agentWrites, end: 70_000) <= 6_000, "Agent keepalive is never starved by LED")
        precondition(steady.frames.count >= 70_000 / 600 && maxGap(steady.frames, end: 70_000) <= 600,
                     "LED keeps 2 Hz")
        precondition(steady.usageWrites.count == 2 && steady.usageWrites[0] < 1_000, "Initial usage is sent")
        precondition(steady.usageWrites[1] >= steady.usageWrites[0] + 30_000
                        && steady.usageWrites[1] <= steady.usageWrites[0] + 31_000,
                     "New usage revision is sent as soon as its own gap allows")

        // Agents changing constantly must not starve LED frames either.
        let churn = runWriter(agentChangeEvery: 50, usageBumpAt: 40_000)
        precondition(churn.frames.count >= 30_000 / 600 && maxGap(churn.frames, end: 30_000) <= 600, "LED is never starved")
        precondition(maxGap(churn.agentWrites, end: 30_000) <= 600, "Changing agents still progress")
        precondition(churn.agentWrites.count <= 30_000 / 250 + 1, "Snapshots stay within their rate gate")
        precondition(churn.usageWrites.count == 1, "No duplicate usage without a new revision")

        // Nothing due: no lane writes and the turn does not advance.
        precondition(PeelPeerWriterTurns.next(after: .frame) { _ in false } == nil)
    }
}
