import Foundation
import Network

/// All socket state and sends run on HostNetworkServer's existing outbound queue.
/// A one-use attachment ticket is issued only after a control-session pairing proof.
nonisolated final class PeelHostAudioChannel: @unchecked Sendable {
    private struct Attachment {
        let requestID: String
        let session: PeelControlSession
        let ticket: String
        let deadline: UInt64
        let uplink: ((PeelAudioPacket) -> Bool)?
    }
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let isCurrent: (PeelControlSession) -> Bool
    private let onAttached: (String, PeelControlSession) -> Void
    private let onClosed: (String, PeelControlSession) -> Void
    private var attachment: Attachment?
    private var connection: NWConnection?
    private var epoch = UUID()
    private var pending: [Data] = []
    private var sending = false
    private var uplinkParser = PeelAudioPacketParser(expectedDirection: .clientToMac)

    init(queue: DispatchQueue, isCurrent: @escaping (PeelControlSession) -> Bool,
         onAttached: @escaping (String, PeelControlSession) -> Void,
         onClosed: @escaping (String, PeelControlSession) -> Void) {
        self.queue = queue
        self.isCurrent = isCurrent
        self.onAttached = onAttached
        self.onClosed = onClosed
        queue.setSpecific(key: queueKey, value: 1)
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    func install(requestID: String, session: PeelControlSession, ticket: String,
                 uplink: ((PeelAudioPacket) -> Bool)? = nil) -> Bool {
        sync {
            close()
            guard isCurrent(session) else { return false }
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            attachment = Attachment(requestID: requestID, session: session, ticket: ticket, deadline: deadline, uplink: uplink)
            let currentEpoch = epoch
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.epoch == currentEpoch, self.connection == nil else { return }
                self.close()
            }
            return true
        }
    }

    func attach(_ socket: NWConnection, hello: PeelAudioStreamHello, hasTrailingData: Bool) {
        queue.async { [weak self] in
            guard let self, !hasTrailingData, hello.version == 1,
                  let target = self.attachment, self.connection == nil,
                  hello.requestId == target.requestID, hello.pairingId == target.session.pairingID,
                  hello.ticket == target.ticket,
                  DispatchTime.now().uptimeNanoseconds < target.deadline,
                  self.isCurrent(target.session) else { socket.cancel(); return }
            self.connection = socket // Consumes the ticket; a second socket cannot attach.
            let currentEpoch = self.epoch
            socket.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.queue.async { [weak self] in
                        guard let self, self.epoch == currentEpoch else { return }
                        self.close()
                    }
                default: break
                }
            }
            if target.uplink != nil {
                self.receiveUplink(socket, epoch: currentEpoch)
            } else {
                // Playback-only sessions must never turn into microphone sessions.
                socket.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.epoch == currentEpoch else { return }
                        self.close()
                    }
                }
            }
            guard let format = try? PeelAudioPacket(formatFor: .macToClient).encode() else { self.close(); return }
            self.pending.append(format)
            self.drain()
            DispatchQueue.main.async { self.onAttached(target.requestID, target.session) }
        }
    }

    private func receiveUplink(_ socket: NWConnection, epoch currentEpoch: UUID) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, complete, error in
            self?.queue.async { [weak self] in
                guard let self, self.epoch == currentEpoch, self.connection === socket else { return }
                guard !complete, error == nil, let attachment = self.attachment,
                      self.isCurrent(attachment.session), let uplink = attachment.uplink else { self.close(); return }
                do {
                    if let data, !data.isEmpty {
                        for packet in try self.uplinkParser.feed(data) {
                            // The bounded sink can drop new PCM under backpressure.
                            // It must not perform Core Audio IPC on the outbound queue.
                            _ = uplink(packet)
                        }
                    }
                    self.receiveUplink(socket, epoch: currentEpoch)
                } catch { self.close() }
            }
        }
    }

    /// Synchronous admission keeps capture from creating an unbounded async backlog.
    func offer(_ packet: PeelAudioPacket, requestID: String, session: PeelControlSession) -> Bool {
        sync {
            guard let attachment, attachment.requestID == requestID, attachment.session == session,
                  connection != nil, isCurrent(session), pending.count < 6 else { return false }
            guard let data = try? packet.encode() else { return false }
            pending.append(data)
            drain()
            return true
        }
    }

    func invalidate() { sync { close() } }

    private func drain() {
        guard !sending, !pending.isEmpty, let connection, let attachment else { return }
        guard isCurrent(attachment.session) else { close(); return }
        sending = true
        let data = pending.removeFirst()
        let currentEpoch = epoch
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, self.epoch == currentEpoch else { return }
                self.sending = false
                if error != nil { self.close() } else { self.drain() }
            }
        })
    }

    private func close() {
        let old = attachment
        epoch = UUID()
        attachment = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        pending.removeAll(keepingCapacity: true)
        sending = false
        uplinkParser.reset()
        if let old { DispatchQueue.main.async { self.onClosed(old.requestID, old.session) } }
    }
}
