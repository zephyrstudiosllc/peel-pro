import Foundation

@main
struct PCMFramerHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw HarnessError.invalidFixture("expected fixture directory argument")
        }
        let fixtureDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )

        try testSourceSampleRateBounds(
            fixtureDirectory.appendingPathComponent("source-rate-bounds.tsv")
        )
        try testExactChunkAndLittleEndianBytes()
        try testPartialAppendsKeepTimestamp()
        try testMultipleChunksRemainBounded()
        try testDiscontinuityDropsPartialAudio()
        try testExplicitDropRebasesTimestamp(
            fixtureDirectory.appendingPathComponent("drop-reset.tsv")
        )
        try testInvalidInputIsRejected()
        print("SystemAudio PCM framing harness passed")
    }

    private static func testSourceSampleRateBounds(_ fixtureURL: URL) throws {
        for fields in try fixtureRows(at: fixtureURL) {
            guard fields.count == 2, let sampleRate = Double(fields[0]) else {
                throw HarnessError.invalidFixture("invalid source-rate row: \(fields)")
            }

            let actual = PeelPCMConversionBounds.maximumInputFrameCount(
                for: sampleRate
            )
            if fields[1] == "reject" {
                try expect(actual == nil, "sample rate \(fields[0]) should be rejected")
            } else {
                guard let expected = Int(fields[1]) else {
                    throw HarnessError.invalidFixture(
                        "invalid expected frame count: \(fields[1])"
                    )
                }
                try expect(
                    actual == expected,
                    "sample rate \(fields[0]) expected \(expected), got \(String(describing: actual))"
                )
            }
        }
    }

    private static func testExactChunkAndLittleEndianBytes() throws {
        var framer = PeelPCMChunkFramer()
        let input = stereoRamp(frameCount: PeelPCMChunkFramer.framesPerChunk)
        let chunks = try framer.append(
            interleavedStereoS16LE: input,
            startSampleTime: 48_000
        )

        try expect(chunks.count == 1, "exact input should emit one chunk")
        try expect(chunks[0].sequenceNumber == 0, "first sequence should be zero")
        try expect(chunks[0].startSampleTime == 48_000, "timestamp should be preserved")
        try expect(chunks[0].pcmData == input, "PCM bytes should be unchanged")
        try expect(chunks[0].pcmData.prefix(8) == Data([
            0x00, 0x80, 0xff, 0x7f,
            0x01, 0x80, 0xfe, 0x7f,
        ]), "samples should use signed 16-bit little-endian byte order")
        try expect(framer.bufferedFrameCount == 0, "exact chunk should leave no remainder")
    }

    private static func testPartialAppendsKeepTimestamp() throws {
        var framer = PeelPCMChunkFramer()
        let firstFrameCount = 317
        let secondFrameCount = PeelPCMChunkFramer.framesPerChunk - firstFrameCount
        let start: Int64 = 12_345

        let first = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: firstFrameCount,
                left: -123,
                right: 456
            ),
            startSampleTime: start
        )
        try expect(first.isEmpty, "partial append should not emit")
        try expect(
            framer.bufferedFrameCount == firstFrameCount,
            "partial frames should remain bounded in the framer"
        )

        let second = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: secondFrameCount,
                left: 789,
                right: -1_234
            ),
            startSampleTime: start + Int64(firstFrameCount)
        )
        try expect(second.count == 1, "two continuous partial appends should emit")
        try expect(second[0].startSampleTime == start, "chunk should use first-frame timestamp")
        try expect(second[0].pcmData.count == PeelPCMChunkFramer.bytesPerChunk, "chunk size")
    }

    private static func testMultipleChunksRemainBounded() throws {
        var framer = PeelPCMChunkFramer()
        let firstCount = 900
        let secondCount = PeelPCMChunkFramer.maxInputFramesPerAppend
        let start: Int64 = 5_000

        _ = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: firstCount,
                left: 1,
                right: 2
            ),
            startSampleTime: start
        )
        let chunks = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: secondCount,
                left: 3,
                right: 4
            ),
            startSampleTime: start + Int64(firstCount)
        )

        try expect(chunks.count == 3, "bounded append should emit at most three chunks")
        try expect(chunks.map(\.sequenceNumber) == [0, 1, 2], "sequences should be monotonic")
        try expect(
            chunks.map(\.startSampleTime) == [
                start,
                start + 960,
                start + 1_920,
            ],
            "chunk timestamps should advance by 20 ms"
        )
        try expect(framer.bufferedFrameCount == 68, "only a sub-chunk remainder should remain")
    }

    private static func testDiscontinuityDropsPartialAudio() throws {
        var framer = PeelPCMChunkFramer()
        let originalStart: Int64 = 100
        let discontinuousStart: Int64 = 10_000

        _ = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: 500,
                left: 10,
                right: 20
            ),
            startSampleTime: originalStart
        )
        let firstAfterGap = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: 600,
                left: 30,
                right: 40
            ),
            startSampleTime: discontinuousStart
        )
        try expect(firstAfterGap.isEmpty, "a gap should discard the old partial chunk")

        let secondAfterGap = try framer.append(
            interleavedStereoS16LE: constantStereo(
                frameCount: 360,
                left: 50,
                right: 60
            ),
            startSampleTime: discontinuousStart + 600
        )
        try expect(secondAfterGap.count == 1, "new continuous timeline should emit")
        try expect(
            secondAfterGap[0].startSampleTime == discontinuousStart,
            "post-gap timestamp should not reuse stale audio"
        )
    }

    private static func testExplicitDropRebasesTimestamp(_ fixtureURL: URL) throws {
        for fields in try fixtureRows(at: fixtureURL) {
            guard fields.count == 5,
                  let emittedStart = Int64(fields[0]),
                  let partialFrames = Int(fields[1]),
                  let rebaseStart = Int64(fields[2]),
                  let rebaseFrames = Int(fields[3]),
                  let expectedSequence = UInt64(fields[4]) else {
                throw HarnessError.invalidFixture("invalid drop-reset row: \(fields)")
            }

            var framer = PeelPCMChunkFramer()
            let emitted = try framer.append(
                interleavedStereoS16LE: constantStereo(
                    frameCount: PeelPCMChunkFramer.framesPerChunk,
                    left: 1,
                    right: -1
                ),
                startSampleTime: emittedStart
            )
            try expect(emitted.count == 1, "fixture setup should emit one chunk")

            _ = try framer.append(
                interleavedStereoS16LE: constantStereo(
                    frameCount: partialFrames,
                    left: 2,
                    right: -2
                ),
                startSampleTime: emittedStart
                    + Int64(PeelPCMChunkFramer.framesPerChunk)
            )
            framer.discardBufferedAudio()

            let rebased = try framer.append(
                interleavedStereoS16LE: constantStereo(
                    frameCount: rebaseFrames,
                    left: 3,
                    right: -3
                ),
                startSampleTime: rebaseStart
            )
            try expect(rebased.count == 1, "rebased fixture should emit one chunk")
            try expect(
                rebased[0].sequenceNumber == expectedSequence,
                "drop should preserve sequence monotonicity"
            )
            try expect(
                rebased[0].startSampleTime == rebaseStart,
                "drop should rebase to the next source timestamp"
            )
        }
    }

    private static func testInvalidInputIsRejected() throws {
        var framer = PeelPCMChunkFramer()

        do {
            _ = try framer.append(
                interleavedStereoS16LE: Data([0x00, 0x01, 0x02]),
                startSampleTime: 0
            )
            throw HarnessError.expectationFailed("unaligned data should fail")
        } catch let error as PeelPCMChunkFramer.FramingError {
            try expect(
                error == .unalignedByteCount(3),
                "unexpected unaligned-data error: \(error)"
            )
        }

        do {
            _ = try framer.append(
                interleavedStereoS16LE: Data(
                    repeating: 0,
                    count: (PeelPCMChunkFramer.maxInputFramesPerAppend + 1)
                        * PeelPCMChunkFramer.bytesPerFrame
                ),
                startSampleTime: 0
            )
            throw HarnessError.expectationFailed("oversized append should fail")
        } catch let error as PeelPCMChunkFramer.FramingError {
            try expect(
                error == .tooManyFrames(
                    PeelPCMChunkFramer.maxInputFramesPerAppend + 1
                ),
                "unexpected oversized-input error: \(error)"
            )
        }
    }

    private static func stereoRamp(frameCount: Int) -> Data {
        var data = Data()
        data.reserveCapacity(frameCount * PeelPCMChunkFramer.bytesPerFrame)

        for frame in 0..<frameCount {
            let left = Int16.min &+ Int16(truncatingIfNeeded: frame)
            let right = Int16.max &- Int16(truncatingIfNeeded: frame)
            appendLittleEndian(left, to: &data)
            appendLittleEndian(right, to: &data)
        }
        return data
    }

    private static func constantStereo(
        frameCount: Int,
        left: Int16,
        right: Int16
    ) -> Data {
        var data = Data()
        data.reserveCapacity(frameCount * PeelPCMChunkFramer.bytesPerFrame)

        for _ in 0..<frameCount {
            appendLittleEndian(left, to: &data)
            appendLittleEndian(right, to: &data)
        }
        return data
    }

    private static func appendLittleEndian(_ sample: Int16, to data: inout Data) {
        var littleEndian = sample.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func fixtureRows(at url: URL) throws -> [[String]] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw HarnessError.expectationFailed(message)
        }
    }

    private enum HarnessError: Error {
        case expectationFailed(String)
        case invalidFixture(String)
    }
}
