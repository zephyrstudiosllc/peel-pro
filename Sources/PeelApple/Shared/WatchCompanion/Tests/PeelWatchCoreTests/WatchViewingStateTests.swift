import XCTest
@testable import PeelWatchCore

final class WatchViewingStateTests: XCTestCase {
    private func status(_ state: WatchViewingState, _ generation: UUID) throws -> WatchStreamRequest {
        let request = try XCTUnwrap(state.nextRequest(generation: generation, viewport: .full))
        XCTAssertEqual(request.kind, .status)
        return request
    }

    private func ready(_ state: inout WatchViewingState, _ generation: UUID,
                       info: WatchStreamInfo) throws {
        let request = try status(state, generation)
        let response = WatchStreamResponse(requestID: request.requestID, info: info, message: "Ready", accepted: true)
        XCTAssertEqual(state.receive(response, to: request, generation: generation), .accepted(info))
    }

    private func input(_ sequence: UInt64, phone: WatchStreamLease) -> WatchStreamRequest {
        WatchStreamRequest(kind: .input, sessionID: phone.id, frameSequence: phone.frameSequence,
                           controlToken: phone.controlToken, inputSequence: sequence, input: .init(kind: .enter))
    }

    func testStartingBeforeSharingCanDiscoverALaterLease() throws {
        var state = WatchViewingState()
        let generation = state.start()
        let first = try status(state, generation)
        let notShared = WatchStreamResponse(requestID: first.requestID, message: "Start sharing on iPhone", accepted: false)
        XCTAssertEqual(state.receive(notShared, to: first, generation: generation), .retry)
        XCTAssertTrue(state.isCurrent(generation))
        XCTAssertNil(state.sessionID)

        let info = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Owned fixture", controlToken: nil)
        try ready(&state, generation, info: info)
        let frame = try XCTUnwrap(state.nextRequest(generation: generation, viewport: .full))
        XCTAssertEqual(frame.kind, .frame)
        XCTAssertEqual(frame.sessionID, info.sessionID)
    }

    func testTemporaryMissingReplyCanReacquireAndAcceptNextFrameReply() throws {
        var state = WatchViewingState()
        let generation = state.start()
        let info = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Owned fixture", controlToken: UUID())
        try ready(&state, generation, info: info)
        let lostPoll = try XCTUnwrap(state.nextRequest(generation: generation, viewport: .full))
        XCTAssertEqual(state.receive(nil, to: lostPoll, generation: generation), .retry)
        XCTAssertNil(state.sessionID)
        XCTAssertNil(state.nextInputSequence(sessionID: info.sessionID, generation: generation))

        try ready(&state, generation, info: info)
        let nextPoll = try XCTUnwrap(state.nextRequest(generation: generation, viewport: .full))
        // This tests the real request policy, not ImageIO or presentation.
        let frame = WatchStreamFrame(sequence: 2, jpeg: Data([1]), width: 1, height: 1, viewport: .full)
        let response = WatchStreamResponse(requestID: nextPoll.requestID, info: info, frame: frame, message: "Live", accepted: true)
        XCTAssertEqual(state.receive(response, to: nextPoll, generation: generation), .accepted(info))
        XCTAssertTrue(state.isCurrent(generation))
        XCTAssertEqual(state.sessionID, info.sessionID)
    }

    func testStopRetiresALateReplyAndGeneratesNoFurtherRequests() throws {
        var state = WatchViewingState()
        let generation = state.start()
        let pending = try status(state, generation)
        state.stop()
        let info = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Retired", controlToken: UUID())
        let late = WatchStreamResponse(requestID: pending.requestID, info: info, message: "Late", accepted: true)
        XCTAssertEqual(state.receive(late, to: pending, generation: generation), .retired)
        XCTAssertFalse(state.isWanted)
        XCTAssertNil(state.sessionID)
        XCTAssertNil(state.nextRequest(generation: generation, viewport: .full))
        XCTAssertNil(state.nextRequest(generation: state.generation, viewport: .full))
        XCTAssertNil(state.nextInputSequence(sessionID: info.sessionID, generation: generation))
    }

    func testCanceledGenerationCannotReplaceTheNewGenerationsLease() throws {
        var state = WatchViewingState()
        let oldGeneration = state.start()
        let pending = try status(state, oldGeneration)
        state.stop()
        let newGeneration = state.start()
        let current = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Current", controlToken: nil)
        try ready(&state, newGeneration, info: current)
        let retired = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Retired", controlToken: UUID())
        let late = WatchStreamResponse(requestID: pending.requestID, info: retired, message: "Late", accepted: true)
        XCTAssertEqual(state.receive(late, to: pending, generation: oldGeneration), .retired)
        XCTAssertEqual(state.sessionID, current.sessionID)
        XCTAssertTrue(state.isCurrent(newGeneration))
    }

    func testFrameReplyCannotAdoptADifferentLeaseWithoutStatusConfirmation() throws {
        var state = WatchViewingState()
        let generation = state.start()
        let first = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "First", controlToken: UUID())
        try ready(&state, generation, info: first)
        let poll = try XCTUnwrap(state.nextRequest(generation: generation, viewport: .full))
        let replacement = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Replacement", controlToken: UUID())
        let response = WatchStreamResponse(requestID: poll.requestID, info: replacement, message: "Changed", accepted: true)
        XCTAssertEqual(state.receive(response, to: poll, generation: generation), .retry)
        XCTAssertNil(state.sessionID)
        XCTAssertNil(state.nextInputSequence(sessionID: replacement.sessionID, generation: generation))
        _ = try status(state, generation)
    }

    func testReconnectKeepsInputSequenceAcceptedByTheSamePhoneLease() throws {
        var phone = WatchStreamLease(now: 100)
        phone.setControlAllowed(true)
        try phone.poll(sessionID: phone.id, now: 101)
        _ = phone.issuedFrame(now: 101)
        let info = WatchStreamInfo(sessionID: phone.id, hostName: "mini", windowTitle: "Owned fixture", controlToken: phone.controlToken)
        var state = WatchViewingState()
        let firstGeneration = state.start()
        try ready(&state, firstGeneration, info: info)
        let first = try XCTUnwrap(state.nextInputSequence(sessionID: phone.id, generation: firstGeneration))
        XCTAssertEqual(first, 1)
        try phone.admit(input(first, phone: phone), now: 101)

        state.stop()
        let reconnect = state.start()
        try ready(&state, reconnect, info: info)
        try phone.poll(sessionID: phone.id, now: 102)
        _ = phone.issuedFrame(now: 102)
        let next = try XCTUnwrap(state.nextInputSequence(sessionID: phone.id, generation: reconnect))
        XCTAssertEqual(next, 2)
        try phone.admit(input(next, phone: phone), now: 102)
        XCTAssertThrowsError(try phone.admit(input(first, phone: phone), now: 102))
    }

    func testInputSequenceResetsOnlyWhenANewLeaseIsConfirmed() throws {
        var state = WatchViewingState()
        let generation = state.start()
        let first = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "First", controlToken: UUID())
        try ready(&state, generation, info: first)
        XCTAssertEqual(state.nextInputSequence(sessionID: first.sessionID, generation: generation), 1)
        state.requireStatus(generation: generation)
        let replacement = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Replacement", controlToken: UUID())
        XCTAssertNil(state.nextInputSequence(sessionID: replacement.sessionID, generation: generation))
        try ready(&state, generation, info: replacement)
        XCTAssertNil(state.nextInputSequence(sessionID: first.sessionID, generation: generation))
        XCTAssertEqual(state.nextInputSequence(sessionID: replacement.sessionID, generation: generation), 1)
    }

    func testAmbiguousInputReplyDoesNotReuseAnAlreadyConsumedSequence() throws {
        var phone = WatchStreamLease(now: 0)
        phone.setControlAllowed(true)
        try phone.poll(sessionID: phone.id, now: 1)
        _ = phone.issuedFrame(now: 1)
        let info = WatchStreamInfo(sessionID: phone.id, hostName: "mini", windowTitle: "Owned fixture", controlToken: phone.controlToken)
        var state = WatchViewingState()
        let generation = state.start()
        try ready(&state, generation, info: info)
        let lostReply = try XCTUnwrap(state.nextInputSequence(sessionID: phone.id, generation: generation))
        try phone.admit(input(lostReply, phone: phone), now: 1)
        // Transport loses the reply after admission. Recovery sends status only.
        state.requireStatus(generation: generation)
        _ = try status(state, generation)
        try ready(&state, generation, info: info)
        let next = try XCTUnwrap(state.nextInputSequence(sessionID: phone.id, generation: generation))
        XCTAssertEqual(next, lostReply + 1)
        try phone.admit(input(next, phone: phone), now: 1)
        XCTAssertThrowsError(try phone.admit(input(lostReply, phone: phone), now: 1))
    }

    func testRejectedOrMismatchedStatusDoesNotSelectALease() throws {
        var state = WatchViewingState()
        let generation = state.start()
        let request = try status(state, generation)
        let info = WatchStreamInfo(sessionID: UUID(), hostName: "mini", windowTitle: "Owned fixture", controlToken: UUID())
        let rejected = WatchStreamResponse(requestID: request.requestID, info: info, message: "Expired", accepted: false)
        XCTAssertEqual(state.receive(rejected, to: request, generation: generation), .retry)
        XCTAssertNil(state.nextInputSequence(sessionID: info.sessionID, generation: generation))
        let mismatched = WatchStreamResponse(requestID: UUID(), info: info, message: "Wrong reply", accepted: true)
        XCTAssertEqual(state.receive(mismatched, to: request, generation: generation), .retry)
        XCTAssertNil(state.sessionID)
        XCTAssertTrue(state.isCurrent(generation))
    }
}
