import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class VehicleTextRemovalReviewTests: XCTestCase {
    func testOnlyReviewedEvidenceCanBeRemoved() {
        let trackID = UUID()
        let evidence = VehicleTextEvidence(
            trackID: trackID,
            candidates: [VehicleTextCandidate(text: "FAKE123", confidence: 0.9)],
            readAt: Date(timeIntervalSince1970: 123),
            cropSHA256: String(repeating: "a", count: 64)
        )
        let review = VehicleTextRemovalReview(evidence: evidence)
        let replacement = VehicleTextEvidence(
            trackID: trackID,
            candidates: [VehicleTextCandidate(text: "FAKE456", confidence: 0.9)],
            readAt: evidence.readAt,
            cropSHA256: evidence.cropSHA256
        )
        var removed: [UUID] = []
        XCTAssertFalse(review.apply(current: nil) { removed.append($0) })
        XCTAssertFalse(review.apply(current: replacement) { removed.append($0) })
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(review.apply(current: evidence) { removed.append($0) })
        XCTAssertEqual(removed, [trackID])
    }
}
