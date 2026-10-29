#if !os(watchOS)
import Foundation

/// Narrow HTTP response grammar: bounded valid UTF-8 JSON, unique decoded object
/// keys at every depth, integer numbers only. Endpoint schemas reject unknown
/// fields separately. No Foundation dictionary conversion can erase duplicates.
indirect enum PluginRelayJSON {
    case object([String: PluginRelayJSON]), array([PluginRelayJSON]), string(String), integer(Int64), bool(Bool), null
    func object(keys: Set<String>) throws -> [String: Self] {
        guard case .object(let result) = self, Set(result.keys) == keys else { throw PluginRelayHTTPError.invalidResponse }
        return result
    }
    func string() throws -> String { guard case .string(let result) = self else { throw PluginRelayHTTPError.invalidResponse }; return result }
    func integer() throws -> Int64 { guard case .integer(let result) = self else { throw PluginRelayHTTPError.invalidResponse }; return result }
    func bool() throws -> Bool { guard case .bool(let result) = self else { throw PluginRelayHTTPError.invalidResponse }; return result }
    func optionalInteger() throws -> Int64? { if case .null = self { return nil }; return try integer() }

    static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 256 * 1_024, String(data: data, encoding: .utf8) != nil else {
            throw PluginRelayHTTPError.invalidResponse
        }
        var parser = Parser(bytes: Array(data))
        let value = try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw PluginRelayHTTPError.invalidResponse }
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
        mutating func value(depth: Int) throws -> PluginRelayJSON {
            space(); nodes += 1
            guard depth <= 16, nodes <= 4_096, index < bytes.count else { throw PluginRelayHTTPError.invalidResponse }
            switch bytes[index] {
            case 123:
                index += 1; var result: [String: PluginRelayJSON] = [:]
                if consume(125) { return .object(result) }
                repeat {
                    space(); let key = try string()
                    guard result[key] == nil, consume(58) else { throw PluginRelayHTTPError.invalidResponse }
                    result[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(result) }
                    guard consume(44) else { throw PluginRelayHTTPError.invalidResponse }
                } while true
            case 91:
                index += 1; var result: [PluginRelayJSON] = []
                if consume(93) { return .array(result) }
                repeat {
                    result.append(try value(depth: depth + 1))
                    if consume(93) { return .array(result) }
                    guard consume(44) else { throw PluginRelayHTTPError.invalidResponse }
                } while true
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57:
                let start = index
                if bytes[index] == 45 { index += 1 }
                guard index < bytes.count else { throw PluginRelayHTTPError.invalidResponse }
                if bytes[index] == 48 { index += 1 }
                else {
                    guard (49...57).contains(bytes[index]) else { throw PluginRelayHTTPError.invalidResponse }
                    while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                }
                guard let result = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw PluginRelayHTTPError.invalidResponse }
                return .integer(result)
            default: throw PluginRelayHTTPError.invalidResponse
            }
        }
        mutating func literal(_ expected: String) throws {
            let value = Array(expected.utf8)
            guard bytes.count - index >= value.count, Array(bytes[index..<index + value.count]) == value else { throw PluginRelayHTTPError.invalidResponse }
            index += value.count
        }
        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw PluginRelayHTTPError.invalidResponse }
            let start = index; index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    // Decode only the individual string after syntax scanning;
                    // JSONDecoder verifies escape/surrogate correctness here.
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw PluginRelayHTTPError.invalidResponse }
                }
                guard byte >= 32 else { throw PluginRelayHTTPError.invalidResponse }
                if byte == 92 {
                    guard index < bytes.count else { throw PluginRelayHTTPError.invalidResponse }
                    index += 1
                }
            }
            throw PluginRelayHTTPError.invalidResponse
        }
    }
}

extension Dictionary where Key == String, Value == PluginRelayJSON {
    func required(_ key: String) throws -> PluginRelayJSON {
        guard let value = self[key] else { throw PluginRelayHTTPError.invalidResponse }; return value
    }
}
#endif
