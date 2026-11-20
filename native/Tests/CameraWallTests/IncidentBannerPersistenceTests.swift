import Foundation
import XCTest
@testable import CameraCore
@testable import CameraWall

@MainActor
final class IncidentBannerPersistenceTests: XCTestCase {
    func testFailedTransitionKeepsCriticalBannerAndReportsFailure() throws {
        try withEngine { engine, root, incident in
            let otherAudit = OperatorAuditLog(url: root.appendingPathComponent("audit.json"))
            let otherManager = UnifiedIncidentManager(storageURL: root.appendingPathComponent("incidents.json"),
                                                      auditLog: otherAudit)
            XCTAssertNotNil(otherManager.transitionStatus(incidentID: incident.id, to: .acknowledged))

            engine.transitionIncident(incident.id, to: .resolved)

            XCTAssertEqual(engine.activeBannerIncident?.id, incident.id)
            XCTAssertEqual(engine.activeBannerIncident?.status, .active)
            XCTAssertEqual(engine.incidents.first?.status, .active)
            XCTAssertNotNil(engine.persistenceError)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode([SafetyIncident].self,
                                           from: Data(contentsOf: root.appendingPathComponent("incidents.json")))
            XCTAssertEqual(saved.first?.status, .acknowledged)
        }
    }

    func testSuccessfulTransitionsOnlyDismissMatchingClosedBanner() throws {
        try withEngine { engine, root, incident in
            engine.transitionIncident(UUID(), to: .resolved)
            XCTAssertEqual(engine.activeBannerIncident?.id, incident.id)

            engine.transitionIncident(incident.id, to: .acknowledged)
            XCTAssertEqual(engine.activeBannerIncident?.status, .acknowledged)

            engine.transitionIncident(incident.id, to: .resolved)
            XCTAssertNil(engine.activeBannerIncident)
            XCTAssertEqual(engine.incidents.first?.status, .resolved)
            XCTAssertNil(engine.persistenceError)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode([SafetyIncident].self,
                                           from: Data(contentsOf: root.appendingPathComponent("incidents.json")))
            XCTAssertEqual(saved.first?.status, .resolved)
        }
    }

    func testEvidenceDeletionFailureIsReportedAndClearedAfterSuccess() throws {
        try withEngine { engine, _, incident in
            let missingID = UUID()
            engine.deleteIncidentEvidence(missingID)
            XCTAssertNotNil(engine.evidenceDeletionError)
            XCTAssertEqual(engine.evidenceDeletionError?.incidentID, missingID)
            XCTAssertNil(engine.persistenceError)

            engine.deleteIncidentEvidence(incident.id)
            XCTAssertNil(engine.evidenceDeletionError)
            XCTAssertNil(engine.persistenceError)
        }
    }

    func testFailedEvidenceReferenceSaveDoesNotClaimSuccessOrClearMemory() throws {
        try withEngine { engine, root, incident in
            let bundleID = UUID()
            XCTAssertNotNil(engine.incidentManager.attachEvidence(incidentID: incident.id, clipID: bundleID,
                                                                  snapshotRelativePath: "snapshot.jpg"))
            let evidence = root.appendingPathComponent("evidence").appendingPathComponent(bundleID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: evidence.appendingPathComponent("snapshot.jpg"))

            let otherAudit = OperatorAuditLog(url: root.appendingPathComponent("audit.json"))
            let otherManager = UnifiedIncidentManager(storageURL: root.appendingPathComponent("incidents.json"),
                                                      auditLog: otherAudit)
            XCTAssertNotNil(otherManager.transitionStatus(incidentID: incident.id, to: .acknowledged))

            engine.deleteIncidentEvidence(incident.id)

            XCTAssertTrue(engine.evidenceDeletionError?.message.contains("may have been deleted") == true)
            XCTAssertEqual(engine.incidentManager.incident(id: incident.id)?.clipID, bundleID)
            XCTAssertFalse(engine.auditLog.recentEntries().contains { $0.action == .evidenceDeleted })
        }
    }

    func testEvidenceDeletionPersistsReferencesAndAudit() throws {
        try withEngine { engine, root, incident in
            let bundleID = UUID()
            XCTAssertNotNil(engine.incidentManager.attachEvidence(incidentID: incident.id, clipID: bundleID,
                                                                  snapshotRelativePath: "snapshot.jpg"))
            let evidence = root.appendingPathComponent("evidence").appendingPathComponent(bundleID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: evidence.appendingPathComponent("snapshot.jpg"))

            engine.deleteIncidentEvidence(incident.id)

            XCTAssertNil(engine.evidenceDeletionError)
            XCTAssertFalse(try engine.evidenceStore.hasEvidenceBundleChecked(for: bundleID))
            let audit = OperatorAuditLog(url: root.appendingPathComponent("audit.json"))
            let manager = UnifiedIncidentManager(storageURL: root.appendingPathComponent("incidents.json"), auditLog: audit)
            XCTAssertNil(manager.incident(id: incident.id)?.clipID)
            XCTAssertNil(manager.incident(id: incident.id)?.snapshotRelativePath)
            XCTAssertEqual(audit.recentEntries().filter { $0.action == .evidenceDeleted }.count, 1)
        }
    }

    func testInvalidEvidencePathCannotBeReportedAsDeleted() throws {
        try withEngine { engine, root, incident in
            let blocker = root.appendingPathComponent("evidence")
            try Data("synthetic".utf8).write(to: blocker)

            engine.deleteIncidentEvidence(incident.id)

            XCTAssertEqual(engine.evidenceDeletionError?.incidentID, incident.id)
            XCTAssertFalse(engine.auditLog.recentEntries().contains { $0.action == .evidenceDeleted })
            XCTAssertEqual(try Data(contentsOf: blocker), Data("synthetic".utf8))
        }
    }

    private func withEngine(_ body: (LocalVideoAnalyticsEngine, URL, SafetyIncident) throws -> Void) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".incident-banner-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = VideoAnalyticsSettings.safeDefaults
        settings.enableProlongedInactivity = false
        settings.enableLoiteringDetection = false
        settings.enableSoundAlert = false
        settings.enableEvidenceRecording = false
        settings.enableVisualAlertBanner = true
        let settingsURL = root.appendingPathComponent("settings.json")
        try VideoAnalyticsSettingsStore.save(settings, to: settingsURL)
        let engine = LocalVideoAnalyticsEngine(
            settingsURL: settingsURL, incidentsURL: root.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence"),
            auditLogURL: root.appendingPathComponent("audit.json"),
            modelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { _ in
                XCTFail("Unexpected model access")
                return ("", 0)
            }))
        let camera = Camera(name: "Synthetic", substream: "rtsp://test.invalid/live", yoloEnabled: true)
        for index in 0..<30 {
            _ = engine.processExternalPoseResult(people: [pose(horizontal: index >= 10)], camera: camera,
                frameWidth: 1000, frameHeight: 1000, monotonicTimestamp: Double(index) * 0.1)
        }
        let incident = try XCTUnwrap(engine.activeBannerIncident)
        XCTAssertEqual(incident.severity, .critical)
        XCTAssertEqual(incident.status, .active)
        XCTAssertNil(engine.persistenceError)
        try body(engine, root, incident)
    }

    private func pose(horizontal: Bool) -> PosePerson {
        let x = 0.5, y = horizontal ? 0.62 : 0.5
        var keypoints = Array(repeating: PoseKeypoint(x: x, y: y, confidence: 0.1), count: 17)
        let shoulder = horizontal ? (x - 0.04, y) : (x, y - 0.04)
        let hip = horizontal ? (x + 0.04, y) : (x, y + 0.04)
        for index in [5, 6] { keypoints[index] = PoseKeypoint(x: shoulder.0, y: shoulder.1, confidence: 0.9) }
        for index in [11, 12] { keypoints[index] = PoseKeypoint(x: hip.0, y: hip.1, confidence: 0.9) }
        let width = horizontal ? 0.2 : 0.07, height = horizontal ? 0.07 : 0.2
        return PosePerson(confidence: 0.9, box: PoseBoundingBox(x: x - width / 2, y: y - height / 2,
            width: width, height: height), keypoints: keypoints)
    }
}
