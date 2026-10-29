import SwiftUI
import UIKit

// MARK: - Delegate that PeeledWindowView implements via KeyboardBridge
protocol InvisibleTextInputDelegate: AnyObject {
    func didInsertText(_ text: String)
    func didPressBackspace()
    func didPressEnter()
    func didPressTab()
    func didPressKeyboardCommand(_ command: KeyboardCommand)
    func didPressKeyboardHardwareKey(
        keyCode: Int,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: [KeyboardCommand]
    )
}

extension InvisibleTextInputDelegate {
    func didPressTab() {}
    func didPressKeyboardCommand(_ command: KeyboardCommand) {}
    func didPressKeyboardHardwareKey(
        keyCode: Int,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: [KeyboardCommand]
    ) {}
}

// MARK: - Hidden UITextField that captures all keystrokes
final class InvisibleUITextField: UITextField, UITextFieldDelegate {

    weak var inputDelegate2: InvisibleTextInputDelegate?

    override var canBecomeFirstResponder: Bool { true }

    // Capture *all* text input (software + hardware)
    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {

        print("InvisibleUITextField replacementString = '\(string)'")

        if string.isEmpty {
            // Backspace
            inputDelegate2?.didPressBackspace()
        } else {
            // Normal printable text (may be multi-character)
            inputDelegate2?.didInsertText(string)
        }

        // Keep field visually empty
        return false
    }

    // Optional extra safety so hardware backspace isn't missed
    override func deleteBackward() {
        print("InvisibleUITextField deleteBackward (fallback)")
        inputDelegate2?.didPressBackspace()
        // Don't call super; we don't hold text
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()

        for press in presses {
            guard let key = press.key, handleHardwareKey(key) else {
                unhandled.insert(press)
                continue
            }
        }

        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    private func handleHardwareKey(_ key: UIKey) -> Bool {
        let shortcutModifierFlags: UIKeyModifierFlags = [.command, .control, .alternate]
        let hasShortcutModifier = !key.modifierFlags.intersection(shortcutModifierFlags).isEmpty

        if hasShortcutModifier {
            inputDelegate2?.didPressKeyboardHardwareKey(
                keyCode: Int(key.keyCode.rawValue),
                characters: key.characters.isEmpty ? nil : key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers.isEmpty ? nil : key.charactersIgnoringModifiers,
                modifiers: key.peelKeyboardCommandModifiers
            )
            return true
        }

        switch key.keyCode {
        case .keyboardDeleteOrBackspace:
            inputDelegate2?.didPressBackspace()
            return true
        case .keyboardReturnOrEnter:
            inputDelegate2?.didPressEnter()
            return true
        case .keyboardTab:
            inputDelegate2?.didPressTab()
            return true
        case .keyboardEscape:
            inputDelegate2?.didPressKeyboardCommand(.escape)
            return true
        case .keyboardLeftArrow:
            inputDelegate2?.didPressKeyboardCommand(.leftArrow)
            return true
        case .keyboardRightArrow:
            inputDelegate2?.didPressKeyboardCommand(.rightArrow)
            return true
        case .keyboardUpArrow:
            inputDelegate2?.didPressKeyboardCommand(.upArrow)
            return true
        case .keyboardDownArrow:
            inputDelegate2?.didPressKeyboardCommand(.downArrow)
            return true
        default:
            break
        }

        guard !key.characters.isEmpty else { return false }
        inputDelegate2?.didInsertText(key.characters)
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        print("InvisibleUITextField Return key")
        inputDelegate2?.didPressEnter()
        return false  // keep keyboard up
    }
}

private extension UIKey {
    var peelKeyboardCommandModifiers: [KeyboardCommand] {
        var result: [KeyboardCommand] = []
        if modifierFlags.contains(.command) {
            result.append(.command)
        }
        if modifierFlags.contains(.shift) {
            result.append(.shift)
        }
        if modifierFlags.contains(.alternate) {
            result.append(.option)
        }
        if modifierFlags.contains(.control) {
            result.append(.control)
        }
        if modifierFlags.contains(.alphaShift) {
            result.append(.shift)
        }
        return result
    }
}

// MARK: - SwiftUI wrapper
struct InvisibleTextInput: UIViewRepresentable {

    @Binding var isFocused: Bool
    var delegate: InvisibleTextInputDelegate?

    func makeUIView(context: Context) -> InvisibleUITextField {
        let tf = InvisibleUITextField()
        tf.delegate = tf
        tf.inputDelegate2 = delegate

        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.spellCheckingType = .no

        tf.backgroundColor = .clear
        tf.tintColor = .clear
        tf.textColor = .clear
        tf.alpha = 0.01
        tf.isHidden = false

        // Grab focus as soon as we're in the hierarchy
        DispatchQueue.main.async {
            tf.becomeFirstResponder()
        }

        return tf
    }

    func updateUIView(_ uiView: InvisibleUITextField, context: Context) {
        uiView.inputDelegate2 = delegate

        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}
