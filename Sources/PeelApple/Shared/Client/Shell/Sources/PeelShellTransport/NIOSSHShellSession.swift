// Adapted from OrcheSSHtra NIOSSHShellSession.swift at 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
import Foundation
import NIOCore
import NIOSSH
import PeelShellCore

/// A slow consumer causes an explicit closed/error state, never a silently truncated live terminal.
/// At most 64 chunks of at most 32 KiB are queued by the stream (~2 MiB).
nonisolated final class ShellDataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var replies = 0
    private var ended = false
    private let opened: () -> Void
    private let failed: (Error) -> Void
    init(continuation: AsyncThrowingStream<Data, Error>.Continuation,
         opened: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        self.continuation = continuation; self.opened = opened; self.failed = failed
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            replies += 1
            if replies == 2 { opened() }
        } else if event is ChannelFailureEvent {
            end(context: context, error: SSHClientError.requestRejected)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !ended, case .byteBuffer(var buffer) = unwrapInboundIn(data).data else { return }
        while buffer.readableBytes > 0 {
            guard let bytes = buffer.readBytes(length: min(32_768, buffer.readableBytes)) else { break }
            switch continuation.yield(Data(bytes)) {
            case .enqueued: break
            case .dropped: end(context: context, error: SSHClientError.outputLimitExceeded); return
            case .terminated: end(context: context, error: SSHClientError.cancelled); return
            @unknown default: end(context: context, error: SSHClientError.outputLimitExceeded); return
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !ended {
            ended = true
            if replies < 2 { failed(SSHClientError.requestRejected) }
            continuation.finish()
        }
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { end(context: context, error: error) }
    private func end(context: ChannelHandlerContext, error: Error) {
        guard !ended else { return }
        ended = true; continuation.finish(throwing: error); failed(error)
        context.close(promise: nil)
    }
}

nonisolated final class NIOSSHShellSession: SSHShellSessionProtocol, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let channel: Channel
    init(channel: Channel, output: AsyncThrowingStream<Data, Error>) { self.channel = channel; self.output = output }
    func send(_ input: Data) async throws {
        guard input.count <= 65_536 else { throw SSHClientError.inputLimitExceeded }
        guard !Task.isCancelled else { throw CancellationError() }
        var buffer = channel.allocator.buffer(capacity: input.count)
        buffer.writeBytes(input)
        try await withTaskCancellationHandler {
            try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
        } onCancel: { self.channel.close(promise: nil) }
    }
    func resize(to size: SSHTerminalSize) async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0)).get()
    }
    func close() async { try? await channel.close().get() }
}
