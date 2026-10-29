import Foundation

/// Pure boundary rules shared by the native controller and exact-source tests.
nonisolated enum PeelAgentControlAction: String, Sendable { case click, type, key, scroll, drag }
nonisolated struct PeelAgentControlCommand: Sendable {
    let action: PeelAgentControlAction
    var x = 0.5, y = 0.5, toX = 0.5, toY = 0.5, deltaX = 0.0, deltaY = 0.0
    var text = "", key = "", button = "left"
    var modifiers: [String] = []
    static let namedKeys: Set<String> = ["backspace", "delete", "forwardDelete", "enter", "returnKey", "space", "tab", "escape", "leftArrow", "rightArrow", "upArrow", "downArrow", "home", "end", "pageUp", "pageDown", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]
    static let modifierKeys: Set<String> = ["command", "option", "control", "shift"]
    static let baseKeys: Set<String> = ["targetPairingId", "windowId", "windowToken", "inspectionId"]
    static func parse(_ params: [String: PeelLocalAgentJSONValue]) -> Self? {
        guard case .string(let raw) = params["action"], let action = PeelAgentControlAction(rawValue: raw) else { return nil }
        var result = Self(action: action)
        let fields: Set<String>
        switch action {
        case .click: fields = ["x", "y", "button"]
        case .type: fields = ["text"]
        case .key: fields = ["key", "modifiers"]
        case .scroll: fields = ["deltaX", "deltaY"]
        case .drag: fields = ["x", "y", "toX", "toY"]
        }
        guard Set(params.keys).isSubset(of: baseKeys.union(fields).union(["action"])) else { return nil }
        func number(_ key: String, range: ClosedRange<Double>) -> Double? {
            let value: Double
            switch params[key] { case .number(let n): value = n; case .integer(let n): value = Double(n); default: return nil }
            return value.isFinite && range.contains(value) ? value : nil
        }
        switch action {
        case .click, .drag:
            guard let x = number("x", range: 0...1), let y = number("y", range: 0...1) else { return nil }
            result.x = x; result.y = y
            if action == .drag {
                guard let x = number("toX", range: 0...1), let y = number("toY", range: 0...1) else { return nil }
                result.toX = x; result.toY = y
            } else if let value = params["button"] {
                guard case .string(let button) = value, ["left", "right"].contains(button) else { return nil }
                result.button = button
            }
        case .type:
            guard case .string(let text) = params["text"], !text.isEmpty, text.utf8.count <= 1024,
                  text.unicodeScalars.count <= 512,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            result.text = text
        case .key:
            guard case .string(let key) = params["key"], namedKeys.contains(key) ||
                    (key.utf8.count == 1 && key.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }) else { return nil }
            result.key = key
            if let value = params["modifiers"] {
                guard case .array(let values) = value, values.count <= 4 else { return nil }
                var modifiers: [String] = []
                for value in values { guard case .string(let modifier) = value, modifierKeys.contains(modifier), !modifiers.contains(modifier) else { return nil }; modifiers.append(modifier) }
                result.modifiers = modifiers
            }
        case .scroll:
            guard let x = number("deltaX", range: -1200...1200), let y = number("deltaY", range: -1200...1200),
                  abs(x) >= 2 || abs(y) >= 2 else { return nil }
            result.deltaX = x; result.deltaY = y
        }
        return result
    }
    var minimumPostedEvents: Int {
        switch action { case .click: 2; case .type: text.unicodeScalars.count * 2; case .key: (modifiers.count + 1) * 2; case .scroll: 1; case .drag: 13 }
    }
}

nonisolated struct PeelAgentControlLeases {
    struct Listed: Sendable {
        let token: String
        let scope: PeelAgentPresentationScope
        let fingerprint: PeelAgentWindowInstanceFingerprint
        let issuedAt: Double
    }
    struct Inspected: Sendable {
        let id: String
        let listed: Listed
        let renderer: UUID
        let bounds: [Double]
        let issuedAt: Double
    }
    private var listed: [UInt32: Listed] = [:]
    private var inspections: [String: Inspected] = [:]
    private var lastCaptureAdmission: Double?
    private var lastInputAdmission: Double?
    mutating func replace(scope: PeelAgentPresentationScope, instances: [PeelAgentWindowInstanceFingerprint], now: Double) {
        listed.removeAll(); inspections.removeAll()
        for fingerprint in instances.prefix(128) where !fingerprint.isDisplay && fingerprint.hasDurableIdentity {
            listed[fingerprint.windowID] = Listed(token: UUID().uuidString, scope: scope, fingerprint: fingerprint, issuedAt: now)
        }
    }
    func entry(windowID: UInt32) -> Listed? { listed[windowID] }
    func validate(windowID: UInt32, token: String, scope: PeelAgentPresentationScope,
                  fingerprint: PeelAgentWindowInstanceFingerprint, now: Double) -> Listed? {
        guard let entry = listed[windowID], entry.token == token, entry.scope == scope,
              entry.fingerprint == fingerprint, now >= entry.issuedAt, now - entry.issuedAt <= 30 else { return nil }
        return entry
    }
    mutating func inspect(_ entry: Listed, renderer: UUID, bounds: [Double], now: Double) -> Inspected {
        inspections = inspections.filter { now >= $0.value.issuedAt && now - $0.value.issuedAt <= 10 }
        if inspections.count >= 4 { inspections.removeAll() }
        let value = Inspected(id: UUID().uuidString, listed: entry, renderer: renderer, bounds: bounds, issuedAt: now)
        inspections[value.id] = value; return value
    }
    func hasInspection(id: String, listed entry: Listed, renderer: UUID, bounds: [Double], now: Double) -> Bool {
        guard let value = inspections[id], value.listed.token == entry.token,
              value.listed.scope == entry.scope, value.renderer == renderer, value.bounds == bounds,
              now >= value.issuedAt, now - value.issuedAt <= 10 else { return false }
        return true
    }
    mutating func takeInspection(id: String, listed entry: Listed, renderer: UUID, bounds: [Double], now: Double) -> Bool {
        let matches = hasInspection(id: id, listed: entry, renderer: renderer, bounds: bounds, now: now)
        inspections.removeValue(forKey: id)
        return matches
    }
    mutating func admit(now: Double, inspection: Bool = false) -> Bool {
        let previous = inspection ? lastCaptureAdmission : lastInputAdmission
        guard previous.map({ now >= $0 && now - $0 >= 0.25 }) ?? true else { return false }
        if inspection { lastCaptureAdmission = now } else { lastInputAdmission = now }
        return true
    }
    mutating func clear() { listed.removeAll(); inspections.removeAll(); lastCaptureAdmission = nil; lastInputAdmission = nil }
}
