import Foundation

/// Shared v2 courier grammar (derived from the accepted owned HTTP parser): bounded valid UTF-8 JSON, unique decoded object
/// keys at every depth, integer numbers only. Endpoint schemas reject unknown
/// fields separately. No Foundation dictionary conversion can erase duplicates.
indirect enum PluginRelayCourierJSON {
    case object([String: PluginRelayCourierJSON]), array([PluginRelayCourierJSON]), string(String), integer(Int64), bool(Bool), null
    func object(keys: Set<String>) throws -> [String: Self] {
        guard case .object(let result) = self, Set(result.keys) == keys else { throw PluginRelayError.invalidPayload }
        return result
    }
    func string() throws -> String { guard case .string(let result) = self else { throw PluginRelayError.invalidPayload }; return result }
    func integer() throws -> Int64 { guard case .integer(let result) = self else { throw PluginRelayError.invalidPayload }; return result }
    func bool() throws -> Bool { guard case .bool(let result) = self else { throw PluginRelayError.invalidPayload }; return result }
    func optionalInteger() throws -> Int64? { if case .null = self { return nil }; return try integer() }

    static func validateEnvelope(_ data: Data) throws {
        let value = try parse(data)
        guard case .object(let root) = value,
              let kind = PluginRelayV2Envelope.Kind(rawValue: try root.required("kind").string()) else {
            throw PluginRelayError.invalidPayload
        }
        let fixed: Set<String> = ["channel", "version", "courierID", "fence", "kind"]
        let payload: Set<String>
        switch kind {
        case .status, .replyRefresh: payload = []
        case .send: payload = ["message"]
        case .receipt: payload = ["receipt"]
        case .chunkRequest: payload = ["requestID", "replyID", "chunkIndex"]
        case .chunk: payload = ["chunk"]
        case .acknowledge: payload = ["requestID", "replyID", "digest"]
        case .localStop: payload = ["cancelCourierID"]
        case .statusReport: payload = ["statusReport"]
        }
        _ = try value.object(keys: fixed.union(payload))
        let fence = try root.required("fence").object(keys: ["binding", "localEpoch"])
        let binding = try fence.required("binding").object(keys: ["route", "pairingEpoch"])
        try route(binding.required("route"))
        switch kind {
        case .send: _ = try root.required("message").object(keys: ["messageID", "text"])
        case .receipt:
            let receipt = try root.required("receipt").object(keys: ["requestID", "route", "receiptID", "state", "agentReplyReceived"])
            try route(receipt.required("route"))
        case .chunk:
            let chunk = try root.required("chunk").object(keys: ["route", "requestID", "replyID", "index", "count", "totalUTF8Bytes", "digest", "text"])
            try route(chunk.required("route"))
        case .statusReport:
            let required: Set<String> = ["state", "remoteReady", "deliveryMode", "automaticDeliveryReady"]
            guard case .object(let report) = try root.required("statusReport"),
                  required.isSubset(of: Set(report.keys)),
                  Set(report.keys).isSubset(of: required.union(["minimumRoutineIntervalSeconds", "nextReply"])) else {
                throw PluginRelayError.invalidPayload
            }
            if let interval = report["minimumRoutineIntervalSeconds"] { _ = try interval.integer() }
            if let notice = report["nextReply"] {
                _ = try notice.object(keys: ["requestID", "replyID", "chunkCount", "totalUTF8Bytes", "digest"])
            }
        case .status, .replyRefresh, .chunkRequest, .acknowledge, .localStop: break
        }
        // JSONDecoder below enforces all scalar/UUID/enum types, while typed
        // validate() enforces the kind union and provider/status combinations.
        // Null optional keys cannot silently bypass the exact payload schema.
    }

    private static func route(_ value: Self) throws {
        _ = try value.object(keys: ["kind", "provider", "routeID", "generation", "accountGeneration"])
    }

    static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= WatchStreamWire.maximumBytes, String(data: data, encoding: .utf8) != nil else {
            throw PluginRelayError.invalidPayload
        }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw PluginRelayError.invalidPayload }
        return value
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            space(); guard index < bytes.count, bytes[index] == byte else { return false }; index += 1; return true
        }
        mutating func value(depth: Int) throws -> PluginRelayCourierJSON {
            space(); nodes += 1
            guard depth <= 16, nodes <= 4_096, index < bytes.count else { throw PluginRelayError.invalidPayload }
            switch bytes[index] {
            case 123:
                index += 1; var result: [String: PluginRelayCourierJSON] = [:]
                if consume(125) { return .object(result) }
                repeat {
                    space(); let key = try string()
                    guard result[key] == nil, consume(58) else { throw PluginRelayError.invalidPayload }
                    result[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(result) }
                    guard consume(44) else { throw PluginRelayError.invalidPayload }
                } while true
            case 91:
                index += 1; var result: [PluginRelayCourierJSON] = []
                if consume(93) { return .array(result) }
                repeat {
                    result.append(try value(depth: depth + 1))
                    if consume(93) { return .array(result) }
                    guard consume(44) else { throw PluginRelayError.invalidPayload }
                } while true
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57:
                let start = index
                if bytes[index] == 45 { index += 1 }
                guard index < bytes.count else { throw PluginRelayError.invalidPayload }
                if bytes[index] == 48 { index += 1 }
                else {
                    guard (49...57).contains(bytes[index]) else { throw PluginRelayError.invalidPayload }
                    while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                }
                guard let result = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw PluginRelayError.invalidPayload }
                return .integer(result)
            default: throw PluginRelayError.invalidPayload
            }
        }
        mutating func literal(_ expected: String) throws {
            let value = Array(expected.utf8)
            guard bytes.count - index >= value.count, Array(bytes[index..<index + value.count]) == value else { throw PluginRelayError.invalidPayload }
            index += value.count
        }
        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw PluginRelayError.invalidPayload }
            let start = index; index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    // Decode only the individual string after syntax scanning;
                    // JSONDecoder verifies escape/surrogate correctness here.
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw PluginRelayError.invalidPayload }
                }
                guard byte >= 32 else { throw PluginRelayError.invalidPayload }
                if byte == 92 {
                    guard index < bytes.count else { throw PluginRelayError.invalidPayload }
                    index += 1
                }
            }
            throw PluginRelayError.invalidPayload
        }
    }
}

extension Dictionary where Key == String, Value == PluginRelayCourierJSON {
    func required(_ key: String) throws -> PluginRelayCourierJSON {
        guard let value = self[key] else { throw PluginRelayError.invalidPayload }; return value
    }
}
