import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

private actor ReviewAuthorizationProbe {
    private(set) var initiators: [String] = []
    func record(_ initiator: String) { initiators.append(initiator) }
}

private struct ReviewAuthorizationAction: ACTAActionProtocol {
    let id = "test.local_review"
    let title = "Synthetic action"
    let description = "Synthetic review"
    let classification = ACTAActionClassification.reversible
    let parameters = [ACTAActionParameterSchema(name: "value", type: "string", description: "Value", isRequired: true)]
    let probe: ReviewAuthorizationProbe
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await probe.record(context.initiator)
        return ACTAActionResult(actionID: id, success: true, summary: "done")
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

@MainActor
final class ACTABrokerReviewAuthorizationTests: XCTestCase {
    private final class VoiceCapture: LocalVoiceCapture {
        let callback: @MainActor (LocalVoiceEvent) -> Void
        init(_ callback: @escaping @MainActor (LocalVoiceEvent) -> Void) { self.callback = callback }
        func finish() {}
        func cancel() {}
    }

    func testCancelledOrSynchronouslyRevokedFinalTranscriptCannotApprove() async throws {
        let probe = ReviewAuthorizationProbe()
        let action = ReviewAuthorizationAction(probe: probe)
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(created)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .voice, threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        _ = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"value":"sample"}"#)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let controller = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
            session: session, review: try XCTUnwrap(reviews.first))
        controller.reviewedAll = true
        var capture: VoiceCapture?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { _, callback in
            let source = VoiceCapture(callback)
            capture = source
            return source
        })

        let first = controller.makeVoiceChallenge(localeIdentifier: "en-US", voiceInput: voice)
        let firstTask = try XCTUnwrap(voice.start(localeIdentifier: "en-US", owner: first.owner))
        await firstTask.value
        voice.finishAndWaitForFinal(owner: first.owner)
        try XCTUnwrap(capture).callback(.transcript("\(first.phrase) \(first.code)", isFinal: true))
        let cancelled = try XCTUnwrap(voice.finalTranscript)
        voice.cancel(owner: first.owner)
        let cancelledResult = await controller.resolveVoice(cancelled, challenge: first, voiceInput: voice)
        XCTAssertNil(cancelledResult)

        let second = controller.makeVoiceChallenge(localeIdentifier: "en-US", voiceInput: voice)
        let secondTask = try XCTUnwrap(voice.start(localeIdentifier: "en-US", owner: second.owner))
        await secondTask.value
        voice.finishAndWaitForFinal(owner: second.owner)
        try XCTUnwrap(capture).callback(.transcript("\(second.phrase) \(second.code)", isFinal: true))
        let final = try XCTUnwrap(voice.finalTranscript)
        let subscription = controller.$resolving.dropFirst().sink { resolving in
            if resolving { voice.cancel(owner: second.owner) }
        }
        let revoked = await controller.resolveVoice(final, challenge: second, voiceInput: voice)
        XCTAssertNil(revoked)
        XCTAssertNil(voice.finalTranscript)
        let initiators = await probe.initiators
        XCTAssertTrue(initiators.isEmpty)
        withExtendedLifetime(subscription) {}
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testVoiceConfirmationStillRequiresCurrentReviewedAuthorizedAction() async throws {
        let probe = ReviewAuthorizationProbe()
        let action = ReviewAuthorizationAction(probe: probe)
        let created = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(created)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .voice,
                                                    threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        _ = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"value":"sample"}"#)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        var current = true
        let controller = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
            session: session, review: try XCTUnwrap(reviews.first), isCurrent: { current })
        var capture: VoiceCapture?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { _, callback in
            let result = VoiceCapture(callback)
            capture = result
            return result
        })
        let challenge = controller.makeVoiceChallenge(localeIdentifier: "en-US", voiceInput: voice)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en-US", owner: challenge.owner))
        await task.value
        voice.finishAndWaitForFinal(owner: challenge.owner)
        try XCTUnwrap(capture).callback(.transcript("\(challenge.phrase) \(challenge.code)", isFinal: true))
        let transcript = try XCTUnwrap(voice.finalTranscript)
        let unreviewed = await controller.resolveVoice(transcript, challenge: challenge, voiceInput: voice)
        XCTAssertNil(unreviewed)
        controller.reviewedAll = true
        current = false
        let stale = await controller.resolveVoice(transcript, challenge: challenge, voiceInput: voice)
        XCTAssertNil(stale)
        current = true
        _ = voice.setInputAllowed(false)
        let revoked = await controller.resolveVoice(transcript, challenge: challenge, voiceInput: voice)
        XCTAssertNil(revoked)
        _ = voice.setInputAllowed(true)
        let afterReenable = await controller.resolveVoice(transcript, challenge: challenge, voiceInput: voice)
        XCTAssertNil(afterReenable)
        let next = controller.makeVoiceChallenge(localeIdentifier: "en-US", voiceInput: voice)
        let nextTask = try XCTUnwrap(voice.start(localeIdentifier: "en-US", owner: next.owner))
        await nextTask.value
        voice.finishAndWaitForFinal(owner: next.owner)
        try XCTUnwrap(capture).callback(.transcript("\(next.phrase) \(next.code)", isFinal: true))
        let nextTranscript = try XCTUnwrap(voice.finalTranscript)
        let approved = await controller.resolveVoice(nextTranscript, challenge: next, voiceInput: voice)
        XCTAssertEqual(approved?.success, true)
        XCTAssertEqual(approved?.verified, true)
        let initiators = await probe.initiators
        XCTAssertEqual(initiators, ["voice_asr"])
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testVoiceConfirmationIsBoundToOneReviewAndConsumedOnce() async throws {
        let probe = ReviewAuthorizationProbe()
        let action = ReviewAuthorizationAction(probe: probe)
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(created)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .voice, threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        _ = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"value":"first"}"#)
        _ = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"value":"second"}"#)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertEqual(reviews.count, 2)
        guard reviews.count == 2 else { return }
        let first = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
                                               session: session, review: reviews[0])
        let second = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
                                                session: session, review: reviews[1])
        first.reviewedAll = true
        second.reviewedAll = true
        var capture: VoiceCapture?
        let voice = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
                                    makeCapture: { _, callback in
            let source = VoiceCapture(callback)
            capture = source
            return source
        })
        let challenge = first.makeVoiceChallenge(localeIdentifier: "en-US", voiceInput: voice)
        let task = try XCTUnwrap(voice.start(localeIdentifier: "en-US", owner: challenge.owner))
        await task.value
        voice.finishAndWaitForFinal(owner: challenge.owner)
        try XCTUnwrap(capture).callback(.transcript("\(challenge.phrase) \(challenge.code)", isFinal: true))
        let final = try XCTUnwrap(voice.finalTranscript)
        let wrongReview = await second.resolveVoice(final, challenge: challenge, voiceInput: voice)
        XCTAssertNil(wrongReview)
        let result = await first.resolveVoice(final, challenge: challenge, voiceInput: voice)
        XCTAssertEqual(result?.success, true)
        let replay = await first.resolveVoice(final, challenge: challenge, voiceInput: voice)
        XCTAssertNil(replay)
        let initiators = await probe.initiators
        XCTAssertEqual(initiators, ["voice_asr"])
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testTextAndVoiceReviewAuthorizationAndAuditFailure() async throws {
        for (input, initiator) in [(ACTABrokerLocalInput.chat, "text_chat"), (.voice, "voice_asr")] {
            let probe = ReviewAuthorizationProbe()
            let action = ReviewAuthorizationAction(probe: probe)
            let created = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id]) {
                if case .review = $0.phase { throw CocoaError(.fileWriteUnknown) }
            }
            let host = try XCTUnwrap(created)
            let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: input,
                                                       threadID: "fixture", actionIDs: [action.id])
            let session = try XCTUnwrap(opened)
            let otherOpened = await host.broker.openSession(operatorKey: host.operatorKey, input: input,
                                                            threadID: "fixture", actionIDs: [action.id])
            let other = try XCTUnwrap(otherOpened)
            let request = await host.broker.request(session: session, actionID: action.id,
                                                     argumentsJSON: #"{"value":"sample\ntext"}"#)
            XCTAssertTrue(request.requiresOperatorConfirmation)
            XCTAssertNil(request.confirmationToken)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            XCTAssertEqual(ACTABrokerReviewRendering.parameters(review).first?.1, #""sample\u{A}text""#)
            let wrong = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
                                                   session: other, review: review)
            wrong.reviewedAll = true
            let wrongResult = await wrong.resolve(true)
            XCTAssertEqual(wrongResult?.success, false)
            let controller = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
                                                        session: session, review: review)
            let premature = await controller.resolve(true)
            XCTAssertNil(premature)
            let staleController = ACTABrokerReviewController(broker: host.broker, operatorKey: host.operatorKey,
                session: session, review: review, isCurrent: { false })
            staleController.reviewedAll = true
            let stale = await staleController.resolve(true)
            XCTAssertNil(stale)
            controller.reviewedAll = true
            let failedAudit = await controller.resolve(true)
            XCTAssertTrue(failedAudit?.error?.hasPrefix("AUDIT_FAILED:") == true)
            let afterAudit = await probe.initiators
            XCTAssertTrue(afterAudit.isEmpty)
            XCTAssertTrue(session.invalidate(operatorKey: host.operatorKey))
            let revoked = await controller.resolve(true)
            XCTAssertEqual(revoked?.success, false)
            let afterRevocation = await probe.initiators
            XCTAssertTrue(afterRevocation.isEmpty)
            await host.broker.closeSession(session, operatorKey: host.operatorKey)
            await host.broker.closeSession(other, operatorKey: host.operatorKey)

            let clean = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
            let allowed = try XCTUnwrap(clean)
            let allowedOpened = await allowed.broker.openSession(operatorKey: allowed.operatorKey, input: input,
                                                                  threadID: "fixture", actionIDs: [action.id])
            let allowedSession = try XCTUnwrap(allowedOpened)
            _ = await allowed.broker.request(session: allowedSession, actionID: action.id,
                                             argumentsJSON: #"{"value":"reject"}"#)
            let rejectReviews = await allowed.broker.reviews(operatorKey: allowed.operatorKey, session: allowedSession)
            let rejectedController = ACTABrokerReviewController(broker: allowed.broker, operatorKey: allowed.operatorKey,
                session: allowedSession, review: try XCTUnwrap(rejectReviews.first))
            let rejected = await rejectedController.resolve(false)
            XCTAssertEqual(rejected?.success, false)
            let afterRejection = await probe.initiators
            XCTAssertTrue(afterRejection.isEmpty)
            _ = await allowed.broker.request(session: allowedSession, actionID: action.id,
                                             argumentsJSON: #"{"value":"approve"}"#)
            let approveReviews = await allowed.broker.reviews(operatorKey: allowed.operatorKey, session: allowedSession)
            let approvedController = ACTABrokerReviewController(broker: allowed.broker, operatorKey: allowed.operatorKey,
                session: allowedSession, review: try XCTUnwrap(approveReviews.first))
            approvedController.reviewedAll = true
            let approved = await approvedController.resolve(true)
            XCTAssertEqual(approved?.success, true)
            XCTAssertEqual(approved?.verified, true)
            let initiators = await probe.initiators
            XCTAssertEqual(initiators, [initiator])
            await allowed.broker.closeSession(allowedSession, operatorKey: allowed.operatorKey)
        }
    }
}
