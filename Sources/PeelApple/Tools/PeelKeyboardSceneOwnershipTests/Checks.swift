import Foundation

var failures = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { failures += 1; print("FAIL: \(message)") }
}
enum Phase { case active, inactive, background }
enum Activation { case foregroundActive, foregroundInactive, background }
final class Scene {
    var activationState: Activation = .foregroundActive
    var windows: [Window] = []
}
final class Window {
    var isKeyWindow = true
    var windowScene: Scene?
    init(_ scene: Scene) { windowScene = scene; scene.windows.append(self) }
}
struct PresentedWindow { let windowId: UInt32 }
final class Session {
    var activeWindowId: UInt32? = 42
    var claims: [UInt32] = []
    var focusRequests: [UInt32] = []
    func setActiveWindow(_ id: UInt32) { activeWindowId = id; claims.append(id) }
    func requestHostFocusForWindow(_ id: UInt32) { focusRequests.append(id) }
}
enum GCKeyboard { static var coalesced: Bool? = true }
enum GCMouse { static func mice() -> [Bool] { [] } }
struct Animation { static func easeInOut(duration: Double) -> Animation { Animation() } }
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
final class ViewState {
    var workspaceAllowsInput = true
    var workspaceInputAdmission: () -> Bool = { true }
    var workspaceIsVisible = true
    var scenePhase: Phase = .active
    var currentScene: Scene?
    let runtimeSession: Session
    let presentedWindow: PresentedWindow
    var keyboardEnabled = false
    var keyboardFocused = false
    var isFocusedBridge = false
    var keyboardFocusRequestID = 0
    var isExternalKeyboardConnected = false
    var lastFocusRequestAt: Date? = nil
    let focusRequestMinInterval: TimeInterval = 0.35
    func isInputReadyForWindow(_ window: PresentedWindow) -> Bool { false }
    init(_ id: UInt32, _ scene: Scene, _ session: Session) {
        presentedWindow = PresentedWindow(windowId: id); currentScene = scene; runtimeSession = session
    }
    // VIEW METHODS
}

final class WorkItem {
    var cancelled = false
    let body: () -> Void
    init(block: @escaping () -> Void) { body = block }
    func cancel() { cancelled = true }
    func perform() { if !cancelled { body() } }
}
final class Scheduler {
    static let main = Scheduler()
    static var now: Double = 0
    var jobs: [(Double, () -> Void)] = []
    func async(execute: @escaping () -> Void) { jobs.append((Self.now, execute)) }
    func asyncAfter(deadline: Double, execute: @escaping () -> Void) { jobs.append((deadline, execute)) }
    func asyncAfter(deadline: Double, execute: WorkItem) { jobs.append((deadline, { execute.perform() })) }
    func drain(until: Double) {
        while let index = jobs.indices.filter({ jobs[$0].0 <= until }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: index); Self.now = job.0; job.1()
        }
        Self.now = until
    }
    func reset() { jobs = []; Self.now = 0 }
}
final class CancelToken { func cancel() {} }
enum KeyboardCommand {
    case command, shift, control, option, backspace, enter, tab, escape, forwardDelete
    case home, end, pageUp, pageDown, leftArrow, rightArrow, upArrow, downArrow
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}
enum KeyCode: Int {
    case keyboardA, keyboardDeleteOrBackspace, keyboardReturnOrEnter, keyboardTab, keyboardEscape
    case keyboardDeleteForward, keyboardHome, keyboardEnd, keyboardPageUp, keyboardPageDown
    case keyboardLeftArrow, keyboardRightArrow, keyboardUpArrow, keyboardDownArrow
    case keyboardF1, keyboardF2, keyboardF3, keyboardF4, keyboardF5, keyboardF6
    case keyboardF7, keyboardF8, keyboardF9, keyboardF10, keyboardF11, keyboardF12
}
struct UIKeyModifierFlags: OptionSet {
    let rawValue: Int
    static let command = Self(rawValue: 1), shift = Self(rawValue: 2)
    static let control = Self(rawValue: 4), alternate = Self(rawValue: 8)
}
struct UIKey {
    var keyCode: KeyCode = .keyboardReturnOrEnter
    var modifierFlags: UIKeyModifierFlags = []
    var characters = "", charactersIgnoringModifiers = ""
}
final class UIPress: NSObject { var key: UIKey?; init(_ key: UIKey) { self.key = key } }
final class UIPressesEvent {}
final class TextSink {
    var values: [String] = [], commands: [KeyboardCommand] = []
    var hardwareCount = 0
    func didInsertText(_ text: String) { values.append(text) }
    func didPressEnter() { commands.append(.enter) }
    func didPressBackspace() { commands.append(.backspace) }
    func didPressKeyboardCommand(_ command: KeyboardCommand) { commands.append(command) }
    func didPressKeyboardHardwareKey(keyCode: Int, characters: String?, charactersIgnoringModifiers: String?, modifiers: [KeyboardCommand]) { hardwareCount += 1 }
}
func CACurrentMediaTime() -> Double { Scheduler.now }
class Responder {
    var window: Window?
    var isFirstResponder = false
    var focusCalls = 0
    var rejectedFocusAttempts = 0
    var canBecomeFirstResponder: Bool { true }
    var localText = ""
    func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}
    func insertText(_ text: String) { localText += text }
    func deleteBackward() { if !localText.isEmpty { localText.removeLast() } }
    func didMoveToWindow() {}
    func becomeFirstResponder() -> Bool {
        focusCalls += 1
        guard canBecomeFirstResponder else { return false }
        if rejectedFocusAttempts > 0 { rejectedFocusAttempts -= 1; return false }
        isFirstResponder = true; return true
    }
    func resignFirstResponder() -> Bool { isFirstResponder = false; return true }
}
final class Capture: Responder {
    var onFocusChanged: ((Bool) -> Void)?
    var focusRequestGeneration = 0
    var focusRetryWorkItems: [WorkItem] = []
    var keyboardOwnershipObservers: [NSObjectProtocol] = []
    var keyboardWillHideObserver: NSObjectProtocol?
    var requestedKeyboardFocus = false
    var sceneInputOwner: () -> Bool = { false }
    var isSuspendingInputOwnership = false
    var compositionFlushTask: CancelToken?
    var pendingComposedText = ""
    var isDictationActive = false
    var isMacroHoldModeEnabled = false
    var markedTextRange: Bool? = nil
    var isCurrentInputModeDictation = false
    var lastComposedTextFlushAt: Double = 0
    let keyDelegate: TextSink? = TextSink()
    var focusChanges: [Bool] = []
    override init() { super.init(); onFocusChanged = { [weak self] in self?.focusChanges.append($0) } }
    func rememberEmittedText(_ text: String) {}
    func syncObservedTextAfterLocalDeletion() {}
    func resetCapturedTextStorage() { pendingComposedText = "" }
    func scheduleComposedTextFlush() { Scheduler.main.asyncAfter(deadline: Scheduler.now + 0.65) { [weak self] in self?.flushPendingComposedText() } }
    // CAPTURE METHODS
}

let session = Session()
let oldScene = Scene(), newScene = Scene()
let oldWindow = Window(oldScene), newWindow = Window(newScene)
let old = ViewState(34, oldScene, session), current = ViewState(42, newScene, session)
oldScene.activationState = .background; old.scenePhase = .background
old.refreshExternalInputState(autoEnableKeyboard: true)
current.refreshExternalInputState(autoEnableKeyboard: true)
check(session.claims == [42] && !old.keyboardEnabled && current.keyboardEnabled,
      "one global keyboard connect cannot let a restored background scene claim input")
session.claims = []; old.scenePhase = .active; oldScene.activationState = .foregroundActive
old.refreshExternalInputState(autoEnableKeyboard: true)
check(session.claims.isEmpty, "two active key scenes do not override the selected window on device broadcast")
current.keyboardEnabled = false; newWindow.isKeyWindow = false
current.refreshExternalInputState(autoEnableKeyboard: true)
check(!current.keyboardEnabled, "non-key scene cannot acquire automatic keyboard ownership")
newWindow.isKeyWindow = true; newScene.activationState = .foregroundInactive
current.refreshExternalInputState(autoEnableKeyboard: true)
check(!current.keyboardEnabled, "native inactive scene is denied even before SwiftUI phase catches up")
newScene.activationState = .foregroundActive
oldScene.activationState = .background; old.scenePhase = .background
old.setSoftwareKeyboardActive(true)
check(old.keyboardEnabled && session.activeWindowId == 42, "hidden manual intent is retained without selecting its window")
old.handleKeyboardFocusChanged(false)
check(old.keyboardEnabled, "late hidden resign callback cannot erase saved keyboard intent")
oldScene.activationState = .foregroundActive; old.scenePhase = .active
old.refreshKeyboardInputOwnership()
check(session.activeWindowId == 34 && old.keyboardFocusRequestID == 1, "eligible scene resumes manual keyboard intent")
old.handleKeyboardFocusChanged(false)
check(!old.keyboardEnabled && !old.isFocusedBridge, "real manual dismissal clears intent in the eligible owner")

Scheduler.main.reset()
let capture = Capture(); capture.window = newWindow
capture.applyFocus(true, force: true, isInputOwner: { true })
newWindow.isKeyWindow = false
Scheduler.main.drain(until: 0)
check(capture.focusCalls == 0, "queued focus rechecks live UIWindow ownership at execution")
check(!capture.becomeFirstResponder(), "direct native focus cannot bypass current UIWindow eligibility")
newWindow.isKeyWindow = true
capture.applyFocus(true, force: true, isInputOwner: { true })
Scheduler.main.drain(until: 0)
check(capture.isFirstResponder, "eligible owner accepts normal focus")
let beforeRetries = capture.focusCalls
capture.isFirstResponder = false; newScene.activationState = .background
Scheduler.main.drain(until: 0.30)
check(capture.focusCalls == beforeRetries, "delayed retries cannot reclaim background focus")
newScene.activationState = .foregroundActive
capture.applyFocus(true, force: true, isInputOwner: { true })
Scheduler.main.drain(until: 0.30)
capture.pendingComposedText = "owned composition"
let beforeLoss = capture.focusChanges
newScene.activationState = .foregroundInactive
capture.applyFocus(true, force: false, isInputOwner: { true })
Scheduler.main.drain(until: 0.30)
check(!capture.isFirstResponder && capture.requestedKeyboardFocus && capture.pendingComposedText == "owned composition",
      "inactive transition releases actual responder and preserves intent/composition")
check(capture.focusChanges == beforeLoss, "ownership-loss resign does not masquerade as manual keyboard dismissal")
capture.flushPendingComposedText()
check(capture.keyDelegate!.values.isEmpty && capture.pendingComposedText == "owned composition",
      "late composition work cannot send or refocus an inactive scene")
newScene.activationState = .foregroundActive
capture.applyFocus(true, force: true, isInputOwner: { true })
Scheduler.main.drain(until: 1)
check(capture.isFirstResponder && capture.keyDelegate!.values == ["owned composition"], "resume delivers retained composition exactly once")
capture.pendingComposedText = "manual hide"
capture.applyFocus(false, force: false, isInputOwner: { true })
Scheduler.main.drain(until: 1)
check(capture.keyDelegate!.values == ["owned composition", "manual hide"] && capture.focusChanges.last == false,
      "manual hide in the owner still flushes committed text")
capture.applyFocus(true, force: true, isInputOwner: { true })
capture.stopManagingFocus()
let callsBeforeStopDrain = capture.focusCalls
Scheduler.main.drain(until: 2)
check(capture.focusCalls == callsBeforeStopDrain && !capture.isFirstResponder,
      "dismantled capture cannot execute already queued focus work")
check(!capture.requestedKeyboardFocus && !capture.sceneInputOwner(), "dismantle retires both intent and ownership")
Scheduler.main.reset()
let switching = Capture(); switching.window = newWindow
session.activeWindowId = 42
switching.applyFocus(true, force: true, isInputOwner: { session.activeWindowId == 42 })
session.activeWindowId = 34
Scheduler.main.drain(until: 0)
check(switching.focusCalls == 0, "queued focus reads live selection before SwiftUI updates the old capture")
Scheduler.main.reset()
let retrying = Capture(); retrying.window = newWindow
retrying.rejectedFocusAttempts = 1
retrying.pendingComposedText = "retry composition"
retrying.applyFocus(true, force: true, isInputOwner: { true })
Scheduler.main.drain(until: 0)
check(!retrying.isFirstResponder && retrying.keyDelegate!.values.isEmpty, "initial focus failure retains pending composition")
Scheduler.main.drain(until: 1)
check(retrying.isFirstResponder && retrying.keyDelegate!.values == ["retry composition"],
      "successful delayed focus retry resumes retained composition without another SwiftUI update")
let direct = Capture(); direct.window = newWindow
session.activeWindowId = 42
direct.applyFocus(true, force: true, isInputOwner: { session.activeWindowId == 42 })
Scheduler.main.drain(until: 1)
session.activeWindowId = 34 // old responder has not yet received a SwiftUI update/resign
let returnKey = UIKey()
direct.pressesBegan([UIPress(returnKey)], with: nil)
check(!direct.handleHardwareKey(returnKey), "late old-scene hardware input does not claim the shared target")
direct.insertText("\n"); direct.deleteBackward()
direct.isMacroHoldModeEnabled = true; direct.insertText("macro")
check(direct.keyDelegate!.commands.isEmpty && direct.keyDelegate!.values.isEmpty,
      "late Return, Backspace and macro text cannot dispatch from a retired input owner")
session.activeWindowId = 42
check(direct.handleHardwareKey(returnKey), "current owner retains external hardware Return")
direct.insertText("macro"); direct.deleteBackward()
check(direct.keyDelegate!.commands == [.enter, .backspace] && direct.keyDelegate!.values == ["macro"],
      "eligible manual hardware and macro actions retain their normal behavior")

let workspaceSession = Session()
let workspaceScene = Scene()
let workspaceWindow = Window(workspaceScene)
let passivePane = ViewState(42, workspaceScene, workspaceSession)
passivePane.workspaceAllowsInput = false
passivePane.refreshExternalInputState(autoEnableKeyboard: true)
passivePane.setSoftwareKeyboardActive(true)
check(workspaceSession.claims.isEmpty && !passivePane.isKeyboardInputOwner,
      "a passive workspace pane cannot select itself or own input even in the key scene")
passivePane.workspaceAllowsInput = true
passivePane.workspaceIsVisible = false
passivePane.refreshKeyboardInputOwnership()
check(workspaceSession.claims.isEmpty && !passivePane.isKeyboardInputOwner,
      "a compact hidden workspace pane cannot reacquire saved keyboard intent")
passivePane.workspaceIsVisible = true
passivePane.refreshKeyboardInputOwnership()
check(workspaceSession.claims == [42] && passivePane.isKeyboardInputOwner,
      "the selected visible workspace pane can resume its explicit keyboard intent")
workspaceSession.claims.removeAll()
var showingWorkspacePicker = true
passivePane.workspaceInputAdmission = { !showingWorkspacePicker }
passivePane.refreshKeyboardInputOwnership()
check(workspaceSession.claims.isEmpty && !passivePane.isKeyboardInputOwner,
      "live modal admission rejects keyboard ownership before rendered pane flags catch up")
showingWorkspacePicker = false
passivePane.refreshKeyboardInputOwnership()
check(workspaceSession.claims == [42] && passivePane.isKeyboardInputOwner,
      "closing the picker restores selected pane keyboard admission")
workspaceSession.claims.removeAll()
showingWorkspacePicker = true
passivePane.requestFocusForPresentedWindow(reason: "queued modal gesture")
check(workspaceSession.focusRequests.isEmpty && workspaceSession.claims.isEmpty,
      "a failed live modal admission cannot fall back into requesting Mac focus")
showingWorkspacePicker = false
passivePane.workspaceAllowsInput = false
passivePane.requestFocusForPresentedWindow(reason: "passive pane")
check(workspaceSession.focusRequests.isEmpty, "passive pane cannot use the not-ready focus fallback")
passivePane.workspaceAllowsInput = true
passivePane.workspaceIsVisible = false
passivePane.requestFocusForPresentedWindow(reason: "hidden pane")
check(workspaceSession.focusRequests.isEmpty, "hidden pane cannot use the not-ready focus fallback")
passivePane.workspaceIsVisible = true
passivePane.requestFocusForPresentedWindow(reason: "selected unconfirmed pane")
check(workspaceSession.focusRequests == [42], "selected current pane can still request missing Host focus confirmation")
print("Keyboard scene ownership checks: \(failures == 0 ? "PASS" : "FAIL")")
exit(failures == 0 ? 0 : 1)
