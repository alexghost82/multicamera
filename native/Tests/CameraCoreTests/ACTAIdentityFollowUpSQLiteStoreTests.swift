import Foundation
import SQLite3
import XCTest
@testable import CameraCore

private final class FollowUpRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.withLock { values.append(value) } }
    var successes: Int { lock.withLock { values.filter { $0 }.count } }
}

final class ACTAIdentityFollowUpSQLiteStoreTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, ACTAIdentityFollowUpSQLiteStore, ACTAIdentityGalleryProfile) {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".identity-follow-up-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let profile = ACTAIdentityGalleryProfile(identityID: UUID().uuidString, kind: "person",
            displayCode: "fixture", displayName: "private-fixture", centroid: [1, 0],
            firstSeenAt: Date(timeIntervalSince1970: 1), lastSeenAt: Date(timeIntervalSince1970: 2))
        try store.upsertACTAIdentityProfile(profile)
        return (root, store, try store.makeACTAIdentityFollowUpStore(), profile)
    }

    func testFlagIsReversibleAndDoesNotChangeProfile() throws {
        let (root, store, flags, profile) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try XCTUnwrap(flags.capture(identityID: profile.identityID))
        XCTAssertFalse(before.flagged)
        let on = try XCTUnwrap(flags.commit(expected: before, flagged: true))
        XCTAssertTrue(on.flagged)
        XCTAssertTrue(try flags.finish(on))
        XCTAssertNil(try flags.commit(expected: before, flagged: false))
        let off = try XCTUnwrap(flags.commit(expected: on, flagged: false))
        XCTAssertFalse(off.flagged)
        XCTAssertTrue(try flags.finish(off))
        XCTAssertEqual(try store.loadACTAIdentityProfiles(), [profile])
    }

    func testProfileABAAndDeletionRecreationInvalidateReviews() throws {
        let (root, store, flags, profile) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(flags.capture(identityID: profile.identityID))
        var changed = profile
        changed.displayCode = "changed"
        try store.upsertACTAIdentityProfile(changed)
        try store.upsertACTAIdentityProfile(profile)
        XCTAssertNil(try flags.commit(expected: original, flagged: true))
        let fresh = try XCTUnwrap(flags.capture(identityID: profile.identityID))
        let flagged = try XCTUnwrap(flags.commit(expected: fresh, flagged: true))
        XCTAssertTrue(try flags.finish(flagged))
        try store.deleteACTAIdentityProfile(identityID: profile.identityID)
        XCTAssertNil(try flags.capture(identityID: profile.identityID))
        try store.upsertACTAIdentityProfile(profile)
        XCTAssertNil(try flags.commit(expected: flagged, flagged: false))
        XCTAssertFalse(try XCTUnwrap(flags.capture(identityID: profile.identityID)).flagged)
    }

    func testCompetingStoresCannotBothCommitSameReview() throws {
        let (root, _, first, profile) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = try ACTAIdentityFollowUpSQLiteStore(databaseURL: root.appendingPathComponent("tracking.sqlite"))
        let captured = try XCTUnwrap(first.capture(identityID: profile.identityID))
        let results = FollowUpRaceResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let store = index == 0 ? first : second
            if let result = try? store.commit(expected: captured, flagged: true) {
                results.add((try? store.finish(result)) == true)
            } else {
                results.add(false)
            }
        }
        XCTAssertEqual(results.successes, 1)
        XCTAssertTrue(try XCTUnwrap(first.capture(identityID: profile.identityID)).flagged)
    }

    func testExtraTriggerEffectsAreRolledBack() throws {
        let (root, store, flags, profile) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try XCTUnwrap(flags.capture(identityID: profile.identityID))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("tracking.sqlite").path, &db,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TRIGGER fixture_side_effect AFTER INSERT ON ghost_identity_follow_up
            BEGIN UPDATE ghost_identities SET kind = 'changed'; END
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try flags.commit(expected: before, flagged: true))
        XCTAssertThrowsError(try flags.capture(identityID: profile.identityID))
        XCTAssertEqual(try flags.recoverySnapshot()?.snapshot, before)
        XCTAssertEqual(try store.loadACTAIdentityProfiles(), [profile])
    }

    func testReplaceClearsFlagAndMissingFenceFailsClosed() throws {
        let (root, _, flags, profile) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try XCTUnwrap(flags.capture(identityID: profile.identityID))
        let flagged = try XCTUnwrap(flags.commit(expected: before, flagged: true))
        XCTAssertTrue(try flags.finish(flagged))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("tracking.sqlite").path, &db,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, """
            INSERT OR REPLACE INTO ghost_identities(identity_id, kind, display_code, profile_json, updated_at)
            SELECT identity_id, kind, display_code, profile_json, updated_at FROM ghost_identities
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertNil(try flags.commit(expected: flagged, flagged: false))
        XCTAssertFalse(try XCTUnwrap(flags.capture(identityID: profile.identityID)).flagged)
        XCTAssertEqual(sqlite3_exec(connection, "DROP TRIGGER ghost_identity_follow_up_profile_update", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try flags.capture(identityID: profile.identityID))
    }

    func testOtherProcessABARejectsReview() throws {
        guard let helper = ProcessInfo.processInfo.environment["IDENTITY_FOLLOW_UP_TEST_HELPER"] else {
            throw XCTSkip("Set IDENTITY_FOLLOW_UP_TEST_HELPER to the compiled fixture helper.")
        }
        let (root, _, flags, profile) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try XCTUnwrap(flags.capture(identityID: profile.identityID))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [root.appendingPathComponent("tracking.sqlite").path, profile.identityID]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(try flags.commit(expected: before, flagged: true))
        XCTAssertFalse(try XCTUnwrap(flags.capture(identityID: profile.identityID)).flagged)
    }

    func testIncompatibleExistingSchemaIsNotOverwritten() throws {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".identity-follow-up-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tracking.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,
            "CREATE TABLE ghost_identity_follow_up (other TEXT); INSERT INTO ghost_identity_follow_up VALUES ('fixture')",
            nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try LocalTrackingStore(url: url))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT other FROM ghost_identity_follow_up", -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(query, 0))), "fixture")
    }
}
