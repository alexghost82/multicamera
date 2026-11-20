import Foundation
import Testing
@testable import CameraCore

@Suite("ACTA Registry Idempotency and Timeout Tests")
struct ACTARegistryIdempotencyTimeoutTests {
    actor Counter {
        var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
    }

    struct IdempotentMutation: ACTAActionProtocol {
        let id = "test.idempotent"
        let title = "Idempotent Mutation"
        let description = "Counts executions"
        let classification = ACTAActionClassification.reversible
        let parameters = [
            ACTAActionParameterSchema(name: "should_fail", type: "boolean", description: "Fail execution")
        ]
        let counter: Counter

        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            let n = await counter.increment()
            if parameters["should_fail"] == "true" {
                return .failed(actionID: id, error: "SYNTHETIC_FAILURE: failed attempt \(n)")
            }
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Executed #\(n)",
                outputJSON: "{\"run\":\(n)}"
            )
        }

        func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
            true
        }
    }

    struct SlowAction: ACTAActionProtocol {
        let id = "test.slow"
        let title = "Slow Action"
        let description = "Sleeps past deadline"
        let classification = ACTAActionClassification.inspect
        let parameters: [ACTAActionParameterSchema] = []
        let sleepNanoseconds: UInt64

        func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
            return ACTAActionResult(actionID: id, success: true, summary: "Finished")
        }
    }

    @Test func idempotencyKeyDeduplicatesVerifiedMutationsOnly() async throws {
        let registry = ACTAActionRegistry()
        let counter = Counter()
        await registry.register(IdempotentMutation(counter: counter))

        let ctx1 = ACTAActionContext(threadID: "t1", idempotencyKey: "key-1")
        let first = try await registry.execute(actionID: "test.idempotent", parameters: [:], context: ctx1)
        #expect(first.success)
        #expect(first.outputJSON == #"{"run":1}"#)

        let duplicate = try await registry.execute(actionID: "test.idempotent", parameters: [:], context: ctx1)
        #expect(duplicate.success)
        #expect(duplicate.outputJSON == #"{"run":1}"#)
        #expect(await counter.count == 1)

        // Different key executes again
        let ctx2 = ACTAActionContext(threadID: "t1", idempotencyKey: "key-2")
        let second = try await registry.execute(actionID: "test.idempotent", parameters: [:], context: ctx2)
        #expect(second.success)
        #expect(second.outputJSON == #"{"run":2}"#)
        #expect(await counter.count == 2)

        // Failed execution is NOT cached for retry
        let failCtx = ACTAActionContext(threadID: "t1", idempotencyKey: "key-fail")
        let failed = try await registry.execute(
            actionID: "test.idempotent",
            parameters: ["should_fail": "true"],
            context: failCtx
        )
        #expect(!failed.success)
        let retried = try await registry.execute(
            actionID: "test.idempotent",
            parameters: [:],
            context: failCtx
        )
        #expect(retried.success)
        #expect(await counter.count == 4)
    }

    @Test func executionDeadlineReturnsTimedOutInRegistryAndBroker() async throws {
        let registry = ACTAActionRegistry()
        await registry.register(SlowAction(sleepNanoseconds: 2_000_000_000))

        let timedOut = try await registry.execute(
            actionID: "test.slow",
            parameters: [:],
            context: ACTAActionContext(timeoutSeconds: 0.05)
        )
        #expect(!timedOut.success)
        #expect(timedOut.error?.hasPrefix("ACTION_TIMED_OUT:") == true)

        let created = try #require(await ACTALocalActionBroker.make(
            actions: [SlowAction(sleepNanoseconds: 2_000_000_000)],
            allowedActionIDs: ["test.slow"],
            actionTimeoutSeconds: 0.05,
            audit: { _ in }
        ))
        let session = try #require(await created.broker.openSession(
            operatorKey: created.operatorKey,
            input: .chat,
            threadID: "t-timeout",
            actionIDs: ["test.slow"]
        ))
        let brokerResult = await created.broker.request(
            session: session,
            actionID: "test.slow",
            argumentsJSON: "{}"
        )
        #expect(!brokerResult.success)
        #expect(brokerResult.error?.hasPrefix("ACTION_TIMED_OUT:") == true)
    }
}
