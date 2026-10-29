import Foundation
import Combine
import WatchConnectivity
import PeelWatchCore
import CoreGraphics
import ImageIO

/// App-local drafts only. No provider credential or authentication state crosses WCSession.
@MainActor
final class PeelCompanionModel: NSObject, ObservableObject {
    static let shared = PeelCompanionModel()

    @Published var provider: CompanionProvider = .openAI {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "Peel.Watch.provider") }
    }
    @Published private(set) var drafts: [CompanionDraft] = []
    @Published private(set) var transportStatus = "Checking iPhone connection…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var delivery: [UUID: String] = [:]
    @Published private(set) var watchStreamInfo: WatchStreamInfo?
    @Published private(set) var watchStreamFrame: WatchStreamFrame?
    @Published private(set) var watchStreamImage: CGImage?
    @Published private(set) var watchStreamStatus = "Start sharing an open stream in Peel Pro on iPhone."
    @Published private(set) var watchStreamBusy = false
    @Published var watchViewport: WatchViewport = .full
    private var watchStreamTask: Task<Void, Never>?
    private var watchViewing = WatchViewingState()
    private var lastWatchFrameAt: TimeInterval = 0
    private var pendingReplies: [UUID: CheckedContinuation<Data?, Never>] = [:]
    @Published private(set) var cloudProvider: CloudAgentProvider = .dot
    @Published private(set) var cloudReady = false
    @Published private(set) var cloudBusy = false
    @Published private(set) var cloudStatus = "Connect your agent in Peel Pro on iPhone."
    @Published private(set) var cloudReplies: [WatchCloudReply] = []
    @Published private(set) var cloudLastSentText: String?
    @Published private(set) var cloudConversation: CloudAgentConversationReference?
    @Published private(set) var cloudNextPoll: Date?
    private var cloudTask: Task<Void, Never>?
    private var cloudGeneration = UUID()
    private var cloudOperationID: UUID?
    private var cloudConnectionStatus: CloudAgentConnectionStatus?
#if os(iOS)
    let phoneWatchRelay = PeelPhoneWatchRelay()
#endif

    private var inbox = CompanionInbox()
    private var storageAvailable = true
    private let disk: CompanionDiskStore
    private let session: WCSession?
    private let payloadKey = "peel.watch.draft.v1"
    private let receiptKey = "peel.watch.receipt.v1"

    override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PeelWatchCompanion", isDirectory: true)
        disk = CompanionDiskStore(fileURL: directory.appendingPathComponent("drafts.json"))
        session = WCSession.isSupported() ? .default : nil
        super.init()
        if let raw = UserDefaults.standard.string(forKey: "Peel.Watch.provider"),
           let saved = CompanionProvider(rawValue: raw) { provider = saved }
        do {
            inbox = try disk.load()
            drafts = inbox.drafts
        } catch {
            storageAvailable = false
            errorMessage = "Saved drafts could not be read. They have been preserved."
        }
        session?.delegate = self
        session?.activate()
        if session == nil { transportStatus = "Watch connection is unavailable on this device" }
    }

    @discardableResult
    func saveDraft(text: String) -> Bool {
        do {
            let draft = try CompanionDraft(provider: provider, text: text)
            // Reject unsendable Unicode-heavy drafts before accepting them into storage.
            _ = try CompanionEnvelope(draft: draft).encodedData()
            var candidate = inbox
            guard candidate.insert(draft) else {
                errorMessage = "Your draft inbox is full. Delete a draft before saving another."
                return false
            }
            return persist(candidate)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteDraft(_ draft: CompanionDraft) {
        let remaining = inbox.drafts.filter { $0.id != draft.id }
        if persist(CompanionInbox(drafts: remaining)) { delivery[draft.id] = nil }
    }

    func clearDrafts() {
        if persist(CompanionInbox()) { delivery.removeAll() }
    }

    func dismissError() { errorMessage = nil }

    /// Live frames use request/reply only: no background media queue and at most
    /// one outstanding Watch frame. A late reply cannot revive a retired view.
    func startWatchViewing() {
#if os(watchOS)
        stopWatchViewing(notifyPhone: false)
        watchStreamStatus = "Connecting to paired iPhone…"
        let generation = watchViewing.start()
        watchStreamTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.watchViewing.isCurrent(generation) {
                if !self.watchStreamBusy,
                   let request = self.watchViewing.nextRequest(generation: generation, viewport: self.watchViewport) {
                    self.watchStreamBusy = true
                    let next = await self.streamRoundTrip(request)
                    guard !Task.isCancelled, self.watchViewing.isCurrent(generation) else { return }
                    self.watchStreamBusy = false
                    self.watchStreamStatus = next?.message ?? "iPhone relay unavailable. Retrying while Live view is open."
                    switch self.watchViewing.receive(next, to: request, generation: generation) {
                    case .retired:
                        return
                    case .retry:
                        self.clearWatchPresentation()
                    case .accepted(let info):
                        self.watchStreamInfo = info
                        // The first frame follows discovery immediately, as before.
                        if request.kind == .status { continue }
                        if let frame = next?.frame,
                           frame.sequence > (self.watchStreamFrame?.sequence ?? 0),
                           let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
                           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                           let width = properties[kCGImagePropertyPixelWidth] as? Int,
                           let height = properties[kCGImagePropertyPixelHeight] as? Int,
                           width == frame.width, height == frame.height,
                           width <= 512, height <= 512,
                           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                            self.watchStreamImage = image; self.watchStreamFrame = frame
                            self.lastWatchFrameAt = ProcessInfo.processInfo.systemUptime
                        }
                        if ProcessInfo.processInfo.systemUptime-self.lastWatchFrameAt > 3 { self.clearWatchFrame() }
                    }
                }
                do { try await Task.sleep(nanoseconds: WatchViewingState.pollIntervalNanoseconds) }
                catch { return }
            }
        }
#endif
    }

    func stopWatchViewing(notifyPhone: Bool = true) {
        let oldInfo = watchStreamInfo
        watchViewing.stop(); watchStreamTask?.cancel(); watchStreamTask = nil
        clearWatchPresentation(); watchStreamBusy = false
        if notifyPhone { watchStreamStatus = "Stopped. Start sharing again on iPhone." }
        if notifyPhone, let oldInfo, let session, session.activationState == .activated, session.isReachable,
           let data = try? WatchStreamRequest(kind: .stop, sessionID: oldInfo.sessionID).encoded() {
            session.sendMessageData(data, replyHandler: { _ in }, errorHandler: nil)
        }
    }

    private func clearWatchFrame() { watchStreamFrame = nil; watchStreamImage = nil; lastWatchFrameAt = 0 }
    private func clearWatchPresentation() { watchStreamInfo = nil; clearWatchFrame() }

    func sendWatchInput(_ input: WatchStreamInput) async {
        guard !watchStreamBusy, let info = watchStreamInfo, let token = info.controlToken,
              let frame = watchStreamFrame, watchStreamImage != nil,
              ProcessInfo.processInfo.systemUptime-lastWatchFrameAt <= 3 else {
            watchStreamStatus = "Wait for a fresh frame and allow Watch Control on iPhone."; return
        }
        let generation = watchViewing.generation
        guard let inputSequence = watchViewing.nextInputSequence(sessionID: info.sessionID, generation: generation) else {
            watchStreamStatus = "Start viewing again before controlling this window."; return
        }
        watchStreamBusy = true
        let response = await streamRoundTrip(WatchStreamRequest(kind: .input, sessionID: info.sessionID,
            frameSequence: frame.sequence, controlToken: token, inputSequence: inputSequence, input: input))
        guard watchViewing.isCurrent(generation) else { return }
        watchStreamBusy = false
        guard !Task.isCancelled else {
            watchViewing.requireStatus(generation: generation)
            clearWatchPresentation()
            return
        }
        watchStreamStatus = response?.message ?? "iPhone relay unavailable. Retrying while Live view is open."
        if response?.accepted == true, response?.info?.sessionID == info.sessionID {
            watchStreamInfo = response?.info
        } else {
            watchViewing.requireStatus(generation: generation)
            clearWatchPresentation()
        }
    }

    private func streamRoundTrip(_ request: WatchStreamRequest) async -> WatchStreamResponse? {
        guard let data = try? request.encoded(), let reply = await companionRoundTrip(data),
              let response = try? WatchStreamResponse.decode(reply), response.requestID == request.requestID else {
            return nil
        }
        return response
    }

    /// Shared foreground transport for stream and cloud-agent requests. Never use
    /// transferUserInfo for frame/control/provider operations that could arrive late.
    func companionRoundTrip(_ data: Data, timeoutSeconds: UInt64 = 4) async -> Data? {
        guard data.count <= WatchStreamWire.maximumBytes, let session,
              session.activationState == .activated, session.isReachable,
              pendingReplies.count < 2 else { return nil }
        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            pendingReplies[requestID] = continuation
            session.sendMessageData(data, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.finishReply(requestID, data: reply.count <= WatchStreamWire.maximumBytes ? reply : nil) }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.finishReply(requestID, data: nil) }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                self?.finishReply(requestID, data: nil)
            }
        }
    }
    private func finishReply(_ id: UUID, data: Data?) { pendingReplies.removeValue(forKey: id)?.resume(returning: data) }

    func startCloudConversation(_ provider: CloudAgentProvider) {
        stopCloudChecking()
        cloudProvider = provider; cloudReplies = []; cloudConversation = nil
        cloudConnectionStatus = nil
        cloudLastSentText = nil; cloudReady = false; cloudNextPoll = nil
        let generation = UUID(); cloudGeneration = generation
        cloudTask = Task { [weak self] in
            guard let self else { return }
            await self.requestCloud(.init(kind: .status, provider: provider), generation: generation)
            while !Task.isCancelled && self.cloudGeneration == generation {
                if self.cloudReady, !self.cloudBusy, let conversation = self.cloudConversation,
                   self.cloudNextPoll.map({ $0 <= Date() }) ?? true {
                    await self.requestCloud(.init(kind: .replies, provider: provider, conversation: conversation), generation: generation)
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func refreshCloud() async {
        guard !cloudBusy else { return }
        if let conversation = cloudConversation, cloudReady {
            guard cloudNextPoll.map({ $0 <= Date() }) ?? true else { return }
            await requestCloud(.init(kind: .replies, provider: cloudProvider, conversation: conversation), generation: cloudGeneration)
        } else {
            await requestCloud(.init(kind: .status, provider: cloudProvider), generation: cloudGeneration)
        }
    }
    func sendCloudText(_ text: String) async {
        guard cloudReady, !cloudBusy else { return }
        cloudLastSentText = text
        // A timeout never automatically repeats a possibly delivered message.
        await requestCloud(.init(kind: .send, provider: cloudProvider, text: text,
                                 conversation: cloudConversation), generation: cloudGeneration)
    }
    private func requestCloud(_ request: WatchCloudRequest, generation: UUID) async {
        guard generation == cloudGeneration, !cloudBusy, let data = try? request.encoded() else { return }
        cloudBusy = true; cloudOperationID = request.requestID
        if request.kind == .send { cloudStatus = "Sending your message…" }
        let dataReply = await companionRoundTrip(data, timeoutSeconds: 25)
        guard cloudGeneration == generation else { return }
        cloudBusy = false; cloudOperationID = nil
        guard let dataReply, let response = try? WatchCloudResponse.decode(dataReply),
              response.requestID == request.requestID, response.provider == cloudProvider,
              request.kind != .replies || request.conversation == response.conversation else {
            cloudReady = false
            cloudStatus = request.kind == .send
                ? "Delivery is uncertain. Check with your agent before sending again."
                : "iPhone unavailable. Keep Peel Pro open and check the connection."
            return
        }
        if cloudConnectionStatus?.verifiedBinding != response.connectionStatus.verifiedBinding || !response.ready {
            cloudReplies.removeAll(); cloudConversation = nil
        }
        cloudConnectionStatus = response.connectionStatus
        cloudReady = response.ready; cloudStatus = response.message
        if let conversation = response.conversation {
            if cloudConversation != nil && cloudConversation != conversation { cloudReplies.removeAll() }
            cloudConversation = conversation
        }
        for message in response.replies {
            if let index = cloudReplies.firstIndex(where: { $0.id == message.id }) { cloudReplies[index] = message }
            else { cloudReplies.append(message) }
        }
        if cloudReplies.count > 100 { cloudReplies.removeFirst(cloudReplies.count-100) }
        cloudNextPoll = response.nextPollAfter ?? Date().addingTimeInterval(60)
    }
    func stopCloudChecking() {
        let operation = cloudOperationID
        cloudGeneration = UUID(); cloudTask?.cancel(); cloudTask = nil
        cloudBusy = false; cloudOperationID = nil
        cloudStatus = "Reply checking stopped here. The remote agent may keep working."
        if let operation, let session, session.activationState == .activated, session.isReachable,
           let data = try? WatchCloudRequest(kind: .cancel, provider: cloudProvider, cancelRequestID: operation).encoded() {
            session.sendMessageData(data, replyHandler: { _ in }, errorHandler: nil)
        }
        // Only local checking stops. The remote agent keeps its own task state.
    }
    func watchDidBecomeInactive() {
        stopWatchViewing(); stopCloudChecking()
        let replies = Array(pendingReplies.values); pendingReplies.removeAll()
        for continuation in replies { continuation.resume(returning: nil) }
    }

    func status(for draft: CompanionDraft) -> String {
        delivery[draft.id] ?? "Saved on this device"
    }

    func sendToPhone(_ draft: CompanionDraft) {
        guard drafts.contains(where: { $0 == draft }), let session,
              session.activationState == .activated else {
            transportStatus = "Open Peel Pro on your paired iPhone and watch first"
            return
        }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else {
            transportStatus = "Install Peel Pro on your paired Apple Watch first"
            return
        }
        #else
        guard session.isCompanionAppInstalled else {
            transportStatus = "Install Peel Pro on your paired iPhone first"
            return
        }
        #endif
        do {
            let data = try CompanionEnvelope(draft: draft).encodedData()
            delivery[draft.id] = "Sending to paired device…"
            if session.isReachable {
                session.sendMessageData(data, replyHandler: { [weak self] reply in
                    Task { @MainActor in
                        guard let self else { return }
                        if String(data: reply, encoding: .utf8) == draft.id.uuidString {
                            self.delivery[draft.id] = "Saved on paired device"
                        } else {
                            self.delivery[draft.id] = "Paired device could not save the draft"
                        }
                    }
                }, errorHandler: { [weak self] _ in
                    Task { @MainActor in self?.queue(data, draftID: draft.id) }
                })
            } else {
                queue(data, draftID: draft.id)
            }
        } catch {
            errorMessage = "This draft is too large to send. Shorten it and try again."
        }
    }

    private func queue(_ data: Data, draftID: UUID) {
        guard let session, session.activationState == .activated else {
            delivery[draftID] = "Not sent. Open Peel Pro on both devices."
            return
        }
        let outstanding = session.outstandingUserInfoTransfers
        let alreadyQueued = outstanding.contains {
            guard let existing = $0.userInfo[payloadKey] as? Data,
                  let envelope = try? CompanionEnvelope(data: existing) else { return false }
            return envelope.draft.id == draftID
        }
        guard alreadyQueued || outstanding.count < 100 else {
            delivery[draftID] = "Queue full. Open Peel Pro on your paired device."
            return
        }
        if !alreadyQueued { session.transferUserInfo([payloadKey: data]) }
        delivery[draftID] = "Queued for paired device"
    }

    private func receive(_ data: Data) -> UUID? {
        do {
            guard case .draft = try WatchCompanionChannel.classify(data) else { return nil }
            let envelope = try CompanionEnvelope(data: data)
            if let existing = inbox.drafts.first(where: { $0.id == envelope.draft.id }) {
                // A reused ID with different content is not an idempotent retry.
                return existing == envelope.draft ? existing.id : nil
            }
            var candidate = inbox
            guard candidate.insert(envelope.draft), persist(candidate) else { return nil }
            delivery[envelope.draft.id] = "Received from paired device"
            return envelope.draft.id
        } catch {
            errorMessage = "A draft from the paired device was rejected."
            return nil
        }
    }

    @discardableResult
    private func persist(_ candidate: CompanionInbox) -> Bool {
        guard storageAvailable else {
            errorMessage = "Draft storage needs recovery. Existing data has not been overwritten."
            return false
        }
        do {
            try disk.save(candidate)
            inbox = candidate
            drafts = candidate.drafts
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The draft could not be saved. Please try again."
            return false
        }
    }

    private func refreshTransportStatus() {
        guard let session, session.activationState == .activated else {
            transportStatus = "Open Peel Pro on both paired devices"
            return
        }
        #if os(iOS)
        if !session.isPaired { transportStatus = "No Apple Watch paired with this iPhone"; return }
        if !session.isWatchAppInstalled { transportStatus = "Install Peel Pro on your Apple Watch"; return }
        #else
        if !session.isCompanionAppInstalled { transportStatus = "Install Peel Pro on your iPhone"; return }
        #endif
        transportStatus = session.isReachable ? "Paired device reachable" : "Paired device offline · drafts can queue"
    }
}

extension PeelCompanionModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            if error != nil || activationState != .activated {
#if os(iOS)
                await PeelCloudAgentPhoneService.shared.pairedWatchDidChange()
#else
                await PeelWatchCloudEnrollment.shared.pairedPhoneDidChange()
#endif
            }
            self?.refreshTransportStatus()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshTransportStatus() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        // Classification failure is terminal. A malformed newer channel must
        // never become a legacy draft or an older cloud request.
        guard let channel = try? WatchCompanionChannel.classify(messageData) else {
            replyHandler(Data())
            return
        }
        switch channel {
        case .enrollment:
            Task { @MainActor in
#if os(watchOS)
                replyHandler(await PeelWatchCloudEnrollment.shared.handle(messageData, from: session))
#elseif os(iOS)
                PeelCloudAgentWCRequest.start(data: messageData, session: session, reply: replyHandler)
#else
                replyHandler(Data())
#endif
            }
        case .cloudV2:
            Task { @MainActor in
#if os(iOS)
                PeelCloudAgentWCRequest.start(data: messageData, session: session, reply: replyHandler)
#else
                replyHandler(Data())
#endif
            }
        case .cloudV1:
            guard let request = try? WatchCloudRequest.decode(messageData) else {
                replyHandler(Data()); return
            }
            Task { @MainActor in
#if os(iOS)
                let response = await PeelCloudAgentPhoneService.shared.handle(request)
                replyHandler((try? response.encoded()) ?? Data())
#else
                replyHandler(Data())
#endif
            }
        case .stream:
            guard let request = try? WatchStreamRequest.decode(messageData) else {
                replyHandler(Data()); return
            }
            Task { @MainActor [weak self] in
#if os(iOS)
                guard let self else { replyHandler(Data()); return }
                let response = await self.phoneWatchRelay.handle(request)
                replyHandler((try? response.encoded()) ?? Data())
#else
                replyHandler(Data())
#endif
            }
        case .draft:
            Task { @MainActor [weak self] in
                let id = self?.receive(messageData)
                replyHandler(Data((id?.uuidString ?? "rejected").utf8))
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // Extract only bounded public draft data; never pass the untyped dictionary across actors.
        let payload = userInfo["peel.watch.draft.v1"] as? Data
        let receipt = userInfo["peel.watch.receipt.v1"] as? String
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let payload, let id = self.receive(payload) {
                self.session?.transferUserInfo([self.receiptKey: id.uuidString])
            }
            if let receipt, receipt.count == 36, let id = UUID(uuidString: receipt),
               self.drafts.contains(where: { $0.id == id }) {
                self.delivery[id] = "Saved on paired device"
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            await PeelCloudAgentPhoneService.shared.pairedWatchDidChange()
            self?.refreshTransportStatus()
        }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            await PeelCloudAgentPhoneService.shared.pairedWatchDidChange()
            self?.refreshTransportStatus()
            session.activate()
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            await PeelCloudAgentPhoneService.shared.pairedWatchDidChange()
            self?.refreshTransportStatus()
        }
    }
    #endif
}
