//
//  PeelUITestHarnessUITests.swift
//  PeelUITestHarnessUITests
//
//  Created by Zach on 8/28/26.
//

import XCTest

final class PeelUITestHarnessUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRemoteTextInputWithoutSimulatorFocusSteal() throws {
        let expectedToken = ProcessInfo.processInfo.environment["PEEL_E2E_TOKEN"]
            ?? "PEEL_E2E_ONBOARD_IPAD_SIM"
        let peel = XCUIApplication(bundleIdentifier: "com.zephyrstudiosllc.Peel")
        peel.launch()

        let returnToPeel = peel.buttons["Return to Peel"]
        if returnToPeel.waitForExistence(timeout: 5) {
            // Reopen the exact TextEdit card so the test always requests a fresh
            // stream on the booted simulator it was assigned.
            returnToPeel.tap()
        }

        let textEditCard = peel.staticTexts["TextEdit"]
        XCTAssertTrue(
            textEditCard.waitForExistence(timeout: 20),
            "The onboard simulator did not receive TextEdit in the host window list"
        )

        let openButtons = peel.buttons.matching(
            NSPredicate(format: "label == %@", "Open")
        ).allElementsBoundByIndex
        let textEditOpenButton = try XCTUnwrap(
            openButtons.min {
                abs($0.frame.midY - textEditCard.frame.midY) <
                    abs($1.frame.midY - textEditCard.frame.midY)
            },
            "The TextEdit card did not expose an Open button"
        )
        textEditOpenButton.tap()
        XCTAssertTrue(
            returnToPeel.waitForExistence(timeout: 10),
            "Peel did not open the TextEdit stream scene"
        )

        let textArea = peel.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.38)
        )

        // The first tap is intentionally a focus request while the stream is in
        // Standby. Only after the Host confirms that TextEdit is frontmost may
        // Peel deliver actual input.
        textArea.tap()

        let activeStream = peel.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "TextEdit. Stream status: Active.")
        ).firstMatch
        XCTAssertTrue(
            activeStream.waitForExistence(timeout: 20),
            "TextEdit never reached Peel's host-confirmed input-ready state"
        )

        textArea.tap()

        let expandToolbar = peel.buttons["Expand toolbar"]
        if expandToolbar.exists {
            expandToolbar.tap()
        }

        let keyboardBridge = peel.textViews.firstMatch
        XCTAssertTrue(
            keyboardBridge.waitForExistence(timeout: 5),
            "The streamed window did not expose Peel's keyboard bridge"
        )
        keyboardBridge.typeText("\n\(expectedToken)")

        let rejection = peel.staticTexts["Peel could not send that input yet."]
        XCTAssertFalse(
            rejection.waitForExistence(timeout: 3),
            "The Host rejected input from the onboard iPad Simulator"
        )
    }
}
