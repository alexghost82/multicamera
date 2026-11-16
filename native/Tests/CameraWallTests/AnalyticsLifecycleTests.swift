import Foundation
import XCTest
@testable import CameraWall
@testable import CameraCore

@MainActor
final class AnalyticsLifecycleTests: XCTestCase {
    func testStopAndCameraReplacementInvalidatePreviouslyScheduledResults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LocalVideoAnalyticsEngine(settingsURL: root.appendingPathComponent("settings.json"),
            incidentsURL: root.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence"),
            auditLogURL: root.appendingPathComponent("audit.json"))
        let camera = UUID(), other = UUID()
        let before = engine.workGeneration(for: camera)
        let otherBefore = engine.workGeneration(for: other)
        engine.removeCamera(camera)
        XCTAssertFalse(engine.isCurrent(before, cameraID: camera))
        XCTAssertTrue(engine.isCurrent(otherBefore, cameraID: other))
        let replacement = engine.workGeneration(for: camera)
        engine.stopEngine()
        XCTAssertFalse(engine.isCurrent(replacement, cameraID: camera))
        XCTAssertFalse(engine.isCurrent(otherBefore, cameraID: other))
        XCTAssertTrue(engine.trackedPosesByCamera.isEmpty)
        XCTAssertEqual(engine.engineState, .disabled)
    }
}
