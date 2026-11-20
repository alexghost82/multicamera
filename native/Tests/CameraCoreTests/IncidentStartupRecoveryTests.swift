import Foundation
import XCTest
@testable import CameraCore

final class IncidentStartupRecoveryTests: XCTestCase {
    private struct Failure: Error {}

    private func seed(_ root: URL) throws -> (URL, URL, Data, Data, UUID) {
        let incidentURL = root.appendingPathComponent("incidents.json")
        let auditURL = root.appendingPathComponent("audit.json")
        let incident = SafetyIncident(cameraID: UUID(), cameraName: "synthetic", trackIDs: [],
                                      type: .fallConfirmed, severity: .critical, confidence: 0.5,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      updatedAt: Date(timeIntervalSince1970: 0),
                                      title: "test", explanation: "test", detectorSource: "test")
        let audit = OperatorAuditEntry(occurredAt: Date(timeIntervalSince1970: 0),
                                       action: .incidentCreated, incidentID: incident.id, summary: "existing")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let incidents = try encoder.encode([incident])
        let audits = try encoder.encode([audit])
        try incidents.write(to: incidentURL)
        try audits.write(to: auditURL)
        return (incidentURL, auditURL, incidents, audits, incident.id)
    }

    func testStartupRecoversSubprocessCrashAtEveryBoundaryAndRefreshesAudit() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incidentURL, auditURL, beforeIncidents, beforeAudit, id) = try seed(root.url)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: helper)
            child.arguments = [root.url.path, "strict-crash", String(describing: boundary)]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 44, "\(boundary)")
            let audit = OperatorAuditLog(url: auditURL)
            let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
            XCTAssertNil(manager.lastPersistenceError, "\(boundary)")
            XCTAssertNil(audit.lastPersistenceError, "\(boundary)")
            let old = boundary == .beforeJournalStaging || boundary == .afterJournalStaging
            XCTAssertEqual(manager.incident(id: id) != nil, old, "\(boundary)")
            XCTAssertEqual(audit.recentEntries().map(\.summary), old ? ["existing"] : [], "\(boundary)")
            XCTAssertEqual(try Data(contentsOf: incidentURL), old ? beforeIncidents : Data("[]".utf8), "\(boundary)")
            XCTAssertEqual(try Data(contentsOf: auditURL), old ? beforeAudit : Data("[]".utf8), "\(boundary)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".incident-audit.transaction.json").path))
        }
    }

    func testManagerNoteAndAuditRecoverTogetherAtEveryTransactionBoundary() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incidentURL, auditURL, _, _, id) = try seed(root.url)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: helper)
            child.arguments = [root.url.path, "manager-crash", String(describing: boundary)]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 44, "\(boundary)")
            let audit = OperatorAuditLog(url: auditURL)
            let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
            XCTAssertNil(manager.lastPersistenceError, "\(boundary)")
            XCTAssertNil(audit.lastPersistenceError, "\(boundary)")
            let committed = boundary != .beforeJournalStaging && boundary != .afterJournalStaging
            XCTAssertEqual(manager.incident(id: id)?.operatorNotes, committed ? "committed" : "", "\(boundary)")
            let notes = audit.recentEntries().filter { $0.action == .incidentNoteUpdated }
            XCTAssertEqual(notes.map(\.details), committed ? ["committed"] : [], "\(boundary)")
        }
    }

    func testManagerAuditedMutationsPersistBothDocuments() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        manager.updateOperatorNote(incidentID: id, note: "operator note")
        _ = manager.transitionStatus(incidentID: id, to: .acknowledged)
        _ = manager.recordSecondaryVLMVerification(incidentID: id, status: .confirmed, summary: "confirmed")
        let candidate = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [], type: .fallConfirmed,
            severity: .critical, confidence: 0.5, monotonicTimestamp: 1,
            explanation: "synthetic", detectorSource: "test")
        let created = try XCTUnwrap(manager.ingest(candidate: candidate, cameraName: "synthetic"))
        XCTAssertNil(manager.lastPersistenceError)
        XCTAssertNil(audit.lastPersistenceError)
        let reopenedAudit = OperatorAuditLog(url: auditURL)
        let reopened = UnifiedIncidentManager(storageURL: incidentURL, auditLog: reopenedAudit)
        XCTAssertNil(reopened.lastPersistenceError)
        XCTAssertEqual(reopened.incident(id: id)?.operatorNotes, "operator note")
        XCTAssertEqual(reopened.incident(id: id)?.status, .acknowledged)
        XCTAssertEqual(reopened.incident(id: id)?.secondaryVLMStatus, .confirmed)
        XCTAssertNotNil(reopened.incident(id: created.id))
        XCTAssertEqual(reopenedAudit.recentEntries().prefix(4).map(\.action),
                       [.incidentCreated, .secondaryVLMVerified, .incidentAcknowledged, .incidentNoteUpdated])
    }

    func testStaleEvidenceAttachmentDoesNotPublishUncommittedReference() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let first = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
        let before = try XCTUnwrap(stale.incident(id: id))
        first.updateOperatorNote(incidentID: id, note: "concurrent change")

        XCTAssertNil(stale.attachEvidence(incidentID: id, clipID: UUID(), snapshotRelativePath: "snapshot.jpg"))
        XCTAssertEqual(stale.incident(id: id), before)
        XCTAssertNotNil(stale.lastPersistenceError)
    }

    func testEvidenceReferencesAndAuditRecoverTogetherAtEveryBoundary() throws {
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incidentURL, auditURL, _, _, id) = try seed(root.url)
            let initial = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
            let bundleID = UUID()
            XCTAssertNotNil(initial.attachEvidence(incidentID: id, clipID: bundleID, snapshotRelativePath: "snapshot.jpg"))
            let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL),
                transactionFault: { if $0 == boundary { throw Failure() } })

            XCTAssertFalse(manager.clearEvidenceReferencesAndAudit(incidentID: id), "\(boundary)")
            XCTAssertEqual(manager.incident(id: id)?.clipID, bundleID, "\(boundary)")
            XCTAssertNotNil(manager.lastPersistenceError, "\(boundary)")

            let recoveredAudit = OperatorAuditLog(url: auditURL)
            let recovered = UnifiedIncidentManager(storageURL: incidentURL, auditLog: recoveredAudit)
            XCTAssertNil(recovered.lastPersistenceError, "\(boundary)")
            let committed = boundary != .beforeJournalStaging && boundary != .afterJournalStaging
            XCTAssertEqual(recovered.incident(id: id)?.clipID, committed ? nil : bundleID, "\(boundary)")
            XCTAssertEqual(recoveredAudit.recentEntries().filter { $0.action == .evidenceDeleted }.count,
                           committed ? 1 : 0, "\(boundary)")
        }
    }

    func testEvidenceReferencesAndAuditRecoverAfterProcessCrash() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incidentURL, auditURL, _, _, id) = try seed(root.url)
            let initial = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
            let bundleID = UUID()
            XCTAssertNotNil(initial.attachEvidence(incidentID: id, clipID: bundleID, snapshotRelativePath: "snapshot.jpg"))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: helper)
            child.arguments = [root.url.path, "manager-evidence-crash", String(describing: boundary)]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 44, "\(boundary)")

            let audit = OperatorAuditLog(url: auditURL)
            let recovered = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
            XCTAssertNil(recovered.lastPersistenceError, "\(boundary)")
            let committed = boundary != .beforeJournalStaging && boundary != .afterJournalStaging
            XCTAssertEqual(recovered.incident(id: id)?.clipID, committed ? nil : bundleID, "\(boundary)")
            XCTAssertEqual(audit.recentEntries().filter { $0.action == .evidenceDeleted }.count,
                           committed ? 1 : 0, "\(boundary)")
        }
    }

    func testFailedRecoveryPreservesInMemoryIncidents() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let first = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
        XCTAssertNotNil(first.recordSecondaryVLMVerification(incidentID: id, status: .pending, summary: "pending"))
        XCTAssertNotNil(first.transitionStatus(incidentID: id, to: .resolved))
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
        let before = try XCTUnwrap(stale.incident(id: id))
        first.updateOperatorNote(incidentID: id, note: "concurrent change")

        stale.recoverInterruptedVerifications()
        XCTAssertEqual(stale.incident(id: id), before)
        XCTAssertNotNil(stale.lastPersistenceError)
    }

    func testFailedClearPreservesInMemoryIncidents() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let first = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
        XCTAssertNotNil(first.transitionStatus(incidentID: id, to: .resolved))
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: OperatorAuditLog(url: auditURL))
        let before = try XCTUnwrap(stale.incident(id: id))
        first.updateOperatorNote(incidentID: id, note: "concurrent change")

        stale.clearResolvedAndClosed()
        XCTAssertEqual(stale.incident(id: id), before)
        XCTAssertNotNil(stale.lastPersistenceError)
    }

    func testFailedSuppressionDoesNotHideSubsequentCriticalAlerts() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let first = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        let incident = try XCTUnwrap(stale.incident(id: id))
        first.updateOperatorNote(incidentID: id, note: "concurrent change")
        XCTAssertNil(first.lastPersistenceError)
        let result = stale.transitionStatus(incidentID: id, to: .suppressed, suppressDurationSeconds: 300)
        XCTAssertNil(result)
        XCTAssertNotNil(stale.lastPersistenceError)
        XCTAssertEqual(stale.incident(id: id)?.status, incident.status)
        let candidate = BehaviorSafetyCandidate(cameraID: incident.cameraID, trackIDs: [],
            type: incident.type, severity: .critical, confidence: 0.9,
            monotonicTimestamp: 1, explanation: "new critical alert", detectorSource: "test")
        XCTAssertNotNil(stale.ingest(candidate: candidate, cameraName: "synthetic"))
        XCTAssertFalse(audit.recentEntries().contains { $0.action == .incidentSuppressed })
    }

    func testFailedVerificationDoesNotDismissCandidateOrShowUncommittedNote() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let first = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        _ = first.transitionStatus(incidentID: id, to: .candidate)
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        first.updateOperatorNote(incidentID: id, note: "concurrent change")
        XCTAssertNil(first.lastPersistenceError)
        XCTAssertNil(stale.recordSecondaryVLMVerification(incidentID: id, status: .rejected, summary: "reject"))
        XCTAssertNotNil(stale.lastPersistenceError)
        XCTAssertEqual(stale.incident(id: id)?.status, .candidate)
        stale.updateOperatorNote(incidentID: id, note: "uncommitted")
        XCTAssertEqual(stale.incident(id: id)?.operatorNotes, "")
        XCTAssertFalse(audit.recentEntries().contains { $0.action == .secondaryVLMVerified })
    }

    func testStartupWithoutJournalDoesNotChangeOrCreateDocuments() throws {
        for existing in [false, true] {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let incidentURL = root.url.appendingPathComponent("incidents.json")
            let auditURL = root.url.appendingPathComponent("audit.json")
            let before = existing ? try seed(root.url) : nil
            let audit = OperatorAuditLog(url: auditURL)
            let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
            XCTAssertNil(manager.lastPersistenceError)
            XCTAssertNil(audit.lastPersistenceError)
            if let before {
                XCTAssertEqual(try Data(contentsOf: incidentURL), before.2)
                XCTAssertEqual(try Data(contentsOf: auditURL), before.3)
                XCTAssertNotNil(manager.incident(id: before.4))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: incidentURL.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: auditURL.path))
            }
        }
    }

    func testStartupConflictDoesNotOverwriteFilesOrJournal() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, _) = try seed(root.url)
        let failing = try IncidentAuditTransactionStore(incidentURL: incidentURL, auditURL: auditURL) {
            if $0 == .afterIncidentPublication { throw Failure() }
        }
        XCTAssertThrowsError(try failing.update { _ in .init(incidents: Data("[]".utf8), audit: Data("[]".utf8)) })
        let conflict = Data("[{\"external\":true}]".utf8)
        try conflict.write(to: auditURL)
        let incidents = try Data(contentsOf: incidentURL)
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        let journalBytes = try Data(contentsOf: journal)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertTrue(manager.lastPersistenceError?.contains("changed outside") == true)
        XCTAssertNotNil(audit.lastPersistenceError)
        let candidate = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [], type: .fallConfirmed,
            severity: .critical, confidence: 0.5, monotonicTimestamp: 1,
            explanation: "synthetic", detectorSource: "test")
        _ = manager.ingest(candidate: candidate, cameraName: "synthetic")
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), conflict)
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    }

    func testFailedIncidentLoadDoesNotRecordAnUncommittedIncident() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, beforeAudit, _) = try seed(root.url)
        let invalid = Data("{invalid".utf8)
        try invalid.write(to: incidentURL)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNotNil(manager.lastPersistenceError)
        let candidate = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [], type: .fallConfirmed,
            severity: .critical, confidence: 0.5, monotonicTimestamp: 1,
            explanation: "synthetic", detectorSource: "test")
        _ = manager.ingest(candidate: candidate, cameraName: "synthetic")
        XCTAssertEqual(try Data(contentsOf: incidentURL), invalid)
        XCTAssertEqual(try Data(contentsOf: auditURL), beforeAudit)
        XCTAssertEqual(audit.recentEntries().map(\.summary), ["existing"])
    }

    func testStartupRejectsIncompatibleJournalWithoutOverwritingLegacy() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, beforeIncidents, beforeAudit, _) = try seed(root.url)
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeIncidents) as? [[String: Any]])
        records[0]["futureField"] = ["nested": "preserve"]
        let unknown = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        let unchecked = try IncidentAuditTransactionStore(incidentURL: incidentURL, auditURL: auditURL,
                                                            validateCompatibility: { _, _ in }) {
            if $0 == .afterJournalDurable { throw Failure() }
        }
        XCTAssertThrowsError(try unchecked.update { _ in .init(incidents: unknown, audit: beforeAudit) })
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        let journalBytes = try Data(contentsOf: journal)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertTrue(manager.lastPersistenceError?.contains("compatible JSON arrays") == true)
        XCTAssertEqual(try Data(contentsOf: incidentURL), beforeIncidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), beforeAudit)
        XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
    }

    func testDifferentDirectoriesDoNotAttemptRecovery() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let auditDirectory = root.url.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDirectory, withIntermediateDirectories: false)
        let (incidentURL, _, incidents, _, id) = try seed(root.url)
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        let blocked = Data("foreign journal".utf8)
        try blocked.write(to: journal)
        let audit = OperatorAuditLog(url: auditDirectory.appendingPathComponent("audit.json"))
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNil(manager.lastPersistenceError)
        XCTAssertNotNil(manager.incident(id: id))
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: journal), blocked)
    }

    func testStartupFailsClosedWhileAuditLockIsHeld() throws {
        guard let helper = ProcessInfo.processInfo.environment["OPERATOR_AUDIT_TEST_HELPER"] else {
            throw XCTSkip("Set OPERATOR_AUDIT_TEST_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, incidents, audits, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [auditURL.path, "hold-lock", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        let blocked = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNotNil(blocked.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), audits)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let retried = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNil(retried.lastPersistenceError)
        XCTAssertNotNil(retried.incident(id: id))
    }

    func testStartupWithoutJournalDoesNotFlushPendingAudit() throws {
        guard let helper = ProcessInfo.processInfo.environment["OPERATOR_AUDIT_TEST_HELPER"] else {
            throw XCTSkip("Set OPERATOR_AUDIT_TEST_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, incidents, audits, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [auditURL.path, "hold-lock", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNil(manager.lastPersistenceError)
        XCTAssertNotNil(manager.incident(id: id))
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), audits)
        manager.updateOperatorNote(incidentID: id, note: "must not bypass pending audit")
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), audits)
        XCTAssertEqual(audit.recentEntries().first?.summary, "pending")
        XCTAssertNil(audit.lastPersistenceError)
        let fresh = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        fresh.updateOperatorNote(incidentID: id, note: "after audit reconciliation")
        XCTAssertNil(fresh.lastPersistenceError)
        XCTAssertEqual(audit.recentEntries().first?.details, "after audit reconciliation")
    }

    func testLegacyIncidentWriteFencesLiveTransactionAndRequiresFreshManagerToRetry() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, incidents, audits, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "strict-pause", "unused"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        manager.updateOperatorNote(incidentID: id, note: "pending")
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), audits)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        manager.updateOperatorNote(incidentID: id, note: "retry")
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), incidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), audits)
        let fresh = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        fresh.updateOperatorNote(incidentID: id, note: "retry")
        XCTAssertNil(fresh.lastPersistenceError)
        XCTAssertEqual(audit.recentEntries().filter { $0.action == .incidentNoteUpdated }.map(\.details), ["retry"])
    }

    func testLegacyWriteFencesUnfinishedJournalAndStalePostRecoverySnapshot() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "strict-crash", "afterIncidentPublication"]
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 44)
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        let beforeJournal = try Data(contentsOf: journal)
        let beforeIncidents = try Data(contentsOf: incidentURL)
        let beforeAudit = try Data(contentsOf: auditURL)
        manager.updateOperatorNote(incidentID: id, note: "must not commit")
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), beforeIncidents)
        XCTAssertEqual(try Data(contentsOf: auditURL), beforeAudit)
        XCTAssertEqual(try Data(contentsOf: journal), beforeJournal)
        let recovered = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNil(recovered.lastPersistenceError)
        manager.clearResolvedAndClosed()
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), Data("[]".utf8))
        XCTAssertEqual(try Data(contentsOf: auditURL), Data("[]".utf8))
    }

    func testLegacyWriteRejectsStaleManagerAndUnknownIncidentFields() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, incidents, _, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let first = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        first.updateOperatorNote(incidentID: id, note: "first")
        XCTAssertNil(first.lastPersistenceError)
        let updated = try Data(contentsOf: incidentURL)
        let audited = try Data(contentsOf: auditURL)
        stale.updateOperatorNote(incidentID: id, note: "stale")
        XCTAssertTrue(stale.lastPersistenceError?.contains("changed outside") == true)
        XCTAssertEqual(try Data(contentsOf: incidentURL), updated)
        XCTAssertEqual(try Data(contentsOf: auditURL), audited)
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: incidents) as? [[String: Any]])
        records[0]["futureField"] = ["nested": "preserve"]
        let unknown = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try unknown.write(to: incidentURL)
        let legacy = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNil(legacy.lastPersistenceError)
        legacy.updateOperatorNote(incidentID: id, note: "must not lose field")
        XCTAssertNotNil(legacy.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: incidentURL), unknown)
        XCTAssertEqual(try Data(contentsOf: auditURL), audited)
    }

    func testLegacyWriteRejectsSnapshotChangedByCompletedSubprocessTransaction() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incidentURL, auditURL, _, _, id) = try seed(root.url)
        let audit = OperatorAuditLog(url: auditURL)
        let stale = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "strict-crash", "afterJournalRemovalDurable"]
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 44)
        stale.updateOperatorNote(incidentID: id, note: "stale")
        XCTAssertTrue(stale.lastPersistenceError?.contains("changed outside") == true)
        XCTAssertEqual(try Data(contentsOf: incidentURL), Data("[]".utf8))
        XCTAssertEqual(try Data(contentsOf: auditURL), Data("[]".utf8))
    }

    func testStartupRejectsAmbiguousNormalizedPathWithoutTouchingData() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let base = root.url.appendingPathComponent("base", isDirectory: true)
        let target = root.url.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("link").path,
                                                   withDestinationPath: target.appendingPathComponent("nested").path)
        let incidentURL = URL(fileURLWithPath: base.path + "/link/../incidents.json")
        let actual = target.appendingPathComponent("incidents.json")
        let original = Data("[]".utf8)
        try original.write(to: actual)
        let audit = OperatorAuditLog(url: base.appendingPathComponent("audit.json"))
        let manager = UnifiedIncidentManager(storageURL: incidentURL, auditLog: audit)
        XCTAssertNotNil(manager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: actual), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("incidents.json").path))
    }

    func testInjectedStoresDoNotAttemptStartupRecovery() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        let original = Data("foreign journal".utf8)
        try original.write(to: journal)
        let audit = OperatorAuditLog(url: root.url.appendingPathComponent("audit.json"), load: { [] }, save: { _ in })
        var loads = 0
        let manager = UnifiedIncidentManager(storageURL: root.url.appendingPathComponent("incidents.json"),
                                             auditLog: audit, load: { loads += 1; return [] }, save: { _ in })
        XCTAssertEqual(loads, 1)
        XCTAssertNil(manager.lastPersistenceError)
        let publicManager = UnifiedIncidentManager(storageURL: root.url.appendingPathComponent("incidents.json"),
                                                   auditLog: audit)
        XCTAssertNil(publicManager.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: journal), original)
    }
}
