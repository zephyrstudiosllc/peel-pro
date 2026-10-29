//
//  Input.swift
//  Peel
//
//  Created by Zach on 5/25/26.
//


import Foundation
import Combine
import Network
import ImageIO
import AVFoundation
import VideoToolbox

#if canImport(UIKit)
import UIKit
#endif

extension PeelClientBrowser {
    // MARK: - Mouse input
    
    func sendClick(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        guard let connection = connection else {
            status = "No active connection to host."
            return
        }
        
        let req = PeelRequest(
            type: "mouseClick",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        
        do {
            let data = try JSONEncoder().encode(req)
            var framed = data
            framed.append(0x0A) // newline delimiter for NDJSON
            print("PeelClient: sending mouseClick window=\(window.windowId) x=\(normX) y=\(normY) button=\(button)")
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    print("Send mouseClick error:", error.localizedDescription)
                }
            })
        } catch {
            print("Encode mouseClick error:", error.localizedDescription)
        }
    }

    func sendMouseMove(on window: PeelWindow, normX: Double, normY: Double) {
        let clampedX = min(max(normX, 0), 1)
        let clampedY = min(max(normY, 0), 1)
        let point = CGPoint(x: clampedX, y: clampedY)
        let now = Date()

        if let lastAt = lastMouseMoveSentAtByWindow[window.windowId],
           let lastPoint = lastMouseMoveNormByWindow[window.windowId] {
            let dt = now.timeIntervalSince(lastAt)
            let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)

            if dt < mouseMoveMinInterval && distance < mouseMoveMinNormalizedDistance {
                return
            }
        }

        lastMouseMoveSentAtByWindow[window.windowId] = now
        lastMouseMoveNormByWindow[window.windowId] = point
        lastNX = clampedX
        lastNY = clampedY
        selectedSession?.lastMouseMoveSentAtByWindow[window.windowId] = now
        selectedSession?.lastMouseMoveNormByWindow[window.windowId] = point
        selectedSession?.lastNX = clampedX
        selectedSession?.lastNY = clampedY

        recordHighFrequencyMouseInteractionIfNeeded(windowId: window.windowId)

        let req = PeelRequest(
            type: "mouseMove",
            windowId: window.windowId,
            normX: clampedX,
            normY: clampedY,
            button: nil
        )

        sendJSONMessage(req)
    }
    
    func sendScroll(on window: PeelWindow,
                    deltaX: Double,
                    deltaY: Double) {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        let request = PeelRequest(
            type: "mouseScroll",
            windowId: window.windowId,
            normX: deltaX,
            normY: deltaY,
            button: nil
        )
        
        sendJSONMessage(request)
    }
    
    /// Press-and-hold / drag support (Finder, sliders, selections, etc.)
    func sendMouseDown(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        forceMouseUpIfNeeded(reason: "pre-down")
        
        lastNX = normX
        lastNY = normY
        isMouseDownLocally = true
        mouseDownWindowId = window.windowId
        mouseDownButton = button
        selectedSession?.lastNX = normX
        selectedSession?.lastNY = normY
        selectedSession?.isMouseDownLocally = true
        selectedSession?.mouseDownWindowId = window.windowId
        selectedSession?.mouseDownButton = button
        let req = PeelRequest(
            type: "mouseDown",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        sendJSONMessage(req)
    }
    
    func sendMouseDrag(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        recordHighFrequencyMouseInteractionIfNeeded(windowId: window.windowId)

        lastNX = normX
        lastNY = normY
        isMouseDownLocally = true
        mouseDownWindowId = window.windowId
        mouseDownButton = button
        selectedSession?.lastNX = normX
        selectedSession?.lastNY = normY
        selectedSession?.isMouseDownLocally = true
        selectedSession?.mouseDownWindowId = window.windowId
        selectedSession?.mouseDownButton = button

        let req = PeelRequest(
            type: "mouseDrag",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        sendJSONMessage(req)
    }

    private func recordHighFrequencyMouseInteractionIfNeeded(windowId: UInt32) {
        let now = Date()
        let shouldUpdateActiveWindow = activeWindowId != windowId
        let shouldRefreshInteraction =
            lastUserInteractionWindowId != windowId ||
            now.timeIntervalSince(lastUserInteractionAt) > 0.25

        if shouldUpdateActiveWindow {
            setActiveWindow(windowId)
        }

        if shouldRefreshInteraction {
            recordUserInteraction(windowId: windowId)
        }
    }

    func sendMouseUp(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        
        lastNX = normX
        lastNY = normY
        selectedSession?.lastNX = normX
        selectedSession?.lastNY = normY
        
        let req = PeelRequest(
            type: "mouseUp",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        sendJSONMessage(req)
        
        isMouseDownLocally = false
        mouseDownWindowId = nil
        mouseDownButton = "left"
        selectedSession?.isMouseDownLocally = false
        selectedSession?.mouseDownWindowId = nil
        selectedSession?.mouseDownButton = "left"
    }
    
    internal func forceMouseUpIfNeeded(reason: String) {
        guard isMouseDownLocally, let windowId = mouseDownWindowId else { return }
        let req = PeelRequest(type: "mouseUp", windowId: windowId, normX: lastNX, normY: lastNY, button: mouseDownButton)
        sendJSONMessage(req)
        
        isMouseDownLocally = false
        mouseDownWindowId = nil
        mouseDownButton = "left"
        selectedSession?.isMouseDownLocally = false
        selectedSession?.mouseDownWindowId = nil
        selectedSession?.mouseDownButton = "left"
    }
    
    // MARK: - Keyboard input
    
    /// Send plain text typed on the client to the host so it can be injected
    /// at the current caret position on the Mac.
    func sendKeyboardText(_ text: String) {
        guard !text.isEmpty else { return }
        recordUserInteraction(windowId: activeWindowId)
        let msg = KeyboardTextMessage(text: text, windowId: activeWindowId)
        sendJSONMessage(msg)
    }
    
    /// Send a special keyboard command such as backspace, enter, or arrow keys
    /// to the host.
    func sendKeyboardCommand(_ command: KeyboardCommand) {
        recordUserInteraction(windowId: activeWindowId)
        let msg = KeyboardCommandMessage(command: command, windowId: activeWindowId)
        sendJSONMessage(msg)
    }

    /// Send a physical/external keyboard shortcut key press to the host.
    func sendKeyboardHardwareKey(
        keyCode: Int,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: [KeyboardCommand],
        action: KeyboardCommandAction = .press
    ) {
        recordUserInteraction(windowId: activeWindowId)
        let msg = KeyboardHardwareKeyMessage(
            windowId: activeWindowId,
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers,
            action: action
        )
        sendJSONMessage(msg)
    }
    
    /// Generic helper for sending any `Encodable` message as a single NDJSON line
    /// over the existing connection.
    func sendJSONMessage<T: Encodable>(_ message: T) {
        guard let connection = connection else {
            DispatchQueue.main.async {
                self.status = "No active connection to host."
                self.selectedSession?.status = self.status
            }
            return
        }
        
        let encoder = JSONEncoder()
        
        do {
            let data = try encoder.encode(message)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let framed = (line + "\n").data(using: .utf8) ?? Data()
            
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    print("Send keyboard message error:", error.localizedDescription)
                }
            })
        } catch {
            print("Encode keyboard message error:", error.localizedDescription)
        }
    }
}


// MARK: - Per-host session input
extension PeelHostSession {
    // MARK: - Mouse input
    
    func sendClick(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        guard let connection = connection else {
            status = "No active connection to host."
            return
        }
        
        let req = PeelRequest(
            type: "mouseClick",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        
        do {
            let data = try JSONEncoder().encode(req)
            var framed = data
            framed.append(0x0A) // newline delimiter for NDJSON
            print("PeelClient: sending mouseClick window=\(window.windowId) x=\(normX) y=\(normY) button=\(button)")
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    print("Send mouseClick error:", error.localizedDescription)
                }
            })
        } catch {
            print("Encode mouseClick error:", error.localizedDescription)
        }
    }

    func sendMouseMove(on window: PeelWindow, normX: Double, normY: Double) {
        let clampedX = min(max(normX, 0), 1)
        let clampedY = min(max(normY, 0), 1)
        let point = CGPoint(x: clampedX, y: clampedY)
        let now = Date()

        if let lastAt = lastMouseMoveSentAtByWindow[window.windowId],
           let lastPoint = lastMouseMoveNormByWindow[window.windowId] {
            let dt = now.timeIntervalSince(lastAt)
            let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)

            if dt < mouseMoveMinInterval && distance < mouseMoveMinNormalizedDistance {
                return
            }
        }

        lastMouseMoveSentAtByWindow[window.windowId] = now
        lastMouseMoveNormByWindow[window.windowId] = point
        lastNX = clampedX
        lastNY = clampedY

        recordHighFrequencyMouseInteractionIfNeeded(windowId: window.windowId)

        let req = PeelRequest(
            type: "mouseMove",
            windowId: window.windowId,
            normX: clampedX,
            normY: clampedY,
            button: nil
        )

        sendJSONMessage(req)
    }
    
    func sendScroll(on window: PeelWindow,
                    deltaX: Double,
                    deltaY: Double) {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        let request = PeelRequest(
            type: "mouseScroll",
            windowId: window.windowId,
            normX: deltaX,
            normY: deltaY,
            button: nil
        )
        
        sendJSONMessage(request)
    }
    
    /// Press-and-hold / drag support (Finder, sliders, selections, etc.)
    func sendMouseDown(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        forceMouseUpIfNeeded(reason: "pre-down")
        
        lastNX = normX
        lastNY = normY
        isMouseDownLocally = true
        mouseDownWindowId = window.windowId
        mouseDownButton = button
        let req = PeelRequest(
            type: "mouseDown",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        sendJSONMessage(req)
    }
    
    func sendMouseDrag(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        recordHighFrequencyMouseInteractionIfNeeded(windowId: window.windowId)

        lastNX = normX
        lastNY = normY
        isMouseDownLocally = true
        mouseDownWindowId = window.windowId
        mouseDownButton = button

        let req = PeelRequest(
            type: "mouseDrag",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        sendJSONMessage(req)
    }

    private func recordHighFrequencyMouseInteractionIfNeeded(windowId: UInt32) {
        let now = Date()
        let shouldUpdateActiveWindow = activeWindowId != windowId
        let shouldRefreshInteraction =
            lastUserInteractionWindowId != windowId ||
            now.timeIntervalSince(lastUserInteractionAt) > 0.25

        if shouldUpdateActiveWindow {
            setActiveWindow(windowId)
        }

        if shouldRefreshInteraction {
            recordUserInteraction(windowId: windowId)
        }
    }

    func sendMouseUp(on window: PeelWindow, normX: Double, normY: Double, button: String = "left") {
        setActiveWindow(window.windowId)
        recordUserInteraction(windowId: window.windowId)
        
        lastNX = normX
        lastNY = normY
        
        let req = PeelRequest(
            type: "mouseUp",
            windowId: window.windowId,
            normX: normX,
            normY: normY,
            button: button
        )
        sendJSONMessage(req)
        
        isMouseDownLocally = false
        mouseDownWindowId = nil
        mouseDownButton = "left"
    }
    
    internal func forceMouseUpIfNeeded(reason: String) {
        guard isMouseDownLocally, let windowId = mouseDownWindowId else { return }
        let req = PeelRequest(type: "mouseUp", windowId: windowId, normX: lastNX, normY: lastNY, button: mouseDownButton)
        sendJSONMessage(req)
        
        isMouseDownLocally = false
        mouseDownWindowId = nil
        mouseDownButton = "left"
    }
    
    // MARK: - Keyboard input
    
    /// Send plain text typed on the client to the host so it can be injected
    /// at the current caret position on the Mac.
    func sendKeyboardText(_ text: String) {
        guard !text.isEmpty else { return }
        recordUserInteraction(windowId: activeWindowId)
        let msg = KeyboardTextMessage(text: text, windowId: activeWindowId)
        sendJSONMessage(msg)
    }
    
    /// Send a special keyboard command such as backspace, enter, or arrow keys
    /// to the host.
    func sendKeyboardCommand(_ command: KeyboardCommand) {
        recordUserInteraction(windowId: activeWindowId)
        let msg = KeyboardCommandMessage(command: command, windowId: activeWindowId)
        sendJSONMessage(msg)
    }

    /// Send a physical/external keyboard shortcut key press to the host.
    func sendKeyboardHardwareKey(
        keyCode: Int,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: [KeyboardCommand],
        action: KeyboardCommandAction = .press
    ) {
        recordUserInteraction(windowId: activeWindowId)
        let msg = KeyboardHardwareKeyMessage(
            windowId: activeWindowId,
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers,
            action: action
        )
        sendJSONMessage(msg)
    }
    
    /// Generic helper for sending any `Encodable` message as a single NDJSON line
    /// over the existing connection.
    func sendJSONMessage<T: Encodable>(_ message: T) {
        guard let connection = connection else {
            DispatchQueue.main.async {
                self.status = "No active connection to host."
            }
            return
        }
        
        let encoder = JSONEncoder()
        
        do {
            let data = try encoder.encode(message)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let framed = (line + "\n").data(using: .utf8) ?? Data()
            
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    print("Send keyboard message error:", error.localizedDescription)
                }
            })
        } catch {
            print("Encode keyboard message error:", error.localizedDescription)
        }
    }
}
