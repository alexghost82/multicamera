import Foundation
import SQLite3
import XCTest
@testable import CameraCore

final class ACTANarrativeCloseJournalTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, ACTANarrativeCloseJournal) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".narrative-journal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("tracking.sqlite")
        let store = try LocalTrackingStore(url: url)
        return (directory, store, try ACTANarrativeCloseJournal(databaseURL: url))
    }

    private func reservation() -> ACTANarrativeCloseReservation {
        ACTANarrativeCloseReservation(
            chapterID: UUID(), cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 101),
            frameCount: 1, sightingCount: 2, identityCount: 1, inferenceInput: Data([1, 2, 3]))
    }

    private func fakeInference(_ input: ACTANarrativeCloseReservation, summary: String = "fixture") -> ACTANarrativeChapterRecord {
        ACTANarrativeChapterRecord(
            chapterID: input.chapterID.uuidString, cameraID: input.cameraID, cameraName: input.cameraName,
            startedAt: input.startedAt, endedAt: input.endedAt,
            narrative: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: summary),
            frameCount: input.frameCount, sightingCount: input.sightingCount, identityCount: input.identityCount)
    }

    private func exec(_ sql: String, directory: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("tracking.sqlite").path, &db,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
    }

    func testReopenAndRetryUsesOneChapterAndPreservesOperatorEdits() throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = reservation()
        try journal.reserve(input)
        try journal.reserve(input)

        let reopened = try ACTANarrativeCloseJournal(databaseURL: directory.appendingPathComponent("tracking.sqlite"))
        XCTAssertEqual(try reopened.pendingReservations(), [input])
        let result = fakeInference(try XCTUnwrap(reopened.reservation(chapterID: input.chapterID)))
        XCTAssertEqual(try reopened.commit(chapterID: input.chapterID, record: result), result)
        try store.setACTANarrativeOperatorText(chapterID: input.chapterID.uuidString, operatorText: "reviewed")
        try store.setACTANarrativePinned(chapterID: input.chapterID.uuidString, pinned: true)

        let afterRestart = try ACTANarrativeCloseJournal(databaseURL: directory.appendingPathComponent("tracking.sqlite"))
        XCTAssertTrue(try afterRestart.pendingReservations().isEmpty)
        XCTAssertEqual(try afterRestart.completed(chapterID: input.chapterID), result)
        XCTAssertEqual(try afterRestart.commit(chapterID: input.chapterID, record: fakeInference(input, summary: "different")), result)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: input.chapterID.uuidString))
        XCTAssertEqual(saved.operatorText, "reviewed")
        XCTAssertTrue(saved.pinned)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: input.cameraID).count, 1)
    }

    func testFailedJournalUpdateRollsBackChapterAndKeepsReservation() throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = reservation()
        try journal.reserve(input)
        try exec("""
            CREATE TRIGGER reject_close BEFORE UPDATE ON acta_narrative_close_journal
            BEGIN SELECT RAISE(FAIL, 'test'); END
            """, directory: directory)
        XCTAssertThrowsError(try journal.commit(chapterID: input.chapterID, record: fakeInference(input)))
        XCTAssertNil(try store.loadACTANarrativeChapterRecord(chapterID: input.chapterID.uuidString))
        let reopened = try ACTANarrativeCloseJournal(databaseURL: directory.appendingPathComponent("tracking.sqlite"))
        XCTAssertEqual(try reopened.pendingReservations(), [input])
        XCTAssertNil(try reopened.completed(chapterID: input.chapterID))
    }

    func testConflictAndChangedChapterFailClosed() throws {
        let (directory, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = reservation()
        try journal.reserve(input)
        let conflicting = ACTANarrativeCloseReservation(
            chapterID: input.chapterID, cameraID: UUID(), cameraName: input.cameraName,
            startedAt: input.startedAt, endedAt: input.endedAt, frameCount: input.frameCount,
            sightingCount: input.sightingCount, identityCount: input.identityCount, inferenceInput: input.inferenceInput)
        XCTAssertThrowsError(try journal.reserve(conflicting)) {
            XCTAssertEqual($0 as? ACTANarrativeCloseJournalError, .reservationConflict)
        }
        XCTAssertThrowsError(try journal.commit(chapterID: input.chapterID, record: fakeInference(conflicting)))
        XCTAssertEqual(try journal.pendingReservations(), [input])
        _ = try journal.commit(chapterID: input.chapterID, record: fakeInference(input))
        try exec("UPDATE ghost_narrative_chapters SET ai_summary = 'changed' WHERE chapter_id = '\(input.chapterID.uuidString)'",
                 directory: directory)
        XCTAssertThrowsError(try journal.completed(chapterID: input.chapterID))
        XCTAssertThrowsError(try journal.commit(chapterID: input.chapterID, record: fakeInference(input)))
    }

    func testExistingChapterDoesNotGetOverwritten() throws {
        let (directory, store, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = reservation()
        let original = fakeInference(input, summary: "existing")
        try store.saveACTANarrativeChapterRecord(original)
        try journal.reserve(input)
        XCTAssertThrowsError(try journal.commit(chapterID: input.chapterID, record: fakeInference(input)))
        XCTAssertEqual(try store.loadACTANarrativeChapterRecord(chapterID: input.chapterID.uuidString), original)
        XCTAssertEqual(try journal.pendingReservations(), [input])
    }

    func testCompetingConnectionsCommitOnlyOneResult() async throws {
        let (directory, store, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = reservation()
        try first.reserve(input)
        let second = try ACTANarrativeCloseJournal(databaseURL: directory.appendingPathComponent("tracking.sqlite"))
        let a = fakeInference(input, summary: "first")
        let b = fakeInference(input, summary: "second")
        async let left = first.commit(chapterID: input.chapterID, record: a)
        async let right = second.commit(chapterID: input.chapterID, record: b)
        let results = try await (left, right)
        XCTAssertEqual(results.0, results.1)
        XCTAssertTrue(results.0 == a || results.0 == b)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: input.cameraID).count, 1)
    }
}
