#if os(iOS) || os(visionOS)

import AVFoundation
import Foundation
import Network

typealias PeelVoiceAudioUplinkSink = @Sendable (PeelAudioPacket) -> Bool
typealias PeelVoiceAudioFailureSink = @Sendable (PeelVoiceAudioFailure) -> Void

/// Synchronously offers bounded voice packets to one bidirectional audio
/// socket. The realtime tap never reaches this type: the capture worker calls
/// `offer(_:)` after draining the fixed-capacity input ring.
nonisolated final class PeelAudioUplinkWriter: @unchecked Sendable {
    static let maxPendingPackets = 4

    private let lock = NSLock()
    private var connection: NWConnection?
    private var generation: UUID?
    private var pendingPacketCount = 0
    private var didReportFailure = false
    private var isBound = false
    private var onFailure: (@Sendable () -> Void)?

    func bind(
        connection: NWConnection,
        generation: UUID,
        onFailure: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        self.connection = connection
        self.generation = generation
        pendingPacketCount = 0
        didReportFailure = false
        isBound = true
        self.onFailure = onFailure
        lock.unlock()
    }

    /// Invalidates this socket generation and drops all pending accounting.
    /// A completion from the old socket cannot decrement a replacement
    /// generation or call its failure sink.
    func invalidate() {
        lock.lock()
        connection = nil
        generation = nil
        pendingPacketCount = 0
        didReportFailure = false
        isBound = false
        onFailure = nil
        lock.unlock()
    }

    /// Offers one already validated client-to-Mac packet. Queue overflow is a
    /// normal bounded drop and returns immediately before packet encoding.
    @discardableResult
    func offer(_ packet: PeelAudioPacket) -> Bool {
        guard packet.direction == .clientToMac,
              packet.format == .v1(for: .clientToMac) else {
            return false
        }

        let socket: NWConnection
        let token: UUID
        lock.lock()
        guard isBound,
              pendingPacketCount < Self.maxPendingPackets,
              let boundSocket = connection,
              let boundGeneration = generation else {
            lock.unlock()
            return false
        }
        pendingPacketCount += 1
        socket = boundSocket
        token = boundGeneration
        lock.unlock()

        guard let data = try? packet.encode() else {
            complete(token: token, error: nil)
            return false
        }

        // Invalidation can race with encoding. Recheck before handing bytes to
        // the socket; a send that races after this check is still confined to
        // the canceled old NWConnection and its callback is generation-gated.
        lock.lock()
        guard isBound, generation == token, connection === socket else {
            if pendingPacketCount > 0 { pendingPacketCount -= 1 }
            lock.unlock()
            return false
        }
        lock.unlock()

        socket.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.complete(token: token, error: error)
        })
        return true
    }

    private func complete(token: UUID, error: NWError?) {
        var failure: (@Sendable () -> Void)?
        lock.lock()
        guard isBound, generation == token else {
            lock.unlock()
            return
        }
        if pendingPacketCount > 0 {
            pendingPacketCount -= 1
        }
        if error != nil, !didReportFailure {
            didReportFailure = true
            failure = onFailure
        }
        lock.unlock()
        failure?()
    }
}

nonisolated final class PeelVoiceAudioGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UUID?

    func activate(_ generation: UUID) {
        lock.lock()
        activeGeneration = generation
        lock.unlock()
    }

    func invalidate(_ generation: UUID) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
    }

    func isCurrent(_ generation: UUID) -> Bool {
        lock.lock()
        let result = activeGeneration == generation
        lock.unlock()
        return result
    }
}

nonisolated final class PeelVoiceAudioObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    func append(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll(keepingCapacity: false)
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

/// Fixed-capacity handoff from the realtime input tap to one serial worker.
nonisolated final class PeelVoiceAudioInputRing: @unchecked Sendable {
    static let tapBufferFrames = 480
    static let ringCapacity = 4
    static let maxInputFrames = 4_096
    static let maxInputChannels = 8

    private struct Slot {
        var samples: [Float] = Array(repeating: 0,
                                      count: PeelVoiceAudioInputRing.maxInputFrames)
        var frameCount = 0
    }

    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    // Each slot owns its storage before the tap can run. This avoids a first
    // write triggering copy-on-write allocation in the realtime callback.
    private var slots = (0..<PeelVoiceAudioInputRing.ringCapacity).map { _ in Slot() }
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var stopped = false
    private var didDropInput = false

    func push(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let stride = Int(buffer.stride)
        guard frameCount > 0,
              frameCount <= Self.maxInputFrames,
              channelCount > 0,
              channelCount <= Self.maxInputChannels,
              stride > 0,
              stride <= Self.maxInputChannels,
              buffer.floatChannelData != nil || buffer.int16ChannelData != nil
        else {
            markDropWithoutWaiting()
            return
        }

        guard lock.try() else {
            markDropWithoutWaiting()
            return
        }
        guard !stopped else {
            lock.unlock()
            return
        }
        guard count < slots.count else {
            let shouldWake = !didDropInput
            didDropInput = true
            lock.unlock()
            if shouldWake {
                wake.signal()
            }
            return
        }

        if let source = buffer.floatChannelData {
            slots[writeIndex].samples.withUnsafeMutableBufferPointer { destination in
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += source[channel][frame * stride]
                    }
                    destination[frame] = sum / Float(channelCount)
                }
            }
        } else if let source = buffer.int16ChannelData {
            slots[writeIndex].samples.withUnsafeMutableBufferPointer { destination in
                for frame in 0..<frameCount {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        sum += Float(source[channel][frame * stride]) / 32_768.0
                    }
                    destination[frame] = sum / Float(channelCount)
                }
            }
        }

        slots[writeIndex].frameCount = frameCount
        writeIndex = (writeIndex + 1) % slots.count
        count += 1
        lock.unlock()
        wake.signal()
    }

    func pop(into destination: inout [Float]) -> Int? {
        lock.lock()
        guard count > 0 else {
            lock.unlock()
            return nil
        }

        let frameCount = slots[readIndex].frameCount
        guard frameCount > 0, frameCount <= destination.count else {
            slots[readIndex].frameCount = 0
            readIndex = (readIndex + 1) % slots.count
            count -= 1
            lock.unlock()
            return nil
        }

        slots[readIndex].samples.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { target in
                guard let sourceBaseAddress = source.baseAddress,
                      let targetBaseAddress = target.baseAddress
                else {
                    return
                }
                targetBaseAddress.update(from: sourceBaseAddress, count: frameCount)
            }
        }
        slots[readIndex].frameCount = 0
        readIndex = (readIndex + 1) % slots.count
        count -= 1
        lock.unlock()
        return frameCount
    }

    func waitForSignal() -> Bool {
        wake.wait()
        lock.lock()
        let shouldContinue = !stopped
        lock.unlock()
        return shouldContinue
    }

    func takeDropFlag() -> Bool {
        lock.lock()
        let result = didDropInput
        didDropInput = false
        lock.unlock()
        return result
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        count = 0
        didDropInput = false
        for index in slots.indices {
            slots[index].frameCount = 0
        }
        lock.unlock()
        wake.signal()
    }

    private func markDropWithoutWaiting() {
        // The tap never waits behind the worker. One drop-state transition
        // wakes the worker so an isolated invalid or overflowing buffer is
        // observable without creating one semaphore signal per dropped buffer.
        var shouldWake = false
        if lock.try() {
            shouldWake = !didDropInput
            didDropInput = true
            lock.unlock()
        }
        if shouldWake {
            wake.signal()
        }
    }
}

/// Drains the input ring on one bounded serial queue and emits the required
/// format packet followed by mono 48 kHz 960-frame uplink packets.
nonisolated final class PeelVoiceAudioCaptureDrainWorker: @unchecked Sendable {
    private let ring: PeelVoiceAudioInputRing
    private let sourceSampleRate: Double
    private let generation: UUID
    private let gate: PeelVoiceAudioGenerationGate
    private let onUplink: PeelVoiceAudioUplinkSink
    private let onFailure: PeelVoiceAudioFailureSink?
    private let queue = DispatchQueue(label: "com.zephyr.peel.ipad-voice-capture",
                                       qos: .userInitiated)

    init(
        ring: PeelVoiceAudioInputRing,
        sourceSampleRate: Double,
        generation: UUID,
        gate: PeelVoiceAudioGenerationGate,
        onUplink: @escaping PeelVoiceAudioUplinkSink,
        onFailure: PeelVoiceAudioFailureSink?
    ) {
        self.ring = ring
        self.sourceSampleRate = sourceSampleRate
        self.generation = generation
        self.gate = gate
        self.onUplink = onUplink
        self.onFailure = onFailure
    }

    func start() {
        queue.async { [self] in
            run()
        }
    }

    func stop() {
        ring.stop()
    }

    private func run() {
        guard gate.isCurrent(generation) else { return }

        let formatAccepted = onUplink(PeelAudioPacket(formatFor: .clientToMac))
        if !formatAccepted {
            onFailure?(.packetSinkRejected)
        }

        var converter = PeelAudioMicrophoneCaptureConverter()
        var scratch = [Float](repeating: 0, count: PeelVoiceAudioInputRing.maxInputFrames)
        var didReportSinkRejection = !formatAccepted

        while ring.waitForSignal() {
            if ring.takeDropFlag() {
                onFailure?(.inputOverrun)
                // An input overrun is a terminal capture error. The caller's
                // failure sink tears down the owner; stopping here also keeps
                // a standalone owner from silently continuing after loss.
                ring.stop()
                return
            }

            while let frameCount = ring.pop(into: &scratch) {
                guard gate.isCurrent(generation) else { return }

                let packets: [PeelAudioPacket]
                do {
                    packets = try scratch.withUnsafeBufferPointer { input in
                        guard let baseAddress = input.baseAddress else {
                            throw PeelAudioMicrophoneCaptureConversionError.inputTooLarge
                        }
                        let boundedInput = UnsafeBufferPointer(start: baseAddress,
                                                               count: frameCount)
                        return try converter.append(boundedInput,
                                                    sourceSampleRate: sourceSampleRate)
                    }
                } catch {
                    onFailure?(.conversionFailed)
                    ring.stop()
                    return
                }

                for packet in packets {
                    guard gate.isCurrent(generation) else { return }
                    if !onUplink(packet), !didReportSinkRejection {
                        onFailure?(.packetSinkRejected)
                        didReportSinkRejection = true
                    }
                }
            }
        }
    }
}

#endif
