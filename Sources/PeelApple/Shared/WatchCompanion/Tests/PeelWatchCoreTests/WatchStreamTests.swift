import XCTest
@testable import PeelWatchCore

final class WatchStreamTests: XCTestCase {
    func testOnlyReservedDisplayIDCanSkipHostWindowFocus() {
        XCTAssertFalse(WatchStreamSourcePolicy.hasInputFocus(windowID: 42, activeWindowID: 42, hostConfirmedWindowID: nil))
        XCTAssertTrue(WatchStreamSourcePolicy.hasInputFocus(windowID: 42, activeWindowID: 42, hostConfirmedWindowID: 42))
        XCTAssertFalse(WatchStreamSourcePolicy.hasInputFocus(windowID: 42, activeWindowID: 99, hostConfirmedWindowID: 42))
        XCTAssertTrue(WatchStreamSourcePolicy.hasInputFocus(windowID: 0xFFF0_0000, activeWindowID: 0xFFF0_0000, hostConfirmedWindowID: nil))
        XCTAssertTrue(WatchStreamSourcePolicy.hasInputFocus(windowID: 0xFFF0_003F, activeWindowID: 0xFFF0_003F, hostConfirmedWindowID: nil))
        XCTAssertFalse(WatchStreamSourcePolicy.hasInputFocus(windowID: 0xFFF0_0040, activeWindowID: 0xFFF0_0040, hostConfirmedWindowID: nil))
    }
    func testFrameRoundTripAndBoundsBeforeDecoding() throws {
        let info = WatchStreamInfo(sessionID: UUID(), hostName: "Surface", windowTitle: "Editor", controlToken: nil)
        let frame = WatchStreamFrame(sequence: 1, jpeg: Data(repeating: 1, count: 32_768), width: 512, height: 288, viewport: .full)
        let value = WatchStreamResponse(requestID: UUID(), info: info, frame: frame, message: "Live", accepted: true)
        let data = try value.encoded()
        XCTAssertLessThan(data.count, WatchStreamWire.maximumBytes)
        XCTAssertEqual(try WatchStreamResponse.decode(data).frame?.jpeg, frame.jpeg)
        XCTAssertThrowsError(try WatchStreamRequest.decode(Data(repeating: 65, count: 61_441)))
        XCTAssertThrowsError(try WatchStreamResponse.decode(Data("{\"version\":99}".utf8)))
        XCTAssertThrowsError(try WatchStreamFrame(sequence: 1, jpeg: Data([1]), width: 8192, height: 2, viewport: .full).validate())
        XCTAssertThrowsError(try WatchStreamFrame(sequence: 0, jpeg: Data([1]), width: 1, height: 1, viewport: .full).validate())
    }
    func testViewportCropsStayInsideSourceAtEdges() throws {
        let crop = WatchViewport.centered(zoom: 8, centerX: 1, centerY: 0)
        XCTAssertEqual(crop.x, 0.875); XCTAssertEqual(crop.y, 0); XCTAssertEqual(crop.width, 0.125)
        try crop.validate()
        XCTAssertThrowsError(try WatchViewport(x: 0.9, y: 0, width: 0.5, height: 1).validate())
        XCTAssertThrowsError(try WatchViewport(x: .nan, y: 0, width: 1, height: 1).validate())
    }
    func testControlRequiresLeaseFreshFrameExactTokenAndIncreasingSequence() throws {
        var lease = WatchStreamLease(now: 100)
        try lease.poll(sessionID: lease.id, now: 101)
        let frame = lease.issuedFrame(now: 101)
        let input = WatchStreamInput(kind: .click, x: 0.3, y: 0.7)
        let fake = WatchStreamRequest(kind: .input, sessionID: lease.id, frameSequence: frame,
            controlToken: UUID(), inputSequence: 1, input: input)
        XCTAssertThrowsError(try lease.admit(fake, now: 101))
        lease.setControlAllowed(true)
        let request = WatchStreamRequest(kind: .input, sessionID: lease.id, frameSequence: frame,
            controlToken: lease.controlToken, inputSequence: 1, input: input)
        try lease.admit(request, now: 102)
        XCTAssertThrowsError(try lease.admit(request, now: 102))
        lease.setControlAllowed(false)
        XCTAssertThrowsError(try lease.admit(request, now: 102))
        lease.setControlAllowed(true)
        XCTAssertThrowsError(try lease.admit(request, now: 102)) // regrant rotates the token
    }
    func testOldFrameAndReplacedSessionCannotControl() throws {
        var lease = WatchStreamLease(now: 0)
        lease.setControlAllowed(true)
        try lease.poll(sessionID: lease.id, now: 1)
        let first = lease.issuedFrame(now: 1)
        _ = lease.issuedFrame(now: 2)
        func request(_ sequence: UInt64, session: UUID? = nil) -> WatchStreamRequest {
            WatchStreamRequest(kind: .input, sessionID: session ?? lease.id, frameSequence: sequence,
                controlToken: lease.controlToken, inputSequence: 1, input: .init(kind: .enter))
        }
        XCTAssertThrowsError(try lease.admit(request(first), now: 2))
        XCTAssertThrowsError(try lease.admit(request(lease.frameSequence, session: UUID()), now: 2))
        XCTAssertThrowsError(try lease.admit(request(lease.frameSequence), now: 5.1))
    }
    func testIdleExpiryDoesNotResumeAndPeerClockCannotRenew() throws {
        var lease = WatchStreamLease(now: 10)
        try lease.check(sessionID: lease.id, now: 69) // user can move from phone to watch
        XCTAssertThrowsError(try lease.check(sessionID: lease.id, now: 71))
        try lease.poll(sessionID: lease.id, now: 11)
        XCTAssertThrowsError(try lease.poll(sessionID: lease.id, now: 18))
        XCTAssertThrowsError(try lease.poll(sessionID: lease.id, now: 9))
        XCTAssertThrowsError(try lease.poll(sessionID: lease.id, now: .infinity))
    }
    func testMalformedAndUnboundedInputRejected() throws {
        for input in [WatchStreamInput(kind: .click, x: -0.1, y: 0),
                      .init(kind: .click, x: .infinity, y: 0),
                      .init(kind: .text, text: String(repeating: "x", count: 501)),
                      .init(kind: .text, text: "bad\0text"), .init(kind: .enter, text: "unexpected")] {
            XCTAssertThrowsError(try input.validate())
        }
        let request = WatchStreamRequest(kind: .input, sessionID: UUID(), input: .init(kind: .enter))
        XCTAssertThrowsError(try WatchStreamRequest.decode(request.encoded()))
        let wrong = WatchStreamRequest(kind: .frame, sessionID: UUID(), viewport: .init(x: 0, y: 0, width: 0, height: 1))
        XCTAssertThrowsError(try WatchStreamRequest.decode(wrong.encoded()))
    }
}
