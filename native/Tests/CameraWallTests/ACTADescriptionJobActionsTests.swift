import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTADescriptionJobActionsTests: XCTestCase {
    private actor FakeBackend: ACTADescriptionJobBackend {
        var authorized = true
        var enabled = true
        var full = false
        var revision = UUID()
        var job: ACTADescriptionJobView
        var receipt: ACTADescriptionRetryReceipt?
        var verifySucceeds = true
        var throwCancellationAfterWrite = false
        var writes = 0

        init() {
            job = ACTADescriptionJobView(id: UUID(), status: .failed, attempts: 2,
                                        updatedAt: Date(timeIntervalSince1970: 123))
        }

        func recent(context: ACTAActionContext) async throws -> [ACTADescriptionJobView] {
            guard authorized else { throw ACTADescriptionJobError.unauthorized }
            return [job]
        }
        func snapshot(id: UUID, context: ACTAActionContext) async throws -> ACTADescriptionJobSnapshot {
            guard authorized, id == job.id else { throw ACTADescriptionJobError.unauthorized }
            return ACTADescriptionJobSnapshot(job: job, revision: revision)
        }
        func retry(_ snapshot: ACTADescriptionJobSnapshot, context: ACTAActionContext) async throws -> ACTADescriptionRetryReceipt {
            try Task.checkCancellation()
            guard authorized, enabled, !full else { throw ACTADescriptionJobError.unauthorized }
            guard snapshot.revision == revision, snapshot.job == job, job.status == .failed else {
                throw ACTADescriptionJobError.stale
            }
            try Task.checkCancellation()
            writes += 1
            job = ACTADescriptionJobView(id: job.id, status: .queued, attempts: job.attempts, updatedAt: Date())
            revision = UUID()
            let result = ACTADescriptionRetryReceipt(jobID: job.id, operationID: UUID())
            receipt = result
            if throwCancellationAfterWrite { throw CancellationError() }
            return result
        }
        func verify(_ receipt: ACTADescriptionRetryReceipt, context: ACTAActionContext) async throws -> Bool {
            guard authorized else { throw ACTADescriptionJobError.unauthorized }
            return verifySucceeds && self.receipt?.operationID == receipt.operationID && self.receipt?.jobID == receipt.jobID
        }
        func changeRevision() { revision = UUID() }
        func setAuthorized(_ value: Bool) { authorized = value }
        func setEnabled(_ value: Bool) { enabled = value }
        func setFull(_ value: Bool) { full = value }
        func setVerifySucceeds(_ value: Bool) { verifySucceeds = value }
        func setThrowCancellationAfterWrite() { throwCancellationAfterWrite = true }
        func claim() {
            job = ACTADescriptionJobView(id: job.id, status: .running, attempts: job.attempts + 1, updatedAt: Date())
        }
    }

    private func setup() async -> (FakeBackend, ACTADescriptionJobService, ACTAActionRegistry, String) {
        let backend = FakeBackend()
        let service = ACTADescriptionJobService(backend: backend)
        let registry = ACTAActionRegistry()
        await registry.register(ACTAInspectDescriptionJobsAction(service: service))
        await registry.register(ACTARetryDescriptionJobAction(service: service))
        let id = await backend.job.id.uuidString
        return (backend, service, registry, id)
    }

    func testInspectionIsAuthorizedAndOnlyReturnsSafeFields() async throws {
        let (backend, _, registry, _) = await setup()
        let result = try await registry.execute(actionID: "description_jobs.inspect", parameters: [:])
        XCTAssertTrue(result.success)
        let jobs = try JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [[String: Any]]
        XCTAssertEqual(Set(try XCTUnwrap(jobs?.first).keys), Set(["id", "status", "attempts", "updatedAt"]))
        await backend.setAuthorized(false)
        let denied = try await registry.execute(actionID: "description_jobs.inspect", parameters: [:])
        XCTAssertFalse(denied.success)
        XCTAssertFalse(denied.outputJSON.contains("failed"))
    }

    func testConfirmationRetryAndDurableReceiptSurviveWorkerClaim() async throws {
        let (backend, service, registry, id) = await setup()
        let params = ["job_id": id]
        let review = try await registry.execute(actionID: "description_jobs.retry", parameters: params)
        XCTAssertTrue(review.requiresOperatorConfirmation)
        let result = try await registry.confirmAndExecute(
            token: try XCTUnwrap(review.confirmationToken), confirmed: true,
            expectedActionID: "description_jobs.retry", expectedParameters: params,
            expectedThreadID: "default", expectedReviewTitle: review.summary)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        await backend.claim()
        let verified = try await service.verify(id: try XCTUnwrap(UUID(uuidString: id)),
                                                context: ACTAActionContext(isConfirmed: true))
        XCTAssertTrue(verified)
        let writes = await backend.writes
        XCTAssertEqual(writes, 1)
    }

    func testStaleSnapshotRevokedAuthorizationDisabledAndFullQueueDoNotWrite() async throws {
        for condition in 0..<4 {
            let (backend, _, registry, id) = await setup()
            let review = try await registry.execute(actionID: "description_jobs.retry", parameters: ["job_id": id])
            switch condition {
            case 0: await backend.changeRevision()
            case 1: await backend.setAuthorized(false)
            case 2: await backend.setEnabled(false)
            default: await backend.setFull(true)
            }
            let result = try await registry.confirmAndExecute(
                token: try XCTUnwrap(review.confirmationToken), confirmed: true,
                expectedActionID: "description_jobs.retry", expectedParameters: ["job_id": id],
                expectedThreadID: "default", expectedReviewTitle: review.summary)
            XCTAssertFalse(result.success)
            let writes = await backend.writes
            XCTAssertEqual(writes, 0)
        }
    }

    func testVerificationFailureAndUnconfirmedOrInvalidRequestsFailClosed() async throws {
        let (backend, service, registry, id) = await setup()
        let action = ACTARetryDescriptionJobAction(service: service)
        let params = ["job_id": id]
        let direct = try await action.execute(parameters: params, context: ACTAActionContext(isConfirmed: true))
        XCTAssertFalse(direct.success)
        XCTAssertThrowsError(try action.validate(parameters: ["job_id": id, "extra": "value"]))
        XCTAssertThrowsError(try action.validate(parameters: ["job_id": "invalid"]))
        let review = try await registry.execute(actionID: action.id, parameters: params)
        await backend.setVerifySucceeds(false)
        let result = try await registry.confirmAndExecute(
            token: try XCTUnwrap(review.confirmationToken), confirmed: true,
            expectedActionID: action.id, expectedParameters: params,
            expectedThreadID: "default", expectedReviewTitle: review.summary)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        let writes = await backend.writes
        XCTAssertEqual(writes, 1)
    }

    func testCancellationBeforeRetryDoesNotWrite() async throws {
        let (backend, service, _, id) = await setup()
        let snapshot = try await service.snapshot(id: try XCTUnwrap(UUID(uuidString: id)), context: ACTAActionContext())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.retry(snapshot, context: ACTAActionContext(isConfirmed: true))
        }
        do {
            try await task.value
            XCTFail("Cancelled retry succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let writes = await backend.writes
        XCTAssertEqual(writes, 0)
    }

    func testCancellationFromBackendAfterWriteRequiresReconciliation() async throws {
        let (backend, _, registry, id) = await setup()
        let params = ["job_id": id]
        let review = try await registry.execute(actionID: "description_jobs.retry", parameters: params)
        await backend.setThrowCancellationAfterWrite()
        let result = try await registry.confirmAndExecute(
            token: try XCTUnwrap(review.confirmationToken), confirmed: true,
            expectedActionID: "description_jobs.retry", expectedParameters: params,
            expectedThreadID: "default", expectedReviewTitle: review.summary)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("reconcile") == true)
        let writes = await backend.writes
        XCTAssertEqual(writes, 1)
    }

    func testUnavailableBackendFailsClosedBeforeReview() async throws {
        let service = ACTADescriptionJobService(backend: ACTADescriptionJobUnavailableBackend())
        let registry = ACTAActionRegistry()
        await registry.register(ACTAInspectDescriptionJobsAction(service: service))
        await registry.register(ACTARetryDescriptionJobAction(service: service))
        let inspection = try await registry.execute(actionID: "description_jobs.inspect", parameters: [:])
        let review = try await registry.execute(actionID: "description_jobs.retry", parameters: ["job_id": UUID().uuidString])
        XCTAssertFalse(inspection.success)
        XCTAssertFalse(review.requiresOperatorConfirmation)
        XCTAssertNil(review.confirmationToken)
    }
}
