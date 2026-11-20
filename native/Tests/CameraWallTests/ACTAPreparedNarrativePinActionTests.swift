import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class NarrativePinFake: ACTANarrativePinReviewDomain, ACTANarrativePinAtomicStore {
    var value: ACTANarrativePinObservation
    var writes = 0
    var beforeCompare: (() -> Void)?
    var afterCommit: (() -> Void)?
    var corrupt = false
    var fail = false
    struct Failure: Error {}

    init(marked: Bool = true) {
        value = .init(chapterID: UUID(), revision: .init(generation: UUID(), sequence: 0), pinned: false,
                      operatorMarked: marked, preservedFields: Data("PRIVATE-NARRATIVE".utf8))
    }

    func capture(chapterID: UUID) throws -> ACTANarrativePinObservation? {
        if fail { throw Failure() }
        return value.chapterID == chapterID ? value : nil
    }

    func commit(chapterID: UUID, expected: ACTANarrativePinObservation,
                pinned: Bool) throws -> ACTANarrativePinObservation? {
        beforeCompare?()
        if fail { throw Failure() }
        guard chapterID == value.chapterID, value == expected else { return nil }
        writes += 1
        value = .init(chapterID: value.chapterID,
                      revision: .init(generation: value.revision.generation, sequence: value.revision.sequence + 1), pinned: pinned,
                      operatorMarked: value.operatorMarked,
                      preservedFields: corrupt ? Data("changed".utf8) : value.preservedFields)
        let committed = value
        afterCommit?()
        return committed
    }

    func touch() {
        value = .init(chapterID: value.chapterID,
                      revision: .init(generation: value.revision.generation, sequence: value.revision.sequence + 1), pinned: value.pinned,
                      operatorMarked: value.operatorMarked, preservedFields: value.preservedFields)
    }
}

@MainActor
final class ACTAPreparedNarrativePinActionTests: XCTestCase {
    func testRealSQLiteDomainThroughBrokerAndStaleOtherWriter() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".narrative-cas-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.sqlite")
        let store = try LocalTrackingStore(url: url)
        let other = try LocalTrackingStore(url: url)
        let chapterID = UUID()
        try store.saveACTANarrativeChapter(id: chapterID, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: "PRIVATE"))
        try store.setACTANarrativeOperatorText(chapterID: chapterID.uuidString, operatorText: "reviewed")
        let atomic = try ACTANarrativePinProductionStore(trackingStore: store)
        var refreshCount = 0
        let domain = ACTANarrativePinCoordinatedDomain(store: atomic) {
            _ = try store.loadACTANarrativeChapterRecords(limit: 50)
            refreshCount += 1
        }
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "thread", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let arguments = #"{"chapter_id":"\#(chapterID.uuidString)","pinned":true}"#
        let first = await host.broker.request(session: session, actionID: action.id, argumentsJSON: arguments)
        XCTAssertTrue(first.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let staleReview = try XCTUnwrap(reviews.first)
        try other.setACTANarrativePinned(chapterID: chapterID.uuidString, pinned: true)
        try other.setACTANarrativePinned(chapterID: chapterID.uuidString, pinned: false)
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: staleReview, approved: true)
        XCTAssertFalse(stale.success)
        XCTAssertEqual(refreshCount, 0)
        let second = await host.broker.request(session: session, actionID: action.id, argumentsJSON: arguments)
        XCTAssertTrue(second.requiresOperatorConfirmation)
        let newReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(newReviews.first)
        XCTAssertFalse(review.title.contains("PRIVATE"))
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertFalse(result.outputJSON.contains("PRIVATE"))
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(try XCTUnwrap(other.loadACTANarrativeChapterRecord(chapterID: chapterID.uuidString)).pinned)
    }

    func testBrokerApprovalReadbackAndReplayDoNotExposeNarrative() async throws {
        let domain = NarrativePinFake()
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "thread", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let request = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"chapter_id":"\#(domain.value.chapterID.uuidString)","pinned":true}"#)
        XCTAssertTrue(request.requiresOperatorConfirmation)
        XCTAssertEqual(domain.writes, 0)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains(domain.value.chapterID.uuidString))
        XCTAssertTrue(review.title.contains("false -> true"))
        XCTAssertFalse(review.title.contains("PRIVATE-NARRATIVE"))
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertFalse(result.outputJSON.contains("PRIVATE-NARRATIVE"))
        XCTAssertTrue(domain.value.pinned)
        XCTAssertEqual(domain.value.preservedFields, Data("PRIVATE-NARRATIVE".utf8))
        let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(replay.success)
        XCTAssertEqual(domain.writes, 1)
    }

    func testStaleABAAndCommitInterleavingRejectWithoutWriting() async throws {
        for duringCommit in [false, true] {
            let domain = NarrativePinFake()
            let action = ACTAPreparedNarrativePinAction(domain: domain)
            let context = ACTAActionContext(threadID: "thread", isConfirmed: true)
            let parameters = ["chapter_id": domain.value.chapterID.uuidString, "pinned": "true"]
            let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
            if duringCommit { domain.beforeCompare = { domain.touch() } }
            else { domain.touch(); domain.touch() }
            let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
            XCTAssertTrue(result.error?.contains("STALE_REVIEW") == true)
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testUnmarkedPinMismatchAndOneShotTicket() async throws {
        let domain = NarrativePinFake(marked: false)
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let context = ACTAActionContext(threadID: "thread", isConfirmed: true)
        let params = ["chapter_id": domain.value.chapterID.uuidString, "pinned": "true"]
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Pinning would mark an unmarked chapter")
        } catch {}
        let unpin = ["chapter_id": domain.value.chapterID.uuidString, "pinned": "false"]
        let prepared = try await action.prepareConfirmation(parameters: unpin, context: context)
        let mismatch = try await action.executeConfirmed(parameters: unpin,
            context: ACTAActionContext(threadID: "thread"), snapshot: prepared.snapshot)
        XCTAssertTrue(mismatch.error?.contains("CONFIRMATION_MISMATCH") == true)
        let replay = try await action.executeConfirmed(parameters: unpin, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(replay.error?.contains("CONFIRMATION_CONSUMED") == true)
        XCTAssertEqual(domain.writes, 0)
        for invalid in [["chapter_id": "bad", "pinned": "true"],
                        ["chapter_id": domain.value.chapterID.uuidString, "pinned": "yes"],
                        ["chapter_id": domain.value.chapterID.uuidString, "pinned": "true", "extra": "x"]] {
            XCTAssertThrowsError(try action.validate(parameters: invalid))
        }
    }

    func testReadbackFailureAndSingleUseVerification() async throws {
        let domain = NarrativePinFake()
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let context = ACTAActionContext(threadID: "thread", isConfirmed: true)
        let params = ["chapter_id": domain.value.chapterID.uuidString, "pinned": "true"]
        var prepared = try await action.prepareConfirmation(parameters: params, context: context)
        domain.corrupt = true
        var result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(result.error?.contains("READBACK_FAILED") == true)
        domain.corrupt = false
        prepared = try await action.prepareConfirmation(parameters: params, context: context)
        result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(result.success)
        domain.touch()
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(verified)
        let replay = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replay)
    }

    func testRejectionAndStaleBrokerReview() async throws {
        let domain = NarrativePinFake()
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "thread", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        for approved in [false, true] {
            let request = await host.broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"chapter_id":"\#(domain.value.chapterID.uuidString)","pinned":true}"#)
            XCTAssertTrue(request.requiresOperatorConfirmation)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            if approved { domain.touch() }
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: review, approved: approved)
            XCTAssertFalse(result.success)
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testReadErrorsAreRedactedAndForeignTicketCannotCommit() async throws {
        let domain = NarrativePinFake()
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let other = ACTAPreparedNarrativePinAction(domain: domain)
        let context = ACTAActionContext(threadID: "thread", isConfirmed: true)
        let params = ["chapter_id": domain.value.chapterID.uuidString, "pinned": "true"]
        domain.fail = true
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Unreadable chapter must not be reviewed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("UNAVAILABLE"))
        }
        domain.fail = false
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        let foreign = try await other.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(foreign.error?.contains("CONFIRMATION_CONSUMED") == true)
        domain.fail = true
        let failure = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(failure.error?.contains("COMMIT_FAILED") == true)
        XCTAssertEqual(domain.writes, 0)
    }

    func testChangedImmediatelyAfterCommitFailsReadback() async throws {
        let domain = NarrativePinFake()
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let context = ACTAActionContext(threadID: "thread", isConfirmed: true)
        let params = ["chapter_id": domain.value.chapterID.uuidString, "pinned": "true"]
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        domain.afterCommit = { domain.touch() }
        let result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(result.error?.contains("READBACK_FAILED") == true)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(verified)
    }

    func testCoordinatedDomainRefreshesAndBlocksReentrantAccess() async throws {
        let store = NarrativePinFake()
        var domain: ACTANarrativePinCoordinatedDomain!
        var refreshCount = 0
        var nestedRejected = false
        domain = ACTANarrativePinCoordinatedDomain(store: store) {
            refreshCount += 1
            do { _ = try domain.capture(chapterID: store.value.chapterID) }
            catch { nestedRejected = true }
        }
        let action = ACTAPreparedNarrativePinAction(domain: domain)
        let context = ACTAActionContext(threadID: "thread", isConfirmed: true)
        let params = ["chapter_id": store.value.chapterID.uuidString, "pinned": "true"]
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        let result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(result.success)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(nestedRejected)
    }

    func testCoordinatedDomainFailsClosedUntilStableReconciliation() throws {
        let store = NarrativePinFake()
        var changeDuringRefresh = true
        let domain = ACTANarrativePinCoordinatedDomain(store: store) {
            if changeDuringRefresh { store.touch() }
        }
        let id = store.value.chapterID
        let before = try XCTUnwrap(domain.capture(chapterID: id))
        XCTAssertThrowsError(try domain.commit(chapterID: id, expected: before, pinned: true))
        XCTAssertThrowsError(try domain.capture(chapterID: id))
        XCTAssertThrowsError(try domain.reconcile(chapterID: id))
        XCTAssertThrowsError(try domain.capture(chapterID: id))
        changeDuringRefresh = false
        try domain.reconcile(chapterID: id)
        XCTAssertEqual(try domain.capture(chapterID: id), store.value)
    }

    func testCoordinatedDomainCommitFailureAndRefreshFailureRequireRepair() throws {
        let store = NarrativePinFake()
        var refreshFails = false
        let domain = ACTANarrativePinCoordinatedDomain(store: store) {
            if refreshFails { throw NarrativePinFake.Failure() }
        }
        let id = store.value.chapterID
        var before = try XCTUnwrap(domain.capture(chapterID: id))
        store.fail = true
        XCTAssertThrowsError(try domain.commit(chapterID: id, expected: before, pinned: true))
        store.fail = false
        XCTAssertThrowsError(try domain.capture(chapterID: id))
        try domain.reconcile(chapterID: id)
        before = try XCTUnwrap(domain.capture(chapterID: id))
        refreshFails = true
        XCTAssertThrowsError(try domain.commit(chapterID: id, expected: before, pinned: true))
        XCTAssertThrowsError(try domain.capture(chapterID: id))
        refreshFails = false
        try domain.reconcile(chapterID: id)
        XCTAssertTrue(try XCTUnwrap(domain.capture(chapterID: id)).pinned)
    }

    func testCoordinatedDomainRejectsIncorrectBackendResult() throws {
        let store = NarrativePinFake()
        var refreshCount = 0
        let domain = ACTANarrativePinCoordinatedDomain(store: store) { refreshCount += 1 }
        let id = store.value.chapterID
        let before = try XCTUnwrap(domain.capture(chapterID: id))
        store.corrupt = true
        XCTAssertThrowsError(try domain.commit(chapterID: id, expected: before, pinned: true))
        XCTAssertEqual(refreshCount, 0)
        XCTAssertThrowsError(try domain.capture(chapterID: id))
    }
}
