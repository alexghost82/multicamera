import Foundation
import XCTest
@testable import CameraCore
@testable import CameraWall

@MainActor
final class SafetyPipelineIntegrationTests: XCTestCase {
    func testSyntheticPoseFallProducesOneDurableIncidentWithEvidenceAndRecoversAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = VideoAnalyticsSettings.safeDefaults
        settings.enableProlongedInactivity = false
        settings.enableLoiteringDetection = false
        settings.enableSoundAlert = false
        try VideoAnalyticsSettingsStore.save(settings, to: root.appendingPathComponent("settings.json"))
        func engine() -> LocalVideoAnalyticsEngine {
            LocalVideoAnalyticsEngine(settingsURL: root.appendingPathComponent("settings.json"),
                incidentsURL: root.appendingPathComponent("incidents.json"),
                evidenceDirectoryURL: root.appendingPathComponent("evidence"), auditLogURL: root.appendingPathComponent("audit.json"))
        }
        let runtime = engine()
        defer { runtime.stopEngine() }
        let camera = Camera(name: "Synthetic", substream: "rtsp://test.invalid/live", yoloEnabled: true)
        let before = Data([1, 2, 3])
        runtime.evidenceStore.recordSampledFrame(cameraID: camera.id, jpegData: before, capturedAt: Date().addingTimeInterval(-1))
        for index in 0..<30 {
            _ = runtime.processExternalPoseResult(people: [pose(horizontal: index >= 10)], camera: camera,
                frameWidth: 1000, frameHeight: 1000, monotonicTimestamp: Double(index) * 0.1)
        }
        XCTAssertEqual(runtime.incidents.count, 1)
        let incident = try XCTUnwrap(runtime.incidents.first)
        XCTAssertEqual(incident.type, .fallConfirmed)
        XCTAssertEqual(incident.clipID, incident.id)
        XCTAssertEqual(runtime.activeBannerIncident?.id, incident.id)
        XCTAssertFalse(runtime.trackedPosesByCamera[camera.id, default: []].isEmpty)
        runtime.evidenceStore.recordSampledFrame(cameraID: camera.id, jpegData: Data([4]), capturedAt: Date().addingTimeInterval(1))
        let manifest = try XCTUnwrap(runtime.evidenceStore.loadManifest(for: incident.id))
        XCTAssertGreaterThanOrEqual(manifest.preEventFrameCount, 1)
        XCTAssertEqual(manifest.postEventFrameCount, 1)
        XCTAssertEqual(manifest.cameraID, camera.id)
        runtime.updateIncidentNote(incident.id, note: "Operator review")
        XCTAssertEqual(runtime.incidents.first?.status, incident.status)
        let restarted = engine()
        defer { restarted.stopEngine() }
        XCTAssertEqual(restarted.incidents.first?.id, incident.id)
        XCTAssertEqual(restarted.incidents.first?.operatorNotes, "Operator review")
        XCTAssertEqual(restarted.evidenceStore.loadSnapshot(for: incident.id), before)
        restarted.deleteIncidentEvidence(incident.id)
        XCTAssertNil(restarted.incidents.first?.clipID)
        XCTAssertNil(restarted.evidenceStore.loadManifest(for: incident.id))
        XCTAssertNil(restarted.persistenceError)
    }

    private func pose(horizontal: Bool) -> PosePerson {
        let centerX = 0.5, centerY = horizontal ? 0.62 : 0.5
        var keypoints = Array(repeating: PoseKeypoint(x: centerX, y: centerY, confidence: 0.1), count: 17)
        let shoulder = horizontal ? (centerX - 0.04, centerY) : (centerX, centerY - 0.04)
        let hip = horizontal ? (centerX + 0.04, centerY) : (centerX, centerY + 0.04)
        for index in [5, 6] { keypoints[index] = PoseKeypoint(x: shoulder.0, y: shoulder.1, confidence: 0.9) }
        for index in [11, 12] { keypoints[index] = PoseKeypoint(x: hip.0, y: hip.1, confidence: 0.9) }
        let width = horizontal ? 0.2 : 0.07, height = horizontal ? 0.07 : 0.2
        return PosePerson(confidence: 0.9, box: PoseBoundingBox(x: centerX - width / 2, y: centerY - height / 2,
            width: width, height: height), keypoints: keypoints)
    }
}
