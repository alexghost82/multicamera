import CameraCore
import Foundation

/// A backend must make the freshness check and deletion one indivisible operation.
protocol ACTACameraMemoryClearBackend: Sendable {
    func snapshot() async throws -> CameraMemoryDeletionSnapshot
    func clear(_ snapshot: CameraMemoryDeletionSnapshot) async throws
    func verify(_ snapshot: CameraMemoryDeletionSnapshot) async throws -> Bool
    /// Registry verification has no snapshot argument. This must conservatively
    /// establish that no reviewed path has reappeared, not just check the index.
    func verifyCurrentState() async throws -> Bool
}

/// The existing store lock cannot exclude older writers that do not cooperate with it.
/// Keep the production backend disabled until those writers and replacement races are addressed.
struct ACTACameraMemoryClearUnavailableBackend: ACTACameraMemoryClearBackend {
    let store: CameraMemoryStore

    func snapshot() async throws -> CameraMemoryDeletionSnapshot {
        try store.deletionSnapshot()
    }

    func clear(_ snapshot: CameraMemoryDeletionSnapshot) async throws {
        throw ACTACameraMemoryClearError.unsafeWriterIsolation
    }

    func verify(_ snapshot: CameraMemoryDeletionSnapshot) async throws -> Bool { false }
    func verifyCurrentState() async throws -> Bool { false }
}

enum ACTACameraMemoryClearError: Error {
    case unsafeWriterIsolation
}

struct ACTACameraMemoryClearAction: ACTAPreparedConfirmationAction {
    let backend: any ACTACameraMemoryClearBackend
    let id = "memory.clear_all_frames"
    let title = "Clear all sampled memory frames"
    let description = "Permanently delete the reviewed indexed memory frames."
    let classification = ACTAActionClassification.destructive
    let parameters: [ACTAActionParameterSchema] = []

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown parameter.") }
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<CameraMemoryDeletionSnapshot> {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let snapshot = try await backend.snapshot()
        try Task.checkCancellation()
        let formatter = ISO8601DateFormatter()
        let rows = snapshot.frames.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            "frame=\($0.id.uuidString), camera=\($0.cameraID.uuidString), captured=\(formatter.string(from: $0.capturedAt)), indexed_bytes=\($0.fileSize)"
        }
        let totalBytes = snapshot.frames.reduce(0) { $0 + $1.fileSize }
        let summary = "Delete \(snapshot.count) indexed frames (\(totalBytes) indexed bytes). "
            + "Unindexed files are excluded; indexed image presence is not checked. "
            + (rows.isEmpty ? "The indexed set is empty." : rows.joined(separator: "; "))
        return ACTAPreparedConfirmation(snapshot: snapshot, reviewSummary: summary)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: A prepared operator confirmation is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: CameraMemoryDeletionSnapshot) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard context.isConfirmed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
        }
        try Task.checkCancellation()
        do {
            try await backend.clear(snapshot)
            guard try await backend.verify(snapshot) else {
                return .failed(actionID: id, error: "PARTIAL_FAILURE: Deletion could not be verified; reconcile memory before retrying.")
            }
            return ACTAActionResult(actionID: id, success: true,
                                    summary: "Reviewed indexed memory frames cleared and verified.")
        } catch ACTACameraMemoryClearError.unsafeWriterIsolation {
            return .failed(actionID: id, error: "UNAVAILABLE: Memory writer isolation is not guaranteed; nothing was cleared.")
        } catch CameraMemoryStoreError.snapshotChanged {
            return .failed(actionID: id, error: "CONFLICT: Memory changed since review; nothing was cleared.")
        } catch CameraMemoryStoreError.recoveryRequired {
            return .failed(actionID: id, error: "RECOVERY_REQUIRED: Resolve the pending memory deletion first.")
        } catch {
            return .failed(actionID: id, error: "PARTIAL_FAILURE: Memory may have changed; reconcile before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try validate(parameters: parameters)
        guard context.isConfirmed else { return false }
        return try await backend.verifyCurrentState()
    }
}
