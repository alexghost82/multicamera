import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor BrokerReviewCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct BrokerReviewProbeAction: ACTAActionProtocol {
    let id = "test.review"
    let title = "Review"
    let description = "Fake review action"
    let classification = ACTAActionClassification.reversible
    let parameters = [ACTAActionParameterSchema(name: "value", type: "string", description: "Value", isRequired: true)]
    let counter: BrokerReviewCounter
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await counter.increment()
        return ACTAActionResult(actionID: id, success: true, summary: "done")
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

@MainActor
final class ACTABrokerReviewViewTests: XCTestCase {
    func testExactRenderingEscapesInvisibleAndDirectionalCharacters() {
        let value = "A\n\"\u{202e}Ж\\"
        XCTAssertEqual(ACTABrokerReviewRendering.exact(value), #""A\u{A}\"\u{202E}\u{416}\\""#)
        XCTAssertNotEqual(ACTABrokerReviewRendering.exact("é"),
                          ACTABrokerReviewRendering.exact("e\u{301}"))
    }

    func testControllerRequiresAcknowledgementAndResolvesOnce() async throws {
        let counter = BrokerReviewCounter()
        let action = BrokerReviewProbeAction(counter: counter)
        let creation = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let created = try XCTUnwrap(creation)
        let issued = await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
                                                       threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        let request = await created.broker.request(session: session, actionID: action.id,
                                                   argumentsJSON: #"{"value":"full\u000atext"}"#)
        XCTAssertTrue(request.requiresOperatorConfirmation)
        XCTAssertNil(request.confirmationToken)
        let reviews = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let fields = ACTABrokerReviewRendering.parameters(review)
        XCTAssertEqual(fields.first?.0, #""value""#)
        XCTAssertEqual(fields.first?.1, #""full\u{A}text""#)
        let controller = ACTABrokerReviewController(broker: created.broker, operatorKey: created.operatorKey,
                                                    session: session, review: review)
        let premature = await controller.resolve(true)
        XCTAssertNil(premature)
        let before = await counter.count
        XCTAssertEqual(before, 0)
        controller.reviewedAll = true
        let approved = await controller.resolve(true)
        XCTAssertEqual(approved?.success, true)
        let replay = await controller.resolve(true)
        XCTAssertEqual(replay?.success, false)
        let after = await counter.count
        XCTAssertEqual(after, 1)

        _ = await created.broker.request(session: session, actionID: action.id,
                                         argumentsJSON: #"{"value":"reject"}"#)
        let pending = await created.broker.reviews(operatorKey: created.operatorKey, session: session)
        let rejectedController = ACTABrokerReviewController(broker: created.broker, operatorKey: created.operatorKey,
                                                            session: session, review: try XCTUnwrap(pending.first))
        let rejected = await rejectedController.resolve(false)
        XCTAssertEqual(rejected?.success, false)
        let finalCount = await counter.count
        XCTAssertEqual(finalCount, 1)
    }
}
