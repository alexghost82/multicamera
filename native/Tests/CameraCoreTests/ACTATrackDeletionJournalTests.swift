import Foundation
import CoreGraphics
import SQLite3
import XCTest
@testable import CameraCore

final class ACTATrackDeletionJournalTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, ACTATrackDeletionJournal, UUID) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".track-deletion-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let database = directory.appendingPathComponent("tracking.sqlite")
        let store = try LocalTrackingStore(url: database)
        let id = UUID()
        try store.record(DetectedObject(id: 0, label: "person", confidence: 0.9, box: .zero, trackID: id),
                         cameraID: UUID(), cameraName: "synthetic",
                         cropJPEG: Data([1, 2, 3]), cutoutPNG: Data([4, 5, 6]))
        return (directory, store, try ACTATrackDeletionJournal(databaseURL: database), id)
    }

    private func exec(_ sql: String, _ directory: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("tracking.sqlite").path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            XCTFail("Unable to open fixture")
            return
        }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testSnapshotRejectsChangedTrackAndImages() throws {
        let (directory, store, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try journal.snapshot(trackID: id)
        try exec("UPDATE tracked_objects SET observation_count = observation_count + 1 WHERE track_id = '\(id.uuidString)'", directory)
        XCTAssertThrowsError(try journal.commit(snapshot)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .staleSnapshot)
        }
        let fresh = try journal.snapshot(trackID: id)
        let image = directory.appendingPathComponent("identity-crops").appendingPathComponent(fresh.imageNames[0])
        try Data([9]).write(to: image)
        XCTAssertThrowsError(try journal.commit(fresh)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .staleSnapshot)
        }
        XCTAssertTrue(try store.contains(trackID: id))
        XCTAssertTrue(try journal.pendingTrackIDs().isEmpty)
    }

    func testDatabaseFailureRollsBackAllRowsAndLeavesImages() throws {
        let (directory, store, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = UUID()
        let other = UUID()
        try exec("""
            INSERT INTO operator_identity_groups VALUES('\(id.uuidString)', '\(group.uuidString)', 1);
            INSERT INTO operator_reid_different_pairs VALUES('\(id.uuidString)', '\(other.uuidString)', 1);
            CREATE TRIGGER reject_track_deletion BEFORE DELETE ON tracked_objects
            BEGIN SELECT RAISE(FAIL, 'synthetic failure'); END;
            """, directory)
        let snapshot = try journal.snapshot(trackID: id)
        XCTAssertThrowsError(try journal.commit(snapshot))
        XCTAssertEqual(try journal.snapshot(trackID: id), snapshot)
        XCTAssertTrue(try store.contains(trackID: id))
        XCTAssertTrue(try journal.pendingTrackIDs().isEmpty)
        for name in snapshot.imageNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("identity-crops").appendingPathComponent(name).path))
        }
    }

    func testChangedOperatorLinkInvalidatesSnapshot() throws {
        let (directory, store, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try journal.snapshot(trackID: id)
        try exec("INSERT INTO operator_identity_groups VALUES('\(id.uuidString)', '\(UUID().uuidString)', 1)", directory)
        XCTAssertThrowsError(try journal.commit(snapshot)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .staleSnapshot)
        }
        XCTAssertTrue(try store.contains(trackID: id))
    }

    func testRecoveryAfterPartialCleanupAndRestart() throws {
        let (directory, store, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try journal.snapshot(trackID: id)
        try journal.commit(snapshot)
        XCTAssertFalse(try store.contains(trackID: id))
        XCTAssertEqual(try journal.pendingTrackIDs(), [id])
        let images = snapshot.imageNames.map { directory.appendingPathComponent("identity-crops").appendingPathComponent($0) }
        let original = try Data(contentsOf: images[1])
        try Data([99]).write(to: images[1])
        XCTAssertThrowsError(try journal.recover(trackID: id)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .imageChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: images[0].path))
        XCTAssertEqual(try journal.pendingTrackIDs(), [id])
        try original.write(to: images[1])
        let reopened = try ACTATrackDeletionJournal(databaseURL: directory.appendingPathComponent("tracking.sqlite"))
        try reopened.recover(trackID: id)
        try reopened.recover(trackID: id)
        XCTAssertTrue(try reopened.pendingTrackIDs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: images[1].path))
    }

    func testSharedImageAndUnsafePathFailClosed() throws {
        let (directory, store, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try journal.snapshot(trackID: id)
        let other = UUID()
        try store.record(DetectedObject(id: 1, label: "person", confidence: 0.8, box: .zero, trackID: other),
                         cameraID: UUID(), cameraName: "synthetic")
        try exec("UPDATE tracked_objects SET crop_path = '\(snapshot.imageNames[0])' WHERE track_id = '\(other.uuidString)'", directory)
        XCTAssertThrowsError(try journal.commit(snapshot)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .sharedImage)
        }
        try exec("UPDATE tracked_objects SET crop_path = '../outside' WHERE track_id = '\(id.uuidString)'", directory)
        XCTAssertThrowsError(try journal.snapshot(trackID: id)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .invalidImage)
        }
        XCTAssertTrue(try store.contains(trackID: id))
    }

    func testRecoveryDoesNotRemoveImageReusedByAnotherTrack() throws {
        let (directory, store, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try journal.snapshot(trackID: id)
        try journal.commit(snapshot)
        let other = UUID()
        try store.record(DetectedObject(id: 1, label: "person", confidence: 0.8, box: .zero, trackID: other),
                         cameraID: UUID(), cameraName: "synthetic")
        try exec("UPDATE tracked_objects SET crop_path = '\(snapshot.imageNames[0])' WHERE track_id = '\(other.uuidString)'", directory)
        XCTAssertThrowsError(try journal.recover(trackID: id)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .sharedImage)
        }
        XCTAssertEqual(try journal.pendingTrackIDs(), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("identity-crops").appendingPathComponent(snapshot.imageNames[0]).path))
    }

    func testRecoveryRejectsSymlinkInsteadOfRemovingTarget() throws {
        let (directory, _, journal, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try journal.snapshot(trackID: id)
        try journal.commit(snapshot)
        let image = directory.appendingPathComponent("identity-crops").appendingPathComponent(snapshot.imageNames[0])
        let target = directory.appendingPathComponent("synthetic-target")
        try Data([1, 2, 3]).write(to: target)
        try FileManager.default.removeItem(at: image)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: target)
        XCTAssertThrowsError(try journal.recover(trackID: id)) {
            XCTAssertEqual($0 as? ACTATrackDeletionError, .invalidImage)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
        XCTAssertEqual(try journal.pendingTrackIDs(), [id])
    }
}
