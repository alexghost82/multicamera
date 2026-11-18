import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTACameraMemoryClearActionTests: XCTestCase {
    private func approve(_ registry: ACTAActionRegistry, _ review: ACTAActionResult) async throws -> ACTAActionResult {
        try await registry.confirmAndExecute(token: try XCTUnwrap(review.confirmationToken), confirmed: true,
                                             expectedActionID: review.actionID, expectedParameters: [:],
                                             expectedThreadID: "default", expectedReviewTitle: review.summary)
    }

    /// Fixture-only backend: all test writers cooperate with the store lock.
    private struct FixtureBackend: ACTACameraMemoryClearBackend {
        let store: CameraMemoryStore
        let root: URL
        var failVerification = false
        var failCurrentVerification = false

        func snapshot() async throws -> CameraMemoryDeletionSnapshot { try store.deletionSnapshot() }
        func clear(_ snapshot: CameraMemoryDeletionSnapshot) async throws {
            try store.deleteConfirmedSnapshot(snapshot)
        }
        func verify(_ snapshot: CameraMemoryDeletionSnapshot) async throws -> Bool {
            try !failVerification && store.verifyConfirmedDeletion(snapshot)
        }
        func verifyCurrentState() async throws -> Bool {
            guard !failCurrentVerification, try store.deletionSnapshot().count == 0 else { return false }
            return try !FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasSuffix(".jpg") })
        }
    }

    private func fixture() throws -> (URL, CameraMemoryStore) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".memory-clear-action-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (root, CameraMemoryStore(url: root))
    }

    private func save(_ store: CameraMemoryStore, camera: UUID = UUID()) throws -> CameraMemoryFrame {
        let date = Date(timeIntervalSince1970: 2_000_000)
        return try store.save(Data("synthetic".utf8), cameraID: camera, cameraName: "private-name",
                              capturedAt: date, summary: "private-summary", now: date)
    }

    func testReviewRejectionAndConfirmedVerifiedClear() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try save(store)
        let second = try save(store)
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(review.requiresOperatorConfirmation)
        XCTAssertTrue(review.summary.contains("2 indexed frames (18 indexed bytes)"))
        for frame in [first, second] {
            XCTAssertTrue(review.summary.contains(frame.id.uuidString))
            XCTAssertTrue(review.summary.contains(frame.cameraID.uuidString))
        }
        XCTAssertFalse(review.summary.contains("private-name"))
        XCTAssertFalse(review.summary.contains("private-summary"))
        let rejected = try await registry.confirmAndExecute(token: try XCTUnwrap(review.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        XCTAssertTrue(try store.hasStoredImage(for: first))
        XCTAssertTrue(try store.hasStoredImage(for: second))

        let next = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, next)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(try store.deletionSnapshot().frames.isEmpty)
        XCTAssertFalse(try store.hasStoredImage(for: first))
        XCTAssertFalse(try store.hasStoredImage(for: second))
        let replay = try await approve(registry, next)
        XCTAssertFalse(replay.success)
    }

    func testChangedSnapshotCannotDeleteEitherOldOrNewFrame() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try save(store)
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let second = try save(store)
        let result = try await approve(registry, review)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("CONFLICT:") == true)
        XCTAssertTrue(try store.hasStoredImage(for: first))
        XCTAssertTrue(try store.hasStoredImage(for: second))
        XCTAssertFalse(try store.hasPendingDeletion())
    }

    func testDirectCallsAndUnknownParametersFailClosed() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try save(store)
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root))
        let prepared = try await action.prepareConfirmation(parameters: [:], context: ACTAActionContext())
        let direct = try await action.execute(parameters: [:], context: ACTAActionContext(isConfirmed: true))
        let unconfirmed = try await action.executeConfirmed(parameters: [:], context: ACTAActionContext(),
                                                            snapshot: prepared.snapshot)
        XCTAssertFalse(direct.success)
        XCTAssertFalse(unconfirmed.success)
        XCTAssertThrowsError(try action.validate(parameters: ["unexpected": "value"]))
        XCTAssertTrue(try store.hasStoredImage(for: frame))
    }

    func testEachTokenRetainsItsOwnSnapshot() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try save(store)
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let oldReview = try await registry.execute(actionID: action.id, parameters: [:])
        let second = try save(store)
        let newReview = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(oldReview.summary.contains("1 indexed frames"))
        XCTAssertTrue(newReview.summary.contains("2 indexed frames"))
        let stale = try await approve(registry, oldReview)
        XCTAssertFalse(stale.success)
        XCTAssertTrue(try store.hasStoredImage(for: first))
        XCTAssertTrue(try store.hasStoredImage(for: second))
        let current = try await approve(registry, newReview)
        XCTAssertTrue(current.success, current.summary)
        XCTAssertFalse(try store.hasStoredImage(for: first))
        XCTAssertFalse(try store.hasStoredImage(for: second))
    }

    func testVerificationFailureDoesNotReportSuccess() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try save(store)
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root, failVerification: true))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, review)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.error?.hasPrefix("PARTIAL_FAILURE:") == true)
    }

    func testProductionBackendRemainsUnavailable() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try save(store)
        let action = ACTACameraMemoryClearAction(backend: ACTACameraMemoryClearUnavailableBackend(store: store))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        let result = try await approve(registry, review)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("UNAVAILABLE:") == true)
        XCTAssertTrue(try store.hasStoredImage(for: frame))
        XCTAssertFalse(try store.hasPendingDeletion())
    }

    func testPendingRecoveryPreventsConfirmation() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = try save(store)
        try Data("fixture".utf8).write(to: root.appendingPathComponent(".deletion-journal.json"))
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(review.requiresOperatorConfirmation)
        XCTAssertNil(review.confirmationToken)
        XCTAssertTrue(review.error?.hasPrefix("CONFIRMATION_PREPARATION_FAILED:") == true)
        XCTAssertTrue(try store.hasStoredImage(for: frame))
    }

    func testRegistryReverificationFailureAndEmptyReview() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTACameraMemoryClearAction(
            backend: FixtureBackend(store: store, root: root, failCurrentVerification: true))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(review.summary.contains("0 indexed frames (0 indexed bytes)"))
        XCTAssertTrue(review.summary.contains("The indexed set is empty"))
        let result = try await approve(registry, review)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
    }

    func testUnindexedImageIsExcludedAndPreventsConservativeVerification() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("orphan.jpg")
        try Data("unindexed".utf8).write(to: orphan)
        let action = ACTACameraMemoryClearAction(backend: FixtureBackend(store: store, root: root))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let review = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(review.summary.contains("Unindexed files are excluded"))
        let result = try await approve(registry, review)
        XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: orphan), Data("unindexed".utf8))
    }
}
