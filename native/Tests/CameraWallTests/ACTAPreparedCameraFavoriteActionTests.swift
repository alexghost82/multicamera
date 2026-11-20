import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class FavoriteReviewFake: ACTAFavoriteReviewDomain {
    var revision = UUID()
    var preference: String?
    var cameras: [(UUID, String)]
    var writes = 0
    var beforeCompare: (() -> Void)?
    var afterWrite: (() -> Void)?
    var failCapture = false
    var failCommit = false
    var failAfterWrite = false
    struct Failure: Error {}

    init(_ cameras: [(UUID, String)], preference: String? = nil) {
        self.cameras = cameras
        self.preference = preference
    }

    func changed() { revision = UUID() }

    func capture(request: String) throws -> ACTAFavoriteObservation? {
        if failCapture { throw Failure() }
        let matches: [(UUID, String)]
        if let id = UUID(uuidString: request) {
            matches = cameras.filter { $0.0 == id }
        } else {
            matches = cameras.filter { $0.1.caseInsensitiveCompare(request) == .orderedSame }
        }
        guard matches.count == 1, cameras.filter({ $0.0 == matches[0].0 }).count == 1 else { return nil }
        return ACTAFavoriteObservation(revision: revision, cameraID: matches[0].0, preference: preference)
    }

    func commit(request: String, expected: ACTAFavoriteObservation,
                replacement: String?) throws -> ACTAFavoriteObservation? {
        beforeCompare?()
        if failCommit { throw Failure() }
        guard try capture(request: request) == expected else { return nil }
        preference = replacement
        writes += 1
        changed()
        if failAfterWrite { throw Failure() }
        let committed = try capture(request: request)
        afterWrite?()
        return committed
    }
}

@MainActor
final class ACTAPreparedCameraFavoriteActionTests: XCTestCase {
    func testBrokerReviewsCompletePreferenceAndConfirmsUniqueCamera() async throws {
        let camera = UUID(), other = UUID()
        let domain = FavoriteReviewFake([(camera, "Entrance"), (other, "Other")],
                                        preference: ACTACameraFavorites.encode([other]))
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let broker = try XCTUnwrap(created)
        let opened = await broker.broker.openSession(operatorKey: broker.operatorKey, input: .chat,
            threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let pending = await broker.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"camera_id":"Entrance","favorite":true}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertEqual(domain.writes, 0)
        let reviews = await broker.broker.reviews(operatorKey: broker.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains(camera.uuidString))
        XCTAssertTrue(review.title.contains(ACTACameraFavorites.encode([other])))
        XCTAssertTrue(review.title.contains(ACTACameraFavorites.encode([camera, other])))
        let result = await broker.broker.resolve(operatorKey: broker.operatorKey, session: session,
                                                 reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertEqual(domain.preference, ACTACameraFavorites.encode([camera, other]))
        XCTAssertEqual(domain.writes, 1)
        let replay = await broker.broker.resolve(operatorKey: broker.operatorKey, session: session,
                                                 reviewed: review, approved: true)
        XCTAssertFalse(replay.success)
    }

    func testStalePreferencesIdentityABAAndInterleavingFailClosed() async throws {
        let camera = UUID(), other = UUID()
        let params = ["camera_id": "Entrance", "favorite": "true"]
        let context = ACTAActionContext()
        for scenario in 0..<5 {
            let domain = FavoriteReviewFake([(camera, "Entrance")])
            let action = ACTAPreparedCameraFavoriteAction(domain: domain)
            let prepared = try await action.prepareConfirmation(parameters: params, context: context)
            switch scenario {
            case 0: domain.preference = ACTACameraFavorites.encode([other]); domain.changed()
            case 1: domain.cameras = [(other, "Entrance")]; domain.changed()
            case 2: domain.cameras.append((other, "Entrance")); domain.changed()
            case 3: domain.preference = "changed"; domain.changed(); domain.preference = nil; domain.changed()
            default:
                domain.beforeCompare = { domain.preference = ACTACameraFavorites.encode([other]); domain.changed() }
            }
            let result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
            XCTAssertFalse(result.success, "scenario \(scenario)")
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testBrokerRejectsStaleAndRejectedReviews() async throws {
        let camera = UUID(), other = UUID()
        let domain = FavoriteReviewFake([(camera, "Entrance")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let broker = try XCTUnwrap(created)
        let opened = await broker.broker.openSession(operatorKey: broker.operatorKey, input: .chat,
            threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        for approved in [true, false] {
            let pending = await broker.broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"camera_id":"Entrance","favorite":true}"#)
            XCTAssertTrue(pending.requiresOperatorConfirmation)
            let reviews = await broker.broker.reviews(operatorKey: broker.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            if approved { domain.preference = ACTACameraFavorites.encode([other]); domain.changed() }
            let result = await broker.broker.resolve(operatorKey: broker.operatorKey, session: session,
                                                      reviewed: review, approved: approved)
            XCTAssertFalse(result.success)
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testConcurrentBrokerApprovalsOfSameObservationNeverLoseAnotherFavorite() async throws {
        let first = UUID(), second = UUID()
        let domain = FavoriteReviewFake([(first, "First"), (second, "Second")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(created)
        let firstOpened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "first", actionIDs: [action.id])
        let secondOpened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "second", actionIDs: [action.id])
        let firstSession = try XCTUnwrap(firstOpened)
        let secondSession = try XCTUnwrap(secondOpened)
        for (session, name) in [(firstSession, "First"), (secondSession, "Second")] {
            let pending = await host.broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"camera_id":"\#(name)","favorite":true}"#)
            XCTAssertTrue(pending.requiresOperatorConfirmation)
        }
        let firstReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: firstSession)
        let secondReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: secondSession)
        let firstReview = try XCTUnwrap(firstReviews.first)
        let secondReview = try XCTUnwrap(secondReviews.first)
        async let firstResult = host.broker.resolve(operatorKey: host.operatorKey, session: firstSession,
                                                     reviewed: firstReview, approved: true)
        async let secondResult = host.broker.resolve(operatorKey: host.operatorKey, session: secondSession,
                                                      reviewed: secondReview, approved: true)
        let results = await [firstResult, secondResult]
        XCTAssertEqual(results.filter(\.success).count, 1)
        XCTAssertEqual(domain.writes, 1)
        XCTAssertTrue([ACTACameraFavorites.encode([first]), ACTACameraFavorites.encode([second])]
            .contains(domain.preference ?? ""))
        await host.broker.closeSession(firstSession, operatorKey: host.operatorKey)
        await host.broker.closeSession(secondSession, operatorKey: host.operatorKey)
    }

    func testMismatchMalformedInputAndMissingOrAmbiguousCameraNeverWrite() async throws {
        let camera = UUID(), other = UUID()
        let domain = FavoriteReviewFake([(camera, "Entrance")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let context = ACTAActionContext()
        let params = ["camera_id": "Entrance", "favorite": "true"]
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        let mismatch = try await action.executeConfirmed(parameters: ["camera_id": "Entrance", "favorite": "false"],
                                                          context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(mismatch.success)
        let direct = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(direct.success)
        domain.preference = "\(other.uuidString),invalid"
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Malformed preference must fail closed")
        } catch {}
        domain.preference = nil
        domain.cameras = [(camera, "Entrance"), (other, "Entrance")]
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Ambiguous camera must fail closed")
        } catch {}
        domain.cameras = []
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Missing camera must fail closed")
        } catch {}
        XCTAssertEqual(domain.writes, 0)
    }

    func testReadbackFailureAndLaterChangesNeverVerify() async throws {
        let camera = UUID(), other = UUID()
        let params = ["camera_id": "Entrance", "favorite": "true"]
        let context = ACTAActionContext(threadID: "test")
        let domain = FavoriteReviewFake([(camera, "Entrance")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        domain.afterWrite = { domain.preference = ACTACameraFavorites.encode([camera, other]); domain.changed() }
        let failed = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(failed.success)
        let failedVerification = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(failedVerification)

        domain.afterWrite = nil
        let fresh = try await action.prepareConfirmation(parameters: params, context: context)
        let success = try await action.executeConfirmed(parameters: params, context: context, snapshot: fresh.snapshot)
        XCTAssertTrue(success.success)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        let renewed = try await action.prepareConfirmation(parameters: params, context: context)
        let updated = try await action.executeConfirmed(parameters: params, context: context, snapshot: renewed.snapshot)
        XCTAssertTrue(updated.success)
        domain.preference = ACTACameraFavorites.encode([camera])
        domain.changed()
        let changedVerification = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(changedVerification)

        let next = try await action.prepareConfirmation(parameters: params, context: context)
        domain.failCommit = true
        let commitFailure = try await action.executeConfirmed(parameters: params, context: context, snapshot: next.snapshot)
        XCTAssertFalse(commitFailure.success)
        let commitVerification = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(commitVerification)
        domain.failCommit = false
        domain.failCapture = true
        let unavailableVerification = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(unavailableVerification)
    }

    func testReadbackErrorAndNoOpPreserveAbsence() async throws {
        let camera = UUID()
        let domain = FavoriteReviewFake([(camera, "Entrance")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let context = ACTAActionContext()
        let params = ["camera_id": "Entrance", "favorite": "false"]
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        XCTAssertTrue(prepared.reviewSummary.contains("Complete preference before: (absent)"))
        XCTAssertTrue(prepared.reviewSummary.contains("Complete preference after: (absent)"))
        domain.afterWrite = { domain.failCapture = true }
        let failed = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(failed.success)
        XCTAssertNil(domain.preference)
        domain.failCapture = false
        domain.afterWrite = nil
        let next = try await action.prepareConfirmation(parameters: params, context: context)
        let success = try await action.executeConfirmed(parameters: params, context: context, snapshot: next.snapshot)
        XCTAssertTrue(success.success)
        XCTAssertNil(domain.preference)
        domain.cameras = [(UUID(), "Entrance")]
        domain.changed()
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(verified)
    }

    func testOverlappingExecutionsCannotReplaceUnverifiedReceipt() async throws {
        let camera = UUID()
        let domain = FavoriteReviewFake([(camera, "Entrance")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let context = ACTAActionContext()
        let params = ["camera_id": "Entrance", "favorite": "true"]
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        let first = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(first.success)
        let secondPrepared = try await action.prepareConfirmation(parameters: params, context: context)
        let second = try await action.executeConfirmed(parameters: params, context: context, snapshot: secondPrepared.snapshot)
        XCTAssertFalse(second.success)
        XCTAssertEqual(domain.writes, 1)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        let replay = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replay)
    }

    func testCommitErrorAfterWriteReportsUnknownOutcomeAndCannotVerify() async throws {
        let camera = UUID()
        let domain = FavoriteReviewFake([(camera, "Entrance")])
        let action = ACTAPreparedCameraFavoriteAction(domain: domain)
        let context = ACTAActionContext(threadID: "test")
        let params = ["camera_id": "Entrance", "favorite": "true"]
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        domain.failAfterWrite = true
        let result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("outcome may be unknown") == true)
        XCTAssertEqual(domain.preference, ACTACameraFavorites.encode([camera]))
        XCTAssertEqual(domain.writes, 1)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(verified)
    }
}
