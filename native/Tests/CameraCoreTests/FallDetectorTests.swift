import XCTest
@testable import CameraCore

final class FallDetectorTests: XCTestCase {
    private let frame = 1000

    func testHorizontalPostureMustPersistBeforeSingleFallEvent() {
        var detector = FallDetector()
        var time = 0.0
        for _ in 0..<10 { _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: time); time += 0.1 }

        var events: [FallEvent] = []
        var states: [FallPersonState] = []
        for _ in 0..<15 {
            let update = detector.update([lying()], frameWidth: frame, frameHeight: frame, timestamp: time)
            events += update.events
            states += update.tracks.map(\.state)
            time += 0.1
        }

        XCTAssertEqual(states.first, .falling)
        XCTAssertEqual(states.last, .fallen)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.previousState, .falling)
        XCTAssertEqual(events.first?.currentState, .fallen)
        XCTAssertGreaterThanOrEqual(events[0].occurredAt - events[0].fallStartedAt, 0.8 - 1e-9)
        XCTAssertEqual(detector.trackCount, 1)
    }

    func testBriefBendDoesNotRaiseFall() {
        var detector = FallDetector()
        var time = 0.0
        var events: [FallEvent] = []
        for index in 0..<30 {
            let pose = (10..<15).contains(index) ? lying() : standing()
            events += detector.update([pose], frameWidth: frame, frameHeight: frame, timestamp: time).events
            time += 0.1
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testDepthAxisFallDetectedByHeightCollapseAndBaselineFrozen() {
        var detector = FallDetector()
        var time = 0.0
        for _ in 0..<10 { _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: time); time += 0.1 }

        // Upright torso and narrow box, but the person is only 40% of their standing height.
        let collapsed = person(centerX: 500, centerY: 700, width: 60, height: 80, horizontalTorso: false)
        var last: FallDetectorUpdate = .empty
        var events: [FallEvent] = []
        for _ in 0..<12 {
            last = detector.update([collapsed], frameWidth: frame, frameHeight: frame, timestamp: time)
            events += last.events
            time += 0.1
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].metrics.heightRatio ?? 1, 0.4, accuracy: 0.01)
        XCTAssertLessThan(events[0].metrics.aspectRatio, 1)
        XCTAssertEqual(last.tracks.first?.metrics.baselineHeightPixels ?? 0, 200, accuracy: 0.01)
    }

    func testSittingIsNotAFallAndDoesNotUpdateBaseline() {
        var detector = FallDetector()
        var time = 0.0
        for _ in 0..<10 { _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: time); time += 0.1 }
        let sitting = person(centerX: 500, centerY: 550, width: 70, height: 130, horizontalTorso: false)
        var last: FallDetectorUpdate = .empty
        for _ in 0..<20 {
            last = detector.update([sitting], frameWidth: frame, frameHeight: frame, timestamp: time)
            XCTAssertTrue(last.events.isEmpty)
            time += 0.1
        }
        XCTAssertEqual(last.tracks.first?.state, .sitting)
        XCTAssertEqual(last.tracks.first?.metrics.baselineHeightPixels ?? 0, 200, accuracy: 0.01)
    }

    func testLowFrameRateExtendsPersistenceAndNeverFiresOnSingleFrame() {
        var detector = FallDetector()
        for time in 0..<4 {
            _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: Double(time))
        }
        XCTAssertEqual(detector.framesPerSecond ?? 0, 1, accuracy: 1e-9)

        XCTAssertTrue(detector.update([lying()], frameWidth: frame, frameHeight: frame, timestamp: 4).events.isEmpty)
        XCTAssertTrue(detector.update([lying()], frameWidth: frame, frameHeight: frame, timestamp: 5).events.isEmpty)
        let confirmed = detector.update([lying()], frameWidth: frame, frameHeight: frame, timestamp: 6)
        XCTAssertEqual(confirmed.events.count, 1)
        XCTAssertEqual(confirmed.events.first?.persistenceSeconds, 2)
    }

    func testFallNeedsAtLeastTwoSamplesEvenAfterLongGap() {
        var detector = FallDetector()
        _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 0)
        _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 0.1)
        let first = detector.update([lying()], frameWidth: frame, frameHeight: frame, timestamp: 2.5)
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(first.tracks.first?.state, .falling)
    }

    func testProximityRelinkKeepsTrackAcrossShapeChangeAndGap() throws {
        var detector = FallDetector()
        let initial = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 0)
        let trackID = try XCTUnwrap(initial.tracks.first?.trackID)
        _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 0.1)

        let relinked = detector.update([lying(centerX: 560)], frameWidth: frame, frameHeight: frame, timestamp: 1.6)
        XCTAssertEqual(relinked.tracks.first?.trackID, trackID)
        XCTAssertEqual(relinked.tracks.first?.relinkCount, 1)
        XCTAssertEqual(relinked.tracks.first?.state, .falling)

        let farAway = detector.update([standing(centerX: 100)], frameWidth: frame, frameHeight: frame, timestamp: 1.7)
        XCTAssertNotEqual(farAway.tracks.first?.trackID, trackID)
    }

    func testTracksExpireAfterRelinkGap() {
        var detector = FallDetector()
        let initial = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 0)
        let later = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 3.5)
        XCTAssertNotEqual(initial.tracks.first?.trackID, later.tracks.first?.trackID)
        XCTAssertEqual(detector.trackCount, 1)
    }

    func testLowConfidenceFloorOnlyKeepsFallPhaseTracks() {
        var detector = FallDetector()
        var time = 0.0
        for _ in 0..<5 { _ = detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: time); time += 0.1 }
        let falling = detector.update([lying()], frameWidth: frame, frameHeight: frame, timestamp: time)
        let trackID = falling.tracks.first?.trackID
        time += 0.1

        var events: [FallEvent] = []
        for _ in 0..<10 {
            let update = detector.update([lying(confidence: 0.2)], frameWidth: frame, frameHeight: frame, timestamp: time)
            XCTAssertEqual(update.tracks.first?.trackID, trackID)
            events += update.events
            time += 0.1
        }
        XCTAssertEqual(events.count, 1)

        let stranger = detector.update([standing(centerX: 50, confidence: 0.2)], frameWidth: frame, frameHeight: frame,
                                       timestamp: time)
        XCTAssertTrue(stranger.tracks.isEmpty)
        XCTAssertEqual(detector.trackCount, 1)
    }

    func testRecoveryIsDebouncedAndAllowsNewIncident() {
        var detector = FallDetector()
        var time = 0.0
        func feed(_ pose: FallPoseObservation, _ count: Int) -> (events: Int, state: FallPersonState?) {
            var events = 0
            var state: FallPersonState?
            for _ in 0..<count {
                let update = detector.update([pose], frameWidth: frame, frameHeight: frame, timestamp: time)
                events += update.events.count
                state = update.tracks.first?.state
                time += 0.1
            }
            return (events, state)
        }

        XCTAssertEqual(feed(standing(), 5).events, 0)
        XCTAssertEqual(feed(lying(), 12).events, 1)
        XCTAssertEqual(feed(standing(), 1).state, .fallen)
        XCTAssertEqual(feed(lying(), 3).events, 0)
        XCTAssertEqual(feed(standing(), 2).state?.isUpright, true)
        XCTAssertEqual(feed(lying(), 12).events, 1)
    }

    func testWalkingRequiresAdequateFrameRate() {
        var fast = FallDetector()
        var state: FallPersonState?
        for index in 0..<10 {
            state = fast.update([standing(centerX: 300 + Double(index) * 15)], frameWidth: frame, frameHeight: frame,
                                timestamp: Double(index) * 0.1).tracks.first?.state
        }
        XCTAssertEqual(state, .walking)

        var slow = FallDetector()
        for index in 0..<10 {
            state = slow.update([standing(centerX: 300 + Double(index) * 40)], frameWidth: frame, frameHeight: frame,
                                timestamp: Double(index) * 0.5).tracks.first?.state
        }
        XCTAssertEqual(state, .standing)
    }

    func testOutOfOrderFramesAndAspectRatioUseFramePixels() {
        var detector = FallDetector()
        XCTAssertFalse(detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 1).tracks.isEmpty)
        XCTAssertEqual(detector.update([standing()], frameWidth: frame, frameHeight: frame, timestamp: 0.5), .empty)

        // Normalized width > height, but on a 9:16 portrait frame the person is still upright.
        let portrait = FallPoseObservation(confidence: 0.9,
                                           box: FallBoundingBox(x: 0.3, y: 0.3, width: 0.3, height: 0.2),
                                           keypoints: keypoints(centerX: 0.45, centerY: 0.4, horizontal: false))
        var portraitDetector = FallDetector()
        let update = portraitDetector.update([portrait], frameWidth: 900, frameHeight: 1600, timestamp: 0)
        XCTAssertEqual(update.tracks.first?.metrics.aspectRatio ?? 0, 0.84375, accuracy: 1e-6)
        XCTAssertEqual(update.tracks.first?.state, .standing)
    }

    // MARK: - Fixtures (pixel geometry on a 1000x1000 frame)

    private func standing(centerX: Double = 500, confidence: Double = 0.9) -> FallPoseObservation {
        person(centerX: centerX, centerY: 500, width: 70, height: 200, horizontalTorso: false, confidence: confidence)
    }

    private func lying(centerX: Double = 500, confidence: Double = 0.9) -> FallPoseObservation {
        person(centerX: centerX, centerY: 620, width: 200, height: 70, horizontalTorso: true, confidence: confidence)
    }

    private func person(centerX: Double, centerY: Double, width: Double, height: Double,
                        horizontalTorso: Bool, confidence: Double = 0.9) -> FallPoseObservation {
        let size = Double(frame)
        return FallPoseObservation(
            confidence: confidence,
            box: FallBoundingBox(x: (centerX - width / 2) / size, y: (centerY - height / 2) / size,
                                 width: width / size, height: height / size),
            keypoints: keypoints(centerX: centerX / size, centerY: centerY / size, horizontal: horizontalTorso)
        )
    }

    private func keypoints(centerX: Double, centerY: Double, horizontal: Bool) -> [FallKeypoint] {
        var points = Array(repeating: FallKeypoint(x: centerX, y: centerY, confidence: 0.1), count: 17)
        let offset = 0.04
        let shoulder = horizontal ? (centerX - offset, centerY) : (centerX, centerY - offset)
        let hip = horizontal ? (centerX + offset, centerY) : (centerX, centerY + offset)
        for index in [FallPoseObservation.leftShoulder, FallPoseObservation.rightShoulder] {
            points[index] = FallKeypoint(x: shoulder.0, y: shoulder.1, confidence: 0.9)
        }
        for index in [FallPoseObservation.leftHip, FallPoseObservation.rightHip] {
            points[index] = FallKeypoint(x: hip.0, y: hip.1, confidence: 0.9)
        }
        return points
    }
}
