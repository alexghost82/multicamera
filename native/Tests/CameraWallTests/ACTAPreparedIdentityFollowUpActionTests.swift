import CameraCore
import Combine
import Foundation
import SQLite3
import XCTest
@testable import CameraWall

private final class FollowUpAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ACTABrokerAuditEvent] = []
    let failReview: Bool
    init(failReview: Bool = false) { self.failReview = failReview }
    func record(_ event: ACTABrokerAuditEvent) throws {
        if failReview && event.phase == .review { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { storage.append(event) }
    }
    var events: [ACTABrokerAuditEvent] { lock.withLock { storage } }
}

@MainActor
final class ACTAPreparedIdentityFollowUpActionTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, ACTAIdentityFollowUpDomain, String) {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".identity-follow-up-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let id = UUID().uuidString
        try store.upsertACTAIdentityProfile(ACTAIdentityGalleryProfile(
            identityID: id, kind: "person", displayCode: "fixture", displayName: "private-name"))
        return (root, store, try ACTAIdentityFollowUpDomain(trackingStore: store), id)
    }

    func testReviewedBrokerCommitIsReversibleAndAuditIsRedacted() async throws {
        let (root, store, domain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTAPreparedIdentityFollowUpAction(domain: domain)
        let audit = FollowUpAudit()
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { try audit.record($0) })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let flags = try store.makeACTAIdentityFollowUpStore()
        for desired in [true, false] {
            let result = await host.broker.request(session: session, actionID: action.id,
                argumentsJSON: #"{"identity_id":"\#(id)","flagged":\#(desired)}"#)
            XCTAssertTrue(result.requiresOperatorConfirmation)
            XCTAssertFalse(result.outputJSON.contains(id))
            XCTAssertEqual(try XCTUnwrap(flags.capture(identityID: id)).flagged, !desired)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            XCTAssertTrue(review.title.contains(id))
            XCTAssertFalse(review.title.contains("private-name"))
            let applied = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                    reviewed: review, approved: true)
            XCTAssertTrue(applied.success && applied.verified, applied.error ?? "")
            XCTAssertFalse(applied.outputJSON.contains(id))
            XCTAssertFalse(applied.outputJSON.contains("private-name"))
            XCTAssertEqual(try XCTUnwrap(flags.capture(identityID: id)).flagged, desired)
        }
        XCTAssertFalse(audit.events.isEmpty)
        for event in audit.events {
            XCTAssertFalse(String(describing: event).contains(id))
            XCTAssertFalse(String(describing: event).contains("private-name"))
        }
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testModelRouteAndOperatorRecoveryShareDomain() async throws {
        let (root, store, domain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            XCTFail("Unexpected credential access")
            return nil
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let action = ACTAPreparedIdentityFollowUpAction(domain: domain)
        let audit = FollowUpAudit()
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { try audit.record($0) })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let name = "acta__identity__set_follow_up"
        let call = ACTAAgentFunctionCall(callID: "follow-up", name: name,
            argumentsJSON: #"{"identity_id":"\#(id)","flagged":true}"#)
        let flags = try store.makeACTAIdentityFollowUpStore()
        let operatorState = ACTAIdentityFollowUpOperatorState(domain: domain)
        operatorState.setIdentityID(id)
        operatorState.refresh()
        XCTAssertEqual(operatorState.readout, .init(identityID: id, flagged: false))

        let denied = await coordinator.executeModelGeneratedAgentTool(call, threadID: "other",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(denied.outputJSON.contains("UNAUTHORIZED"))
        let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"), pending.outputJSON)
        XCTAssertFalse(pending.outputJSON.contains(id))
        XCTAssertFalse(pending.outputJSON.contains("private-name"))
        XCTAssertFalse(try XCTUnwrap(flags.capture(identityID: id)).flagged)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
            reviewed: try XCTUnwrap(reviews.first), approved: true)
        XCTAssertTrue(approved.success && approved.verified, approved.error ?? "")
        XCTAssertFalse(approved.outputJSON.contains(id))
        XCTAssertFalse(approved.outputJSON.contains("private-name"))
        XCTAssertTrue(try XCTUnwrap(flags.capture(identityID: id)).flagged)
        operatorState.domainChanged()
        XCTAssertEqual(operatorState.readout, .init(identityID: id, flagged: true))

        // Simulate an interrupted writer after its durable commit but before verification.
        let previous = try XCTUnwrap(flags.capture(identityID: id))
        _ = try XCTUnwrap(flags.commit(expected: previous, flagged: false))
        XCTAssertFalse(domain.canStart)
        let blocked = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertFalse(blocked.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertFalse(blocked.outputJSON.contains(id))
        XCTAssertFalse(blocked.outputJSON.contains("private-name"))
        operatorState.setAcknowledged(true)
        operatorState.confirmRecovery()
        XCTAssertFalse(domain.canStart)
        operatorState.inspectUncertainOutcome()
        XCTAssertEqual(operatorState.recoveryReadout, .init(identityID: id, flagged: false))
        operatorState.confirmRecovery()
        XCTAssertFalse(domain.canStart)
        operatorState.setAcknowledged(true)
        var profile = try XCTUnwrap(store.loadACTAIdentityProfiles().first)
        profile.displayCode = "changed"
        try store.upsertACTAIdentityProfile(profile)
        operatorState.confirmRecovery()
        XCTAssertFalse(domain.canStart)
        XCTAssertEqual(operatorState.message, .inspectAgain)
        operatorState.inspectUncertainOutcome()
        operatorState.setAcknowledged(true)
        operatorState.confirmRecovery()
        XCTAssertTrue(domain.canStart)
        XCTAssertEqual(operatorState.readout, .init(identityID: id, flagged: false))
        XCTAssertEqual(operatorState.message, .recovered)

        let retry = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(retry.outputJSON.contains("requires_operator_confirmation"), retry.outputJSON)
        XCTAssertFalse(retry.outputJSON.contains(id))
        XCTAssertFalse(retry.outputJSON.contains("private-name"))
        let retryReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let completed = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
            reviewed: try XCTUnwrap(retryReviews.first), approved: true)
        XCTAssertTrue(completed.success && completed.verified, completed.error ?? "")
        XCTAssertFalse(completed.outputJSON.contains(id))
        XCTAssertFalse(completed.outputJSON.contains("private-name"))
        XCTAssertTrue(try XCTUnwrap(flags.capture(identityID: id)).flagged)
        XCTAssertFalse(audit.events.isEmpty)
        for event in audit.events {
            XCTAssertFalse(String(describing: event).contains(id))
            XCTAssertFalse(String(describing: event).contains("private-name"))
        }
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testStaleApprovalAndAuditFailureDoNotWrite() async throws {
        let (root, store, domain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTAPreparedIdentityFollowUpAction(domain: domain)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let json = #"{"identity_id":"\#(id)","flagged":true}"#
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: json)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let flags = try store.makeACTAIdentityFollowUpStore()
        let initial = try XCTUnwrap(flags.capture(identityID: id))
        let on = try XCTUnwrap(flags.commit(expected: initial, flagged: true))
        XCTAssertTrue(try flags.finish(on))
        let off = try XCTUnwrap(flags.commit(expected: on, flagged: false))
        XCTAssertTrue(try flags.finish(off))
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: review, approved: true)
        XCTAssertFalse(rejected.success)
        XCTAssertFalse(try XCTUnwrap(flags.capture(identityID: id)).flagged)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)

        let failingAudit = FollowUpAudit(failReview: true)
        let secondHost = await ACTALocalActionBroker.make(actions: [action],
            allowedActionIDs: [action.id], audit: { try failingAudit.record($0) })
        let second = try XCTUnwrap(secondHost)
        let secondOpened = await second.broker.openSession(operatorKey: second.operatorKey,
            input: .chat, threadID: "fixture", actionIDs: [action.id])
        let secondSession = try XCTUnwrap(secondOpened)
        _ = await second.broker.request(session: secondSession, actionID: action.id, argumentsJSON: json)
        let next = await second.broker.reviews(operatorKey: second.operatorKey, session: secondSession)
        let denied = await second.broker.resolve(operatorKey: second.operatorKey, session: secondSession,
                                                 reviewed: try XCTUnwrap(next.first), approved: true)
        XCTAssertFalse(denied.success)
        XCTAssertTrue(denied.error?.contains("AUDIT_FAILED") == true)
        XCTAssertFalse(try XCTUnwrap(flags.capture(identityID: id)).flagged)
        await second.broker.closeSession(secondSession, operatorKey: second.operatorKey)
    }

    func testUncertainOutcomeRequiresAcknowledgingExactSnapshot() async throws {
        let (root, store, domain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTAPreparedIdentityFollowUpAction(domain: domain)
        let operatorState = ACTAIdentityFollowUpOperatorState(domain: domain)
        let parameters = ["identity_id": id, "flagged": "true"]
        let context = ACTAActionContext(threadID: "fixture", isConfirmed: true)
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("tracking.sqlite").path, &db,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TRIGGER fixture_side_effect AFTER INSERT ON ghost_identity_follow_up
            BEGIN UPDATE ghost_identities SET kind = 'changed'; END
            """, nil, nil, nil), SQLITE_OK)
        let failed = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(failed.success)
        XCTAssertFalse(domain.canStart)
        operatorState.setAcknowledged(true)
        operatorState.confirmRecovery()
        XCTAssertFalse(operatorState.acknowledged)
        XCTAssertFalse(domain.canStart)
        XCTAssertEqual(sqlite3_exec(connection, "DROP TRIGGER fixture_side_effect", nil, nil, nil), SQLITE_OK)
        operatorState.inspectUncertainOutcome()
        XCTAssertEqual(operatorState.recoveryReadout?.identityID, id)
        XCTAssertEqual(operatorState.recoveryReadout?.flagged, false)
        operatorState.domainChanged()
        XCTAssertEqual(operatorState.recoveryReadout?.identityID, id)
        operatorState.confirmRecovery()
        XCTAssertFalse(domain.canStart)
        operatorState.setAcknowledged(true)
        XCTAssertTrue(operatorState.canConfirmRecovery)
        var attempted = false
        let subscription = operatorState.objectWillChange.sink {
            if operatorState.acknowledged {
                attempted = true
                operatorState.confirmRecovery()
            }
        }
        operatorState.setAcknowledged(false)
        subscription.cancel()
        XCTAssertTrue(attempted)
        XCTAssertFalse(domain.canStart)
        operatorState.setAcknowledged(true)
        var profile = try XCTUnwrap(store.loadACTAIdentityProfiles().first)
        profile.displayCode = "changed"
        try store.upsertACTAIdentityProfile(profile)
        operatorState.confirmRecovery()
        XCTAssertFalse(domain.canStart)
        XCTAssertEqual(operatorState.message, .inspectAgain)
        XCTAssertNil(operatorState.recoveryReadout)
        XCTAssertFalse(operatorState.acknowledged)
        operatorState.inspectUncertainOutcome()
        operatorState.setAcknowledged(true)
        operatorState.confirmRecovery()
        XCTAssertTrue(domain.canStart)
        XCTAssertEqual(operatorState.readout?.identityID, id)
        XCTAssertEqual(operatorState.readout?.flagged, false)
        XCTAssertEqual(operatorState.message, .recovered)
        let repeated = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
        XCTAssertFalse(repeated.success)
    }

    func testOperatorReadoutReflectsStoredFlagAndClearsOnSelectionChange() throws {
        let (root, store, domain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ACTAIdentityFollowUpOperatorState(domain: domain)
        state.setIdentityID(id)
        state.refresh()
        XCTAssertEqual(state.readout, .init(identityID: id, flagged: false))
        let flags = try store.makeACTAIdentityFollowUpStore()
        let before = try XCTUnwrap(flags.capture(identityID: id))
        let on = try XCTUnwrap(flags.commit(expected: before, flagged: true))
        XCTAssertTrue(try flags.finish(on))
        state.refresh()
        XCTAssertEqual(state.readout, .init(identityID: id, flagged: true))
        state.setIdentityID(UUID().uuidString)
        XCTAssertNil(state.readout)
        state.refresh()
        XCTAssertNil(state.readout)
        XCTAssertEqual(state.message, .notFound)
        state.setIdentityID("bad identifier")
        state.refresh()
        XCTAssertEqual(state.message, .invalidID)
    }

    func testDomainNotificationsPreventReentrantMutationsAndRefreshReadout() throws {
        let (root, _, domain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ACTAIdentityFollowUpOperatorState(domain: domain)
        state.setIdentityID(id)
        state.refresh()
        let before = try XCTUnwrap(domain.capture(identityID: id))
        var rejected = false
        let subscription = domain.objectWillChange.sink {
            do { _ = try domain.capture(identityID: id) }
            catch { rejected = true }
        }
        let after = try XCTUnwrap(domain.commit(expected: before, flagged: true))
        subscription.cancel()
        XCTAssertTrue(rejected)
        XCTAssertTrue(domain.verify(after))
        state.domainChanged()
        XCTAssertEqual(state.readout, .init(identityID: id, flagged: true))
    }

    func testExitedProcessRequiresOperatorRecoveryInNewDomain() throws {
        guard let helper = ProcessInfo.processInfo.environment["IDENTITY_FOLLOW_UP_TEST_HELPER"] else {
            throw XCTSkip("Set IDENTITY_FOLLOW_UP_TEST_HELPER to the compiled fixture helper.")
        }
        let (root, store, originalDomain, id) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [root.appendingPathComponent("tracking.sqlite").path, id, "leave-pending"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let newDomain = try ACTAIdentityFollowUpDomain(trackingStore: store)
        XCTAssertFalse(newDomain.canStart)
        XCTAssertFalse(originalDomain.canStart)
        XCTAssertThrowsError(try originalDomain.capture(identityID: id))
        let state = ACTAIdentityFollowUpOperatorState(domain: newDomain)
        state.confirmRecovery()
        XCTAssertFalse(newDomain.canStart)
        state.inspectUncertainOutcome()
        XCTAssertEqual(state.recoveryReadout, .init(identityID: id, flagged: true))
        state.confirmRecovery()
        XCTAssertFalse(newDomain.canStart)
        state.setAcknowledged(true)
        state.confirmRecovery()
        XCTAssertTrue(newDomain.canStart)
        XCTAssertEqual(state.readout, .init(identityID: id, flagged: true))
    }
}
