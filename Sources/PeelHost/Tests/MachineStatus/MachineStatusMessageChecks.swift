import Foundation

@main
struct PeelMachineStatusMessageChecks {
    static func main() throws {
        let requestID = UUID(uuidString: "A7D3F8B4-17C7-4A01-A07E-3A6F773E33A2")!
        let request = PeelMachineStatusRequest(requestID: requestID)
        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(
            PeelMachineStatusRequest.self,
            from: requestData)
        precondition(decodedRequest == request)
        precondition(decodedRequest.type == "machineStatusRequest")
        precondition(decodedRequest.requestId == requestID.uuidString)

        let app = try PeelMachineStatusApp(
            displayName: "Example",
            pid: 42,
            cpuPercent: 12.5,
            memoryBytes: 64 * 1024 * 1024)
        let multicoreApp = try PeelMachineStatusApp(
            displayName: "Multicore Example",
            pid: 43,
            cpuPercent: 250,
            memoryBytes: 1)
        precondition(multicoreApp.cpuPercent == 250)
        let usage = try PeelMachineStatusUsage(
            providerName: "Example Provider",
            usedPercent: 37.5,
            resetAt: 1_800_000_000)
        let message = try PeelMachineStatusMessage(
            requestId: request.requestId,
            sampledAt: 1_700_000_000,
            hostName: "Example Mac",
            cpuFraction: 0.25,
            memoryUsedBytes: 4 * 1024 * 1024 * 1024,
            memoryTotalBytes: 16 * 1024 * 1024 * 1024,
            storageFreeBytes: 200 * 1024 * 1024 * 1024,
            storageTotalBytes: 1_000 * 1024 * 1024 * 1024,
            batteryFraction: 0.9,
            networkReceiveBytesPerSecond: 12_345.5,
            networkSendBytesPerSecond: 678.25,
            gpuFraction: 0.5,
            topApps: [app],
            usage: [usage],
            localStatus: "Available")

        let messageData = try JSONEncoder().encode(message)
        let decodedMessage = try JSONDecoder().decode(
            PeelMachineStatusMessage.self,
            from: messageData)
        precondition(decodedMessage == message)
        precondition(decodedMessage.type == "machineStatus")
        precondition(decodedMessage.topApps.count == 1)
        precondition(decodedMessage.usage.count == 1)

        let sparseMessage = try PeelMachineStatusMessage(
            requestId: request.requestId,
            sampledAt: 1,
            hostName: "Mac")
        precondition(sparseMessage.cpuFraction == nil)
        precondition(sparseMessage.memoryUsedBytes == nil)
        precondition(sparseMessage.storageFreeBytes == nil)
        precondition(sparseMessage.networkReceiveBytesPerSecond == nil)
        precondition(sparseMessage.localStatus == nil)

        expectThrow {
            _ = try PeelMachineStatusRequest(requestId: "not-a-uuid")
        }
        expectThrow {
            _ = try PeelMachineStatusMessage(
                requestId: request.requestId,
                sampledAt: 1,
                hostName: "Mac",
                cpuFraction: .nan)
        }
        expectThrow {
            _ = try PeelMachineStatusMessage(
                requestId: request.requestId,
                sampledAt: 1,
                hostName: "Mac",
                topApps: Array(repeating: app, count: 6))
        }
        expectThrow {
            _ = try PeelMachineStatusMessage(
                requestId: request.requestId,
                sampledAt: 1,
                hostName: "Mac",
                usage: Array(repeating: usage, count: 9))
        }
        let appJSON = #"{"displayName":"Example","pid":42,"cpuPercent":1,"memoryBytes":1}"#
        let oversizedTopApps = Data((#"{"type":"machineStatus","requestId":""#
            + request.requestId
            + #"","sampledAt":1,"hostName":"Mac","topApps":["#
            + Array(repeating: appJSON, count: 6).joined(separator: ",")
            + #"]}"#).utf8)
        expectThrow {
            _ = try JSONDecoder().decode(
                PeelMachineStatusMessage.self,
                from: oversizedTopApps)
        }
        expectThrow {
            _ = try JSONDecoder().decode(
                PeelMachineStatusRequest.self,
                from: Data(#"{"type":"other","requestId":"A7D3F8B4-17C7-4A01-A07E-3A6F773E33A2"}"#.utf8))
        }

        let ram = try PeelMachineStatusMessage(requestId: request.requestId,
            sampledAt: 1, hostName: "Mac", memoryFraction: 0.75)
        let ramRoundTrip = try JSONDecoder().decode(PeelMachineStatusMessage.self,
            from: JSONEncoder().encode(ram))
        precondition(ramRoundTrip.memoryFraction == 0.75)
        expectThrow {
            _ = try PeelMachineStatusMessage(requestId: request.requestId,
                sampledAt: 1, hostName: "Mac", memoryFraction: 1.01)
        }
        let error = try PeelMachineStatusErrorMessage(requestId: request.requestId, reason: "Unavailable")
        let errorRoundTrip = try JSONDecoder().decode(PeelMachineStatusErrorMessage.self,
            from: JSONEncoder().encode(error))
        precondition(errorRoundTrip == error)
        expectThrow { _ = try PeelMachineStatusErrorMessage(requestId: "wrong", reason: "Unavailable") }
        expectThrow { _ = try PeelMachineStatusErrorMessage(requestId: request.requestId, reason: String(repeating: "x", count: 257)) }

        print("PeelMachineStatusMessageChecks passed")
    }

    private static func expectThrow(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected validation failure")
        } catch {
            // Expected.
        }
    }
}
