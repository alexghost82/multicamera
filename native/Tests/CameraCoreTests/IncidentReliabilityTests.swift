import Foundation
import XCTest
@testable import CameraCore

final class IncidentReliabilityTests: XCTestCase {
    private func candidate(cameraID: UUID = UUID()) -> BehaviorSafetyCandidate {
        BehaviorSafetyCandidate(cameraID: cameraID, trackIDs: [UUID()], type: .fallConfirmed,
            severity: .critical, confidence: 0.9, monotonicTimestamp: 1,
            explanation: "Test fall", detectorSource: "test")
    }

    func testConcurrentMutationsSurviveReloadWithoutAnOlderSnapshotWinning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = OperatorAuditLog(url: root.appendingPathComponent("audit.json"))
        let url = root.appendingPathComponent("incidents.json")
        let manager = UnifiedIncidentManager(storageURL: url, auditLog: audit)
        let candidates = (0..<100).map { _ in candidate() }
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let event = candidates[index]
            _ = manager.ingest(candidate: event, cameraName: "Camera")
            _ = manager.transitionStatus(incidentID: event.id, to: .acknowledged)
        }
        XCTAssertNil(manager.lastPersistenceError)
        XCTAssertNil(audit.lastPersistenceError)
        let reloaded = UnifiedIncidentManager(storageURL: url, auditLog: audit)
        XCTAssertEqual(Set(reloaded.allIncidents().map(\.id)), Set(candidates.map(\.id)))
        XCTAssertTrue(reloaded.allIncidents().allSatisfy { $0.status == .acknowledged })
        XCTAssertEqual(OperatorAuditLog(url: audit.url).recentEntries(limit: 1000).count, 200)
    }

    func testCorruptHistoryIsReportedAndNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let broken = Data("{truncated".utf8)
        let url = root.appendingPathComponent("incidents.json")
        let auditURL = root.appendingPathComponent("audit.json")
        try broken.write(to: url)
        try broken.write(to: auditURL)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: url, auditLog: audit)
        _ = manager.ingest(candidate: candidate(), cameraName: "Camera")
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertEqual(try Data(contentsOf: auditURL), broken)
    }

    func testWriteFailureIsVisibleAndNextMutationRetriesPendingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("blocked")
        try Data("file blocks directory".utf8).write(to: parent)
        let manager = UnifiedIncidentManager(storageURL: parent.appendingPathComponent("incidents.json"),
            auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
        _ = manager.ingest(candidate: candidate(), cameraName: "Camera")
        XCTAssertNotNil(manager.lastPersistenceError)
        try FileManager.default.removeItem(at: parent)
        _ = manager.ingest(candidate: candidate(), cameraName: "Camera")
        XCTAssertNil(manager.lastPersistenceError)
        let reloaded = UnifiedIncidentManager(storageURL: manager.storageURL, auditLog: manager.auditLog)
        XCTAssertEqual(reloaded.allIncidents().count, 2)
    }

    func testSecondaryVerificationRejectsAmbiguousOrMalformedOutput() throws {
        for response in ["normal", "I cannot rule out a fall", "{}",
                         "{\"decision\":\"confirmed\",\"summary\":\"\"}",
                         "{\"decision\":\"yes\",\"summary\":\"fall\"}",
                         "{\"decision\":\"confirmed\",\"summary\":\"fall\",\"extra\":true}",
                         "```json\n{\"decision\":\"confirmed\",\"summary\":\"fall\"}\n```"] {
            XCTAssertThrowsError(try IncidentVerification.parse(response), response)
        }
        let result = try IncidentVerification.parse("{\"decision\":\"inconclusive\",\"summary\":\" Person obscured \"}")
        XCTAssertEqual(result.status, .inconclusive)
        XCTAssertEqual(result.summary, "Person obscured")
    }

    func testInconclusiveAndRejectedVerificationPreservePrimaryFallAlert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = UnifiedIncidentManager(storageURL: root.appendingPathComponent("incidents.json"),
            auditLog: OperatorAuditLog(url: root.appendingPathComponent("audit.json")))
        let event = candidate()
        _ = manager.ingest(candidate: event, cameraName: "Camera")
        for status: SecondaryVerificationStatus in [.inconclusive, .unavailable, .rejected] {
            let updated = manager.recordSecondaryVLMVerification(incidentID: event.id, status: status, summary: "Uncertain")
            XCTAssertEqual(updated?.status, .active)
        }
    }
}
