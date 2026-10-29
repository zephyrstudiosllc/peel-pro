import CryptoKit
import Dispatch
import Foundation
import Network
import Security

private enum InteropFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private struct ResolvedService {
    let hostName: String
    let port: UInt16
    let txt: [String: Data]
}

private final class BonjourResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let serviceType: String
    private let serviceName: String
    private let browser = NetServiceBrowser()
    private var retainedServices: [NetService] = []
    private var resolved: ResolvedService?
    private var failure: Error?

    init(serviceType: String, serviceName: String) {
        self.serviceType = serviceType
        self.serviceName = serviceName
        super.init()
    }

    func resolve(timeout: TimeInterval) throws -> ResolvedService {
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
        let deadline = Date().addingTimeInterval(timeout)
        while resolved == nil && failure == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        browser.stop()
        retainedServices.forEach { $0.stop() }

        if let failure {
            throw failure
        }
        guard let resolved else {
            throw InteropFailure.message("Bonjour did not resolve \(serviceName) in time.")
        }
        return resolved
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard service.name == serviceName else {
            return
        }
        retainedServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        failure = InteropFailure.message("Bonjour browsing failed.")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName,
              sender.port > 0,
              sender.port <= Int(UInt16.max),
              let txtData = sender.txtRecordData() else {
            failure = InteropFailure.message("Bonjour resolved an incomplete Peel service.")
            return
        }
        resolved = ResolvedService(
            hostName: hostName,
            port: UInt16(sender.port),
            txt: NetService.dictionary(fromTXTRecord: txtData))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        failure = InteropFailure.message("Bonjour could not resolve \(serviceName).")
    }
}

private final class OneShot<Value> {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw InteropFailure.message("A Network.framework operation timed out.")
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}

private final class PskConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.zephyrstudios.peel.apple-interop")
    private var buffered = Data()

    init(hostName: String, port: UInt16, identity: String, psk: Data) {
        connection = NWConnection(
            host: NWEndpoint.Host(hostName),
            port: NWEndpoint.Port(rawValue: port)!,
            using: PeelTLS.makeClientParameters(pairingID: identity, psk: psk))
    }

    func start(timeout: TimeInterval = 10) throws {
        let ready = OneShot<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.resolve(.success(()))
            case .failed(let error):
                ready.resolve(.failure(error))
            case .waiting(let error):
                ready.resolve(.failure(error))
            case .cancelled:
                ready.resolve(.failure(InteropFailure.message(
                    "The TLS-PSK connection was cancelled before it became ready.")))
            default:
                break
            }
        }
        connection.start(queue: queue)
        try ready.wait(timeout: timeout)
    }

    func send(_ data: Data, timeout: TimeInterval = 10) throws {
        let sent = OneShot<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                sent.resolve(.failure(error))
            } else {
                sent.resolve(.success(()))
            }
        })
        try sent.wait(timeout: timeout)
    }

    func receiveJSON<Value: Decodable>(
        _ type: Value.Type,
        maximumBytes: Int,
        timeout: TimeInterval = 10
    ) throws -> Value {
        while buffered.count <= maximumBytes {
            if let value = try? JSONDecoder().decode(Value.self, from: buffered) {
                buffered.removeAll(keepingCapacity: false)
                return value
            }
            let chunk = try receiveChunk(timeout: timeout)
            buffered.append(chunk.data)
            if chunk.complete && buffered.isEmpty {
                throw InteropFailure.message("The TLS-PSK peer closed without a JSON response.")
            }
        }
        throw InteropFailure.message("The TLS-PSK peer sent an oversized JSON response.")
    }

    func receiveLine(maximumBytes: Int, timeout: TimeInterval = 10) throws -> Data {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                var line = buffered[..<newline]
                buffered.removeSubrange(...newline)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                return Data(line)
            }
            if buffered.count >= maximumBytes {
                throw InteropFailure.message("The Host sent an oversized NDJSON line.")
            }
            let chunk = try receiveChunk(timeout: timeout)
            buffered.append(chunk.data)
            if chunk.complete {
                throw InteropFailure.message("The Host closed before a complete NDJSON line.")
            }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveChunk(timeout: TimeInterval) throws -> (data: Data, complete: Bool) {
        let received = OneShot<(Data, Bool)>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            data,
            _,
            isComplete,
            error in
            if let error {
                received.resolve(.failure(error))
            } else {
                received.resolve(.success((data ?? Data(), isComplete)))
            }
        }
        return try received.wait(timeout: timeout)
    }
}

private enum PeelTLS {
    static let pairingPinIdentity = "peel-pin"
    static let standardPSKOrderTXTValue = "psk-identity"

    static func makeClientParameters(pairingID: String, psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secOptions = tls.securityProtocolOptions
        let identityData = Data(pairingID.utf8)
        let dispatchIdentity = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        let dispatchKey = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        // Security.framework takes the PSK bytes before the public identity bytes.
        sec_protocol_options_add_pre_shared_key(
            secOptions,
            dispatchKey as __DispatchData,
            dispatchIdentity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv12)
        let suite = tls_ciphersuite_t(
            rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(secOptions, suite)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func derivePairingPinPSK(pin: String, salt: Data, hostId: String) -> Data {
        let input = SymmetricKey(data: Data((pin + "|" + hostId).utf8))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: Data("peel-pair-pin-v1".utf8),
            outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func makePairingPinProof(
        pinPSK: Data,
        hostId: String,
        clientDeviceId: String
    ) -> String {
        let message = "peel-pin-proof-v1|\(hostId)|\(clientDeviceId)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: pinPSK))
        return Data(signature).base64EncodedString()
    }
}

private struct PairRequestMessage: Encodable {
    let type = "pairRequest"
    let clientName: String
    let clientDeviceId: String
    let pinProof: String
}

private struct PairResponseMessage: Decodable {
    let type: String
    let hostName: String
    let serviceName: String
    let pairingId: String
    var psk: Data
    let accepted: Bool
    let reason: String?
}

private struct ClientHelloMessage: Encodable {
    let type = "clientHello"
    let pairingID: String
    let deviceName = "Apple Network.framework Interop"
    let deviceModel = "Mac"
    let platform = "macOS"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let appVersion = "interop-smoke"
    let protocolVersion = 2
    let minimumSupportedProtocolVersion = 2
    let capabilities = [
        "binary-video-transport-v2",
        "client-session-load",
        "client-visibility",
        "client-window-activity",
        "client-window-load",
        "clipboard-sync",
        "expanded-keyboard",
        "h264-video",
        "hevc-video",
        "host-commands",
        "host-performance",
        "host-state",
        "input-capabilities",
        "input-focus",
        "keyboard-macros",
        "pairing-revocation",
        "peeled-window-hosting-modes",
        "per-window-video-connections",
        "space-switching",
        "stream-quality-hints",
        "window-geometry",
        "window-priority",
    ]
}

private struct WindowListRequest: Encodable {
    let type = "requestWindowList"
}

private struct MessageEnvelope: Decodable {
    let type: String
}

private struct HostHelloMessage: Decodable {
    let type: String
    let hostName: String
    let platform: String
    let protocolVersion: Int?
    let minimumSupportedProtocolVersion: Int?
}

private struct WindowSummary: Decodable {}

private struct WindowListMessage: Decodable {
    let type: String
    let windows: [WindowSummary]
}

private struct InteropDescriptor: Decodable {
    let controlServiceName: String
    let pairingServiceName: String
    let hostName: String
}

@main
private enum AppleInteropSmoke {
    private static let clientDeviceId = "peel-apple-network-framework-interop"

    static func main() {
        do {
            guard CommandLine.arguments.count == 5 || CommandLine.arguments.count == 7,
                  CommandLine.arguments[1] == "--pin-file",
                  CommandLine.arguments[3] == "--descriptor-file",
                  CommandLine.arguments.count == 5 || CommandLine.arguments[5] == "--connect-host" else {
                throw InteropFailure.message(
                    "Usage: macos-apple-interop-smoke --pin-file <path> " +
                    "--descriptor-file <path> [--connect-host <address>]")
            }
            try run(
                pinPath: CommandLine.arguments[2],
                descriptorPath: CommandLine.arguments[4],
                connectHost: CommandLine.arguments.count == 7
                    ? CommandLine.arguments[6]
                    : nil)
            print(
                "PASS Apple Network.framework interop: Bonjour, PIN TLS-PSK, proof, " +
                "credential reconnect, v2 hello, window list")
        } catch {
            fputs("FAIL Apple Network.framework interop: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(
        pinPath: String,
        descriptorPath: String,
        connectHost: String?
    ) throws {
        let pinData = try Data(contentsOf: URL(fileURLWithPath: pinPath), options: .mappedIfSafe)
        try? FileManager.default.removeItem(atPath: pinPath)
        guard pinData.count <= 32,
              let pin = String(data: pinData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              pin.count == 6,
              pin.allSatisfy({ $0.isNumber }) else {
            throw InteropFailure.message("The short-lived pairing PIN file was invalid.")
        }

        let descriptorData = try Data(
            contentsOf: URL(fileURLWithPath: descriptorPath),
            options: .mappedIfSafe)
        try? FileManager.default.removeItem(atPath: descriptorPath)
        guard descriptorData.count <= 4096 else {
            throw InteropFailure.message("The interoperability descriptor was oversized.")
        }
        let descriptor = try JSONDecoder().decode(InteropDescriptor.self, from: descriptorData)
        guard descriptor.controlServiceName.hasPrefix("Peel on Windows Apple Interop "),
              descriptor.pairingServiceName.hasPrefix("Peel Pair on Windows Apple Interop "),
              descriptor.hostName.hasPrefix("Windows Apple Interop "),
              descriptor.controlServiceName.count <= 300,
              descriptor.pairingServiceName.count <= 300,
              descriptor.hostName.count <= 256 else {
            throw InteropFailure.message("The interoperability descriptor was invalid.")
        }

        let control = try BonjourResolver(
            serviceType: "_peel._tcp.",
            serviceName: descriptor.controlServiceName).resolve(timeout: 10)
        let pairing = try BonjourResolver(
            serviceType: "_peelpair._tcp.",
            serviceName: descriptor.pairingServiceName).resolve(timeout: 10)
        let controlTxt = try validateTxt(control.txt)
        let pairingTxt = try validateTxt(pairing.txt)
        guard controlTxt.hostId == pairingTxt.hostId,
              controlTxt.salt == pairingTxt.salt,
              controlTxt.pairingPort == pairing.port,
              pairingTxt.pairingPort == pairing.port else {
            throw InteropFailure.message("The control and pairing advertisements disagree.")
        }

        var pinPSK = PeelTLS.derivePairingPinPSK(
            pin: pin,
            salt: controlTxt.salt,
            hostId: controlTxt.hostId)
        defer { pinPSK.resetBytes(in: 0..<pinPSK.count) }
        let proof = PeelTLS.makePairingPinProof(
            pinPSK: pinPSK,
            hostId: controlTxt.hostId,
            clientDeviceId: clientDeviceId)
        let pairRequest = PairRequestMessage(
            clientName: "Apple Network.framework Interop",
            clientDeviceId: clientDeviceId,
            pinProof: proof)

        let pairingConnectHost = connectHost ?? pairing.hostName
        let pairConnection = PskConnection(
            hostName: pairingConnectHost,
            port: pairing.port,
            identity: PeelTLS.pairingPinIdentity,
            psk: pinPSK)
        defer { pairConnection.cancel() }
        do {
            try pairConnection.start()
        } catch {
            throw InteropFailure.message(
                "Pairing TLS-PSK failed at \(pairingConnectHost):\(pairing.port): \(error)")
        }
        do {
            try pairConnection.send(JSONEncoder().encode(pairRequest))
        } catch {
            throw InteropFailure.message("The pairing request send failed: \(error)")
        }
        var response: PairResponseMessage
        do {
            response = try pairConnection.receiveJSON(
                PairResponseMessage.self,
                maximumBytes: 64 * 1024)
        } catch {
            throw InteropFailure.message("The pairing response failed: \(error)")
        }
        guard response.type == "pairResponse",
              response.accepted,
              response.reason == nil,
              !response.hostName.isEmpty,
              !response.serviceName.isEmpty,
              !response.pairingId.isEmpty,
              response.pairingId.utf8.count <= 1024,
              response.psk.count == 32 else {
            throw InteropFailure.message("The Host returned invalid pairing material.")
        }

        pairConnection.cancel()
        let controlConnectHost = connectHost ?? control.hostName
        let controlConnection = PskConnection(
            hostName: controlConnectHost,
            port: control.port,
            identity: response.pairingId,
            psk: response.psk)
        defer {
            controlConnection.cancel()
            response.psk.resetBytes(in: 0..<response.psk.count)
        }
        do {
            try controlConnection.start()
        } catch {
            throw InteropFailure.message(
                "Authenticated control TLS-PSK failed at " +
                "\(controlConnectHost):\(control.port): \(error)")
        }
        let encoder = JSONEncoder()
        var request = try encoder.encode(ClientHelloMessage(pairingID: response.pairingId))
        request.append(0x0A)
        request.append(try encoder.encode(WindowListRequest()))
        request.append(0x0A)
        do {
            try controlConnection.send(request)
        } catch {
            throw InteropFailure.message("The v2 control request send failed: \(error)")
        }

        var hello: HostHelloMessage?
        var windowCount: Int?
        for _ in 0..<8 where hello == nil || windowCount == nil {
            let line = try controlConnection.receiveLine(maximumBytes: 1024 * 1024)
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: line)
            switch envelope.type {
            case "hostHello":
                hello = try JSONDecoder().decode(HostHelloMessage.self, from: line)
            case "windowList":
                windowCount = try JSONDecoder().decode(WindowListMessage.self, from: line)
                    .windows.count
            default:
                break
            }
        }

        guard let hello,
              hello.type == "hostHello",
              hello.hostName == descriptor.hostName,
              hello.platform == "Windows",
              hello.protocolVersion == 2,
              hello.minimumSupportedProtocolVersion == 2,
              let windowCount,
              windowCount > 0 else {
            throw InteropFailure.message("The authenticated Host v2 handshake was incomplete.")
        }
    }

    private static func validateTxt(
        _ txt: [String: Data]
    ) throws -> (hostId: String, salt: Data, pairingPort: UInt16) {
        guard txt.count == 6,
              let hostId = txt["hostId"].flatMap({ String(data: $0, encoding: .utf8) }),
              !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hostId.utf8.count <= 1024,
              txt["pairMode"].flatMap({ String(data: $0, encoding: .utf8) }) == "pin",
              txt["tlsPSKOrder"].flatMap({ String(data: $0, encoding: .utf8) }) ==
                PeelTLS.standardPSKOrderTXTValue,
              let saltText = txt["pinSalt"].flatMap({ String(data: $0, encoding: .utf8) }),
              let salt = Data(base64Encoded: saltText),
              salt.count == 16,
              let expiryText = txt["pinExp"].flatMap({ String(data: $0, encoding: .utf8) }),
              let expiry = TimeInterval(expiryText),
              expiry > Date().timeIntervalSince1970,
              expiry <= Date().timeIntervalSince1970 + 3600,
              let portText = txt["pairPort"].flatMap({ String(data: $0, encoding: .utf8) }),
              let pairingPort = UInt16(portText),
              pairingPort > 0 else {
            throw InteropFailure.message("The Peel Bonjour TXT contract was invalid.")
        }
        return (hostId.trimmingCharacters(in: .whitespacesAndNewlines), salt, pairingPort)
    }
}
