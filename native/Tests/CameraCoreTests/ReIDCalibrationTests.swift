import XCTest
@testable import CameraCore

final class ReIDCalibrationTests: XCTestCase {
    func testRecommendsLargestRecallThresholdThatMeetsPrecisionTarget() {
        let pairs = [
            LabeledReIDPair(distance: 0.08, sameObject: true),
            LabeledReIDPair(distance: 0.10, sameObject: true),
            LabeledReIDPair(distance: 0.14, sameObject: true),
            LabeledReIDPair(distance: 0.18, sameObject: true),
            LabeledReIDPair(distance: 0.23, sameObject: true),
            LabeledReIDPair(distance: 0.12, sameObject: false),
            LabeledReIDPair(distance: 0.30, sameObject: false),
            LabeledReIDPair(distance: 0.45, sameObject: false)
        ]

        let result = ReIDThresholdCalibrator.calibrate(
            pairs, targetPrecision: 0.9, minimumPositivePairs: 2, minimumNegativePairs: 2
        )

        XCTAssertEqual(result.recommendedDistance, 0.10)
        XCTAssertEqual(result.precision, 1)
        XCTAssertEqual(result.recall, 0.4)
        XCTAssertEqual(result.falsePositives, 0)
        XCTAssertEqual(result.truePositives, 2)
    }

    func testDoesNotRecommendThresholdWithoutEnoughRealLabels() {
        let pairs = [
            LabeledReIDPair(distance: 0.1, sameObject: true),
            LabeledReIDPair(distance: 0.4, sameObject: false)
        ]

        let result = ReIDThresholdCalibrator.calibrate(pairs)

        XCTAssertFalse(result.isReady)
        XCTAssertNil(result.recommendedDistance)
        XCTAssertEqual(result.positivePairs, 1)
        XCTAssertEqual(result.negativePairs, 1)
    }

    func testIgnoresInvalidDistances() {
        let result = ReIDThresholdCalibrator.calibrate([
            LabeledReIDPair(distance: .nan, sameObject: true),
            LabeledReIDPair(distance: 2.5, sameObject: false)
        ])

        XCTAssertEqual(result.positivePairs, 0)
        XCTAssertEqual(result.negativePairs, 0)
        XCTAssertNil(result.recommendedDistance)
    }

    func testFalseMatchRateIsUndefinedWithoutNegativeLabels() {
        let result = ReIDThresholdCalibrator.calibrate([
            LabeledReIDPair(distance: 0.1, sameObject: true)
        ])

        XCTAssertNil(result.sweep.first?.falseMatchRate)
        XCTAssertNil(result.recommendedDistance)
    }
}