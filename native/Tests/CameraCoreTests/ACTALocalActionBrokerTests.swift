import Foundation
import Testing
@testable import CameraCore

struct ACTALocalActionBrokerTests {
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    final class AuditLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ACTABrokerAuditEvent] = []
        private var failingPhase: String?
        func fail(_ phase: String?) { lock.lock(); defer { lock.unlock() }; failingPhase = phase }
        func record(_ event: ACTABrokerAuditEvent) throws {
            lock.lock()
            defer { lock.unlock() }
            if String(describing: event.phase) == failingPhase { throw AuditError() }
            entries.append(event)
        }
        func events() -> [ACTABrokerAuditEvent] { lock.lock(); defer { lock.unlock() }; return entries }
        struct AuditError: Error {}
    }

    struct ProbeAction: ACTAActionProtocol {
        let id: String
        let title = "Probe"
        let description = "Isolated fake action"
        let classification: ACTAActionClassification
        let parameters = [ACTAActionParameterSchema(name: "value", type: "string", description: "Value", isRequired: true)]
        let counter: Counter
        func requiresConfirmation(parameters: [String: String]) -> Bool { false }
        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            await counter.increment()
            return ACTAActionResult(actionID: id, success: true, summary: "done")
        }
        func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
    }

    actor PreparationLatch {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                started = true
                waiters.forEach { $0.resume() }
                waiters.removeAll()
            }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { releaseContinuation?.resume(); releaseContinuation = nil }
    }

    struct SuspendedPreparedAction: ACTAPreparedConfirmationAction {
        let id = "test.prepared"
        let title = "Prepared"
        let description = "Fake prepared action"
        let classification = ACTAActionClassification.reversible
        let parameters: [ACTAActionParameterSchema] = []
        let latch: PreparationLatch
        let counter: Counter
        func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAPreparedConfirmation<Int> {
            await latch.hold()
            return ACTAPreparedConfirmation(snapshot: 1, reviewSummary: "Fake snapshot")
        }
        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            await counter.increment()
            return ACTAActionResult(actionID: id, success: true, summary: "unexpected")
        }
        func executeConfirmed(parameters: [String: String], context: ACTAActionContext, snapshot: Int) async throws -> ACTAActionResult {
            await counter.increment()
            return ACTAActionResult(actionID: id, success: true, summary: "confirmed")
        }
        func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
    }

    @Test func inspectionsAreScopedAndEveryMutationNeedsPrivateReview() async throws {
        let counter = Counter()
        let log = AuditLog()
        let actions = [
            ProbeAction(id: "test.inspect", classification: .inspect, counter: counter),
            ProbeAction(id: "test.mutate", classification: .reversible, counter: counter),
            ProbeAction(id: "test.hidden", classification: .reversible, counter: counter)
        ]
        let created = try #require(await ACTALocalActionBroker.make(
            actions: actions, allowedActionIDs: ["test.inspect", "test.mutate"], audit: { try log.record($0) }))
        let session = try #require(await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
            threadID: "local-thread", actionIDs: ["test.inspect", "test.mutate"]))
        let catalogue = await created.broker.catalogue(session: session)
        #expect(catalogue.map(\.id) == ["test.inspect", "test.mutate"])

        let inspection = await created.broker.request(session: session, actionID: "test.inspect",
                                                       argumentsJSON: #"{"value":"sample"}"#)
        #expect(inspection.success)
        #expect(await counter.value == 1)
        let spoofed = await created.broker.request(session: session, actionID: "test.mutate",
            argumentsJSON: #"{"value":"sample","initiator":"ui_direct"}"#)
        #expect(spoofed.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        #expect(await counter.value == 1)
        let mutation = await created.broker.request(session: session, actionID: "test.mutate",
                                                     argumentsJSON: #"{"value":"complete request"}"#)
        #expect(mutation.requiresOperatorConfirmation)
        #expect(mutation.confirmationToken == nil)
        #expect(!mutation.summary.contains("complete request"))
        #expect(!mutation.outputJSON.contains("complete request"))
        #expect(await counter.value == 1)
        let review = try #require(await created.broker.reviews(operatorKey: created.operatorKey, session: session).first)
        #expect(review.threadID == "local-thread")
        #expect(review.parameters == ["value": "complete request"])
        let approved = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                    reviewed: review, approved: true)
        #expect(approved.success)
        #expect(await counter.value == 2)
        let replay = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                  reviewed: review, approved: true)
        #expect(!replay.success)
        let hidden = await created.broker.request(session: session, actionID: "test.hidden",
                                                  argumentsJSON: #"{"value":"sample"}"#)
        #expect(hidden.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
        #expect(await counter.value == 2)
        let events = log.events()
        #expect(events.contains { String(describing: $0.phase) == "review" && $0.approved == true
                                  && $0.threadID == "local-thread" })
        #expect(events.contains { String(describing: $0.phase) == "result" && $0.outcome == "failed"
                                  && $0.actionID == "[unrecognized]" })
    }

    @Test func unsafeReviewParametersAreRejectedWithoutLeakingToAudit() async throws {
        let counter = Counter()
        let log = AuditLog()
        let action = ProbeAction(id: "test.mutate", classification: .reversible, counter: counter)
        let created = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { try log.record($0) }))
        let session = try #require(await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
            threadID: "x", actionIDs: [action.id]))
        let result = await created.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"value":"rtsp://operator:private@example.invalid/live"}"#)
        #expect(result.error?.hasPrefix("REVIEW_UNDISPLAYABLE:") == true)
        #expect(!result.summary.contains("private"))
        #expect(await created.broker.reviews(operatorKey: created.operatorKey, session: session).isEmpty)
        #expect(await counter.value == 0)
        #expect(!String(describing: log.events()).contains("private"))
    }

    struct FailingPreparedAction: ACTAPreparedConfirmationAction {
        let id = "test.failure"
        let title = "Failure"
        let description = "Fake failure"
        let classification = ACTAActionClassification.reversible
        let parameters: [ACTAActionParameterSchema] = []
        let cancelled: Bool
        struct Failure: Error {}
        func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAPreparedConfirmation<Int> {
            if cancelled { throw CancellationError() }
            throw Failure()
        }
        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            .failed(actionID: id, error: "unexpected")
        }
        func executeConfirmed(parameters: [String: String], context: ACTAActionContext, snapshot: Int) async throws -> ACTAActionResult {
            .failed(actionID: id, error: "unexpected")
        }
    }

    struct SensitiveFieldAction: ACTAActionProtocol {
        let id = "test.password"
        let title = "Credentials"
        let description = "Fake credentials"
        let classification = ACTAActionClassification.reversible
        let parameters = [ACTAActionParameterSchema(name: "password", type: "string", description: "Password", isRequired: true)]
        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            ACTAActionResult(actionID: id, success: true, summary: "unexpected")
        }
    }

    @Test func sensitiveFieldsAndOversizedReviewsFailClosed() async throws {
        let counter = Counter()
        let action = ProbeAction(id: "test.mutate", classification: .reversible, counter: counter)
        let secret = SensitiveFieldAction()
        let created = try #require(await ACTALocalActionBroker.make(
            actions: [action, secret], allowedActionIDs: [action.id, secret.id], audit: { _ in }))
        let session = try #require(await created.broker.openSession(operatorKey: created.operatorKey,
            input: .chat, threadID: "x", actionIDs: [action.id, secret.id]))
        let forbidden = await created.broker.request(session: session, actionID: secret.id,
                                                     argumentsJSON: #"{"password":"secret"}"#)
        #expect(forbidden.error?.hasPrefix("REVIEW_UNDISPLAYABLE:") == true)
        let long = String(repeating: "a", count: 8193)
        let json = String(decoding: try JSONEncoder().encode(["value": long]), as: UTF8.self)
        let oversized = await created.broker.request(session: session, actionID: action.id, argumentsJSON: json)
        #expect(oversized.error?.hasPrefix("REVIEW_UNDISPLAYABLE:") == true)
        #expect(await created.broker.reviews(operatorKey: created.operatorKey, session: session).isEmpty)
        #expect(await counter.value == 0)
    }

    @Test func cancellationAndPreparationFailureHaveDifferentCodes() async throws {
        for cancelled in [false, true] {
            let action = FailingPreparedAction(cancelled: cancelled)
            let created = try #require(await ACTALocalActionBroker.make(
                actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
            let session = try #require(await created.broker.openSession(operatorKey: created.operatorKey,
                input: .chat, threadID: "x", actionIDs: [action.id]))
            let result = await created.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            let prefix = cancelled ? "ACTION_CANCELLED:" : "CONFIRMATION_PREPARATION_FAILED:"
            #expect(result.error?.hasPrefix(prefix) == true)
            #expect(!result.requiresOperatorConfirmation)
        }
    }

    @Test func foreignClosedAndTamperedReviewCapabilitiesFailClosed() async throws {
        let counter = Counter()
        let actions = [ProbeAction(id: "test.mutate", classification: .serviceAffecting, counter: counter)]
        let first = try #require(await ACTALocalActionBroker.make(
            actions: actions, allowedActionIDs: ["test.mutate"], audit: { _ in }))
        let second = try #require(await ACTALocalActionBroker.make(
            actions: actions, allowedActionIDs: ["test.mutate"], audit: { _ in }))
        #expect(await first.broker.openSession(operatorKey: second.operatorKey, input: .chat,
            threadID: "x", actionIDs: ["test.mutate"]) == nil)
        #expect(await first.broker.openSession(operatorKey: first.operatorKey, input: .chat,
            threadID: "x", actionIDs: ["test.other"]) == nil)
        let session = try #require(await first.broker.openSession(operatorKey: first.operatorKey, input: .voice,
            threadID: "x", actionIDs: ["test.mutate"]))
        let foreign = try #require(await second.broker.openSession(operatorKey: second.operatorKey, input: .chat,
            threadID: "x", actionIDs: ["test.mutate"]))
        let foreignResult = await first.broker.request(session: foreign, actionID: "test.mutate",
                                                        argumentsJSON: #"{"value":"one"}"#)
        #expect(foreignResult.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
        let proposed = await first.broker.request(session: session, actionID: "test.mutate",
                                                   argumentsJSON: #"{"value":"one"}"#)
        #expect(proposed.requiresOperatorConfirmation)
        #expect(await first.broker.reviews(operatorKey: second.operatorKey, session: session).isEmpty)
        let review = try #require(await first.broker.reviews(operatorKey: first.operatorKey, session: session).first)
        let tampered = ACTABrokerReview(handle: review.handle, actionID: review.actionID,
                                        threadID: review.threadID, parameters: ["value": "two"], title: review.title)
        let rejected = await first.broker.resolve(operatorKey: first.operatorKey, session: session,
                                                   reviewed: tampered, approved: true)
        #expect(!rejected.success)
        #expect(await counter.value == 0)
        await first.broker.closeSession(session, operatorKey: first.operatorKey)
        let closed = await first.broker.resolve(operatorKey: first.operatorKey, session: session,
                                                 reviewed: review, approved: true)
        #expect(!closed.success)
        #expect(await first.broker.catalogue(session: session).isEmpty)
        #expect(await counter.value == 0)
    }

    @Test func auditFailurePreventsExecutionAndApproval() async throws {
        let counter = Counter()
        let log = AuditLog()
        let action = ProbeAction(id: "test.mutate", classification: .reversible, counter: counter)
        let created = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { try log.record($0) }))
        let session = try #require(await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
            threadID: "x", actionIDs: [action.id]))
        for phase in ["request", "validated"] {
            log.fail(phase)
            let result = await created.broker.request(session: session, actionID: action.id,
                                                       argumentsJSON: #"{"value":"one"}"#)
            #expect(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            #expect(await counter.value == 0)
        }
        log.fail("result")
        let failedResultAudit = await created.broker.request(session: session, actionID: action.id,
                                                             argumentsJSON: #"{"value":"one"}"#)
        #expect(failedResultAudit.error?.hasPrefix("AUDIT_FAILED:") == true)
        #expect(await created.broker.reviews(operatorKey: created.operatorKey, session: session).isEmpty)
        #expect(await counter.value == 0)
        log.fail(nil)
        _ = await created.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"value":"one"}"#)
        let review = try #require(await created.broker.reviews(operatorKey: created.operatorKey, session: session).first)
        log.fail("review")
        let failed = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                   reviewed: review, approved: true)
        #expect(failed.error?.hasPrefix("AUDIT_FAILED:") == true)
        #expect(await counter.value == 0)
        log.fail(nil)
        let approved = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                     reviewed: review, approved: true)
        #expect(approved.success)
        #expect(await counter.value == 1)

        _ = await created.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"value":"two"}"#)
        let rejectedReview = try #require(await created.broker.reviews(operatorKey: created.operatorKey, session: session).first)
        let rejected = await created.broker.resolve(operatorKey: created.operatorKey, session: session,
                                                    reviewed: rejectedReview, approved: false)
        #expect(!rejected.success)
        #expect(await counter.value == 1)
    }

    @Test func closedSessionCannotReceiveLatePreparedReview() async throws {
        let counter = Counter()
        let latch = PreparationLatch()
        let action = SuspendedPreparedAction(latch: latch, counter: counter)
        let created = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await created.broker.openSession(operatorKey: created.operatorKey, input: .voice,
            threadID: "x", actionIDs: [action.id]))
        let task = Task {
            await created.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        }
        await latch.waitUntilStarted()
        await created.broker.closeSession(session, operatorKey: created.operatorKey)
        await latch.release()
        let result = await task.value
        #expect(!result.requiresOperatorConfirmation)
        #expect(result.confirmationToken == nil)
        #expect(await created.broker.reviews(operatorKey: created.operatorKey, session: session).isEmpty)
        #expect(await counter.value == 0)
    }
}
