import Darwin
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

    func testDeletionReportsInaccessiblePathInsteadOfClaimingAbsence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocker)
        let evidence = SafetyEvidenceStore(baseDirectoryURL: blocker.appendingPathComponent("evidence"))
        let id = UUID()
        XCTAssertThrowsError(try evidence.hasEvidenceBundleChecked(for: id))
        XCTAssertThrowsError(try evidence.deleteEvidence(for: id))
        XCTAssertNotNil(evidence.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: blocker), Data([1]))
    }

    func testCheckedExistenceRejectsDanglingParentWithoutChangingLinkedRootBehavior() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let id = UUID()
        let dangling = root.url.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling,
            withDestinationURL: root.url.appendingPathComponent("missing"))
        let store = SafetyEvidenceStore(baseDirectoryURL: dangling.appendingPathComponent("evidence"))
        XCTAssertThrowsError(try store.hasEvidenceBundleChecked(for: id))
        XCTAssertThrowsError(try store.deleteEvidence(for: id))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: dangling).hasEvidenceBundleChecked(for: id))
        let linkedRoot = root.url.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root.url)
        let linkedStore = SafetyEvidenceStore(baseDirectoryURL: linkedRoot)
        XCTAssertFalse(try linkedStore.hasEvidenceBundleChecked(for: id))
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent(id.uuidString.lowercased()),
                                                withIntermediateDirectories: false)
        XCTAssertTrue(try linkedStore.hasEvidenceBundleChecked(for: id))
        XCTAssertFalse(try SafetyEvidenceStore(baseDirectoryURL: root.url.appendingPathComponent("absent"))
            .hasEvidenceBundleChecked(for: id))
    }

    func testDeletionRejectsNonDirectoryBundleWithoutRemovingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = SafetyEvidenceStore(baseDirectoryURL: root)
        let id = UUID()
        let path = root.appendingPathComponent(id.uuidString.lowercased())
        try Data([1, 2]).write(to: path)
        XCTAssertThrowsError(try evidence.deleteEvidence(for: id))
        XCTAssertEqual(try Data(contentsOf: path), Data([1, 2]))
        let linkedID = UUID()
        let link = root.appendingPathComponent(linkedID.uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try evidence.deleteEvidence(for: linkedID))
        XCTAssertEqual(try Data(contentsOf: link), Data([1, 2]))
    }

    func testCheckedSnapshotDistinguishesAbsenceFromReadableFile() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let base = root.url.appendingPathComponent("evidence")
        let store = SafetyEvidenceStore(baseDirectoryURL: base)
        let id = UUID()
        XCTAssertNil(try store.loadSnapshotChecked(for: id))

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        XCTAssertNil(try store.loadSnapshotChecked(for: id))
        let bundle = base.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        XCTAssertNil(try store.loadSnapshotChecked(for: id))
        XCTAssertNil(store.loadSnapshot(for: id))

        let bytes = Data([1, 2, 3])
        try bytes.write(to: bundle.appendingPathComponent("snapshot.jpg"))
        XCTAssertEqual(try store.loadSnapshotChecked(for: id), bytes)
        XCTAssertEqual(store.loadSnapshot(for: id), bytes)
    }

    func testCheckedSnapshotRejectsInvalidPathsAndLinks() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let id = UUID()
        let blocker = root.url.appendingPathComponent("file")
        try Data([1]).write(to: blocker)
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: blocker).loadSnapshotChecked(for: id))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: blocker.appendingPathComponent("child"))
            .loadSnapshotChecked(for: id))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: URL(string: "https://example.invalid/evidence")!)
            .loadSnapshotChecked(for: id))

        let store = SafetyEvidenceStore(baseDirectoryURL: root.url)
        let bundle = root.url.appendingPathComponent(id.uuidString.lowercased())
        try Data([1]).write(to: bundle)
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: id))
        try FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let snapshot = bundle.appendingPathComponent("snapshot.jpg")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: id))
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: blocker)
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: id))
        XCTAssertEqual(store.loadSnapshot(for: id), Data([1]))
        XCTAssertEqual(try Data(contentsOf: blocker), Data([1]))
        try FileManager.default.removeItem(at: snapshot)
        XCTAssertEqual(mkfifo(snapshot.path, 0o600), 0)
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: id))

        let linkedID = UUID()
        let linkedBundle = root.url.appendingPathComponent(linkedID.uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: linkedBundle, withDestinationURL: bundle)
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: linkedID))
        let danglingID = UUID()
        try FileManager.default.createSymbolicLink(
            at: root.url.appendingPathComponent(danglingID.uuidString.lowercased()),
            withDestinationURL: root.url.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: danglingID))
        let linkedBase = root.url.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedBase, withDestinationURL: root.url)
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: linkedBase).loadSnapshotChecked(for: id))
        let danglingParent = root.url.appendingPathComponent("dangling-parent")
        try FileManager.default.createSymbolicLink(at: danglingParent,
                                                   withDestinationURL: root.url.appendingPathComponent("missing"))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: danglingParent.appendingPathComponent("evidence"))
            .loadSnapshotChecked(for: id))
    }

    func testCheckedSnapshotReportsRealReadPermissionFailure() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can bypass file permissions.") }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let id = UUID()
        let bundle = root.url.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let snapshot = bundle.appendingPathComponent("snapshot.jpg")
        try Data([1]).write(to: snapshot)
        guard chmod(snapshot.path, 0) == 0 else { throw POSIXError(.EIO) }
        defer { _ = chmod(snapshot.path, 0o600) }

        let store = SafetyEvidenceStore(baseDirectoryURL: root.url)
        XCTAssertThrowsError(try store.loadSnapshotChecked(for: id)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertNil(store.loadSnapshot(for: id))
    }

    func testCheckedClipFramesHandlesMissingAndPreservesFrameOrder() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let base = root.url.appendingPathComponent("evidence")
        let store = SafetyEvidenceStore(baseDirectoryURL: base)
        let id = UUID()
        XCTAssertEqual(try store.loadClipFramesChecked(for: id), [])
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        XCTAssertEqual(try store.loadClipFramesChecked(for: id), [])
        let bundle = base.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        XCTAssertEqual(try store.loadClipFramesChecked(for: id), [])
        for (name, value) in [("post-02.jpg", 4), ("pre-02.jpg", 2),
                              ("post-01.jpg", 3), ("pre-01.jpg", 1), ("other.jpg", 5)] {
            try Data([UInt8(value)]).write(to: bundle.appendingPathComponent(name))
        }
        let frames = [Data([1]), Data([2]), Data([3]), Data([4])]
        XCTAssertEqual(try store.loadClipFramesChecked(for: id), frames)
        XCTAssertEqual(store.loadClipFrames(for: id), frames)
    }

    func testCheckedClipFramesRejectsInvalidPathsAndFrameTypes() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let id = UUID()
        let blocker = root.url.appendingPathComponent("file")
        try Data([1]).write(to: blocker)
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: blocker).loadClipFramesChecked(for: id))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: blocker.appendingPathComponent("child"))
            .loadClipFramesChecked(for: id))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: URL(string: "https://example.invalid/evidence")!)
            .loadClipFramesChecked(for: id))
        let dangling = root.url.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.url.appendingPathComponent("missing"))
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: dangling.appendingPathComponent("evidence"))
            .loadClipFramesChecked(for: id))

        let store = SafetyEvidenceStore(baseDirectoryURL: root.url)
        let bundle = root.url.appendingPathComponent(id.uuidString.lowercased())
        try Data([1]).write(to: bundle)
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: id))
        try FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let frame = bundle.appendingPathComponent("pre-01.jpg")
        try FileManager.default.createDirectory(at: frame, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: id))
        try FileManager.default.removeItem(at: frame)
        try FileManager.default.createSymbolicLink(at: frame, withDestinationURL: blocker)
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: id))
        XCTAssertEqual(store.loadClipFrames(for: id), [Data([1])])
        try FileManager.default.removeItem(at: frame)
        XCTAssertEqual(mkfifo(frame.path, 0o600), 0)
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: id))

        let linkedID = UUID()
        try FileManager.default.createSymbolicLink(at: root.url.appendingPathComponent(linkedID.uuidString.lowercased()),
                                                   withDestinationURL: bundle)
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: linkedID))
        let danglingID = UUID()
        try FileManager.default.createSymbolicLink(at: root.url.appendingPathComponent(danglingID.uuidString.lowercased()),
                                                   withDestinationURL: root.url.appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: danglingID))
        let linkedBase = root.url.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedBase, withDestinationURL: root.url)
        XCTAssertThrowsError(try SafetyEvidenceStore(baseDirectoryURL: linkedBase).loadClipFramesChecked(for: id))
    }

    func testCheckedClipFramesReportsRealPermissionFailure() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can bypass file permissions.") }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let id = UUID()
        let bundle = root.url.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let frame = bundle.appendingPathComponent("pre-01.jpg")
        try Data([1]).write(to: frame)
        guard chmod(frame.path, 0) == 0 else { throw POSIXError(.EIO) }
        defer { _ = chmod(frame.path, 0o600) }

        let store = SafetyEvidenceStore(baseDirectoryURL: root.url)
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: id)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertEqual(store.loadClipFrames(for: id), [])
        defer { _ = chmod(bundle.path, 0o700) }
        guard chmod(frame.path, 0o600) == 0, chmod(bundle.path, 0o100) == 0 else { throw POSIXError(.EIO) }
        XCTAssertThrowsError(try store.loadClipFramesChecked(for: id)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
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
