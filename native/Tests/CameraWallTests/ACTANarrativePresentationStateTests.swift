import CameraCore
import Combine
import Foundation
import SQLite3
import XCTest
@testable import CameraWall

@MainActor
final class ACTANarrativePresentationStateTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, LocalTrackingStore, ACTANarrativePresentationState, UUID) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".narrative-cas-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("tracking.sqlite")
        let first = try LocalTrackingStore(url: url)
        let second = try LocalTrackingStore(url: url)
        let id = UUID()
        try first.saveACTANarrativeChapter(id: id, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: "private"))
        try first.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        let state = try ACTANarrativePresentationState(trackingStore: first)
        try state.refresh()
        return (directory, first, second, state, id)
    }

    func testUnmarkedPinIsRefusedAndOldRowCannotBeReplayed() throws {
        let (directory, store, _, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unmarkedID = UUID()
        try store.saveACTANarrativeChapter(id: unmarkedID, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 3), endedAt: Date(timeIntervalSince1970: 4),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "unmarked", summary: "private"))
        try state.refresh()
        let unmarked = try XCTUnwrap(state.rows.first { $0.chapter.chapterID == unmarkedID.uuidString })
        XCTAssertThrowsError(try state.toggle(unmarked))
        let unchanged = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: unmarkedID.uuidString))
        XCTAssertFalse(unchanged.pinned || unchanged.operatorMarked)
        let old = try XCTUnwrap(state.rows.first { $0.chapter.chapterID == id.uuidString })
        try state.toggle(old)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString))
        XCTAssertTrue(saved.pinned && saved.operatorMarked)
        XCTAssertEqual(saved.aiSummary, "private")
        XCTAssertTrue(try XCTUnwrap(state.rows.first { $0.chapter.chapterID == id.uuidString }).chapter.pinned)
        XCTAssertThrowsError(try state.toggle(old))
        XCTAssertTrue(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
        try state.toggle(try XCTUnwrap(state.rows.first { $0.chapter.chapterID == id.uuidString }))
        let unpinned = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString))
        XCTAssertFalse(unpinned.pinned)
        XCTAssertTrue(unpinned.operatorMarked)
    }

    func testExternalABARejectsDisplayedToggleUntilRefresh() throws {
        let (directory, store, other, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = try XCTUnwrap(state.rows.first)
        try other.setACTANarrativePinned(chapterID: id.uuidString, pinned: true)
        try other.setACTANarrativePinned(chapterID: id.uuidString, pinned: false)
        XCTAssertThrowsError(try state.toggle(row))
        XCTAssertFalse(state.canToggle)
        XCTAssertFalse(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
        try state.refresh()
        XCTAssertTrue(state.canToggle)
        try state.toggle(try XCTUnwrap(state.rows.first))
        XCTAssertTrue(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
    }

    func testOtherProcessABARejectsDisplayedToggle() throws {
        guard let helper = ProcessInfo.processInfo.environment["NARRATIVE_CAS_TEST_HELPER"] else {
            throw XCTSkip("Set NARRATIVE_CAS_TEST_HELPER to the compiled isolated fixture.")
        }
        let (directory, store, _, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = try XCTUnwrap(state.rows.first)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["aba", directory.appendingPathComponent("tracking.sqlite").path, id.uuidString]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try state.toggle(row))
        XCTAssertFalse(state.canToggle)
        XCTAssertFalse(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
    }

    func testReentrantNotificationCannotToggleOrInstallStaleRefresh() throws {
        let (directory, store, other, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try XCTUnwrap(state.rows.first)
        var nestedRejected = false
        var wrote = false
        let subscription = state.objectWillChange.sink {
            if !wrote {
                wrote = true
                do { try state.toggle(before) } catch { nestedRejected = true }
                try? other.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "changed")
            }
        }
        XCTAssertThrowsError(try state.refresh())
        XCTAssertTrue(nestedRejected)
        XCTAssertEqual(state.rows.first?.chapter.operatorText, before.chapter.operatorText)
        XCTAssertFalse(state.canToggle)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)?.operatorText, "changed")
        subscription.cancel()
        try state.refresh()
        XCTAssertEqual(state.rows.first?.chapter.operatorText, "changed")
        XCTAssertTrue(state.canToggle)
    }

    func testInvalidStoredChapterFailsRefreshClosed() throws {
        let (directory, _, _, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = try XCTUnwrap(state.rows.first)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("tracking.sqlite").path, &db,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,
            "UPDATE ghost_narrative_chapters SET chapter_json = 'invalid' WHERE chapter_id = '\(id.uuidString)'",
            nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try state.refresh())
        XCTAssertFalse(state.canToggle)
        XCTAssertEqual(state.rows.first?.chapter, row.chapter)
        XCTAssertThrowsError(try state.toggle(row))
    }

    func testBrokerCommitRefreshesSamePublishedState() async throws {
        let (directory, store, _, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        try state.refresh()
        let oldRow = try XCTUnwrap(state.rows.first)
        let action = state.makePinAction()
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let request = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"chapter_id":"\#(id.uuidString)","pinned":true}"#)
        XCTAssertTrue(request.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertTrue(try XCTUnwrap(state.rows.first).chapter.pinned)
        XCTAssertThrowsError(try state.toggle(oldRow))
    }

    func testAgentRefreshFailureBlocksGUIUntilExplicitReconciliation() async throws {
        let (directory, store, other, state, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        try state.refresh()
        let action = state.makePinAction()
        let context = ACTAActionContext(threadID: "fixture", isConfirmed: true)
        let parameters = ["chapter_id": id.uuidString, "pinned": "true"]
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        var wrote = false
        let subscription = state.objectWillChange.sink {
            if !wrote {
                wrote = true
                try? other.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "changed")
            }
        }
        let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertFalse(state.canToggle)
        XCTAssertThrowsError(try state.toggle(try XCTUnwrap(state.rows.first)))
        subscription.cancel()
        try state.refresh()
        XCTAssertFalse(state.canToggle)
        XCTAssertEqual(state.reconciliationChapterID, id)
        XCTAssertThrowsError(try state.reconcile(chapterID: UUID()))
        XCTAssertFalse(state.canToggle)
        try state.reconcile(chapterID: id)
        XCTAssertTrue(state.canToggle)
        XCTAssertNil(state.reconciliationChapterID)
        XCTAssertTrue(try XCTUnwrap(state.rows.first).chapter.pinned)
        XCTAssertEqual(state.rows.first?.chapter.operatorText, "changed")
    }
}
