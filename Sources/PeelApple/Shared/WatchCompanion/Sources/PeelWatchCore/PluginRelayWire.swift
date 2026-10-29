import Foundation

public struct PluginRelayChunk: Codable, Equatable, Sendable {
    public let route: PluginRelayReference
    public let requestID: UUID
    public let replyID: String
    public let index: Int
    public let count: Int
    public let totalUTF8Bytes: Int
    public let digest: String
    public let text: String

    public init(route: PluginRelayReference, requestID: UUID, replyID: String, index: Int,
                count: Int, totalUTF8Bytes: Int, digest: String, text: String) throws {
        self.route = route; self.requestID = requestID; self.replyID = replyID
        self.index = index; self.count = count; self.totalUTF8Bytes = totalUTF8Bytes
        self.digest = digest; self.text = text; try validate()
    }
    public func validate() throws {
        try route.validate()
        guard PluginRelayValidation.opaque(replyID), (1...8).contains(count), (0..<count).contains(index),
              (1...32_000).contains(totalUTF8Bytes), PluginRelayValidation.isDigest(digest),
              PluginRelayValidation.text(text, send: false, allowBlank: true),
              text.utf8.count <= 8 * 1_024, text.utf8.count <= totalUTF8Bytes else {
            throw PluginRelayError.invalidPayload
        }
    }
    func sameAssembly(as other: Self) -> Bool {
        route == other.route && requestID == other.requestID && PluginRelayValidation.sameBytes(replyID, other.replyID)
        && count == other.count && totalUTF8Bytes == other.totalUTF8Bytes && digest == other.digest
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sameAssembly(as: rhs) && lhs.index == rhs.index && PluginRelayValidation.sameBytes(lhs.text, rhs.text)
    }
    public static func split(_ reply: PluginRelayReply, route: PluginRelayReference) throws -> [Self] {
        try reply.validate(); try route.validate()
        var pieces: [String] = [], current = "", bytes = 0
        for scalar in reply.text.unicodeScalars {
            let text = String(scalar), size = text.utf8.count
            if bytes + size > 8 * 1_024 { pieces.append(current); current = ""; bytes = 0 }
            current.unicodeScalars.append(scalar); bytes += size
        }
        if !current.isEmpty { pieces.append(current) }
        return try pieces.enumerated().map { index, text in
            try Self(route: route, requestID: reply.requestID, replyID: reply.replyID, index: index,
                     count: pieces.count, totalUTF8Bytes: reply.text.utf8.count,
                     digest: PluginRelayValidation.digest(reply.text), text: text)
        }
    }
}

/// Additive v2 courier with no secret-bearing field or native authority grant.
/// A statusReport is an ephemeral remote report, not verified native readiness.
/// Actual composition belongs to the authenticated phone coordinator and trusted
/// session/peer adapters, never an encoded route or restored local checkpoint.
public struct PluginRelayV2Envelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case status, send, receipt, chunkRequest, chunk, acknowledge, localStop, statusReport, replyRefresh }
    public let channel: String
    public let version: Int
    public let courierID: UUID
    public let fence: PluginRelayFence
    public let kind: Kind
    public let message: PluginRelayMessage?
    public let receipt: PluginRelayReceipt?
    public let chunk: PluginRelayChunk?
    public let requestID: UUID?
    public let replyID: String?
    public let chunkIndex: Int?
    public let digest: String?
    public let cancelCourierID: UUID?
    public let statusReport: PluginRelayStatusReport?

    public init(courierID: UUID, fence: PluginRelayFence, kind: Kind,
                message: PluginRelayMessage? = nil, receipt: PluginRelayReceipt? = nil,
                chunk: PluginRelayChunk? = nil, requestID: UUID? = nil, replyID: String? = nil,
                chunkIndex: Int? = nil, digest: String? = nil, cancelCourierID: UUID? = nil,
                statusReport: PluginRelayStatusReport? = nil) throws {
        channel = "peel.watch.cloud.v2"; version = 2; self.courierID = courierID; self.fence = fence; self.kind = kind
        self.message = message; self.receipt = receipt; self.chunk = chunk; self.requestID = requestID
        self.replyID = replyID; self.chunkIndex = chunkIndex; self.digest = digest; self.cancelCourierID = cancelCourierID; self.statusReport = statusReport
        try validate()
    }
    public func validate() throws {
        try fence.binding.route.validate()
        guard channel == "peel.watch.cloud.v2", version == 2 else { throw PluginRelayError.invalidPayload }
        let present = Set([(message != nil, "message"), (receipt != nil, "receipt"), (chunk != nil, "chunk"),
                           (requestID != nil, "requestID"), (replyID != nil, "replyID"), (chunkIndex != nil, "chunkIndex"),
                           (digest != nil, "digest"), (cancelCourierID != nil, "cancelCourierID"),
                           (statusReport != nil, "statusReport")].compactMap { $0.0 ? $0.1 : nil })
        let required: Set<String>
        switch kind {
        case .status, .replyRefresh: required = []
        case .statusReport:
            required = ["statusReport"]; try statusReport?.validate(provider: fence.binding.route.provider)
        case .send: required = ["message"]; try message?.validate()
        case .receipt:
            required = ["receipt"]; try receipt?.validate()
            guard receipt?.route == fence.binding.route else { throw PluginRelayError.wrongBinding }
        case .chunk:
            required = ["chunk"]; try chunk?.validate()
            guard chunk?.route == fence.binding.route else { throw PluginRelayError.wrongBinding }
        case .chunkRequest: required = ["requestID", "replyID", "chunkIndex"]
        case .acknowledge: required = ["requestID", "replyID", "digest"]
        case .localStop: required = ["cancelCourierID"]
        }
        guard present == required,
              replyID.map(PluginRelayValidation.opaque) ?? true,
              chunkIndex.map({ (0..<8).contains($0) }) ?? true,
              digest.map(PluginRelayValidation.isDigest) ?? true else { throw PluginRelayError.invalidPayload }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= WatchStreamWire.maximumBytes else { throw PluginRelayError.capacity }
        return data
    }
    public static func decode(_ data: Data, expectedFence: PluginRelayFence,
                              expectedCourierID: UUID? = nil) throws -> Self {
        guard !data.isEmpty, data.count <= WatchStreamWire.maximumBytes else { throw PluginRelayError.capacity }
        try PluginRelayCourierJSON.validateEnvelope(data)
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate()
        guard value.fence == expectedFence else { throw PluginRelayError.wrongBinding }
        if let id = expectedCourierID, value.courierID != id { throw PluginRelayError.wrongBinding }
        return value
    }
}
