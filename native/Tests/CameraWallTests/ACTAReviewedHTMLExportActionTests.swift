import CameraCore
import Foundation
import XCTest
#if !ACTA_STANDALONE
@testable import CameraWall
#endif

private actor HTMLSelectionFake: ACTAReviewedHTMLSelectionProvider {
    var selection: ACTAReviewedHTMLSelection
    var requests = 0
    var cancelled = false
    init(_ selection: ACTAReviewedHTMLSelection) { self.selection = selection }
    func selectAndReview() async throws -> ACTAReviewedHTMLSelection {
        requests += 1
        if cancelled { throw CancellationError() }
        return selection
    }
    func replace(_ selection: ACTAReviewedHTMLSelection) { self.selection = selection }
    func cancel() { cancelled = true }
}

private actor HTMLPublisherFake: ACTAReviewedHTMLPublication {
    var stored: ACTAReviewedHTMLSelection?
    var authorized = true
    var exists = false
    var verificationOK = true
    var writes = 0
    func publish(_ selection: ACTAReviewedHTMLSelection, threadID: String) async throws {
        guard authorized, !exists else { throw Failure() }
        stored = selection
        writes += 1
    }
    func verify(_ selection: ACTAReviewedHTMLSelection, threadID: String) async throws -> Bool {
        verificationOK && stored?.bytes == selection.bytes && stored?.destination == selection.destination
    }
    func configure(authorized: Bool = true, exists: Bool = false, verificationOK: Bool = true) {
        self.authorized = authorized
        self.exists = exists
        self.verificationOK = verificationOK
    }
    struct Failure: Error {}
}

private final class HTMLClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

final class ACTAReviewedHTMLExportActionTests: XCTestCase {
    private func selection(_ text: String = "<html>private report</html>",
                           path: String = "/operator/report.html") -> ACTAReviewedHTMLSelection {
        .init(kind: "mission", bytes: Data(text.utf8), destination: URL(fileURLWithPath: path))
    }

    func testBrokerReviewFrozenContentAndReplay() async throws {
        let original = selection()
        let selector = HTMLSelectionFake(original)
        let publisher = HTMLPublisherFake()
        let action = ACTAReviewedHTMLExportAction(selector: selector, publisher: publisher)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: "report", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let injected = await host.broker.request(session: session, actionID: action.id,
                                                  argumentsJSON: #"{"destination":"/model.html"}"#)
        XCTAssertFalse(injected.success)
        let requests = await selector.requests
        XCTAssertEqual(requests, 0)
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertFalse(pending.summary.contains(original.destination.path))
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains(original.destination.path))
        XCTAssertTrue(review.title.contains("sha256="))
        XCTAssertFalse(review.title.contains("private report"))
        await selector.replace(selection("changed", path: "/other/report.html"))
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        let stored = await publisher.stored
        XCTAssertEqual(stored?.bytes, original.bytes)
        XCTAssertEqual(stored?.destination, original.destination)
        let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(replay.success)
        let writes = await publisher.writes
        XCTAssertEqual(writes, 1)
    }

    func testRejectCancelCollisionAndRevokedAuthorizationDoNotWrite() async throws {
        for scenario in 0..<4 {
            let selector = HTMLSelectionFake(selection())
            let publisher = HTMLPublisherFake()
            let action = ACTAReviewedHTMLExportAction(selector: selector, publisher: publisher)
            let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
            let host = try XCTUnwrap(made)
            let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .voice,
                                                        threadID: "report", actionIDs: [action.id])
            let session = try XCTUnwrap(opened)
            if scenario == 0 { await selector.cancel() }
            let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            if scenario == 0 {
                XCTAssertFalse(pending.requiresOperatorConfirmation)
            } else {
                XCTAssertTrue(pending.requiresOperatorConfirmation)
                let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
                let review = try XCTUnwrap(reviews.first)
                if scenario == 2 { await publisher.configure(exists: true) }
                if scenario == 3 { await publisher.configure(authorized: false) }
                let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                       reviewed: review, approved: scenario != 1)
                XCTAssertFalse(result.success)
            }
            let writes = await publisher.writes
            XCTAssertEqual(writes, 0)
        }
    }

    func testWrongThreadExpiredAndVerificationFailure() async throws {
        let selector = HTMLSelectionFake(selection())
        let publisher = HTMLPublisherFake()
        let action = ACTAReviewedHTMLExportAction(selector: selector, publisher: publisher, now: { 100 })
        let context = ACTAActionContext(threadID: "report")
        let confirmed = ACTAActionContext(threadID: "report", isConfirmed: true)
        let prepared = try await action.prepareConfirmation(parameters: [:], context: context)
        let wrong = try await action.executeConfirmed(parameters: [:],
            context: ACTAActionContext(threadID: "other", isConfirmed: true), snapshot: prepared.snapshot)
        XCTAssertFalse(wrong.success)
        let replay = try await action.executeConfirmed(parameters: [:], context: confirmed, snapshot: prepared.snapshot)
        XCTAssertFalse(replay.success)

        let clock = HTMLClock()
        let expiredAction = ACTAReviewedHTMLExportAction(selector: selector, publisher: publisher, now: { clock.now() })
        let expired = try await expiredAction.prepareConfirmation(parameters: [:], context: context)
        clock.set(401)
        let expiredResult = try await expiredAction.executeConfirmed(parameters: [:], context: confirmed, snapshot: expired.snapshot)
        XCTAssertTrue(expiredResult.error?.contains("REVIEW_EXPIRED") == true)
        let laterAction = ACTAReviewedHTMLExportAction(selector: selector, publisher: publisher, now: { 401 })
        let foreign = try await laterAction.executeConfirmed(parameters: [:], context: confirmed, snapshot: expired.snapshot)
        XCTAssertFalse(foreign.success)

        await publisher.configure(verificationOK: false)
        let next = try await action.prepareConfirmation(parameters: [:], context: context)
        let failed = try await action.executeConfirmed(parameters: [:], context: confirmed, snapshot: next.snapshot)
        XCTAssertFalse(failed.success)
        XCTAssertFalse(failed.verified)
        XCTAssertTrue(failed.error?.contains("VERIFICATION_FAILED") == true)
    }

    func testClosedBrokerSessionCannotApprovePendingReview() async throws {
        let selector = HTMLSelectionFake(selection())
        let publisher = HTMLPublisherFake()
        let action = ACTAReviewedHTMLExportAction(selector: selector, publisher: publisher)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: "report", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(result.success)
        let writes = await publisher.writes
        XCTAssertEqual(writes, 0)
    }

    func testPreviewEscapesHiddenCharacters() {
        XCTAssertEqual(ACTAReviewedHTMLExportUI.escaped("a\\\n\u{202E}é"),
                       "a\\\\\\u{A}\n\\u{202E}\\u{E9}")
    }
}
