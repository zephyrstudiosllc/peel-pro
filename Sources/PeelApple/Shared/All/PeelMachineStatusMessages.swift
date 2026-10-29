//
//  PeelMachineStatusMessages.swift
//  Shared Mac status request/reply contract.
//
//  Foundation only. The host owns sampling and authenticated transport; this
//  file only validates and encodes the bounded value snapshot.
//

import Foundation

nonisolated public enum PeelMachineStatusValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidType(expected: String, actual: String)
    case invalidRequestID
    case invalidSampledAt
    case invalidHostName
    case invalidText(field: String)
    case invalidFraction(field: String)
    case invalidPercent(field: String)
    case invalidProcessCPUPercent
    case invalidRate(field: String)
    case invalidResetAt
    case invalidProcessID
    case tooManyTopApps(Int)
    case tooManyUsageEntries(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidType(expected, actual):
            return "Expected message type \(expected), received \(actual)."
        case .invalidRequestID:
            return "The request id must be a UUID string."
        case .invalidSampledAt:
            return "sampledAt must be a finite, non-negative epoch timestamp."
        case .invalidHostName:
            return "hostName must be a non-empty, bounded display name."
        case let .invalidText(field):
            return "\(field) must be a non-empty, bounded display string."
        case let .invalidFraction(field):
            return "\(field) must be finite and in the 0...1 range."
        case let .invalidPercent(field):
            return "\(field) must be finite and in the 0...100 range."
        case .invalidProcessCPUPercent:
            return "cpuPercent must be finite and in the 0...100000 range."
        case let .invalidRate(field):
            return "\(field) must be finite and non-negative."
        case .invalidResetAt:
            return "resetAt must be a finite, non-negative epoch timestamp."
        case .invalidProcessID:
            return "pid must be a non-negative process id."
        case let .tooManyTopApps(count):
            return "topApps contains \(count) entries; at most \(PeelMachineStatusValidation.maxTopApps) are allowed."
        case let .tooManyUsageEntries(count):
            return "usage contains \(count) entries; at most \(PeelMachineStatusValidation.maxUsageEntries) are allowed."
        }
    }
}

/// Shared bounds for the status wire model and its UI. A malformed peer is
/// rejected before the client renders or retains an oversized snapshot.
nonisolated public enum PeelMachineStatusValidation {
    public static let maxTopApps = 5
    public static let maxUsageEntries = 8

    public static func requestID(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else {
            throw PeelMachineStatusValidationError.invalidRequestID
        }
        return value
    }

    public static func text(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int = 256
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumUTF8Bytes,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw PeelMachineStatusValidationError.invalidText(field: field)
        }
        return value
    }

    public static func hostName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw PeelMachineStatusValidationError.invalidHostName
        }
        return value
    }

    public static func epochSeconds(_ value: Double, field: String) throws -> Double {
        guard value.isFinite, value >= 0 else {
            if field == "sampledAt" {
                throw PeelMachineStatusValidationError.invalidSampledAt
            }
            throw PeelMachineStatusValidationError.invalidResetAt
        }
        return value
    }

    public static func fraction(_ value: Double?, field: String) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, (0...1).contains(value) else {
            throw PeelMachineStatusValidationError.invalidFraction(field: field)
        }
        return value
    }

    public static func percent(_ value: Double?, field: String) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, (0...100).contains(value) else {
            throw PeelMachineStatusValidationError.invalidPercent(field: field)
        }
        return value
    }

    /// `ps %cpu` may exceed 100 on a multicore Mac. Keep that measured value,
    /// while applying a generous finite wire bound against corrupt payloads.
    public static func processCPUPercent(_ value: Double) throws -> Double {
        guard value.isFinite, (0...100_000).contains(value) else {
            throw PeelMachineStatusValidationError.invalidProcessCPUPercent
        }
        return value
    }

    public static func rate(_ value: Double?, field: String) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value >= 0 else {
            throw PeelMachineStatusValidationError.invalidRate(field: field)
        }
        return value
    }

    public static func processID(_ value: Int32) throws -> Int32 {
        guard value >= 0 else {
            throw PeelMachineStatusValidationError.invalidProcessID
        }
        return value
    }

    public static func topApps(_ value: [PeelMachineStatusApp]) throws -> [PeelMachineStatusApp] {
        guard value.count <= maxTopApps else {
            throw PeelMachineStatusValidationError.tooManyTopApps(value.count)
        }
        return value
    }

    public static func usage(_ value: [PeelMachineStatusUsage]) throws -> [PeelMachineStatusUsage] {
        guard value.count <= maxUsageEntries else {
            throw PeelMachineStatusValidationError.tooManyUsageEntries(value.count)
        }
        return value
    }
}

/// Client -> host. `requestId` is kept as a string on the wire for consistency
/// with the existing Peel message envelope, while the UUID initializer prevents
/// locally-created requests from using an arbitrary identifier.
nonisolated public struct PeelMachineStatusRequest: Codable, Equatable, Sendable {
    public static let messageType = "machineStatusRequest"

    public let type: String
    public let requestId: String

    public init(requestID: UUID) {
        type = Self.messageType
        requestId = requestID.uuidString
    }

    public init(requestId: String) throws {
        type = Self.messageType
        self.requestId = try PeelMachineStatusValidation.requestID(requestId)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case requestId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == Self.messageType else {
            throw PeelMachineStatusValidationError.invalidType(expected: Self.messageType, actual: type)
        }
        try self.init(requestId: container.decode(String.self, forKey: .requestId))
    }
}

nonisolated public struct PeelMachineStatusApp: Codable, Equatable, Sendable, Identifiable {
    public let displayName: String
    public let pid: Int32
    /// App CPU load in existing App Mechanic `ps %cpu` units. Multicore values
    /// can exceed 100, so this is bounded at 100000 only for wire validation.
    public let cpuPercent: Double
    /// Resident memory converted by the host from App Mechanic's MB sample.
    public let memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(
        displayName: String,
        pid: Int32,
        cpuPercent: Double,
        memoryBytes: UInt64
    ) throws {
        self.displayName = try PeelMachineStatusValidation.text(displayName, field: "displayName")
        self.pid = try PeelMachineStatusValidation.processID(pid)
        self.cpuPercent = try PeelMachineStatusValidation.processCPUPercent(cpuPercent)
        self.memoryBytes = memoryBytes
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case pid
        case cpuPercent
        case memoryBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            displayName: container.decode(String.self, forKey: .displayName),
            pid: container.decode(Int32.self, forKey: .pid),
            cpuPercent: container.decode(Double.self, forKey: .cpuPercent),
            memoryBytes: container.decode(UInt64.self, forKey: .memoryBytes))
    }
}

nonisolated public struct PeelMachineStatusUsage: Codable, Equatable, Sendable, Identifiable {
    public let providerName: String
    /// Provider usage in the existing Peel usage adapter's 0...100 percent units.
    public let usedPercent: Double?
    /// Optional reset instant as finite, non-negative epoch seconds.
    public let resetAt: Double?

    public var id: String { providerName }

    public init(
        providerName: String,
        usedPercent: Double? = nil,
        resetAt: Double? = nil
    ) throws {
        self.providerName = try PeelMachineStatusValidation.text(providerName, field: "providerName")
        self.usedPercent = try PeelMachineStatusValidation.percent(usedPercent, field: "usedPercent")
        if let resetAt {
            self.resetAt = try PeelMachineStatusValidation.epochSeconds(resetAt, field: "resetAt")
        } else {
            self.resetAt = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerName
        case usedPercent
        case resetAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            providerName: container.decode(String.self, forKey: .providerName),
            usedPercent: container.decodeIfPresent(Double.self, forKey: .usedPercent),
            resetAt: container.decodeIfPresent(Double.self, forKey: .resetAt))
    }
}

/// Host -> client. Optional measurements stay nil when the host cannot expose
/// them; nil is never overloaded to mean zero.
nonisolated public struct PeelMachineStatusMessage: Codable, Equatable, Sendable {
    public static let messageType = "machineStatus"

    public let type: String
    public let requestId: String
    /// Seconds since 1970, rather than an ISO-8601 string, for compact replies.
    public let sampledAt: Double
    public let hostName: String

    public let cpuFraction: Double?
    public let memoryFraction: Double?
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    public let storageFreeBytes: UInt64?
    public let storageTotalBytes: UInt64?
    public let batteryFraction: Double?
    public let networkReceiveBytesPerSecond: Double?
    public let networkSendBytesPerSecond: Double?
    public let gpuFraction: Double?
    public let topApps: [PeelMachineStatusApp]
    public let usage: [PeelMachineStatusUsage]
    /// Host-owned local status/availability text, such as "Available" or a
    /// bounded explanation for an unavailable source.
    public let localStatus: String?

    public init(
        requestId: String,
        sampledAt: Double,
        hostName: String,
        cpuFraction: Double? = nil,
        memoryFraction: Double? = nil,
        memoryUsedBytes: UInt64? = nil,
        memoryTotalBytes: UInt64? = nil,
        storageFreeBytes: UInt64? = nil,
        storageTotalBytes: UInt64? = nil,
        batteryFraction: Double? = nil,
        networkReceiveBytesPerSecond: Double? = nil,
        networkSendBytesPerSecond: Double? = nil,
        gpuFraction: Double? = nil,
        topApps: [PeelMachineStatusApp] = [],
        usage: [PeelMachineStatusUsage] = [],
        localStatus: String? = nil
    ) throws {
        type = Self.messageType
        self.requestId = try PeelMachineStatusValidation.requestID(requestId)
        self.sampledAt = try PeelMachineStatusValidation.epochSeconds(sampledAt, field: "sampledAt")
        self.hostName = try PeelMachineStatusValidation.hostName(hostName)
        self.cpuFraction = try PeelMachineStatusValidation.fraction(cpuFraction, field: "cpuFraction")
        self.memoryFraction = try PeelMachineStatusValidation.fraction(memoryFraction, field: "memoryFraction")
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.storageFreeBytes = storageFreeBytes
        self.storageTotalBytes = storageTotalBytes
        self.batteryFraction = try PeelMachineStatusValidation.fraction(batteryFraction, field: "batteryFraction")
        self.networkReceiveBytesPerSecond = try PeelMachineStatusValidation.rate(
            networkReceiveBytesPerSecond,
            field: "networkReceiveBytesPerSecond")
        self.networkSendBytesPerSecond = try PeelMachineStatusValidation.rate(
            networkSendBytesPerSecond,
            field: "networkSendBytesPerSecond")
        self.gpuFraction = try PeelMachineStatusValidation.fraction(gpuFraction, field: "gpuFraction")
        self.topApps = try PeelMachineStatusValidation.topApps(topApps)
        self.usage = try PeelMachineStatusValidation.usage(usage)
        if let localStatus {
            self.localStatus = try PeelMachineStatusValidation.text(
                localStatus,
                field: "localStatus",
                maximumUTF8Bytes: 512)
        } else {
            self.localStatus = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case requestId
        case sampledAt
        case hostName
        case cpuFraction
        case memoryFraction
        case memoryUsedBytes
        case memoryTotalBytes
        case storageFreeBytes
        case storageTotalBytes
        case batteryFraction
        case networkReceiveBytesPerSecond
        case networkSendBytesPerSecond
        case gpuFraction
        case topApps
        case usage
        case localStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == Self.messageType else {
            throw PeelMachineStatusValidationError.invalidType(expected: Self.messageType, actual: type)
        }
        self = try Self(
            requestId: container.decode(String.self, forKey: .requestId),
            sampledAt: container.decode(Double.self, forKey: .sampledAt),
            hostName: container.decode(String.self, forKey: .hostName),
            cpuFraction: container.decodeIfPresent(Double.self, forKey: .cpuFraction),
            memoryFraction: container.decodeIfPresent(Double.self, forKey: .memoryFraction),
            memoryUsedBytes: container.decodeIfPresent(UInt64.self, forKey: .memoryUsedBytes),
            memoryTotalBytes: container.decodeIfPresent(UInt64.self, forKey: .memoryTotalBytes),
            storageFreeBytes: container.decodeIfPresent(UInt64.self, forKey: .storageFreeBytes),
            storageTotalBytes: container.decodeIfPresent(UInt64.self, forKey: .storageTotalBytes),
            batteryFraction: container.decodeIfPresent(Double.self, forKey: .batteryFraction),
            networkReceiveBytesPerSecond: container.decodeIfPresent(Double.self, forKey: .networkReceiveBytesPerSecond),
            networkSendBytesPerSecond: container.decodeIfPresent(Double.self, forKey: .networkSendBytesPerSecond),
            gpuFraction: container.decodeIfPresent(Double.self, forKey: .gpuFraction),
            topApps: try Self.decodeTopApps(from: container),
            usage: try Self.decodeUsage(from: container),
            localStatus: container.decodeIfPresent(String.self, forKey: .localStatus))
    }

    private static func decodeTopApps(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [PeelMachineStatusApp] {
        guard container.contains(.topApps) else { return [] }
        var values = try container.nestedUnkeyedContainer(forKey: .topApps)
        if let count = values.count, count > PeelMachineStatusValidation.maxTopApps {
            throw PeelMachineStatusValidationError.tooManyTopApps(count)
        }

        var apps: [PeelMachineStatusApp] = []
        apps.reserveCapacity(min(values.count ?? 0, PeelMachineStatusValidation.maxTopApps))
        while !values.isAtEnd {
            guard apps.count < PeelMachineStatusValidation.maxTopApps else {
                throw PeelMachineStatusValidationError.tooManyTopApps(apps.count + 1)
            }
            apps.append(try values.decode(PeelMachineStatusApp.self))
        }
        return apps
    }

    private static func decodeUsage(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [PeelMachineStatusUsage] {
        guard container.contains(.usage) else { return [] }
        var values = try container.nestedUnkeyedContainer(forKey: .usage)
        if let count = values.count, count > PeelMachineStatusValidation.maxUsageEntries {
            throw PeelMachineStatusValidationError.tooManyUsageEntries(count)
        }

        var entries: [PeelMachineStatusUsage] = []
        entries.reserveCapacity(min(values.count ?? 0, PeelMachineStatusValidation.maxUsageEntries))
        while !values.isAtEnd {
            guard entries.count < PeelMachineStatusValidation.maxUsageEntries else {
                throw PeelMachineStatusValidationError.tooManyUsageEntries(entries.count + 1)
            }
            entries.append(try values.decode(PeelMachineStatusUsage.self))
        }
        return entries
    }
}

/// Name used by callers that prefer the request/reply terminology.
public typealias PeelMachineStatusResponse = PeelMachineStatusMessage

/// Host -> client failure scoped to one explicitly requested status snapshot.
nonisolated public struct PeelMachineStatusErrorMessage: Codable, Equatable, Sendable {
    public let type: String
    public let requestId: String
    public let reason: String

    public init(requestId: String, reason: String) throws {
        self.type = "machineStatusError"
        self.requestId = try PeelMachineStatusValidation.requestID(requestId)
        self.reason = try PeelMachineStatusValidation.text(reason, field: "reason")
    }

    private enum CodingKeys: String, CodingKey { case type, requestId, reason }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        guard type == "machineStatusError" else {
            throw PeelMachineStatusValidationError.invalidType(expected: "machineStatusError", actual: type)
        }
        try self.init(requestId: values.decode(String.self, forKey: .requestId),
                      reason: values.decode(String.self, forKey: .reason))
    }
}

/// Client consent is independent of agent presentation, notifications and audio.
nonisolated enum PeelMachineStatusAccess {
    static let optInDefaultsKey = "peel.ai.allowMachineStatus"
    static var isOptedIn: Bool {
#if os(iOS) || os(visionOS)
        UserDefaults.standard.bool(forKey: optInDefaultsKey)
#else
        false
#endif
    }
}
