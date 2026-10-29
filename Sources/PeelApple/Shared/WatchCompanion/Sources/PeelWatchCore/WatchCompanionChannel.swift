import Foundation

/// Classifies bounded native messages before any legacy decoder can discard an
/// unknown field. Classification grants no authority; each channel still runs
/// its own complete schema, direction, peer and session validation.
public enum WatchCompanionChannel: Sendable {
    case enrollment, cloudV2, cloudV1, stream, draft

    public enum ClassificationError: Error { case invalidMessage }

    public static func classify(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= WatchStreamWire.maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClassificationError.invalidMessage
        }
        // JSONSerialization can erase duplicate keys, including escaped forms.
        // Validate the original top-level keys before trusting its channel.
        try requireUniqueTopLevelKeys(data)
        guard let channel = root["channel"] else {
            guard Set(root.keys) == ["version", "draft"] else {
                throw ClassificationError.invalidMessage
            }
            return .draft
        }
        switch channel as? String {
        case "peel.watch.cloud.enrollment.v1": return .enrollment
        case "peel.watch.cloud.v2": return .cloudV2
        case "peel.watch.cloud.v1": return .cloudV1
        case "peel.watch.stream.v1": return .stream
        default: throw ClassificationError.invalidMessage
        }
    }

    private static func requireUniqueTopLevelKeys(_ data: Data) throws {
        // JSONSerialization above has already checked JSON syntax, including
        // string escapes and numbers. This scan only preserves original keys.
        let bytes = Array(data)
        var index = 0, depth = 0
        var expectsKey = false
        var keys = Set<String>()
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x5C { index += 2; continue }
                    if bytes[index] == 0x22 { break }
                    index += 1
                }
                guard index < bytes.count else { throw ClassificationError.invalidMessage }
                if depth == 1 && expectsKey {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard keys.insert(key).inserted else { throw ClassificationError.invalidMessage }
                    expectsKey = false
                }
            case 0x7B, 0x5B:
                depth += 1
                if depth == 1 { expectsKey = true }
            case 0x7D, 0x5D: depth -= 1
            case 0x2C:
                if depth == 1 { expectsKey = true }
            default: break
            }
            index += 1
        }
    }
}
