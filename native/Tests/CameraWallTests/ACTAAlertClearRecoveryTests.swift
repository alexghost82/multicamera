import Foundation
import XCTest
import CameraCore
@testable import CameraWall

@MainActor
final class ACTAAlertClearRecoveryTests: XCTestCase {
    private enum Failure: Error {
        case read, write, restore
    }

    private final class Stores: ACTAAlertClearRecoveryStores {
        var images: [String: Data]
        var failAfterWrite: String?
        var failRestore: String?
        var corruptAfterWrite: String?
        var writes: [String] = []
        private var leased = false

        init(_ images: [String: Data]) { self.images = images }

        func withExclusiveLease<T>(_ body: () throws -> T) throws -> T {
            precondition(!leased)
            leased = true
            defer { leased = false }
            return try body()
        }

        func readImage(store: String) throws -> Data {
            precondition(leased)
            guard let image = images[store] else { throw Failure.read }
            return image
        }

        func replaceImage(store: String, matching: Data, with: Data) throws -> Bool {
            precondition(leased)
            guard images[store] == matching else { return false }
            if failRestore == store && writes.contains(store) { throw Failure.restore }
            writes.append(store)
            images[store] = with
            if corruptAfterWrite == store {
                corruptAfterWrite = nil
                images[store] = Data("unexpected".utf8)
            }
            if failAfterWrite == store {
                failAfterWrite = nil
                throw Failure.write
            }
            return true
        }
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func fixture(_ body: (URL, Stores, [ACTAAlertClearRecovery.Change]) throws -> Void) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".alert-clear-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let changes = [
            ACTAAlertClearRecovery.Change(store: "alerts", before: data("alert-A,alert-B"), after: data("")),
            .init(store: "clips", before: data("clip-A,unrelated-clip-C"), after: data("unrelated-clip-C")),
            .init(store: "reviews", before: data("review-A,orphan-review-C,audit-C"), after: data(""))
        ]
        let stores = Stores(Dictionary(uniqueKeysWithValues: changes.map { ($0.store, $0.before) }))
        try body(root.appendingPathComponent("recovery.json"), stores, changes)
    }

    func testVerifiedClearPreservesExactUnrelatedClip() throws {
        try fixture { journal, stores, changes in
            let recovery = ACTAAlertClearRecovery(journalURL: journal, stores: stores)
            try recovery.execute(confirmed: changes)
            XCTAssertEqual(stores.images, Dictionary(uniqueKeysWithValues: changes.map { ($0.store, $0.after) }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        }
    }

    func testPartialCrossStoreFailureRollsBackIncludingThrowAfterWrite() throws {
        for failingStore in ["alerts", "clips", "reviews"] {
            try fixture { journal, stores, changes in
                stores.failAfterWrite = failingStore
                let recovery = ACTAAlertClearRecovery(journalURL: journal, stores: stores)
                XCTAssertThrowsError(try recovery.execute(confirmed: changes)) {
                    XCTAssertEqual($0 as? Failure, .write)
                }
                XCTAssertEqual(stores.images, Dictionary(uniqueKeysWithValues: changes.map { ($0.store, $0.before) }))
                XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
            }
        }
    }

    func testFailedRollbackRetainsPrivateJournalAndCanRecoverAfterRestart() throws {
        try fixture { journal, stores, changes in
            stores.failAfterWrite = "reviews"
            stores.failRestore = "clips"
            XCTAssertThrowsError(try ACTAAlertClearRecovery(journalURL: journal, stores: stores).execute(confirmed: changes)) {
                guard let failure = $0 as? ACTAAlertClearRecoveryFailure else {
                    return XCTFail("Expected both clear and recovery errors, got \($0)")
                }
                XCTAssertEqual(failure.initialError as? Failure, .write)
                XCTAssertEqual(failure.recoveryError as? Failure, .restore)
                XCTAssertTrue(failure.localizedDescription.contains("Alert clear failed"))
                XCTAssertTrue(failure.localizedDescription.contains("Recovery failed"))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
            XCTAssertEqual(stores.images["reviews"], changes[2].before)
            XCTAssertEqual(stores.images["clips"], changes[1].after)
            let permissions = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            XCTAssertThrowsError(try ACTAAlertClearRecovery(journalURL: journal, stores: stores).execute(confirmed: changes)) {
                XCTAssertEqual($0 as? ACTAAlertClearRecoveryError, .pendingRecovery)
            }
            stores.failRestore = nil
            try ACTAAlertClearRecovery(journalURL: journal, stores: stores).recover()
            XCTAssertEqual(stores.images, Dictionary(uniqueKeysWithValues: changes.map { ($0.store, $0.before) }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        }
    }

    func testUnexpectedStoreImagePreventsAnyRecoveryOverwrite() throws {
        try fixture { journal, stores, changes in
            stores.corruptAfterWrite = "clips"
            XCTAssertThrowsError(try ACTAAlertClearRecovery(journalURL: journal, stores: stores).execute(confirmed: changes)) {
                guard let failure = $0 as? ACTAAlertClearRecoveryFailure else {
                    return XCTFail("Expected both verification and recovery errors, got \($0)")
                }
                XCTAssertEqual(failure.initialError as? ACTAAlertClearRecoveryError, .verificationFailed)
                XCTAssertEqual(failure.recoveryError as? ACTAAlertClearRecoveryError, .conflict)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
            let afterFailure = stores.images
            XCTAssertThrowsError(try ACTAAlertClearRecovery(journalURL: journal, stores: stores).recover())
            XCTAssertEqual(stores.images, afterFailure)
            stores.images["clips"] = changes[1].after
            try ACTAAlertClearRecovery(journalURL: journal, stores: stores).recover()
            XCTAssertEqual(stores.images, Dictionary(uniqueKeysWithValues: changes.map { ($0.store, $0.before) }))
        }
    }

    func testStaleConfirmationAndInvalidPlansNeverWrite() throws {
        try fixture { journal, stores, changes in
            let recovery = ACTAAlertClearRecovery(journalURL: journal, stores: stores)
            stores.images["reviews"] = data("new audit")
            XCTAssertThrowsError(try recovery.execute(confirmed: changes))
            XCTAssertTrue(stores.writes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
            XCTAssertThrowsError(try recovery.execute(confirmed: []))
            XCTAssertThrowsError(try recovery.execute(confirmed: [changes[0], changes[0]]))
            XCTAssertTrue(stores.writes.isEmpty)
        }
    }

    func testCorruptJournalFailsClosed() throws {
        try fixture { journal, stores, changes in
            try data("{").write(to: journal)
            let recovery = ACTAAlertClearRecovery(journalURL: journal, stores: stores)
            XCTAssertThrowsError(try recovery.recover())
            XCTAssertThrowsError(try recovery.execute(confirmed: changes))
            XCTAssertTrue(stores.writes.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        }
    }

    func testPlanReportsGlobalOrphanReviewsAndOnlyLinkedClips() throws {
        let alertID = UUID(), linkedClip = UUID(), missingClip = UUID(), unrelatedClip = UUID(), orphanID = UUID()
        let alert = VLMAlert(id: alertID, cameraID: UUID(), cameraName: "synthetic",
                             condition: "condition", evidence: "evidence", clipID: linkedClip)
        let second = VLMAlert(cameraID: UUID(), cameraName: "synthetic",
                              condition: "condition", evidence: "evidence", clipID: missingClip)
        let review = OperationsAlertReview(alertID: orphanID, priority: .normal, status: .acknowledged,
                                           note: "orphan", updatedAt: Date(timeIntervalSince1970: 10))
        let snapshot = ACTAAlertClearSnapshot(alerts: [alert, second], reviews: [orphanID: review],
            acknowledgements: [orphanID: review.updatedAt], audit: [review],
            clips: [linkedClip: data("linked frames"), unrelatedClip: data("unrelated frames")])
        let plan = try ACTAAlertClearPlan.make(snapshot: snapshot)
        XCTAssertEqual(plan.affectedAlerts, [alert, second])
        XCTAssertEqual(plan.affectedReviews, [review])
        XCTAssertEqual(plan.affectedAudit, [review])
        XCTAssertEqual(plan.affectedAcknowledgements, snapshot.acknowledgements)
        XCTAssertEqual(plan.referencedClipIDs, [linkedClip, missingClip])
        XCTAssertEqual(plan.missingClipIDs, [missingClip])
        let clipsAfter = try XCTUnwrap(plan.changes.first { $0.store == "clips" }?.after)
        let clips = try XCTUnwrap(JSONSerialization.jsonObject(with: clipsAfter) as? [[String: Any]])
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?["id"] as? String, unrelatedClip.uuidString)
        XCTAssertEqual(clips.first?["image"] as? String, data("unrelated frames").base64EncodedString())
        XCTAssertThrowsError(try ACTAAlertClearPlan.make(snapshot: ACTAAlertClearSnapshot(
            alerts: [alert, alert], reviews: [:], acknowledgements: [:], audit: [], clips: [:])))
    }
}
