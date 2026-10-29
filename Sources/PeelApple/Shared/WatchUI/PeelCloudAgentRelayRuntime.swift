#if os(iOS)
import Foundation
import CryptoKit
import PeelWatchCore
import WatchConnectivity
import UIKit

/// The production registration/session adapter is deliberately REQUIRED. It
/// redeems the one-time grant once, verifies identity and broker authority, and
/// enrolls the actual current phone/Watch peer. Identity metadata is not a bearer.
@MainActor
protocol PeelCloudAgentBrokerConnector: AnyObject {
    func complete(_ grant: CloudAgentOAuthCodeGrant, configuration: CloudAgentIdentityConfiguration) async throws -> PeelCloudAgentVerifiedEnrollment
    /// Continue the same Connect flow into the selected actual Dot or Grok Bot's
    /// scoped plugin authorization. No history import or generic agent substitute.
    func authorizeAgent(_ response: PluginRelayConnectResponse, enrollment: PeelCloudAgentVerifiedEnrollment) async throws
    func ensurePro(_ enrollment: PeelCloudAgentVerifiedEnrollment, fence: PluginRelayFence?, force: Bool) async throws
    func withdrawPro(_ enrollment: PeelCloudAgentVerifiedEnrollment, revision: UUID) async throws
    /// Publish only through the independently enrolled Watch bootstrap channel.
    /// Its Watch-side verifier must authenticate the full fence; merely decoding
    /// route JSON or receiving application context must never install authority.
    func publishRoute(_ fence: PluginRelayFence, enrollment: PeelCloudAgentVerifiedEnrollment) async throws
    /// Delete/revoke the scoped local broker credential and peer lease. Remote
    /// account/subscription revocation must report its own actual outcome.
    func invalidate(_ provider: CloudAgentProvider) async throws
    func savedSessionDeadline(_ provider: CloudAgentProvider) async throws -> Date
    func requestWatchResume(_ provider: CloudAgentProvider) async throws
    func didBindRoute(_ fence: PluginRelayFence) async throws
    func continuityContext(_ provider: CloudAgentProvider) async throws -> PluginRelayWatchResumeContext
    func beginRenewal(_ context: PluginRelayWatchResumeContext, from callback: PeelCloudAgentWatchCallback) async throws -> (PluginRelayWatchResumeChallenge, String)
    func finishRenewal(_ challengeID: UUID, signature: String, from callback: PeelCloudAgentWatchCallback) async throws -> PluginRelayVerifiedPhoneRestoration
    func pairedWatchDidChange()
    func approvalTransaction(in url: URL) -> UUID?
    func pluginReview(transactionID: UUID, enrollment: PeelCloudAgentVerifiedEnrollment) async throws -> PluginRelayPluginConsentReview
    func approvePlugin(_ review: PluginRelayPluginConsentReview, fence: PluginRelayFence,
                       enrollment: PeelCloudAgentVerifiedEnrollment) async throws -> URL
}

/// Returned ONLY by the trusted adapter above after real provider and broker
/// verification. This is not Codable, a credential, or a Watch wire payload.
struct PeelCloudAgentVerifiedEnrollment {
    let identity: CloudAgentVerifiedIdentity
    let session: any PluginRelayPhoneVerifiedSession
    var applicationDeadline: Date {
        (session as? PluginRelayEnrolledPhoneSession)?.applicationSessionExpiresAt ?? identity.identityExpiresAt
    }
}

/// Callback attribution only. The verified session must correlate this actual
/// native channel and current paired directory with its independently enrolled
/// peer proof. WC flags, this object, URL, or object ID alone grant no authority.
struct PeelCloudAgentWatchCallback: PluginRelayNativePeerCallback, @unchecked Sendable {
    let nativeSession: WCSession
    let channelIdentity: ObjectIdentifier
    let pairedDirectory: URL?
    let receivedAt: Date
    @MainActor init(session: WCSession) {
        nativeSession = session; channelIdentity = ObjectIdentifier(session)
        pairedDirectory = session.watchDirectoryURL; receivedAt = Date()
    }
}

enum PeelCloudAgentRelayPersistence {
    /// Phone-only explicit class-C opt-in. A missing/protected/corrupt prior file
    /// throws; never fall back to a fresh store or a different data partition.
    static func makeOwner() throws -> PluginRelayPhoneRouteOwner {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("PeelWatchPluginRelay", isDirectory: true)
        return PluginRelayPhoneRouteOwner { fence in
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let partition = SHA256.hash(data: try encoder.encode(fence.binding))
                .map { String(format: "%02x", $0) }.joined()
            let file = root.appendingPathComponent(partition, isDirectory: true).appendingPathComponent("phone.json")
            return try PluginRelayFilePersistence.phoneRelayAfterFirstUnlock(fileURL: file)
        }
    }
}

/// One finite WC request. This neither guarantees background runtime nor starts
/// a polling loop. The OS expiry and a 20-second monotonic deadline cancel work;
/// the callback is returned once, even if a cancelled operation finishes late.
@MainActor
final class PeelCloudAgentWCRequest {
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var reply: ((Data) -> Void)?
    private var didFinish = false

    static func start(data: Data, session: WCSession,
                      reply: @escaping (Data) -> Void) {
        let request = PeelCloudAgentWCRequest(reply: reply)
        request.run(data: data, session: session)
    }
    private init(reply: @escaping (Data) -> Void) { self.reply = reply }
    private func run(data: Data, session: WCSession) {
        let callback = PeelCloudAgentWatchCallback(session: session)
        background = UIApplication.shared.beginBackgroundTask(withName: "Peel Watch agent courier") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        guard !didFinish else { return }
        // Strong self ownership lasts only until this bounded operation ends.
        operation = Task { [self] in
            if PluginRelayEnrollmentWire.claims(data) {
                let result = await PeelCloudAgentPhoneService.shared.handlePluginRelay(data, from: callback)
                guard !Task.isCancelled else { finish(Data()); return }
                finish(result)
            } else {
                let result = await PeelCloudAgentPhoneService.shared.handlePluginRelayOutput(data, from: callback)
                guard !Task.isCancelled else { finish(Data()); return }
                finish(Data(), paidOutput: result)
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }
    private func expire() { operation?.cancel(); finish(Data()) }
    private func finish(_ result: Data, paidOutput: PluginRelayPhoneOutput? = nil) {
        guard !didFinish else { return }; didFinish = true
        deadline?.cancel(); deadline = nil
        let callback = reply; reply = nil
        operation = nil
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        if let paidOutput {
            // Actual WC submission is serialized with paid withdrawal. A check
            // before this actor hop would leave the content-output race open.
            do { try paidOutput.submit { callback?($0) } }
            catch { callback?(Data()) }
        } else { callback?(result) }
    }
}
#endif
