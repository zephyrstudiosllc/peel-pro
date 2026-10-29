import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PeelAgentWindowSnapshot: Sendable { let data: Data; let width: Int; let height: Int }

@MainActor
struct PeelAgentControlContext {
    /// Lease scope: a paired session, or the reserved local-computer target.
    let scope: PeelAgentPresentationScope
    /// Exact InputSynthesizer control generation that owns this operation.
    let inputGeneration: UInt64
    let fingerprint: PeelAgentWindowInstanceFingerprint
    let bounds: CGRect
    /// Presentation evidence an inspection is bound to: the paired receiver's
    /// renderer generation, or the local-access grant generation.
    let renderer: UUID
    let visibilityEvidence: String
    let captureNotes: String
    let remotePresentationVerified = false
    let validate: () -> Bool
    let validateEvent: (CGEvent) -> Bool
    var boundsValues: [Double] { [bounds.minX, bounds.minY, bounds.width, bounds.height] }

    /// Paired-stream control: unchanged scope, generation and receipt text.
    init(session: PeelControlSession, fingerprint: PeelAgentWindowInstanceFingerprint, bounds: CGRect, renderer: UUID,
         validate: @escaping () -> Bool, validateEvent: @escaping (CGEvent) -> Bool) {
        self.init(scope: PeelAgentPresentationScope(pairingID: session.pairingID, generation: session.generation),
            inputGeneration: session.generation, fingerprint: fingerprint, bounds: bounds, renderer: renderer,
            visibilityEvidence: "paired_peer_reported_active_display_layer",
            captureNotes: "Window-only source capture. Receiver reports enqueue, not independently verified scanout or human viewing. Inspect again after one action.",
            validate: validate, validateEvent: validateEvent)
    }

    init(scope: PeelAgentPresentationScope, inputGeneration: UInt64, fingerprint: PeelAgentWindowInstanceFingerprint,
         bounds: CGRect, renderer: UUID, visibilityEvidence: String, captureNotes: String,
         validate: @escaping () -> Bool, validateEvent: @escaping (CGEvent) -> Bool) {
        self.scope = scope; self.inputGeneration = inputGeneration; self.fingerprint = fingerprint
        self.bounds = bounds; self.renderer = renderer; self.visibilityEvidence = visibilityEvidence
        self.captureNotes = captureNotes; self.validate = validate; self.validateEvent = validateEvent
    }
}

/// Window-only capture and input. Trust, focus and visible renderer are supplied
/// by the Host, then checked again at every asynchronous/event boundary.
@MainActor
final class PeelAgentWindowControl {
    private var leases = PeelAgentControlLeases()
    private var operation: UUID?
    private var inputOperation: UUID?
    private let captureWindow: @Sendable (UInt32, CGRect) -> PeelAgentWindowSnapshot?
    private let uptime: () -> Double
    init(capture: (@Sendable (UInt32, CGRect) -> PeelAgentWindowSnapshot?)? = nil,
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        captureWindow = capture ?? Self.capture
        self.uptime = uptime
    }
    var onStatus: (String) -> Void = { _ in }
    var isBusy: Bool { operation != nil }

    func replace(scope: PeelAgentPresentationScope, instances: [PeelAgentWindowInstanceFingerprint]) {
        leases.replace(scope: scope, instances: instances, now: uptime())
    }
    func token(windowID: UInt32) -> String? { leases.entry(windowID: windowID)?.token }
    func cancel(input: InputSynthesizer, reason: String) {
        let ownedInput = inputOperation
        operation = nil; inputOperation = nil; leases.clear()
        if let ownedInput { input.cancelAgentOperation(operationID: ownedInput) }
        onStatus(reason)
    }

    func handle(_ request: PeelLocalAgentRequest, context: PeelAgentControlContext,
                input: InputSynthesizer, completion: @escaping PeelLocalAgentServer.Completion) {
        func fail(_ code: String, _ message: String) { completion(.failure(.init(code: code, message: message))) }
        let params = request.params
        let isInspection = request.method == .inspectWindow
        let scope = context.scope
        let now = uptime()
        guard case .string(let token) = params["windowToken"], token.utf8.count == 36,
              let listed = leases.validate(windowID: context.fingerprint.windowID, token: token,
                scope: scope, fingerprint: context.fingerprint, now: now) else {
            fail("window_changed", "List windows again. The exact window identity or 30-second token has changed."); return
        }
        guard !isBusy else { fail("busy", "Another agent inspection or input operation is in progress."); return }
        guard request.lifetime.isActive, context.validate() else { fail("target_unavailable", "Window focus, consent, stream or paired session changed."); return }
        let command: PeelAgentControlCommand?
        if isInspection {
            guard Set(params.keys) == ["targetPairingId", "windowId", "windowToken"] else {
                fail("invalid_params", "Inspect requires only targetPairingId, windowId and windowToken."); return
            }
            command = nil
        } else {
            guard let parsed = PeelAgentControlCommand.parse(params), case .string(let inspectionID) = params["inspectionId"],
                  inspectionID.utf8.count == 36 else {
                fail("invalid_params", "Use a bounded click, type, key, scroll or drag with a fresh inspectionId."); return
            }
            guard leases.hasInspection(id: inspectionID, listed: listed, renderer: context.renderer,
                bounds: context.boundsValues, now: now) else {
                fail("inspection_required", "Inspect this exact active window again; each inspection authorizes one action for 10 seconds."); return
            }
            command = parsed
        }
        guard leases.admit(now: now, inspection: isInspection) else {
            fail("rate_limited", "Wait up to 250 ms before another capture or another input action. The inspection remains valid until its expiry."); return
        }
        if !isInspection, case .string(let inspectionID) = params["inspectionId"] {
            guard leases.takeInspection(id: inspectionID, listed: listed, renderer: context.renderer,
                bounds: context.boundsValues, now: now) else {
                fail("inspection_required", "Inspect this exact active window again."); return
            }
        }
        let id = UUID(); operation = id
        onStatus("Agent \(isInspection ? "inspecting" : command!.action.rawValue): \(String(context.fingerprint.appName.prefix(80)))")
        if isInspection {
            let windowID = context.fingerprint.windowID
            let bounds = context.bounds
            let capture = captureWindow
            Task { [weak self] in
                let snapshot = await Task.detached(priority: .userInitiated) { capture(windowID, bounds) }.value
                guard let self else { return }
                guard self.operation == id else {
                    completion(.failure(.init(code: "cancelled", message: "Agent inspection was stopped."))); return
                }
                self.operation = nil
                guard request.lifetime.isActive, context.validate(), DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds else {
                    self.onStatus("Agent inspection cancelled")
                    completion(.failure(.init(code: "target_unavailable", message: "The window changed during capture."))); return
                }
                guard let snapshot else {
                    self.onStatus("Agent capture unavailable")
                    completion(.failure(.init(code: "capture_unavailable", message: "Window capture failed. Screen Recording permission and a visible Mac window are required."))); return
                }
                let inspection = self.leases.inspect(listed, renderer: context.renderer,
                    bounds: context.boundsValues, now: self.uptime())
                self.onStatus("Agent inspected \(String(context.fingerprint.appName.prefix(80)))")
                completion(.success(.object([
                    "status": .string("captured"), "windowId": .integer(Int64(windowID)),
                    "inspectionId": .string(inspection.id), "expiresInSeconds": .integer(10),
                    "width": .integer(Int64(snapshot.width)), "height": .integer(Int64(snapshot.height)),
                    "mimeType": .string("image/jpeg"), "imageBase64": .string(snapshot.data.base64EncodedString()),
                    "visibilityEvidence": .string(context.visibilityEvidence),
                    "notes": .string(context.captureNotes)
                ])))
            }
            return
        }
        guard let command else { return }
        inputOperation = id
        let accepted = input.performAgentOperation(controlGeneration: context.inputGeneration, operationID: id,
            allowed: { [weak self] in self?.operation == id && request.lifetime.isActive && context.validate() && DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds },
            eventAllowed: context.validateEvent,
            point: { x, y in CGPoint(x: context.bounds.minX + x * context.bounds.width, y: context.bounds.minY + y * context.bounds.height) },
            completion: { [weak self] posted, finished in
                guard let self else { return }
                let current = self.operation == id
                if current { self.operation = nil }
                if self.inputOperation == id { self.inputOperation = nil }
                // Local text posts one down/up per bounded Unicode run (InputSynthesizer).
                let minimum = command.action == .type && InputSynthesizer.isLocalControlGeneration(context.inputGeneration)
                    ? PeelKeyboardEventFactory.unicodeRunCount(command.text) * 2 : command.minimumPostedEvents
                let complete = current && finished && posted >= minimum
                self.onStatus(complete ? "Agent posted \(command.action.rawValue) to \(String(context.fingerprint.appName.prefix(80)))" : "Agent input stopped; inspect before retrying")
                // A partial operation is never retried automatically: text/keys
                // may already have affected the application.
                completion(.success(.object([
                    "status": .string(complete ? "events_posted" : "interrupted"),
                    "action": .string(command.action.rawValue), "postedEvents": .integer(Int64(posted)),
                    "windowId": .integer(Int64(context.fingerprint.windowID)),
                    "applicationDeliveryVerified": .bool(false), "remotePresentationVerified": .bool(context.remotePresentationVerified),
                    "nextStep": .string("Inspect the window to verify the result. Do not blindly retry interrupted input.")
                ])))
            }) { synth in
                let windowID = context.fingerprint.windowID
                switch command.action {
                case .click: synth.performClick(windowId: windowID, normX: command.x, normY: command.y, button: command.button)
                case .type: synth.handleKeyboardText(.init(text: command.text, windowId: windowID))
                case .key:
                    let modifiers = command.modifiers.compactMap(KeyboardCommand.init(rawValue:))
                    if let key = KeyboardCommand(rawValue: command.key) {
                        synth.handleKeyboardCommand(.init(command: key, windowId: windowID, modifiers: modifiers, action: .press))
                    } else {
                        synth.handleKeyboardHardwareKey(.init(windowId: windowID, keyCode: -1,
                            charactersIgnoringModifiers: command.key, modifiers: modifiers, action: .press))
                    }
                case .scroll: synth.performScroll(windowId: windowID, deltaX: command.deltaX, deltaY: command.deltaY)
                case .drag: synth.performAgentDrag(windowId: windowID, fromX: command.x, fromY: command.y, toX: command.toX, toY: command.toY)
                }
            }
        if !accepted {
            operation = nil
            if inputOperation == id { inputOperation = nil }
            onStatus("Agent input not admitted")
            fail("busy", "The input path is busy, holding user input or no longer authorized. Inspect before retrying.")
        }
    }

    private nonisolated static func capture(windowID: UInt32, bounds: CGRect) -> PeelAgentWindowSnapshot? {
        // Same WindowServer capture primitive as Peel's snapshot stream, always
        // isolated to this window. No desktop or unrelated-window fallback.
        guard CGPreflightScreenCaptureAccess(),
              let image = CGWindowListCreateImageShim(bounds, [.optionIncludingWindow, .excludeDesktopElements], windowID, [.boundsIgnoreFraming]),
              image.width > 1, image.height > 1 else { return nil }
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let width = max(2, Int(Double(image.width) * scale)), height = max(2, Int(Double(image.height) * scale))
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = canvas.makeImage() else { return nil }
        for quality in [0.65, 0.4, 0.2] {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), bytes.length <= 120_000 {
                return PeelAgentWindowSnapshot(data: bytes as Data, width: width, height: height)
            }
        }
        return nil
    }
}
