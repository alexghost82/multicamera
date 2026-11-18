import CameraCore
import Foundation

/// Only these fields may leave the job service; payloads, results, errors and camera
/// identities are deliberately excluded.
struct ACTADescriptionJobView: Codable, Equatable, Sendable {
    let id: UUID
    let status: CameraFeatureJobStatus
    let attempts: Int
    let updatedAt: Date
}

struct ACTADescriptionJobSnapshot: Sendable {
    let job: ACTADescriptionJobView
    /// Opaque revision which must change on every relevant job or policy change.
    let revision: UUID
}

struct ACTADescriptionRetryReceipt: Sendable {
    let jobID: UUID
    let operationID: UUID
}

enum ACTADescriptionJobError: Error {
    case unavailable, unauthorized, stale, notFailed, busy, verificationFailed
}

/// Implementations must authorize each operation using a trusted principal, not the
/// caller-supplied initiator or thread ID. Retry must atomically reauthorize, compare
/// the complete revision, check feature policy and queue capacity, check cancellation
/// immediately before committing, and durably record an operation-specific receipt.
/// Once committed, retry must return its receipt even if cancellation arrives.
/// Verification must read that receipt and still work if the worker has claimed the job.
protocol ACTADescriptionJobBackend: Sendable {
    func recent(context: ACTAActionContext) async throws -> [ACTADescriptionJobView]
    func snapshot(id: UUID, context: ACTAActionContext) async throws -> ACTADescriptionJobSnapshot
    func retry(_ snapshot: ACTADescriptionJobSnapshot, context: ACTAActionContext) async throws -> ACTADescriptionRetryReceipt
    func verify(_ receipt: ACTADescriptionRetryReceipt, context: ACTAActionContext) async throws -> Bool
}

/// The GUI coordinator has no trusted agent authorization, atomic revision check, or
/// durable retry receipt. Never substitute its list/retry methods for this backend.
struct ACTADescriptionJobUnavailableBackend: ACTADescriptionJobBackend {
    func recent(context: ACTAActionContext) async throws -> [ACTADescriptionJobView] { throw ACTADescriptionJobError.unavailable }
    func snapshot(id: UUID, context: ACTAActionContext) async throws -> ACTADescriptionJobSnapshot { throw ACTADescriptionJobError.unavailable }
    func retry(_ snapshot: ACTADescriptionJobSnapshot, context: ACTAActionContext) async throws -> ACTADescriptionRetryReceipt { throw ACTADescriptionJobError.unavailable }
    func verify(_ receipt: ACTADescriptionRetryReceipt, context: ACTAActionContext) async throws -> Bool { false }
}

actor ACTADescriptionJobService {
    private let backend: any ACTADescriptionJobBackend
    private var busy = false
    private var receipt: (ACTADescriptionRetryReceipt, String)?

    init(backend: any ACTADescriptionJobBackend) { self.backend = backend }

    func recent(context: ACTAActionContext) async throws -> [ACTADescriptionJobView] {
        try Task.checkCancellation()
        let jobs = try await backend.recent(context: context)
        try Task.checkCancellation()
        guard jobs.count <= 50 else { throw ACTADescriptionJobError.unavailable }
        return jobs
    }

    func snapshot(id: UUID, context: ACTAActionContext) async throws -> ACTADescriptionJobSnapshot {
        try Task.checkCancellation()
        let snapshot = try await backend.snapshot(id: id, context: context)
        try Task.checkCancellation()
        guard snapshot.job.id == id else { throw ACTADescriptionJobError.unavailable }
        guard snapshot.job.status == .failed else { throw ACTADescriptionJobError.notFailed }
        return snapshot
    }

    func retry(_ snapshot: ACTADescriptionJobSnapshot, context: ACTAActionContext) async throws {
        guard !busy else { throw ACTADescriptionJobError.busy }
        busy = true
        receipt = nil
        defer { busy = false }
        try Task.checkCancellation()
        let written: ACTADescriptionRetryReceipt
        do {
            written = try await backend.retry(snapshot, context: context)
        } catch is CancellationError {
            // A backend cancellation error does not prove that no commit occurred.
            throw ACTADescriptionJobError.verificationFailed
        }
        guard written.jobID == snapshot.job.id else { throw ACTADescriptionJobError.verificationFailed }
        // A cancellation after commit cannot undo the write; verify rather than claiming
        // the operation was cancelled without a side effect.
        let verified: Bool
        do { verified = try await backend.verify(written, context: context) }
        catch { throw ACTADescriptionJobError.verificationFailed }
        guard verified else {
            throw ACTADescriptionJobError.verificationFailed
        }
        receipt = (written, context.threadID)
    }

    func verify(id: UUID, context: ACTAActionContext) async throws -> Bool {
        guard !busy, let (written, threadID) = receipt, written.jobID == id,
              threadID == context.threadID else { return false }
        let verified = try await backend.verify(written, context: context)
        guard !busy, let current = receipt, current.0.operationID == written.operationID,
              current.0.jobID == written.jobID, current.1 == threadID else { return false }
        return verified
    }
}

private func descriptionJobID(_ parameters: [String: String]) throws -> UUID {
    guard parameters.count == 1, let raw = parameters["job_id"], let id = UUID(uuidString: raw),
          raw.uppercased() == id.uuidString else {
        throw ConfigurationError.invalid("INVALID_ARGUMENT: A canonical job_id is required.")
    }
    return id
}

struct ACTAInspectDescriptionJobsAction: ACTAActionProtocol {
    let id = "description_jobs.inspect"
    let title = "Inspect recent description jobs"
    let description = "List authorized recent description job statuses without payloads, results, errors or camera details."
    let classification = ACTAActionClassification.inspect
    let parameters: [ACTAActionParameterSchema] = []
    let service: ACTADescriptionJobService

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown parameter.") }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        do {
            let jobs = try await service.recent(context: context)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let json = String(decoding: try encoder.encode(jobs), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Recent authorized description jobs.", outputJSON: json)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(actionID: id, error: "UNAVAILABLE: Description job inspection is unavailable or unauthorized.")
        }
    }
}

struct ACTARetryDescriptionJobAction: ACTAPreparedConfirmationAction {
    let id = "description_jobs.retry"
    let title = "Retry a failed description job"
    let description = "With operator confirmation, retry the reviewed failed description job if its state and policy are unchanged."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [ACTAActionParameterSchema(name: "job_id", type: "string", description: "Description job UUID", isRequired: true)]
    let service: ACTADescriptionJobService

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }
    func validate(parameters: [String: String]) throws { _ = try descriptionJobID(parameters) }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAPreparedConfirmation<ACTADescriptionJobSnapshot> {
        let snapshot = try await service.snapshot(id: descriptionJobID(parameters), context: context)
        return ACTAPreparedConfirmation(snapshot: snapshot,
            reviewSummary: "Retry failed description job \(snapshot.job.id.uuidString), attempt count \(snapshot.job.attempts). This can run description processing.")
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepared operator confirmation is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ACTADescriptionJobSnapshot) async throws -> ACTAActionResult {
        let jobID = try descriptionJobID(parameters)
        guard context.isConfirmed, jobID == snapshot.job.id, snapshot.job.status == .failed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Reviewed job confirmation is required.")
        }
        do {
            try await service.retry(snapshot, context: context)
            return ACTAActionResult(actionID: id, success: true, summary: "Description job retry recorded and verified.")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(actionID: id, error: "RETRY_NOT_VERIFIED: Retry was rejected or could not be verified; reconcile before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard context.isConfirmed else { return false }
        return try await service.verify(id: descriptionJobID(parameters), context: context)
    }
}
