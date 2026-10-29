// Adapted from OrcheSSHtra NIOSSHTransport.swift at 7add890ce1897a75f23ba8da41f1c83e1dcf1179.
// Only independent interactive shells are exposed; no exec, SFTP, forwarding or tmux attachment.
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import PeelShellCore

private final class ConnectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false
    func install(_ channel: Channel) {
        lock.lock(); self.channel = channel; let shouldClose = cancelled; lock.unlock()
        if shouldClose { channel.close(promise: nil) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let channel = channel; lock.unlock()
        channel?.close(promise: nil)
    }
}

/// NIOSSH reports handshake/authentication failures through the pipeline. Close immediately
/// so a pending child-channel request is released instead of waiting for the outer deadline.
private nonisolated final class SSHConnectionErrorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

public nonisolated final class NIOSSHClient: SSHClientProtocol {
    public init() {}
    public func connect(to endpoint: SSHEndpoint, authentication: SSHAuthMethod,
                        hostKeyVerifier: any SSHHostKeyVerifier) async throws -> any SSHConnectionProtocol {
        guard endpoint.isValid else { throw SSHClientError.invalidEndpoint }
        // Parse unsupported keys before a network connection, without logging key material.
        if case .privateKey(let pem, let passphrase) = authentication {
            _ = try UserAuthDelegate.parsePrivateKey(pem: pem, passphrase: passphrase)
        }
        let cancellation = ConnectCancellation()
        return try await withTaskCancellationHandler {
            let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
                .connectTimeout(.seconds(15))
                .channelInitializer { channel in
                    cancellation.install(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: UserAuthDelegate(username: endpoint.username, method: authentication),
                                serverAuthDelegate: HostKeyValidationDelegate(endpoint: endpoint, verifier: hostKeyVerifier)
                            )), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                        try channel.pipeline.syncOperations.addHandler(SSHConnectionErrorHandler())
                    }
                }
            let channel = try await bootstrap.connect(host: endpoint.host, port: Int(endpoint.port)).get()
            guard !Task.isCancelled else { try? await channel.close().get(); throw CancellationError() }
            return NIOSSHConnection(channel: channel)
        } onCancel: { cancellation.cancel() }
    }
}

/// Event-loop-owned completion gate. Each promise is completed exactly once, including timeout races.
private final class ShellOpenGate {
    let result: EventLoopPromise<any SSHShellSessionProtocol>
    private var done = false
    private var timeout: Scheduled<Void>?
    var child: Channel?
    let parent: Channel
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(parent: Channel, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.parent = parent; self.continuation = continuation
        result = parent.eventLoop.makePromise(of: (any SSHShellSessionProtocol).self)
    }
    func startTimeout() {
        // Covers authentication plus the bounded 60-second user fingerprint decision.
        timeout = parent.eventLoop.scheduleTask(in: .seconds(75)) { self.fail(SSHClientError.timedOut) }
    }
    func succeed(_ session: any SSHShellSessionProtocol) {
        guard !done else { child?.close(promise: nil); return }
        done = true; timeout?.cancel(); timeout = nil
        result.succeed(session)
    }
    func fail(_ error: Error) {
        guard !done else { return }
        done = true; timeout?.cancel(); timeout = nil
        continuation.finish(throwing: error)
        result.fail(error)
        child?.close(promise: nil)
        parent.close(promise: nil)
    }
}

nonisolated final class NIOSSHConnection: SSHConnectionProtocol, @unchecked Sendable {
    private let channel: Channel
    init(channel: Channel) { self.channel = channel }
    func openShell(initialSize: SSHTerminalSize) async throws -> any SSHShellSessionProtocol {
        let (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let result: EventLoopFuture<any SSHShellSessionProtocol> = channel.eventLoop.flatSubmit {
            let gate = ShellOpenGate(parent: self.channel, continuation: continuation)
            gate.startTimeout()
            self.channel.closeFuture.whenComplete { _ in gate.fail(SSHClientError.channelFailure(reason: "Connection closed before shell opened")) }
            let childPromise = self.channel.eventLoop.makePromise(of: Channel.self)
            do {
                let handler = try self.channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                handler.createChannel(childPromise, channelType: .session) { child, _ in
                    gate.child = child
                    let session = NIOSSHShellSession(channel: child, output: output)
                    return child.pipeline.addHandler(ShellDataHandler(continuation: continuation,
                        opened: { gate.succeed(session) }, failed: { gate.fail($0) }))
                }
            } catch { gate.fail(error) }
            childPromise.futureResult.whenComplete { result in
                switch result {
                case .failure(let error): gate.fail(error)
                case .success(let child):
                    let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true, term: "xterm-256color", terminalCharacterWidth: initialSize.columns,
                        terminalRowHeight: initialSize.rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                        terminalModes: SSHTerminalModes([:]))
                    child.triggerUserOutboundEvent(pty).flatMap {
                        child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
                    }.whenFailure { gate.fail($0) }
                }
            }
            return gate.result.futureResult
        }
        return try await withTaskCancellationHandler {
            try await result.get()
        } onCancel: { self.channel.close(promise: nil) }
    }
    func disconnect() async { try? await channel.close().get() }
}
