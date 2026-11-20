import Foundation
import SQLite3
import XCTest
@testable import CameraCore

final class ACTANarrativePinSQLiteStoreTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, UUID) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".narrative-cas-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite"))
        let id = UUID()
        try store.saveACTANarrativeChapter(id: id, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 11),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: "fixture"))
        try store.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        return (directory, store, id)
    }

    func testRealStoreCASRejectsABAAndPreservesFields() throws {
        let (directory, writer, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite"))
        let cas = try writer.makeACTANarrativePinStore()
        let before = try XCTUnwrap(cas.capture(chapterID: id))
        try second.setACTANarrativePinned(chapterID: id.uuidString, pinned: true)
        try second.setACTANarrativePinned(chapterID: id.uuidString, pinned: false)
        XCTAssertNil(try cas.commit(expected: before, pinned: true))
        let fresh = try XCTUnwrap(cas.capture(chapterID: id))
        let saved = try XCTUnwrap(cas.commit(expected: fresh, pinned: true))
        XCTAssertTrue(saved.pinned)
        XCTAssertNotEqual(saved.revision, fresh.revision)
        XCTAssertEqual(saved.preservedFields, fresh.preservedFields)
        XCTAssertTrue(try XCTUnwrap(second.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
        XCTAssertNil(try cas.commit(expected: fresh, pinned: false))
    }

    func testChapterWritesAndJournalInvalidateGlobalRevision() throws {
        let (directory, writer, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cas = try writer.makeACTANarrativePinStore()
        var snapshot = try XCTUnwrap(cas.capture(chapterID: id))
        try writer.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        XCTAssertNil(try cas.commit(expected: snapshot, pinned: true))
        snapshot = try XCTUnwrap(cas.capture(chapterID: id))
        let otherID = UUID()
        try writer.saveACTANarrativeChapter(id: otherID, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 20), endedAt: Date(timeIntervalSince1970: 21),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "other", summary: "fixture"))
        XCTAssertNil(try cas.commit(expected: snapshot, pinned: true))
        snapshot = try XCTUnwrap(cas.capture(chapterID: id))
        let journal = try ACTANarrativeCloseJournal(databaseURL: directory.appendingPathComponent("tracking.sqlite"))
        let reservation = ACTANarrativeCloseReservation(chapterID: UUID(), cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 30), endedAt: Date(timeIntervalSince1970: 31),
            frameCount: 1, sightingCount: 0, identityCount: 0, inferenceInput: Data([1]))
        try journal.reserve(reservation)
        let chapter = ACTANarrativeChapterRecord(chapterID: reservation.chapterID.uuidString,
            cameraID: reservation.cameraID, cameraName: reservation.cameraName, startedAt: reservation.startedAt,
            endedAt: reservation.endedAt, narrative: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: "fixture"),
            frameCount: 1, sightingCount: 0, identityCount: 0)
        _ = try journal.commit(chapterID: reservation.chapterID, record: chapter)
        XCTAssertNil(try cas.commit(expected: snapshot, pinned: true))
    }

    func testUnknownColumnsAndTriggerSideEffectsAreNotLost() throws {
        let (directory, writer, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,
            "ALTER TABLE ghost_narrative_chapters ADD COLUMN future BLOB; UPDATE ghost_narrative_chapters SET future = X'0001FF'",
            nil, nil, nil), SQLITE_OK)
        let cas = try writer.makeACTANarrativePinStore()
        let before = try XCTUnwrap(cas.capture(chapterID: id))
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TRIGGER fixture_mutation AFTER UPDATE OF pinned ON ghost_narrative_chapters
            BEGIN UPDATE ghost_narrative_chapters SET future = X'02' WHERE chapter_id = NEW.chapter_id; END
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try cas.commit(expected: before, pinned: true))
        let after = try XCTUnwrap(cas.capture(chapterID: id))
        XCTAssertFalse(after.pinned)
        XCTAssertEqual(after.preservedFields, before.preservedFields)
        XCTAssertNotEqual(after.revision, before.revision)
    }

    func testTriggerChangingAnotherChapterIsRolledBack() throws {
        let (directory, writer, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherID = UUID()
        try writer.saveACTANarrativeChapter(id: otherID, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 20), endedAt: Date(timeIntervalSince1970: 21),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "other", summary: "original"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("tracking.sqlite").path, &db,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TRIGGER fixture_other AFTER UPDATE OF pinned ON ghost_narrative_chapters
            BEGIN UPDATE ghost_narrative_chapters SET ai_summary = 'changed'
            WHERE chapter_id = '\(otherID.uuidString)'; END
            """, nil, nil, nil), SQLITE_OK)
        let cas = try writer.makeACTANarrativePinStore()
        let before = try XCTUnwrap(cas.capture(chapterID: id))
        XCTAssertThrowsError(try cas.commit(expected: before, pinned: true))
        XCTAssertFalse(try XCTUnwrap(cas.capture(chapterID: id)).pinned)
        XCTAssertEqual(try writer.loadACTANarrativeChapterRecord(chapterID: otherID.uuidString)?.aiSummary, "original")
    }

    func testUnmarkedPinAndDamagedRevisionFailClosed() throws {
        let (directory, writer, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newID = UUID()
        try writer.saveACTANarrativeChapter(id: newID, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: "fixture"))
        let cas = try writer.makeACTANarrativePinStore()
        let before = try XCTUnwrap(cas.capture(chapterID: newID))
        XCTAssertNil(try cas.commit(expected: before, pinned: true))
        let revision = directory.appendingPathComponent(".tracking.sqlite.narrative-revision")
        try Data("damaged".utf8).write(to: revision)
        XCTAssertThrowsError(try cas.capture(chapterID: id))
        XCTAssertThrowsError(try writer.setACTANarrativePinned(chapterID: id.uuidString, pinned: true))
    }

    func testSeparateProcessABAAndLock() throws {
        guard let helper = ProcessInfo.processInfo.environment["NARRATIVE_CAS_TEST_HELPER"] else {
            throw XCTSkip("Set NARRATIVE_CAS_TEST_HELPER to the compiled isolated fixture.")
        }
        let (directory, writer, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.sqlite")
        let cas = try writer.makeACTANarrativePinStore()
        let before = try XCTUnwrap(cas.capture(chapterID: id))
        func child(_ mode: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [mode, url.path, id.uuidString]
            return process
        }
        let aba = child("aba")
        try aba.run()
        aba.waitUntilExit()
        XCTAssertEqual(aba.terminationStatus, 0)
        XCTAssertNil(try cas.commit(expected: before, pinned: true))

        let latest = try XCTUnwrap(cas.capture(chapterID: id))
        let holder = child("hold")
        let input = Pipe()
        let output = Pipe()
        holder.standardInput = input
        holder.standardOutput = output
        try holder.run()
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            try? input.fileHandleForWriting.write(contentsOf: Data([1]))
        }
        let committed = try XCTUnwrap(cas.commit(expected: latest, pinned: true))
        holder.waitUntilExit()
        XCTAssertEqual(holder.terminationStatus, 0)
        XCTAssertTrue(committed.pinned)

        try writer.setACTANarrativePinned(chapterID: id.uuidString, pinned: false)
        let raceSnapshot = try XCTUnwrap(cas.capture(chapterID: id))
        let racer = child("race")
        let raceInput = Pipe()
        let raceOutput = Pipe()
        defer { try? raceInput.fileHandleForWriting.close() }
        racer.standardInput = raceInput
        racer.standardOutput = raceOutput
        try racer.run()
        XCTAssertEqual(try raceOutput.fileHandleForReading.read(upToCount: 1), Data([1]))
        XCTAssertNotNil(try cas.commit(expected: raceSnapshot, pinned: true))
        try raceInput.fileHandleForWriting.write(contentsOf: Data([1]))
        XCTAssertEqual(try raceOutput.fileHandleForReading.read(upToCount: 1), Data([0]))
        racer.waitUntilExit()
        XCTAssertEqual(racer.terminationStatus, 0)
    }
}
