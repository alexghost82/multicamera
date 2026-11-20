import CameraCore
import Foundation

/// Model input selects only a camera. The destination and reviewed JPEG come
/// exclusively from the trusted local selector.
actor ACTAAgentFrameExportAction: ACTAPreparedConfirmationAction {
    typealias Review = @Sendable (UUID, any ACTASnapshotFrameProvider) async throws -> ACTAReviewedCameraFrame

    struct Snapshot: Sendable {
        fileprivate let owner: UUID
        fileprivate let ticket: ACTAReviewedFileExportAction.Ticket
        fileprivate let cameraID: UUID
        fileprivate let threadID: String
        fileprivate let frame: ACTASnapshotFrame
        fileprivate let fileAction: ACTAReviewedFileExportAction
        fileprivate let fileSnapshot: ACTAReviewedFileExportAction.Snapshot
    }

    private struct FrozenSelection: ACTAReviewedFileSelector {
        let selection: ACTAReviewedFileSelection
        func selectAndReview() async throws -> ACTAReviewedFileSelection { selection }
    }

    private struct Receipt {
        let cameraID: UUID
        let threadID: String
        let issuedAt: TimeInterval
        let action: ACTAReviewedFileExportAction
    }

    nonisolated let id = "camera.snapshot"
    nonisolated let title = "Save a camera snapshot"
    nonisolated let description = "Capture a camera frame; the operator chooses the destination and reviews the complete JPEG locally."
    nonisolated let classification = ACTAActionClassification.serviceAffecting
    nonisolated let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID", isRequired: true)
    ]

    private let owner = UUID()
    private let frames: any ACTASnapshotFrameProvider
    private let review: Review
    private let now: @Sendable () -> TimeInterval
    private let language: @Sendable () -> AppLanguage
    private var preparing = false
    private var busy = false
    private var receipt: Receipt?

    init(frames: any ACTASnapshotFrameProvider,
         review: @escaping Review = { cameraID, frames in
             try await ACTAReviewedFrameExportSelector(cameraID: cameraID, frames: frames).selectAndReviewFrame()
         },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         language: @escaping @Sendable () -> AppLanguage = { AppLanguage.current }) {
        self.frames = frames
        self.review = review
        self.now = now
        self.language = language
    }

    nonisolated func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    nonisolated func validate(parameters: [String: String]) throws {
        _ = try cameraID(parameters)
    }

    private nonisolated func cameraID(_ parameters: [String: String]) throws -> UUID {
        guard parameters.count == 1, let raw = parameters["camera_id"], let value = UUID(uuidString: raw),
              raw.lowercased() == value.uuidString.lowercased() else {
            throw ACTASnapshotActionError.invalidArguments
        }
        return value
    }

    private nonisolated func isFresh(_ frame: ACTASnapshotFrame, at instant: TimeInterval) -> Bool {
        frame.capturedUptime.isFinite && frame.selectedUptime.isFinite && instant.isFinite
            && frame.capturedUptime >= 0 && frame.selectedUptime >= frame.capturedUptime
            && frame.selectedUptime - frame.capturedUptime <= 2
            && instant >= frame.selectedUptime && instant - frame.selectedUptime < 300
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<Snapshot> {
        let camera = try cameraID(parameters)
        guard !preparing, !context.threadID.isEmpty else { throw ACTASnapshotActionError.invalidPreparation }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        let startedAt = now()
        guard startedAt.isFinite, startedAt >= 0 else { throw ACTASnapshotActionError.staleFrame }
        let selected = try await review(camera, frames)
        try Task.checkCancellation()
        let captured = selected.frame
        let frame = ACTASnapshotFrame(cameraID: captured.cameraID, frameID: captured.frameID,
                                      capturedUptime: captured.capturedUptime,
                                      selectedUptime: captured.selectedUptime, jpeg: Data([UInt8](captured.jpeg)))
        guard frame.cameraID == camera, frame.selectedUptime >= startedAt, isFresh(frame, at: now()),
              selected.selection.kind == .cameraFrame, selected.selection.bytes == frame.jpeg else {
            throw ACTASnapshotActionError.staleFrame
        }
        let preview = try ACTAFrameExportPreview(jpeg: frame.jpeg)
        guard preview.bytes == selected.selection.bytes, try await frames.isCaptureValid(frame) else {
            throw ACTASnapshotActionError.staleFrame
        }
        try Task.checkCancellation()
        let selection = ACTAReviewedFileSelection(kind: .cameraFrame, bytes: preview.bytes,
                                                  destination: selected.selection.destination)
        let fileAction = ACTAReviewedFileExportAction(kind: .cameraFrame,
            selector: FrozenSelection(selection: selection), now: now)
        let prepared = try await fileAction.prepareConfirmation(parameters: [:], context: context)
        try Task.checkCancellation()
        guard isFresh(frame, at: now()), try await frames.isCaptureValid(frame) else {
            throw ACTASnapshotActionError.staleFrame
        }
        try Task.checkCancellation()
        guard isFresh(frame, at: now()) else { throw ACTASnapshotActionError.staleFrame }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let path = String(decoding: try encoder.encode(selection.destination.path), as: UTF8.self)
        let summary = language().localized(
            "Camera frame, camera=%@, frame=%@, destination=%@, bytes=%@, sha256=%@. Full content reviewed locally. Create only; no replacement.",
            arguments: [camera.uuidString, frame.frameID.uuidString, path, String(preview.bytes.count), preview.digest])
        return .init(snapshot: Snapshot(owner: owner, ticket: .init(), cameraID: camera, threadID: context.threadID,
                                        frame: frame, fileAction: fileAction, fileSnapshot: prepared.snapshot),
                     reviewSummary: summary)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Local review is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: Snapshot) async throws -> ACTAActionResult {
        guard snapshot.owner == owner, snapshot.ticket.consume() else {
            return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review already used.")
        }
        guard let camera = try? cameraID(parameters), camera == snapshot.cameraID,
              snapshot.frame.cameraID == camera, context.isConfirmed, context.threadID == snapshot.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request changed.")
        }
        let instant = now()
        if let receipt, !instant.isFinite || instant < receipt.issuedAt || instant - receipt.issuedAt >= 300 {
            self.receipt = nil
        }
        guard !busy, receipt == nil else {
            return .failed(actionID: id, error: "ACTION_BUSY: Publication is in progress.")
        }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        guard isFresh(snapshot.frame, at: now()) else {
            return .failed(actionID: id, error: "STALE_FRAME: The reviewed capture is no longer available.")
        }
        let valid: Bool
        do {
            valid = try await frames.isCaptureValid(snapshot.frame)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(actionID: id, error: "STALE_FRAME: The reviewed capture is no longer available.")
        }
        try Task.checkCancellation()
        guard valid, isFresh(snapshot.frame, at: now()) else {
            return .failed(actionID: id, error: "STALE_FRAME: The reviewed capture is no longer available.")
        }
        let result = try await snapshot.fileAction.executeConfirmed(parameters: [:], context: context,
                                                                     snapshot: snapshot.fileSnapshot)
        if result.success {
            receipt = Receipt(cameraID: camera, threadID: context.threadID, issuedAt: now(),
                              action: snapshot.fileAction)
        }
        return result
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let camera = try? cameraID(parameters), context.isConfirmed,
              !busy, let saved = receipt, saved.cameraID == camera, saved.threadID == context.threadID else {
            return false
        }
        receipt = nil
        busy = true
        defer { busy = false }
        return try await saved.action.verify(parameters: [:], context: context)
    }
}
