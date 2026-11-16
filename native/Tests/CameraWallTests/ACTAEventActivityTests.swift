import Foundation
import XCTest
@testable import CameraCore
@testable import CameraWall

final class ACTAEventActivityTests: XCTestCase {
    func testSummaryUsesRealRecordsWithoutDoubleCountingSafetyFeedCopies() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), camera = UUID()
        let incident = SafetyIncident(cameraID: camera, cameraName: "Camera", trackIDs: [], type: .fallConfirmed,
            severity: .critical, confidence: 0.9, createdAt: now.addingTimeInterval(-60), title: "Fall", explanation: "Test", detectorSource: "test")
        let copied = VLMAlert(id: incident.id, createdAt: incident.createdAt, cameraID: camera,
            cameraName: "Camera", condition: "Fall", evidence: "Test")
        let separate = VLMAlert(createdAt: now.addingTimeInterval(-3600), cameraID: camera,
            cameraName: "Camera", condition: "AI rule", evidence: "Test")
        let expired = VLMAlert(createdAt: now.addingTimeInterval(-86_401), cameraID: camera,
            cameraName: "Camera", condition: "Expired", evidence: "Test")
        let future = VLMAlert(createdAt: now.addingTimeInterval(1), cameraID: camera,
            cameraName: "Camera", condition: "Future", evidence: "Test")
        let summary = ACTAEventActivitySnapshot(alerts: [copied, separate, separate, expired, future],
            incidents: [incident], hardwareEvents: [], now: now)
        XCTAssertEqual(summary.safetyCount, 1)
        XCTAssertEqual(summary.aiCount, 1)
        XCTAssertEqual(summary.cameraCount, 0)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.buckets.reduce(0, +), summary.total)
        XCTAssertEqual(summary.buckets.count, 24)
    }

    func testEmptySummaryHasNoInventedMetrics() {
        let summary = ACTAEventActivitySnapshot(alerts: [], incidents: [], hardwareEvents: [], now: Date())
        XCTAssertEqual(summary.total, 0)
        XCTAssertTrue(summary.buckets.allSatisfy { $0 == 0 })
    }
}
