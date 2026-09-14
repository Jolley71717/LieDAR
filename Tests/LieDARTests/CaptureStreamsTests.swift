import Foundation
import XCTest
import simd
@testable import LieDAR

/// The stream lifecycle a live source relies on, tested where ARKit is not: a closed trio
/// finishes rather than hanging, `open()` replaces the previous trio, and a delegate callback
/// that arrives after `stop()` is dropped instead of reaching a consumer.
final class CaptureStreamsTests: XCTestCase {

    private func sample(_ timestamp: TimeInterval) -> CameraSample {
        CameraSample(transform: matrix_identity_float4x4, timestamp: timestamp, trackingState: .normal) { nil }
    }

    private func anchorEvent(_ id: UUID) -> AnchorEvent {
        .removed(id)
    }

    func testStreamsAreFinishedBeforeOpen() async {
        let streams = CaptureStreams()
        XCTAssertFalse(streams.isOpen, "a fresh CaptureStreams is closed")

        var seen = 0
        for await _ in streams.samples { seen += 1 }
        XCTAssertEqual(seen, 0, "samples before open: expected a finished stream")

        var events = 0
        for await _ in streams.sessionEvents { events += 1 }
        XCTAssertEqual(events, 0, "session events before open: expected a finished stream")
    }

    func testYieldedValuesReachTheConsumerWhileOpen() async {
        let streams = CaptureStreams(sampleBufferSize: 8)
        streams.open()
        XCTAssertTrue(streams.isOpen, "open() leaves the streams open")

        XCTAssertTrue(streams.yield(sample(1)), "yield while open")
        XCTAssertTrue(streams.yield(sample(2)), "yield while open")
        XCTAssertTrue(streams.yield(CaptureSessionEvent.interrupted), "yield while open")
        streams.close()

        var timestamps: [TimeInterval] = []
        for await value in streams.samples { timestamps.append(value.timestamp) }
        XCTAssertEqual(timestamps, [], "samples read after close belong to a finished stream")
    }

    func testClosedStreamsDropWhatIsYieldedAfterwards() async {
        let streams = CaptureStreams(sampleBufferSize: 8)
        streams.open()
        let samples = streams.samples
        let events = streams.sessionEvents
        XCTAssertTrue(streams.yield(sample(1)))
        streams.close()

        XCTAssertFalse(streams.yield(sample(2)), "yield after close must be refused")
        XCTAssertFalse(streams.yield(anchorEvent(Golden.anchorID)), "yield after close must be refused")
        XCTAssertFalse(streams.yield(CaptureSessionEvent.failed("late")), "yield after close must be refused")
        XCTAssertFalse(streams.isOpen, "close() leaves the streams closed")

        var timestamps: [TimeInterval] = []
        for await value in samples { timestamps.append(value.timestamp) }
        XCTAssertEqual(timestamps, [1], "the stream carries what was yielded while open and nothing after")

        var eventCount = 0
        for await _ in events { eventCount += 1 }
        XCTAssertEqual(eventCount, 0, "no session event was yielded while open")
    }

    func testCloseIsSafeTwiceAndFinishesEveryStream() async {
        let streams = CaptureStreams()
        streams.open()
        let anchors = streams.anchorEvents
        XCTAssertTrue(streams.yield(AnchorEvent.added(Golden.quadAnchor())))
        streams.close()
        streams.close()

        var ids: [UUID] = []
        for await event in anchors { ids.append(event.anchorID) }
        XCTAssertEqual(ids, [Golden.anchorID], "anchor events survive close; the stream then finishes")
    }

    func testOpenAgainReplacesThePreviousTrio() async {
        let streams = CaptureStreams(sampleBufferSize: 8)
        streams.open()
        let first = streams.samples
        XCTAssertTrue(streams.yield(sample(1)))

        streams.open()
        let second = streams.samples
        XCTAssertTrue(streams.yield(sample(2)))
        streams.close()

        var firstTimestamps: [TimeInterval] = []
        for await value in first { firstTimestamps.append(value.timestamp) }
        XCTAssertEqual(firstTimestamps, [1], "the first capture's stream keeps its own frame and finishes")

        var secondTimestamps: [TimeInterval] = []
        for await value in second { secondTimestamps.append(value.timestamp) }
        XCTAssertEqual(secondTimestamps, [2], "the second capture's frame does not go to the first capture's loop")
    }

    func testSampleBufferKeepsTheNewestFrameForASlowConsumer() async {
        let streams = CaptureStreams()
        XCTAssertEqual(streams.sampleBufferSize, 1, "one frame by default, so ARKit keeps delivering")
        streams.open()
        let samples = streams.samples
        for i in 1...5 { XCTAssertTrue(streams.yield(sample(TimeInterval(i)))) }
        streams.close()

        var timestamps: [TimeInterval] = []
        for await value in samples { timestamps.append(value.timestamp) }
        XCTAssertEqual(timestamps, [5], "buffering newest 1: a consumer that never ran sees only the newest frame")
    }

    func testEveryStreamIsIndependentlyBuffered() async {
        let streams = CaptureStreams()
        streams.open()
        let anchors = streams.anchorEvents
        let events = streams.sessionEvents
        for _ in 0..<10 { XCTAssertTrue(streams.yield(AnchorEvent.removed(Golden.anchorID))) }
        XCTAssertTrue(streams.yield(CaptureSessionEvent.interrupted))
        XCTAssertTrue(streams.yield(CaptureSessionEvent.interruptionEnded))
        streams.close()

        var anchorCount = 0
        for await _ in anchors { anchorCount += 1 }
        XCTAssertEqual(anchorCount, 10, "anchor events are unbounded: bookkeeping must not miss a removal")

        var seen: [CaptureSessionEvent] = []
        for await event in events { seen.append(event) }
        XCTAssertEqual(seen, [.interrupted, .interruptionEnded], "session events are unbounded and ordered")
    }

    func testDefaultSourceHasNoSessionEventsAndNoWorldMap() async {
        let source: CaptureSource = NullCaptureSource()
        var events = 0
        for await _ in source.sessionEvents { events += 1 }
        XCTAssertEqual(events, 0, "the default sessionEvents is a finished stream")
        let map = await source.worldMapData()
        XCTAssertNil(map, "a source with nothing to relocalize against returns no world map")
    }
}
