import Foundation
import XCTest
@testable import CameraCore

final class EvidenceReliabilityTests: XCTestCase {
    private func candidate(camera: UUID, at date: Date = Date()) -> BehaviorSafetyCandidate {
        BehaviorSafetyCandidate(cameraID: camera, trackIDs: [UUID()], type: .fallConfirmed,
            severity: .critical, confidence: 0.9, monotonicTimestamp: 1, occurredAt: date,
            explanation: "Test event", detectorSource: "test")
    }

    func testSuppressionSurvivesRestartAndExplicitReopenRemovesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("incidents.json")
        let audit = OperatorAuditLog(url: root.appendingPathComponent("audit.json"))
        let manager = UnifiedIncidentManager(storageURL: url, auditLog: audit)
        let camera = UUID(), now = Date(), event = candidate(camera: camera)
        _ = manager.ingest(candidate: event, cameraName: "Camera")
        _ = manager.transitionStatus(incidentID: event.id, to: .suppressed, suppressDurationSeconds: 300, at: now)
        let restarted = UnifiedIncidentManager(storageURL: url, auditLog: audit)
        XCTAssertNil(restarted.ingest(candidate: candidate(camera: camera, at: now.addingTimeInterval(1)), cameraName: "Camera"))
        _ = restarted.transitionStatus(incidentID: event.id, to: .active, at: now.addingTimeInterval(2))
        let reopened = UnifiedIncidentManager(storageURL: url, auditLog: audit)
        XCTAssertNotNil(reopened.ingest(candidate: candidate(camera: camera, at: now.addingTimeInterval(3)), cameraName: "Camera"))
        XCTAssertNil(reopened.incident(id: event.id)?.suppressedUntil)
    }

    func testConcurrentDuplicateEventsShareOneCanonicalEvidenceBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = UnifiedIncidentManager(storageURL: root.appendingPathComponent("incidents.json"),
            auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
        let evidence = SafetyEvidenceStore(baseDirectoryURL: root.appendingPathComponent("evidence"))
        let camera = UUID(), now = Date()
        let candidates = (0..<20).map { _ in candidate(camera: camera, at: now) }
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            _ = manager.ingestWithEvidence(candidate: candidates[index], cameraName: "Camera", evidenceStore: evidence,
                triggerSnapshotJPEG: Data([1, 2, 3]), enableEvidence: true, postEventBufferSeconds: 0)
        }
        let incident = try XCTUnwrap(manager.allIncidents().first)
        XCTAssertEqual(manager.allIncidents().count, 1)
        XCTAssertEqual(incident.clipID, incident.id)
        XCTAssertEqual(evidence.loadManifest(for: incident.id)?.incidentID, incident.id)
        let directories = try FileManager.default.contentsOfDirectory(at: evidence.baseDirectoryURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(directories.map(\.lastPathComponent), [incident.id.uuidString.lowercased()])
        XCTAssertNil(evidence.lastPersistenceError)
    }

    func testEvidenceFailurePreservesAlertAndRetryUsesItsOriginalID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocker)
        let manager = UnifiedIncidentManager(storageURL: root.appendingPathComponent("incidents.json"),
            auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
        let evidence = SafetyEvidenceStore(baseDirectoryURL: blocker.appendingPathComponent("evidence"))
        let camera = UUID(), first = candidate(camera: camera)
        let initial = manager.ingestWithEvidence(candidate: first, cameraName: "Camera", evidenceStore: evidence,
            triggerSnapshotJPEG: Data([1]), enableEvidence: true)
        XCTAssertEqual(initial?.id, first.id)
        XCTAssertNil(initial?.clipID)
        XCTAssertNotNil(evidence.lastPersistenceError)
        try FileManager.default.removeItem(at: blocker)
        let retried = manager.ingestWithEvidence(candidate: candidate(camera: camera), cameraName: "Camera", evidenceStore: evidence,
            triggerSnapshotJPEG: Data([2]), enableEvidence: true)
        XCTAssertEqual(retried?.id, first.id)
        XCTAssertEqual(retried?.clipID, first.id)
        XCTAssertEqual(evidence.loadSnapshot(for: first.id), Data([2]))
    }

    func testPublishedBundleIsNotOverwrittenAndCorruptionIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = SafetyEvidenceStore(baseDirectoryURL: root)
        let event = candidate(camera: UUID()), canonicalID = UUID()
        _ = try evidence.createEvidenceBundle(for: event, incidentID: canonicalID, cameraName: "Camera",
            triggerSnapshotJPEG: Data([1]), postEventBufferSeconds: 0)
        _ = try evidence.createEvidenceBundle(for: event, incidentID: canonicalID, cameraName: "Camera",
            triggerSnapshotJPEG: Data([2]), postEventBufferSeconds: 0)
        XCTAssertEqual(evidence.loadSnapshot(for: canonicalID), Data([1]))
        let manifest = root.appendingPathComponent(canonicalID.uuidString.lowercased()).appendingPathComponent("manifest.json")
        let broken = Data("broken".utf8)
        try broken.write(to: manifest)
        XCTAssertThrowsError(try evidence.createEvidenceBundle(for: event, incidentID: canonicalID, cameraName: "Camera", triggerSnapshotJPEG: Data([3])))
        XCTAssertEqual(try Data(contentsOf: manifest), broken)
        XCTAssertEqual(evidence.loadSnapshot(for: canonicalID), Data([1]))
        XCTAssertNotNil(evidence.lastPersistenceError)
    }

    func testSuppressedEventCreatesNoEvidenceAndDeletionClearsReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("incidents.json")
        let manager = UnifiedIncidentManager(storageURL: url, auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
        let evidence = SafetyEvidenceStore(baseDirectoryURL: root.appendingPathComponent("evidence"))
        let camera = UUID(), event = candidate(camera: camera)
        let incident = try XCTUnwrap(manager.ingestWithEvidence(candidate: event, cameraName: "Camera", evidenceStore: evidence,
            triggerSnapshotJPEG: Data([1]), enableEvidence: true, postEventBufferSeconds: 0))
        _ = manager.transitionStatus(incidentID: incident.id, to: .suppressed, suppressDurationSeconds: 300)
        XCTAssertNil(manager.ingestWithEvidence(candidate: candidate(camera: camera), cameraName: "Camera", evidenceStore: evidence,
            triggerSnapshotJPEG: Data([2]), enableEvidence: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: evidence.baseDirectoryURL.path).count, 1)
        try evidence.deleteEvidence(for: incident.id)
        manager.clearEvidenceReferences(incidentID: incident.id)
        let reloaded = UnifiedIncidentManager(storageURL: url, auditLog: manager.auditLog)
        XCTAssertNil(reloaded.incident(id: incident.id)?.clipID)
        XCTAssertNil(reloaded.incident(id: incident.id)?.snapshotRelativePath)
    }
}
