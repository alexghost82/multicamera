import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class CameraFlagsFake: ACTACameraFlagsReviewDomain {
    var current: ACTACameraFlagsObservation?
    var writes = 0
    var safe = true
    var beforeCompare: (() -> Void)?
    var afterCommit: (() -> Void)?
    var failure: FailurePoint?
    var corrupt = false
    enum FailurePoint { case capture, commit }
    struct Failure: LocalizedError {
        var errorDescription: String? { "PRIVATE-STREAM-SECRET" }
    }

    init(_ id: UUID) {
        current = .init(revision: UUID(), cameraID: id, enabled: false, yolo: false, aiChat: false)
    }

    func capture(cameraID: UUID) throws -> ACTACameraFlagsObservation? {
        if failure == .capture { throw Failure() }
        return current?.cameraID == cameraID ? current : nil
    }

    func commit(expected: ACTACameraFlagsObservation, field: ACTACameraFlag,
                value: Bool) throws -> ACTACameraFlagsObservation? {
        beforeCompare?()
        if failure == .commit { throw Failure() }
        guard safe, current == expected else { return nil }
        writes += 1
        let next = expected.replacing(field, value: value, revision: UUID())
        current = corrupt ? next.replacing(.aiChat, value: !next.aiChat, revision: next.revision) : next
        let result = current
        afterCommit?()
        return result
    }

    func changeRevision() {
        guard let current else { return }
        self.current = current.replacing(.enabled, value: current.enabled, revision: UUID())
    }
}

@MainActor
final class ACTAPreparedCameraFlagsActionTests: XCTestCase {
    func testBrokerReviewConfirmationAndReplayForBothActions() async throws {
        for kind in [ACTAPreparedCameraFlagsAction.Kind.enabled, .processing] {
            let camera = UUID(), domain = CameraFlagsFake(camera)
            let action = ACTAPreparedCameraFlagsAction(kind: kind, domain: domain)
            let made = await ACTALocalActionBroker.make(
                actions: [action], allowedActionIDs: [action.id], audit: { _ in })
            let host = try XCTUnwrap(made)
            let opened = await host.broker.openSession(operatorKey: host.operatorKey,
                input: .chat, threadID: "test", actionIDs: [action.id])
            let session = try XCTUnwrap(opened)
            let args = kind == .enabled
                ? #"{"camera_id":"\#(camera.uuidString)","enabled":true}"#
                : #"{"camera_id":"\#(camera.uuidString)","enabled":true,"feature":"yolo"}"#
            let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: args)
            XCTAssertTrue(pending.requiresOperatorConfirmation)
            XCTAssertEqual(domain.writes, 0)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            XCTAssertTrue(review.title.contains(camera.uuidString))
            XCTAssertTrue(review.title.contains("false -> true"))
            XCTAssertTrue(review.title.contains("later service start"))
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                    reviewed: review, approved: true)
            XCTAssertTrue(result.success && result.verified, result.summary)
            XCTAssertEqual(domain.writes, 1)
            XCTAssertEqual(domain.current?.value(kind == .enabled ? .enabled : .yolo), true)
            let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                    reviewed: review, approved: true)
            XCTAssertFalse(replay.success)
            XCTAssertEqual(domain.writes, 1)
        }
    }

    func testStaleABAInterleavingUnsafeAndMissingNeverWrite() async throws {
        for scenario in 0..<5 {
            let camera = UUID(), domain = CameraFlagsFake(camera)
            let action = ACTAPreparedCameraFlagsAction(kind: .enabled, domain: domain)
            let params = ["camera_id": camera.uuidString, "enabled": "true"]
            let context = ACTAActionContext(threadID: "test")
            let review = try await action.prepareConfirmation(parameters: params, context: context)
            switch scenario {
            case 0: domain.changeRevision()
            case 1: domain.changeRevision(); domain.changeRevision()
            case 2: domain.beforeCompare = { domain.changeRevision() }
            case 3: domain.safe = false
            default: domain.current = nil
            }
            let result = try await action.executeConfirmed(parameters: params, context: context, snapshot: review.snapshot)
            XCTAssertFalse(result.success)
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testTicketBindingAndStrictInputs() async throws {
        let camera = UUID(), domain = CameraFlagsFake(camera)
        let action = ACTAPreparedCameraFlagsAction(kind: .processing, domain: domain)
        let other = ACTAPreparedCameraFlagsAction(kind: .processing, domain: domain)
        let context = ACTAActionContext(threadID: "test")
        let params = ["camera_id": camera.uuidString, "enabled": "true", "feature": "ai_chat"]
        for invalid in [
            ["camera_id": "rtsp://secret", "enabled": "true", "feature": "ai_chat"],
            ["camera_id": camera.uuidString, "enabled": "1", "feature": "ai_chat"],
            ["camera_id": camera.uuidString, "enabled": "true", "feature": "enabled"],
            params.merging(["extra": "secret"]) { _, new in new }
        ] { XCTAssertThrowsError(try action.validate(parameters: invalid)) }
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        let wrongOwner = try await other.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(wrongOwner.success)
        let wrongThread = try await action.executeConfirmed(parameters: params,
            context: ACTAActionContext(threadID: "other"), snapshot: prepared.snapshot)
        XCTAssertFalse(wrongThread.success)
        let retry = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(retry.success)
        let direct = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(direct.success)
        XCTAssertEqual(domain.writes, 0)
    }

    func testFailuresReadbackAndVerifyDoNotLeakOrClaimSuccess() async throws {
        let camera = UUID(), domain = CameraFlagsFake(camera)
        let action = ACTAPreparedCameraFlagsAction(kind: .enabled, domain: domain)
        let params = ["camera_id": camera.uuidString, "enabled": "true"]
        let context = ACTAActionContext(threadID: "test")
        domain.failure = .capture
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("capture must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE-STREAM-SECRET")) }
        domain.failure = nil
        let review = try await action.prepareConfirmation(parameters: params, context: context)
        domain.failure = .commit
        let failed = try await action.executeConfirmed(parameters: params, context: context, snapshot: review.snapshot)
        XCTAssertFalse(failed.success)
        XCTAssertFalse(failed.summary.contains("PRIVATE-STREAM-SECRET"))
        domain.failure = nil
        let corruptReview = try await action.prepareConfirmation(parameters: params, context: context)
        domain.corrupt = true
        let corrupt = try await action.executeConfirmed(parameters: params, context: context, snapshot: corruptReview.snapshot)
        XCTAssertFalse(corrupt.success)
        domain.corrupt = false
        let changedReview = try await action.prepareConfirmation(parameters: params, context: context)
        domain.afterCommit = { domain.changeRevision() }
        let changed = try await action.executeConfirmed(parameters: params, context: context, snapshot: changedReview.snapshot)
        XCTAssertFalse(changed.success)
        domain.afterCommit = nil
        let validReview = try await action.prepareConfirmation(parameters: params, context: context)
        let valid = try await action.executeConfirmed(parameters: params, context: context, snapshot: validReview.snapshot)
        XCTAssertTrue(valid.success)
        domain.changeRevision()
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(verified)
        let replay = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replay)
    }

    func testRejectAndBusyDoNotWrite() async throws {
        let camera = UUID(), domain = CameraFlagsFake(camera)
        let action = ACTAPreparedCameraFlagsAction(kind: .enabled, domain: domain)
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let pending = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"camera_id":"\#(camera.uuidString)","enabled":true}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                  reviewed: try XCTUnwrap(reviews.first), approved: false)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(domain.writes, 0)
        let params = ["camera_id": camera.uuidString, "enabled": "true"]
        let context = ACTAActionContext(threadID: "test")
        let one = try await action.prepareConfirmation(parameters: params, context: context)
        let first = try await action.executeConfirmed(parameters: params, context: context, snapshot: one.snapshot)
        XCTAssertTrue(first.success)
        let two = try await action.prepareConfirmation(parameters: params, context: context)
        let busy = try await action.executeConfirmed(parameters: params, context: context, snapshot: two.snapshot)
        XCTAssertFalse(busy.success)
        XCTAssertEqual(domain.writes, 1)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
    }

    func testAuditFailureAndRevocationPreventExecution() async throws {
        struct AuditFailure: Error {}
        let camera = UUID(), domain = CameraFlagsFake(camera)
        let action = ACTAPreparedCameraFlagsAction(kind: .enabled, domain: domain)
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in throw AuditFailure() })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let args = #"{"camera_id":"\#(camera.uuidString)","enabled":true}"#
        let failed = await host.broker.request(session: session, actionID: action.id, argumentsJSON: args)
        XCTAssertFalse(failed.success)
        XCTAssertFalse(failed.requiresOperatorConfirmation)
        let validMade = await ACTALocalActionBroker.make(actions: [action],
            allowedActionIDs: [action.id], audit: { _ in })
        let validHost = try XCTUnwrap(validMade)
        let validOpened = await validHost.broker.openSession(operatorKey: validHost.operatorKey,
            input: .chat, threadID: "test", actionIDs: [action.id])
        let validSession = try XCTUnwrap(validOpened)
        let pending = await validHost.broker.request(session: validSession, actionID: action.id, argumentsJSON: args)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await validHost.broker.reviews(operatorKey: validHost.operatorKey, session: validSession)
        let review = try XCTUnwrap(reviews.first)
        await validHost.broker.closeSession(validSession, operatorKey: validHost.operatorKey)
        let revoked = await validHost.broker.resolve(operatorKey: validHost.operatorKey, session: validSession,
                                                       reviewed: review, approved: true)
        XCTAssertFalse(revoked.success)
        XCTAssertEqual(domain.writes, 0)
    }
}
