import Darwin
import Foundation
import XCTest
@testable import CameraCore

final class IncidentAuditTransactionStoreTests: XCTestCase {
    private struct Injected: Error {}
    private let oldIncident = Data("[ { \"legacy\" : true, \"future\" : 1 } ]".utf8)
    private let oldAudit = Data("[ { \"legacy\" : \"audit\" } ]".utf8)
    private let newDocument = Data("[{\"new\":1}]".utf8)

    private func urls(_ root: URL) -> (URL, URL) {
        (root.appendingPathComponent("incidents.json"), root.appendingPathComponent("audit.json"))
    }

    private func store(_ root: URL, fault: @escaping (IncidentAuditTransactionStore.Boundary) throws -> Void = { _ in }) throws -> IncidentAuditTransactionStore {
        let (incident, audit) = urls(root)
        return try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit,
                                                 validateCompatibility: { _, _ in }, fault: fault)
    }

    private func seed(_ root: URL) throws {
        let (incident, audit) = urls(root)
        try oldIncident.write(to: incident)
        try oldAudit.write(to: audit)
    }

    private func update(_ store: IncidentAuditTransactionStore) throws {
        try store.update { _ in .init(incidents: newDocument, audit: newDocument) }
    }

    private func compatibleDocuments() throws -> (Data, Data) {
        let incident = SafetyIncident(cameraID: UUID(), cameraName: "synthetic", trackIDs: [],
                                      type: .fallConfirmed, severity: .critical, confidence: 0.5,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      updatedAt: Date(timeIntervalSince1970: 0),
                                      title: "test", explanation: "test", detectorSource: "test",
                                      metrics: ["ratio": 1])
        let audit = OperatorAuditEntry(occurredAt: Date(timeIntervalSince1970: 0),
                                       action: .incidentCreated, incidentID: incident.id, summary: "test")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try encoder.encode([incident]), try encoder.encode([audit]))
    }

    private func addingUnknownField(to data: Data) throws -> Data {
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        records[0]["futureField"] = ["nested": "preserve"]
        return try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
    }

    func testCompatibleLegacyDocumentsRemainByteIdentical() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incident, audit) = urls(root.url)
        let documents = try compatibleDocuments()
        let formatted = Data((" \n" + String(decoding: documents.0, as: UTF8.self) + "\n").utf8)
        try formatted.write(to: incident)
        try documents.1.write(to: audit)
        let checked = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
        let before = try checked.snapshot()
        XCTAssertEqual(before.incidents, formatted)
        XCTAssertEqual(before.audit, documents.1)
        _ = try checked.update { $0 }
        XCTAssertEqual(try Data(contentsOf: incident), formatted)
        XCTAssertEqual(try Data(contentsOf: audit), documents.1)
    }

    func testLargeCompatibleAuditSurvivesInterruptedRecovery() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incident, audit) = urls(root.url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = OperatorAuditEntry(action: .settingsUpdated, summary: String(repeating: "a", count: 4_050_000))
        let original = try encoder.encode([entry])
        XCTAssertGreaterThan(original.count, 4_000_000)
        try Data("[]".utf8).write(to: incident)
        try original.write(to: audit)
        let failing = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit) {
            if $0 == .afterIncidentPublication { throw Injected() }
        }
        XCTAssertThrowsError(try failing.update { $0 })
        let recovered = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit).snapshot()
        XCTAssertEqual(recovered.audit, original)
        XCTAssertEqual(try Data(contentsOf: audit), original)
    }

    func testUnknownLegacyFieldsRejectSnapshotAndUpdateWithoutWriting() throws {
        for incidentIsUnknown in [false, true] {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incident, audit) = urls(root.url)
            let documents = try compatibleDocuments()
            let incidents = incidentIsUnknown ? try addingUnknownField(to: documents.0) : documents.0
            let audits = incidentIsUnknown ? documents.1 : try addingUnknownField(to: documents.1)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode([SafetyIncident].self, from: incidents)
            _ = try decoder.decode([OperatorAuditEntry].self, from: audits)
            try incidents.write(to: incident)
            try audits.write(to: audit)
            let checked = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
            XCTAssertThrowsError(try checked.snapshot()) { error in
                guard case IncidentAuditTransactionStore.StoreError.invalidDocument = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            var called = false
            XCTAssertThrowsError(try checked.update { snapshot in called = true; return snapshot })
            XCTAssertFalse(called)
            XCTAssertEqual(try Data(contentsOf: incident), incidents)
            XCTAssertEqual(try Data(contentsOf: audit), audits)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".incident-audit.transaction.json").path))
        }
    }

    func testLossyNumbersAndDuplicateKeysAreRejectedWithoutWriting() throws {
        let documents = try compatibleDocuments()
        let incidentText = try XCTUnwrap(String(data: documents.0, encoding: .utf8))
        let auditText = try XCTUnwrap(String(data: documents.1, encoding: .utf8))
        let lossy = incidentText.replacingOccurrences(of: "\"ratio\":1", with: "\"ratio\":9007199254740993")
        let duplicate = auditText.replacingOccurrences(of: "\"summary\":\"test\"",
                                                       with: "\"summary\":\"hidden\",\"summary\":\"test\"")
        XCTAssertNotEqual(lossy, incidentText)
        XCTAssertNotEqual(duplicate, auditText)
        for (incidents, audits) in [(Data(lossy.utf8), documents.1), (documents.0, Data(duplicate.utf8))] {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incident, audit) = urls(root.url)
            try incidents.write(to: incident)
            try audits.write(to: audit)
            let checked = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
            XCTAssertThrowsError(try checked.snapshot())
            XCTAssertEqual(try Data(contentsOf: incident), incidents)
            XCTAssertEqual(try Data(contentsOf: audit), audits)
        }
    }

    func testIncompatibleProposedDocumentCannotPublishJournal() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let (incident, audit) = urls(root.url)
        let documents = try compatibleDocuments()
        try documents.0.write(to: incident)
        try documents.1.write(to: audit)
        let incompatible = try addingUnknownField(to: documents.1)
        let checked = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
        XCTAssertThrowsError(try checked.update { _ in .init(incidents: documents.0, audit: incompatible) })
        XCTAssertEqual(try Data(contentsOf: incident), documents.0)
        XCTAssertEqual(try Data(contentsOf: audit), documents.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".incident-audit.transaction.json").path))
    }

    func testRecoveryRejectsIncompatiblePreviousOrProposedDocumentsWithoutWriting() throws {
        for incidentIsUnknown in [false, true] {
            for previousIsUnknown in [false, true] {
                let root = try IsolatedStoreTestDirectory()
                defer { try? root.remove() }
                let (incident, audit) = urls(root.url)
                let documents = try compatibleDocuments()
                let unknown = try addingUnknownField(to: incidentIsUnknown ? documents.0 : documents.1)
                let beforeIncidents = incidentIsUnknown && previousIsUnknown ? unknown : documents.0
                let beforeAudit = !incidentIsUnknown && previousIsUnknown ? unknown : documents.1
                let afterIncidents = incidentIsUnknown && !previousIsUnknown ? unknown : documents.0
                let afterAudit = !incidentIsUnknown && !previousIsUnknown ? unknown : documents.1
                try beforeIncidents.write(to: incident)
                try beforeAudit.write(to: audit)
                let unchecked = try store(root.url) { if $0 == .afterIncidentPublication { throw Injected() } }
                XCTAssertThrowsError(try unchecked.update { _ in .init(incidents: afterIncidents, audit: afterAudit) })
                let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
                let journalBytes = try Data(contentsOf: journal)
                let checked = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
                XCTAssertThrowsError(try checked.snapshot()) { error in
                    guard case IncidentAuditTransactionStore.StoreError.invalidDocument = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
                XCTAssertEqual(try Data(contentsOf: incident), afterIncidents)
                XCTAssertEqual(try Data(contentsOf: audit), beforeAudit)
                XCTAssertEqual(try Data(contentsOf: journal), journalBytes)
            }
        }
    }

    func testCompatibleRecoveryAtEveryCommitBoundary() throws {
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incident, audit) = urls(root.url)
            let before = try compatibleDocuments()
            let after = try compatibleDocuments()
            try before.0.write(to: incident)
            try before.1.write(to: audit)
            let failing = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit) {
                if $0 == boundary { throw Injected() }
            }
            XCTAssertThrowsError(try failing.update { _ in .init(incidents: after.0, audit: after.1) })
            let recovered = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit).snapshot()
            let old = boundary == .beforeJournalStaging || boundary == .afterJournalStaging
            XCTAssertEqual(recovered.incidents, old ? before.0 : after.0, "\(boundary)")
            XCTAssertEqual(recovered.audit, old ? before.1 : after.1, "\(boundary)")
        }
    }

    func testCompatibleSubprocessCrashAtEveryCommitBoundary() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            let (incident, audit) = urls(root.url)
            let before = try compatibleDocuments()
            try before.0.write(to: incident)
            try before.1.write(to: audit)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: helper)
            child.arguments = [root.url.path, "strict-crash", String(describing: boundary)]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 44, "\(boundary)")
            let recovered = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit).snapshot()
            let old = boundary == .beforeJournalStaging || boundary == .afterJournalStaging
            XCTAssertEqual(recovered.incidents, old ? before.0 : Data("[]".utf8), "\(boundary)")
            XCTAssertEqual(recovered.audit, old ? before.1 : Data("[]".utf8), "\(boundary)")
        }
    }

    func testEveryCommitBoundaryRecoversWithoutMixedSnapshots() throws {
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            try seed(root.url)
            let failing = try store(root.url) { if $0 == boundary { throw Injected() } }
            XCTAssertThrowsError(try update(failing), "\(boundary)")
            let recovered = try store(root.url).snapshot()
            let old = boundary == .beforeJournalStaging || boundary == .afterJournalStaging
            XCTAssertEqual(recovered.incidents, old ? oldIncident : newDocument, "\(boundary)")
            XCTAssertEqual(recovered.audit, old ? oldAudit : newDocument, "\(boundary)")
            let again = try store(root.url).snapshot()
            XCTAssertEqual(again.incidents, recovered.incidents)
            XCTAssertEqual(again.audit, recovered.audit)
        }
    }

    func testUnsafeCoordinationLocksFailClosed() throws {
        for name in [".audit.json.lock", ".incident-audit.transaction.lock"] {
            for kind in ["symlink", "fifo", "hardlink"] {
                let root = try IsolatedStoreTestDirectory()
                defer { try? root.remove() }
                let path = root.url.appendingPathComponent(name)
                let target = root.url.appendingPathComponent("target")
                try Data("untouched".utf8).write(to: target)
                switch kind {
                case "symlink":
                    try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target.path)
                case "fifo":
                    XCTAssertEqual(mkfifo(path.path, 0o600), 0)
                default:
                    XCTAssertEqual(link(target.path, path.path), 0)
                }
                let (incident, audit) = urls(root.url)
                let checked = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
                XCTAssertThrowsError(try checked.snapshot(), "\(name): \(kind)")
                XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: incident.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path))
            }
        }
    }

    func testDerivedAuditLockCannotAliasADataFileOrTransactionLock() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        XCTAssertThrowsError(try IncidentAuditTransactionStore(
            incidentURL: root.url.appendingPathComponent(".audit.json.lock"),
            auditURL: root.url.appendingPathComponent("audit.json")))
        XCTAssertThrowsError(try IncidentAuditTransactionStore(
            incidentURL: root.url.appendingPathComponent("incidents.json"),
            auditURL: root.url.appendingPathComponent("incident-audit.transaction")))
    }

    func testReplacedLockInodeIsRejected() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let dir = open(root.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(dir, 0)
        guard dir >= 0 else { return }
        defer { close(dir) }
        let name = IncidentAuditTransactionStore.auditLockName(for: "audit.json")
        let fd = try IncidentAuditTransactionStore.openCoordinationLock(directory: dir, name: name)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN) }
        XCTAssertNoThrow(try IncidentAuditTransactionStore.verifyCoordinationLock(directory: dir, name: name, fd: fd))
        XCTAssertEqual(renameat(dir, name, dir, "old-lock"), 0)
        let replacement = openat(dir, name, O_CREAT | O_EXCL | O_RDWR, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(replacement, 0)
        if replacement >= 0 { close(replacement) }
        XCTAssertThrowsError(try IncidentAuditTransactionStore.verifyCoordinationLock(directory: dir, name: name, fd: fd))
    }

    func testEveryRecoveryBoundaryCanBeInterruptedAgain() throws {
        let boundaries: [IncidentAuditTransactionStore.Boundary] = [
            .afterIncidentStaging, .afterIncidentPublication, .afterIncidentDurable,
            .afterAuditStaging, .afterAuditPublication, .afterAuditDurable,
            .afterJournalRemoval, .afterJournalRemovalDurable
        ]
        for boundary in boundaries {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            try seed(root.url)
            XCTAssertThrowsError(try update(store(root.url) { if $0 == .afterJournalDurable { throw Injected() } }))
            XCTAssertThrowsError(try store(root.url) { if $0 == boundary { throw Injected() } }.snapshot())
            let recovered = try store(root.url).snapshot()
            XCTAssertEqual(recovered.incidents, newDocument, "\(boundary)")
            XCTAssertEqual(recovered.audit, newDocument, "\(boundary)")
        }
    }

    func testInvalidJournalAndExternalChangesFailClosed() throws {
        for damageJournal in [true, false] {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            try seed(root.url)
            XCTAssertThrowsError(try update(store(root.url) { if $0 == .afterIncidentPublication { throw Injected() } }))
            let (incident, audit) = urls(root.url)
            if damageJournal {
                try Data("{broken".utf8).write(to: root.url.appendingPathComponent(".incident-audit.transaction.json"))
            } else {
                try Data("[{\"external\":true}]".utf8).write(to: audit)
            }
            let beforeIncident = try Data(contentsOf: incident), beforeAudit = try Data(contentsOf: audit)
            XCTAssertThrowsError(try store(root.url).snapshot())
            XCTAssertEqual(try Data(contentsOf: incident), beforeIncident)
            XCTAssertEqual(try Data(contentsOf: audit), beforeAudit)
        }
    }

    func testJournalChecksumMismatchDoesNotTouchEitherFile() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        try seed(root.url)
        XCTAssertThrowsError(try update(store(root.url) { if $0 == .afterIncidentPublication { throw Injected() } }))
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        object["checksum"] = Data(repeating: 0, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: journal)
        let (incident, audit) = urls(root.url)
        XCTAssertThrowsError(try store(root.url).snapshot())
        XCTAssertEqual(try Data(contentsOf: incident), newDocument)
        XCTAssertEqual(try Data(contentsOf: audit), oldAudit)
    }

    func testExistingBytesAndAbsentFilesArePreservedUntilValidUpdate() throws {
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let store = try store(root.url)
        let empty = try store.snapshot()
        XCTAssertNil(empty.incidents)
        XCTAssertNil(empty.audit)
        XCTAssertThrowsError(try store.update { _ in .init(incidents: Data("broken".utf8), audit: newDocument) })
        XCTAssertNil(try store.snapshot().incidents)
        try seed(root.url)
        let before = try store.snapshot()
        XCTAssertEqual(before.incidents, oldIncident)
        XCTAssertEqual(before.audit, oldAudit)
        try store.update { $0 }
        let after = try store.snapshot()
        XCTAssertEqual(after.incidents, oldIncident)
        XCTAssertEqual(after.audit, oldAudit)
    }

    func testSubprocessCrashAtEachBoundaryAndRecovery() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        for boundary in IncidentAuditTransactionStore.Boundary.allCases {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            try seed(root.url)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: helper)
            child.arguments = [root.url.path, "crash", String(describing: boundary)]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 44, "\(boundary)")
            let recovered = try store(root.url).snapshot()
            let old = boundary == .beforeJournalStaging || boundary == .afterJournalStaging
            XCTAssertEqual(recovered.incidents, old ? oldIncident : newDocument, "\(boundary)")
            XCTAssertEqual(recovered.audit, old ? oldAudit : newDocument, "\(boundary)")
        }
    }

    func testReaderCannotObserveHalfPublishedTransaction() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        try seed(root.url)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "pause", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        XCTAssertThrowsError(try store(root.url).snapshot()) { error in
            guard case IncidentAuditTransactionStore.StoreError.busy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let result = try store(root.url).snapshot()
        XCTAssertEqual(result.incidents, newDocument)
        XCTAssertEqual(result.audit, newDocument)
    }

    func testSubprocessCrashDuringRecoveryCanRecoverAgain() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let boundaries: [IncidentAuditTransactionStore.Boundary] = [
            .afterIncidentStaging, .afterIncidentPublication, .afterIncidentDurable,
            .afterAuditStaging, .afterAuditPublication, .afterAuditDurable,
            .afterJournalRemoval, .afterJournalRemovalDurable
        ]
        for boundary in boundaries {
            let root = try IsolatedStoreTestDirectory()
            defer { try? root.remove() }
            try seed(root.url)
            XCTAssertThrowsError(try update(store(root.url) { if $0 == .afterJournalDurable { throw Injected() } }))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: helper)
            child.arguments = [root.url.path, "recover-crash", String(describing: boundary)]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 44, "\(boundary)")
            let recovered = try store(root.url).snapshot()
            XCTAssertEqual(recovered.incidents, newDocument, "\(boundary)")
            XCTAssertEqual(recovered.audit, newDocument, "\(boundary)")
        }
    }

    func testSubprocessLockIsFailFastAndConcurrentWritersSerialize() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try IsolatedStoreTestDirectory()
        defer { try? root.remove() }
        let store = try store(root.url)
        func child(_ mode: String, _ argument: String) throws -> (Process, Pipe, Pipe) {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [root.url.path, mode, argument]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            return (process, input, output)
        }
        let (holder, input, output) = try child("hold", "0")
        defer {
            try? input.fileHandleForWriting.close()
            if holder.isRunning { holder.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        XCTAssertThrowsError(try store.snapshot()) { error in
            guard case IncidentAuditTransactionStore.StoreError.busy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationStatus, 0)
        let children = try (0..<3).map { _ in try child("write", "15") }
        for (_, _, output) in children {
            XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        }
        for (_, input, _) in children { try input.fileHandleForWriting.write(contentsOf: Data([1])) }
        for (process, _, _) in children {
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let final = try store.snapshot()
        XCTAssertEqual(final.incidents, final.audit)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(final.incidents)) as? [String])
        XCTAssertEqual(values.count, 45)
        XCTAssertEqual(Set(values).count, 45)
    }
}
