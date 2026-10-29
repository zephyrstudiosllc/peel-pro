import Foundation

/// Bounded encoder observations. Reads never reset counters or touch capture state.
/// Tokens reject callbacks from replaced encoders, including after a disconnect.
nonisolated final class PeelStreamingDiagnostics: @unchecked Sendable {
    static let maximumStreams = 32
    static let maximumSamples = 1024
    static let measurementWindowSeconds: Double = 5

    struct Sample: Sendable {
        let uptime: Double
        let bytes: Int
        let encodeMilliseconds: Double?
    }

    private struct Stream {
        let token: UUID
        let windowID: UInt32
        let startedAt: Double
        var active = true
        var width: Int
        var height: Int
        var targetFPS: Int
        var targetBitrate: Int
        var codec: String
        var encoderMode: String?
        var encoderID: String?
        var hardwareAccelerated: Bool?
        var hardwareVerification: String?
        var speedPriorityPropertyStatus: Int32?
        var submittedFrames = 0
        var outputFrames = 0
        var outputBytes = 0
        var keyframes = 0
        var replacedPendingFrames = 0
        var explicitVTDroppedFrames = 0
        var resets = 0
        var sessionFailures = 0
        var lastSessionFailure: String?
        var recentSessionFailures: [String] = []
        var lastResetReason: String?
        var recoveryState = "waitingForSession"
        var nextEncoderCandidate: String?
        var consecutiveRuntimeFailures = 0
        var retryAfterUptime: Double?
        var lastOutputAt: Double?
        var sourceClockVerifiedAt: Double?
        var samples = [Sample?](repeating: nil, count: maximumSamples)
        var nextSample = 0
    }

    private let lock = NSLock()
    private var streams: [UInt32: Stream] = [:]
    private var untrackedEncoderStarts = 0
    private let uptime: @Sendable () -> Double

    init(uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func begin(windowID: UInt32, width: Int, height: Int, targetFPS: Int,
               targetBitrate: Int, preferredCodec: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if streams[windowID] == nil, streams.count >= Self.maximumStreams {
            // Telemetry must never stop streaming or grow without a bound.
            guard let oldest = streams.values.filter({ !$0.active })
                .min(by: { $0.startedAt < $1.startedAt }) else {
                    untrackedEncoderStarts += 1
                    return nil
                }
            streams.removeValue(forKey: oldest.windowID)
        }
        let token = UUID()
        streams[windowID] = Stream(token: token, windowID: windowID, startedAt: uptime(),
            width: width, height: height, targetFPS: targetFPS,
            targetBitrate: targetBitrate, codec: preferredCodec)
        return token
    }

    private func update(windowID: UInt32, token: UUID?, _ change: (inout Stream) -> Void) {
        guard let token else { return }
        lock.lock()
        defer { lock.unlock() }
        guard streams[windowID]?.token == token, streams[windowID]?.active == true else { return }
        change(&streams[windowID]!)
    }

    func setPolicy(windowID: UInt32, token: UUID?, fps: Int, bitrate: Int) {
        update(windowID: windowID, token: token) { $0.targetFPS = fps; $0.targetBitrate = bitrate }
    }

    func setEncoder(windowID: UInt32, token: UUID?, codec: String, mode: String,
                    hardwareAccelerated: Bool?, hardwareVerification: String? = nil, encoderID: String? = nil) {
        update(windowID: windowID, token: token) {
            $0.codec = codec; $0.encoderMode = mode; $0.hardwareAccelerated = hardwareAccelerated
            $0.hardwareVerification = hardwareVerification
            $0.encoderID = encoderID.map { String($0.prefix(160)) }
        }
    }

    func submitted(windowID: UInt32, token: UUID?) {
        update(windowID: windowID, token: token) { $0.submittedFrames += 1 }
    }

    func noteSourceClock(windowID: UInt32, token: UUID?, verified: Bool) {
        update(windowID: windowID, token: token) { $0.sourceClockVerifiedAt = verified ? uptime() : nil }
    }

    func verifiedSourceWindowIds() -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        let now = uptime()
        return streams.values.filter {
            $0.active && ($0.sourceClockVerifiedAt.map { now >= $0 && now - $0 <= 5 } ?? false)
        }.map(\.windowID).sorted()
    }

    func setSpeedPriorityStatus(windowID: UInt32, token: UUID?, status: Int32) {
        update(windowID: windowID, token: token) { $0.speedPriorityPropertyStatus = status }
    }

    func replacedPending(windowID: UInt32, token: UUID?) {
        update(windowID: windowID, token: token) { $0.replacedPendingFrames += 1 }
    }

    func explicitFrameDropped(windowID: UInt32, token: UUID?) {
        update(windowID: windowID, token: token) { $0.explicitVTDroppedFrames += 1 }
    }

    func sessionFailure(windowID: UInt32, token: UUID?, reason: String) {
        update(windowID: windowID, token: token) {
            $0.sessionFailures += 1; $0.lastSessionFailure = String(reason.prefix(160))
            $0.recentSessionFailures.append(String(reason.prefix(160)))
            if $0.recentSessionFailures.count > 8 { $0.recentSessionFailures.removeFirst() }
        }
    }

    func resetEncoder(windowID: UInt32, token: UUID?, reason: String) {
        update(windowID: windowID, token: token) {
            $0.resets += 1; $0.encoderMode = nil; $0.hardwareAccelerated = nil
            $0.hardwareVerification = nil
            $0.encoderID = nil
            $0.speedPriorityPropertyStatus = nil
            $0.lastResetReason = String(reason.prefix(160))
        }
    }

    func setRecovery(windowID: UInt32, token: UUID?, state: String, nextCandidate: String,
                     consecutiveFailures: Int, retryAfterUptime: Double?) {
        update(windowID: windowID, token: token) {
            $0.recoveryState = String(state.prefix(32))
            $0.nextEncoderCandidate = String(nextCandidate.prefix(32))
            $0.consecutiveRuntimeFailures = max(0, consecutiveFailures)
            $0.retryAfterUptime = retryAfterUptime.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    func output(windowID: UInt32, token: UUID?, bytes: Int, keyframe: Bool,
                encodeMilliseconds: Double?) {
        guard bytes >= 0 else { return }
        let now = uptime()
        let duration = encodeMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        update(windowID: windowID, token: token) {
            $0.outputFrames += 1
            $0.outputBytes += bytes
            if keyframe { $0.keyframes += 1 }
            $0.lastOutputAt = now
            $0.recoveryState = "active"
            $0.consecutiveRuntimeFailures = 0
            $0.retryAfterUptime = nil
            $0.samples[$0.nextSample] = Sample(uptime: now, bytes: bytes, encodeMilliseconds: duration)
            $0.nextSample = ($0.nextSample + 1) % Self.maximumSamples
        }
    }

    func end(windowID: UInt32, token: UUID?) {
        update(windowID: windowID, token: token) { $0.active = false }
    }

    func reset() {
        lock.lock()
        streams.removeAll()
        untrackedEncoderStarts = 0
        lock.unlock()
    }

    func snapshot() -> PeelLocalAgentJSONValue {
        lock.lock()
        let now = uptime()
        let observations = Array(streams.values)
        let untracked = untrackedEncoderStarts
        lock.unlock()

        func number(_ value: Double?) -> PeelLocalAgentJSONValue {
            guard let value, value.isFinite else { return .null }
            return .number(value)
        }
        let rows = observations.sorted { $0.windowID < $1.windowID }.map { stream in
            let elapsed = min(Self.measurementWindowSeconds, max(0, now - stream.startedAt))
            let samples = stream.samples.compactMap { $0 }.filter {
                $0.uptime > now - Self.measurementWindowSeconds && $0.uptime <= now
            }
            let durations = samples.compactMap(\.encodeMilliseconds).sorted()
            func percentile(_ fraction: Double) -> Double? {
                guard !durations.isEmpty else { return nil }
                return durations[max(0, Int(ceil(Double(durations.count) * fraction)) - 1)]
            }
            let bytes = samples.reduce(0) { $0 + $1.bytes }
            return PeelLocalAgentJSONValue.object([
                "windowId": .integer(Int64(stream.windowID)),
                "encoderGeneration": .string(stream.token.uuidString),
                "active": .bool(stream.active),
                "width": .integer(Int64(stream.width)), "height": .integer(Int64(stream.height)),
                "targetFPS": .integer(Int64(stream.targetFPS)),
                "sourcePTSHostClockVerified": .bool(stream.sourceClockVerifiedAt.map { now >= $0 && now - $0 <= 5 } ?? false),
                "targetBitrate": .integer(Int64(stream.targetBitrate)),
                "codec": .string(stream.codec),
                "encoderMode": stream.encoderMode.map(PeelLocalAgentJSONValue.string) ?? .null,
                "encoderID": stream.encoderID.map(PeelLocalAgentJSONValue.string) ?? .null,
                "hardwareAccelerated": stream.hardwareAccelerated.map(PeelLocalAgentJSONValue.bool) ?? .null,
                "hardwareVerification": stream.hardwareVerification.map(PeelLocalAgentJSONValue.string) ?? .null,
                "speedPriorityPropertyStatus": stream.speedPriorityPropertyStatus.map { .integer(Int64($0)) } ?? .null,
                "lastOutputAgeSeconds": number(stream.lastOutputAt.map { max(0, now - $0) }),
                "measurementWindowSeconds": .number(elapsed),
                "outputSampleCount": .integer(Int64(samples.count)),
                "sampleCapacityReached": .bool(samples.count == Self.maximumSamples),
                "encodedFPS": number(elapsed >= 1 && samples.count < Self.maximumSamples ? Double(samples.count) / elapsed : nil),
                "encodedMbps": number(elapsed >= 1 && samples.count < Self.maximumSamples ? Double(bytes) * 8 / elapsed / 1_000_000 : nil),
                "encodeCallbackMillisecondsP50": number(percentile(0.5)),
                "encodeCallbackMillisecondsP95": number(percentile(0.95)),
                "encodeCallbackMillisecondsMax": number(durations.last),
                "submittedFrames": .integer(Int64(stream.submittedFrames)),
                "outputFrames": .integer(Int64(stream.outputFrames)),
                "outputBytes": .integer(Int64(stream.outputBytes)),
                "keyframes": .integer(Int64(stream.keyframes)),
                "replacedPendingRawFrames": .integer(Int64(stream.replacedPendingFrames)),
                "explicitVTDroppedFrames": .integer(Int64(stream.explicitVTDroppedFrames)),
                "encoderResets": .integer(Int64(stream.resets)),
                "sessionFailures": .integer(Int64(stream.sessionFailures)),
                "lastSessionFailure": stream.lastSessionFailure.map(PeelLocalAgentJSONValue.string) ?? .null,
                "recentSessionFailures": .array(stream.recentSessionFailures.map(PeelLocalAgentJSONValue.string)),
                "lastEncoderResetReason": stream.lastResetReason.map(PeelLocalAgentJSONValue.string) ?? .null,
                "recoveryState": .string(stream.recoveryState),
                "nextEncoderCandidate": stream.nextEncoderCandidate.map(PeelLocalAgentJSONValue.string) ?? .null,
                "consecutiveRuntimeFailures": .integer(Int64(stream.consecutiveRuntimeFailures)),
                "retryAfterHostUptimeSeconds": number(stream.retryAfterUptime)
            ])
        }
        return .object([
            "schemaVersion": .integer(1),
            "scope": .string("host_encoder"),
            "sampledAtHostUptimeSeconds": .number(now),
            "maximumStreams": .integer(Int64(Self.maximumStreams)),
            "untrackedEncoderStarts": .integer(Int64(untracked)),
            "streams": .array(rows),
            "clientReceiveMetrics": .null,
            "clientPresentationMetrics": .null,
            "endToEndLatencyMilliseconds": .null,
            "measurementNotes": .array([
                .string("Encoder output is not network delivery or client display."),
                .string("Encode callback duration includes callback queue scheduling; it is not input-to-photon latency."),
                .string("Rates cover the trailing five seconds; snapshots do not reset counters. Rates are null during the first second."),
                .string("A static source may legitimately emit fewer frames than the target FPS."),
                .string("No screenshots, window titles, input contents or pairing keys are included.")
            ])
        ])
    }
}
