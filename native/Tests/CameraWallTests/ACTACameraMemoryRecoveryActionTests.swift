import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTACameraMemoryRecoveryActionTests: XCTestCase {
    private func approve(_ registry: ACTAActionRegistry, _ review: ACTAActionResult) async throws -> ACTAActionResult {
        try await registry.confirmAndExecute(token: try XCTUnwrap(review.confirmationToken), confirmed: true,
                                             expectedActionID: review.actionID, expectedParameters: [:],
                                             expectedThreadID: "default", expectedReviewTitle: review.summary)
    }

    private struct Journal: Encodable {
        let frames: [CameraMemoryFrame]
    }

    /// Fixture writers are serialized by this actor; this is not a production backend.
    private actor FixtureBackend: ACTACameraMemoryRecoveryBackend {
        let store: CameraMemoryStore
        let failVerification: Bool
        private var completed: CameraMemoryRecoverySnapshot?

        init(store: CameraMemoryStore, failVerification: Bool = false) {
            self.store = store
            self.failVerification = failVerification
        }

        func snapshot() async throws -> CameraMemoryRecoverySnapshot { try store.recoverySnapshot() }
        func recover(_ snapshot: CameraMemoryRecoverySnapshot) async throws {
            guard try store.recoverySnapshot() == snapshot else { throw CameraMemoryStoreError.snapshotChanged }
            try store.recoverPendingDeletion()
            completed = snapshot
        }
        func verify(_ snapshot: CameraMemoryRecoverySnapshot) async throws -> Bool {
            guard !failVerification, try !store.hasPendingDeletion() else { return false }
            let indexed = try store.deletionSnapshot().frames
            for frame in snapshot.frames {
                if indexed.contains(where: { $0.id == frame.id || $0.fileName == frame.fileName }) {
                    return false
                }
                if try store.hasStoredImage(for: frame) { return false }
            }
            return true
        }
        func verifyCurrentState() async throws -> Bool {
            guard let completed else { return false }
            return try await verify(completed)
        }
    }

    private func fixture() throws -> (URL, CameraMemoryStore, [CameraMemoryFrame]) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".memory-recovery-action-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        let frames = try (0..<2).map { _ in
            try store.save(Data("synthetic".utf8), cameraID: UUID(), cameraName: "private-name",
                           capturedAt: date, summary: "private-summary", now: date)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Journal(frames: frames)).write(to: root.appendingPathComponent(".deletion-journal.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(frames[0].fileName))
        return (root, store, frames)
    }

    func testReviewedRecoveryRejectsThenResumesOnlyJournaledFrames() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTACameraMemoryRecoveryAction(backend: FixtureBackend(store: store))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(review.requiresOperatorConfirmation)
        XCTAssertTrue(review.summary.contains("2 frames (18 indexed bytes)"))
        XCTAssertTrue(review.summary.contains("1 reviewed paths currently exist"))
        XCTAssertTrue(review.summary.contains("path=present"))
        XCTAssertTrue(review.summary.contains("path=missing"))
        for frame in frames {
            XCTAssertTrue(review.summary.contains(frame.id.uuidString))
            XCTAssertTrue(review.summary.contains(frame.cameraID.uuidString))
        }
        XCTAssertFalse(review.summary.contains("private-name"))
        XCTAssertFalse(review.summary.contains("private-summary"))
        let rejected = try await registry.confirmAndExecute(token: try XCTUnwrap(review.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        XCTAssertTrue(try store.hasPendingDeletion())
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
        let next = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, next)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(try store.hasPendingDeletion())
        for frame in frames { XCTAssertFalse(try store.hasStoredImage(for: frame)) }
        XCTAssertTrue(try store.deletionSnapshot().frames.isEmpty)
        let replay = try await approve(registry, next)
        XCTAssertFalse(replay.success)
    }

    func testJournalByteChangeRejectsConfirmationBeforeDeleting() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        let action = ACTACameraMemoryRecoveryAction(backend: FixtureBackend(store: store))
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let journalURL = root.appendingPathComponent(".deletion-journal.json")
        var journal = try Data(contentsOf: journalURL)
        journal.append(Data(" ".utf8))
        try journal.write(to: journalURL)
        let result = try await approve(registry, review)
        XCTAssertTrue(result.error?.hasPrefix("CONFLICT:") == true)
        XCTAssertEqual(try Data(contentsOf: journalURL), journal)
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
    }

    func testRecoveryDoesNotRemoveFramesOutsideJournal() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Journal(frames: [frames[0]])).write(to: root.appendingPathComponent(".deletion-journal.json"))
        let registry = ACTAActionRegistry()
        let action = ACTACameraMemoryRecoveryAction(backend: FixtureBackend(store: store))
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, review)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
        XCTAssertEqual(try store.deletionSnapshot().frames, [frames[1]])
    }

    func testDifferentReviewTitleDoesNotRecoverOrConsumeToken() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        let action = ACTACameraMemoryRecoveryAction(backend: FixtureBackend(store: store))
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let mismatch = try await registry.confirmAndExecute(
            token: try XCTUnwrap(review.confirmationToken), confirmed: true, expectedActionID: action.id,
            expectedParameters: [:], expectedThreadID: "default", expectedReviewTitle: review.summary + " changed")
        XCTAssertFalse(mismatch.success)
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
        let result = try await approve(registry, review)
        XCTAssertTrue(result.success, result.summary)
    }

    func testReplacementOrReappearanceRejectsReview() async throws {
        for replacement in [true, false] {
            let (root, store, frames) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let registry = ACTAActionRegistry()
            let action = ACTACameraMemoryRecoveryAction(backend: FixtureBackend(store: store))
            await registry.register(action)
            let review = try await registry.execute(actionID: action.id, parameters: [:])
            let target = root.appendingPathComponent(frames[replacement ? 1 : 0].fileName)
            try Data("replacement".utf8).write(to: target, options: .atomic)
            let result = try await approve(registry, review)
            XCTAssertTrue(result.error?.hasPrefix("CONFLICT:") == true)
            XCTAssertEqual(try Data(contentsOf: target), Data("replacement".utf8))
            XCTAssertTrue(try store.hasPendingDeletion())
        }
    }

    func testUnconfirmedDirectCallsAndProductionBackendAreUnavailable() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTACameraMemoryRecoveryAction(backend: ACTACameraMemoryRecoveryUnavailableBackend(store: store))
        let prepared = try await action.prepareConfirmation(parameters: [:], context: ACTAActionContext())
        let direct = try await action.execute(parameters: [:], context: ACTAActionContext(isConfirmed: true))
        let unconfirmed = try await action.executeConfirmed(parameters: [:], context: ACTAActionContext(),
                                                            snapshot: prepared.snapshot)
        XCTAssertFalse(direct.success)
        XCTAssertFalse(unconfirmed.success)
        XCTAssertThrowsError(try action.validate(parameters: ["unexpected": "value"]))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, review)
        XCTAssertTrue(result.error?.hasPrefix("UNAVAILABLE:") == true)
        XCTAssertTrue(try store.hasPendingDeletion())
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
    }

    func testNoJournalAndInvalidJournalDoNotOfferConfirmation() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent(".deletion-journal.json")
        let registry = ACTAActionRegistry()
        let action = ACTACameraMemoryRecoveryAction(backend: ACTACameraMemoryRecoveryUnavailableBackend(store: store))
        await registry.register(action)
        try FileManager.default.removeItem(at: journal)
        let missing = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertNil(missing.confirmationToken)
        try Data("invalid".utf8).write(to: journal)
        let invalid = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertNil(invalid.confirmationToken)
        XCTAssertTrue(invalid.error?.hasPrefix("CONFIRMATION_PREPARATION_FAILED:") == true)
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
    }

    func testSymlinkJournalCannotBeReviewed() async throws {
        let (root, store, frames) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent(".deletion-journal.json")
        let copy = root.appendingPathComponent("journal-copy")
        try FileManager.default.moveItem(at: journal, to: copy)
        try FileManager.default.createSymbolicLink(atPath: journal.path, withDestinationPath: copy.path)
        let registry = ACTAActionRegistry()
        let action = ACTACameraMemoryRecoveryAction(backend: ACTACameraMemoryRecoveryUnavailableBackend(store: store))
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertNil(review.confirmationToken)
        XCTAssertTrue(try store.hasStoredImage(for: frames[1]))
    }

    func testFailedVerificationDoesNotReportSuccess() async throws {
        let (root, store, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        let action = ACTACameraMemoryRecoveryAction(backend: FixtureBackend(store: store, failVerification: true))
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, review)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.error?.hasPrefix("PARTIAL_FAILURE:") == true)
    }
}
