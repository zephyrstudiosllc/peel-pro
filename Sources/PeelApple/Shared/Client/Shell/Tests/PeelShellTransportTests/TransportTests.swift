// Real SSH loopback fixtures adapted from Conductor/ConductorTests/SSHEndToEndTests.swift.
// No system sshd, saved credentials, owner machines or user terminals are used.
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
import PeelShellCore
@testable import PeelShellTransport

private struct FixtureAuth: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if request.username == "fixture", case .password(let password) = request.request,
           password.password == "fixture-only" { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}
private struct FixtureVerifier: SSHHostKeyVerifier {
    let accepted: Bool
    func decision(for hostKey: SSHHostKey, endpoint: SSHEndpoint) async -> SSHHostKeyDecision {
        accepted ? .trustOnce : .reject
    }
}
private final class FixtureShell: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    let rejectPTY: Bool
    let flood: Bool
    init(rejectPTY: Bool, flood: Bool) { self.rejectPTY = rejectPTY; self.flood = flood }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.PseudoTerminalRequest {
            context.triggerUserOutboundEvent(rejectPTY ? ChannelFailureEvent() as Any : ChannelSuccessEvent(), promise: nil)
        } else if event is SSHChannelRequestEvent.ShellRequest {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            if flood {
                var buffer = context.channel.allocator.buffer(capacity: 3_000_000)
                buffer.writeRepeatingByte(65, count: 3_000_000)
                context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            }
        } else { context.fireUserInboundEventTriggered(event) }
    }
}

private func server(rejectPTY: Bool = false, flood: Bool = false) async throws -> Channel {
    let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    return try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(SSHServerConfiguration(hostKeys: [key], userAuthDelegate: FixtureAuth())),
                    allocator: channel.allocator, inboundChildChannelInitializer: { child, _ in
                        child.pipeline.addHandler(FixtureShell(rejectPTY: rejectPTY, flood: flood))
                    }))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
}
private func connect(_ server: Channel, accepted: Bool = true) async throws -> any SSHConnectionProtocol {
    try await NIOSSHClient().connect(
        to: SSHEndpoint(host: "127.0.0.1", port: UInt16(server.localAddress!.port!), username: "fixture"),
        authentication: .password("fixture-only"), hostKeyVerifier: FixtureVerifier(accepted: accepted))
}

struct TransportTests {
    @Test(.timeLimit(.minutes(1))) func realHandshakePTYBytesResizeAndClose() async throws {
        let server = try await server()
        defer { server.close(promise: nil) }
        let connection = try await connect(server)
        let shell = try await connection.openShell(initialSize: SSHTerminalSize(columns: 90, rows: 32))
        let expected = Data("peel-independent-shell-fixture\r\n".utf8)
        try await shell.resize(to: SSHTerminalSize(columns: 120, rows: 40))
        try await shell.send(expected)
        var bytes = Data()
        for try await chunk in shell.output {
            bytes.append(chunk)
            if bytes.count >= expected.count { break }
        }
        #expect(bytes == expected)
        await shell.close()
        await connection.disconnect()
    }
    @Test(.timeLimit(.minutes(1))) func rejectedHostKeyNeverOpensShell() async throws {
        let server = try await server()
        defer { server.close(promise: nil) }
        let connection = try await connect(server, accepted: false)
        do { _ = try await connection.openShell(initialSize: .fallback); Issue.record("Rejected host key opened shell") }
        catch {}
        await connection.disconnect()
    }
    @Test(.timeLimit(.minutes(1))) func refusedPTYIsNotReportedConnected() async throws {
        let server = try await server(rejectPTY: true)
        defer { server.close(promise: nil) }
        let connection = try await connect(server)
        do { _ = try await connection.openShell(initialSize: .fallback); Issue.record("Refused PTY opened shell") }
        catch { #expect(error as? SSHClientError == .requestRejected) }
        await connection.disconnect()
    }
    @Test(.timeLimit(.minutes(1))) func unconsumedOutputClosesWithExplicitLimitError() async throws {
        let server = try await server(flood: true)
        defer { server.close(promise: nil) }
        let connection = try await connect(server)
        let shell = try await connection.openShell(initialSize: .fallback)
        try await Task.sleep(nanoseconds: 150_000_000)
        var count = 0
        do {
            for try await chunk in shell.output { count += chunk.count }
            Issue.record("Expected bounded-output failure")
        } catch { #expect(error as? SSHClientError == .outputLimitExceeded) }
        #expect(count <= 64 * 32_768)
        await connection.disconnect()
    }
    @Test func encryptedKeyRejectedWithoutOpeningSocket() async {
        do {
            _ = try await NIOSSHClient().connect(to: SSHEndpoint(host: "127.0.0.1", port: 1, username: "fixture"),
                authentication: .privateKey(pem: "synthetic", passphrase: "synthetic"),
                hostKeyVerifier: FixtureVerifier(accepted: true))
            Issue.record("Unsupported key accepted")
        } catch {
            if case .privateKeyUnsupported = error as? SSHClientError {} else { Issue.record("Unexpected key rejection") }
        }
    }
}
