import Foundation
import CoreAudio
import Security

/// Bounded, session-owned bridge into the separately installed Peel input driver.
/// Core Audio property RPCs never run on the audio socket queue or a realtime tap.
nonisolated final class PeelRemoteMicrophoneSink: @unchecked Sendable {
    enum SinkError: Error, LocalizedError {
        case driverMissing, authorizationFailed, connectionEnded
        var errorDescription: String? {
            switch self {
            case .driverMissing: return "Peel Remote Microphone is unavailable to Core Audio. Install or enable the driver to use Voice."
            case .authorizationFailed: return "The microphone driver could not authorize the signed Mac app."
            case .connectionEnded: return "The Mac microphone connection ended."
            }
        }
    }
    enum RouteState: Equatable { case waitingForVoiceApp, ready }

    private struct Pending { let bytes: Data; let receivedAt: UInt64 }
    private let queue = DispatchQueue(label: "peel.remoteMicrophone.properties", qos: .userInteractive)
    private let lock = NSLock()
    private var accepting = true
    private var pending: [Pending] = []
    private var drainScheduled = false
    // The remaining state is confined to queue. One sink is used for one session.
    private var plugin: AudioObjectID = kAudioObjectUnknown
    private var token = Data()
    private var lastState: RouteState?
    private var lastStatusAt: UInt64 = 0
    private let onState: (RouteState) -> Void
    private let onFailure: (SinkError) -> Void

    init(onState: @escaping (RouteState) -> Void, onFailure: @escaping (SinkError) -> Void) {
        self.onState = onState
        self.onFailure = onFailure
    }

    func start(completion: @escaping (Result<Void, SinkError>) -> Void) {
        queue.async {
            guard self.isAccepting else { completion(.failure(.connectionEnded)); return }
            guard let plugin = Self.resolvePlugin() else { completion(.failure(.driverMissing)); return }
            var token = Data(count: 16)
            let randomStatus = token.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard randomStatus == errSecSuccess else { completion(.failure(.authorizationFailed)); return }
            self.plugin = plugin
            self.token = token
            guard self.write(selector: 0x70626567, bytes: self.envelope("PPBG")) == noErr else {
                self.plugin = kAudioObjectUnknown
                self.token.removeAll()
                completion(.failure(.authorizationFailed)); return
            }
            guard self.isAccepting else {
                self.endOnQueue()
                completion(.failure(.connectionEnded)); return
            }
            guard self.readStatus() != nil else {
                self.endOnQueue()
                completion(.failure(.authorizationFailed)); return
            }
            completion(.success(()))
        }
    }

    /// Called synchronously by the non-realtime socket receiver. Reject-new on
    /// overflow and age out queued audio; delayed speech must not replay later.
    func offer(_ packet: PeelAudioPacket) -> Bool {
        guard packet.direction == .clientToMac else { return false }
        if packet.kind == .format { return isAccepting }
        guard let bytes = try? packet.encode() else { return false }
        lock.lock()
        guard accepting, pending.count < 3 else { lock.unlock(); return false }
        pending.append(Pending(bytes: bytes, receivedAt: DispatchTime.now().uptimeNanoseconds))
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { queue.async { self.drainOne() } }
        return true
    }

    func stop() {
        lock.lock()
        accepting = false
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        queue.async { self.endOnQueue() }
    }

    private var isAccepting: Bool {
        lock.lock(); defer { lock.unlock() }
        return accepting
    }

    private func drainOne() {
        lock.lock()
        guard accepting, !pending.isEmpty else {
            drainScheduled = false
            lock.unlock(); return
        }
        let next = pending.removeFirst()
        lock.unlock()
        let now = DispatchTime.now().uptimeNanoseconds
        if now - next.receivedAt <= 80_000_000, isAccepting, plugin != kAudioObjectUnknown {
            var body = envelope("PPCM")
            body.append(next.bytes)
            let status = write(selector: 0x7070636D, bytes: body)
            // A full ring drops fresh PCM. Other errors terminate this session;
            // never retry a stale packet or accumulate speech behind an RPC.
            if status != noErr {
                guard let disposition = readStatus(), disposition == 3 else {
                    fail(); return
                }
            } else if now - lastStatusAt >= 1_000_000_000 {
                guard readStatus() != nil else { fail(); return }
            }
        }
        queue.async { self.drainOne() }
    }

    private func fail() {
        stop()
        onFailure(.connectionEnded)
    }

    private func endOnQueue() {
        if plugin != kAudioObjectUnknown, token.count == 16 {
            _ = write(selector: 0x70656E64, bytes: envelope("PPEN"))
        }
        plugin = kAudioObjectUnknown
        token.resetBytes(in: token.startIndex..<token.endIndex)
        token.removeAll()
    }

    private func envelope(_ magic: String) -> Data {
        var bytes = Data(magic.utf8)
        bytes.append(contentsOf: [1, 0, 0, 0])
        bytes.append(token)
        return bytes
    }

    private func write(selector: AudioObjectPropertySelector, bytes: Data) -> OSStatus {
        var address = Self.address(selector)
        var value: CFData = bytes as CFData
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(plugin, &address, 0, nil, UInt32(MemoryLayout<CFData>.size), $0)
        }
    }

    @discardableResult private func readStatus() -> UInt8? {
        var address = Self.address(0x70737473)
        var qualifier: CFData = envelope("PPST") as CFData
        var result: Unmanaged<CFData>?
        var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(plugin, &address, UInt32(MemoryLayout<CFData>.size),
                                       qualifierPointer, &size, &result)
        }
        guard status == noErr, let result else { return nil }
        let bytes = result.takeRetainedValue() as Data
        guard bytes.count == 40, Array(bytes.prefix(5)) == [80, 80, 83, 82, 1],
              bytes[7] == 0, bytes[6] <= 4, bytes[5] == 1 || bytes[5] == 2 else { return nil }
        let state: RouteState = bytes[5] == 1 ? .waitingForVoiceApp : .ready
        lastStatusAt = DispatchTime.now().uptimeNanoseconds
        if lastState != state { lastState = state; onState(state) }
        return bytes[6]
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func resolvePlugin() -> AudioObjectID? {
        var uid: CFString = "com.zephyrstudiosllc.PeelRemoteMicrophone.Device.v1" as CFString
        var device: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var lookup = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &lookup,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        var owner = address(kAudioObjectPropertyOwner)
        var plugin: AudioObjectID = kAudioObjectUnknown
        guard AudioObjectGetPropertyData(device, &owner, 0, nil, &size, &plugin) == noErr,
              plugin != kAudioObjectUnknown else { return nil }
        var begin = address(0x70626567)
        return AudioObjectHasProperty(plugin, &begin) ? plugin : nil
    }
}
