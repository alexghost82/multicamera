import CameraCore
import Foundation

/// Implementations must atomically compare the complete review snapshot with recovery.
protocol ACTACameraMemoryRecoveryBackend: Sendable {
    func snapshot() async throws -> CameraMemoryRecoverySnapshot
    func recover(_ snapshot: CameraMemoryRecoverySnapshot) async throws
    func verify(_ snapshot: CameraMemoryRecoverySnapshot) async throws -> Bool
    /// Registry verification has no snapshot argument; this must still prove that
    /// the reviewed paths remain absent, without confusing concurrent receipts.
    func verifyCurrentState() async throws -> Bool
}

struct ACTACameraMemoryRecoveryUnavailableBackend: ACTACameraMemoryRecoveryBackend {
    let store: CameraMemoryStore

    func snapshot() async throws -> CameraMemoryRecoverySnapshot { try store.recoverySnapshot() }
    func recover(_ snapshot: CameraMemoryRecoverySnapshot) async throws {
        throw ACTACameraMemoryRecoveryError.unsafeWriterIsolation
    }
    func verify(_ snapshot: CameraMemoryRecoverySnapshot) async throws -> Bool { false }
    func verifyCurrentState() async throws -> Bool { false }
}

enum ACTACameraMemoryRecoveryError: Error {
    case unsafeWriterIsolation
}

struct ACTACameraMemoryRecoveryAction: ACTAPreparedConfirmationAction {
    let backend: any ACTACameraMemoryRecoveryBackend
    let id = "memory.resume_frame_deletion"
    let title = "Resume interrupted memory frame deletion"
    let description = "Resume only the reviewed, previously journaled memory frame deletion."
    let classification = ACTAActionClassification.destructive
    let parameters: [ACTAActionParameterSchema] = []

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown parameter.") }
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<CameraMemoryRecoverySnapshot> {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let snapshot = try await backend.snapshot()
        try Task.checkCancellation()
        let present = Set(snapshot.presentFrameIDs)
        let formatter = ISO8601DateFormatter()
        let rows = snapshot.frames.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            "frame=\($0.id.uuidString), camera=\($0.cameraID.uuidString), captured=\(formatter.string(from: $0.capturedAt)), indexed_bytes=\($0.fileSize), path=\(present.contains($0.id) ? "present" : "missing")"
        }
        let totalBytes = snapshot.frames.reduce(0) { $0 + $1.fileSize }
        let summary = "Resume the journaled deletion of \(snapshot.frames.count) frames "
            + "(\(totalBytes) indexed bytes); \(snapshot.presentFrameIDs.count) reviewed paths currently exist. "
            + "Missing paths may already have been deleted. " + rows.joined(separator: "; ")
        return ACTAPreparedConfirmation(snapshot: snapshot, reviewSummary: summary)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: A prepared operator confirmation is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: CameraMemoryRecoverySnapshot) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard context.isConfirmed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
        }
        try Task.checkCancellation()
        do {
            try await backend.recover(snapshot)
            guard try await backend.verify(snapshot) else {
                return .failed(actionID: id, error: "PARTIAL_FAILURE: Recovery could not be verified; reconcile memory before retrying.")
            }
            return ACTAActionResult(actionID: id, success: true,
                                    summary: "Reviewed memory deletion recovered and verified.")
        } catch ACTACameraMemoryRecoveryError.unsafeWriterIsolation {
            return .failed(actionID: id, error: "UNAVAILABLE: Memory writer isolation is not guaranteed; nothing was recovered.")
        } catch CameraMemoryStoreError.snapshotChanged {
            return .failed(actionID: id, error: "CONFLICT: The journal or memory changed since review; nothing was recovered.")
        } catch {
            return .failed(actionID: id, error: "PARTIAL_FAILURE: Recovery may have changed memory; reconcile before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try validate(parameters: parameters)
        guard context.isConfirmed else { return false }
        return try await backend.verifyCurrentState()
    }
}
