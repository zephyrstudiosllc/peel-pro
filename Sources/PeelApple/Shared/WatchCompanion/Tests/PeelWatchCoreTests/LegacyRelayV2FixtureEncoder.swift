import Foundation
@testable import PeelWatchCore

// Frozen pre-change encoder/validator from the captured base, renamed with internal visibility only.
// Compatibility oracle, never production routing or a new wire implementation.
struct LegacyRelayV2FixtureEnvelope: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case status, send, receipt, chunkRequest, chunk, acknowledge, localStop }
    let channel: String
    let version: Int
    let courierID: UUID
    let fence: PluginRelayFence
    let kind: Kind
    let message: PluginRelayMessage?
    let receipt: PluginRelayReceipt?
    let chunk: PluginRelayChunk?
    let requestID: UUID?
    let replyID: String?
    let chunkIndex: Int?
    let digest: String?
    let cancelCourierID: UUID?

    init(courierID: UUID, fence: PluginRelayFence, kind: Kind,
                message: PluginRelayMessage? = nil, receipt: PluginRelayReceipt? = nil,
                chunk: PluginRelayChunk? = nil, requestID: UUID? = nil, replyID: String? = nil,
                chunkIndex: Int? = nil, digest: String? = nil, cancelCourierID: UUID? = nil) throws {
        channel = "peel.watch.cloud.v2"; version = 2; self.courierID = courierID; self.fence = fence; self.kind = kind
        self.message = message; self.receipt = receipt; self.chunk = chunk; self.requestID = requestID
        self.replyID = replyID; self.chunkIndex = chunkIndex; self.digest = digest; self.cancelCourierID = cancelCourierID
        try validate()
    }
    func validate() throws {
        try fence.binding.route.validate()
        guard channel == "peel.watch.cloud.v2", version == 2 else { throw PluginRelayError.invalidPayload }
        let present = Set([(message != nil, "message"), (receipt != nil, "receipt"), (chunk != nil, "chunk"),
                           (requestID != nil, "requestID"), (replyID != nil, "replyID"), (chunkIndex != nil, "chunkIndex"),
                           (digest != nil, "digest"), (cancelCourierID != nil, "cancelCourierID")].compactMap { $0.0 ? $0.1 : nil })
        let required: Set<String>
        switch kind {
        case .status: required = []
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
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= WatchStreamWire.maximumBytes else { throw PluginRelayError.capacity }
        return data
    }
    static func decode(_ data: Data, expectedFence: PluginRelayFence,
                              expectedCourierID: UUID? = nil) throws -> Self {
        guard !data.isEmpty, data.count <= WatchStreamWire.maximumBytes else { throw PluginRelayError.capacity }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate()
        guard value.fence == expectedFence else { throw PluginRelayError.wrongBinding }
        if let id = expectedCourierID, value.courierID != id { throw PluginRelayError.wrongBinding }
        return value
    }
}
