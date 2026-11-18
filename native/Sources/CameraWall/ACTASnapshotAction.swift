import CameraCore
import CryptoKit
import Foundation

struct ACTASnapshotFrame: Sendable {
    let cameraID: UUID
    let frameID: UUID
    let capturedUptime: TimeInterval
    let jpeg: Data
}

protocol ACTASnapshotFrameProvider: Sendable {
    func captureFreshFrame(cameraID: UUID) async throws -> ACTASnapshotFrame
}

/// Implementations must serialize publication and verification for the exact
/// request, and only publish in a namespace protected against replacement.
protocol ACTASnapshotPublicationBackend: Sendable {
    func prepare(cameraID: UUID, jpeg: Data, destination: String) async throws -> ACTASnapshotExportFoundation.Request
    func cancel(_ request: ACTASnapshotExportFoundation.Request) async
    func publish(_ request: ACTASnapshotExportFoundation.Request) async throws
    func verify(_ request: ACTASnapshotExportFoundation.Request) async throws -> Bool
    func verifyCurrent(cameraID: UUID, destination: String) async throws -> Bool
}

enum ACTASnapshotActionError: Error {
    case invalidArguments
    case staleFrame
    case invalidPreparation
    case unsafePublication
}

/// The current publisher cannot exclude concurrent ancestor renames or ensure
/// that a failed write leaves no ambiguous file. Never invoke it in production.
struct ACTASnapshotUnavailablePublisher: ACTASnapshotPublicationBackend {
    let foundation: ACTASnapshotExportFoundation

    func prepare(cameraID: UUID, jpeg: Data, destination: String) async throws -> ACTASnapshotExportFoundation.Request {
        try await foundation.prepareForPublication(cameraID: cameraID, jpeg: jpeg, destinationPath: destination)
    }

    func cancel(_ request: ACTASnapshotExportFoundation.Request) async {
        await foundation.cancel(token: request.token)
    }

    func publish(_ request: ACTASnapshotExportFoundation.Request) async throws {
        await cancel(request)
        throw ACTASnapshotActionError.unsafePublication
    }

    func verify(_ request: ACTASnapshotExportFoundation.Request) async throws -> Bool { false }
    func verifyCurrent(cameraID: UUID, destination: String) async throws -> Bool { false }
}

struct ACTASnapshotAction: ACTAPreparedConfirmationAction {
    struct Snapshot: Sendable {
        let frameID: UUID
        let capturedUptime: TimeInterval
        let request: ACTASnapshotExportFoundation.Request
    }

    let frames: any ACTASnapshotFrameProvider
    let publisher: any ACTASnapshotPublicationBackend
    let now: @Sendable () -> TimeInterval

    init(frames: any ACTASnapshotFrameProvider, publisher: any ACTASnapshotPublicationBackend,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.frames = frames
        self.publisher = publisher
        self.now = now
    }

    let id = "camera.snapshot"
    let title = "Save a camera snapshot"
    let description = "Review the exact captured frame and destination before saving a JPEG without overwriting."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID", isRequired: true),
        ACTAActionParameterSchema(name: "destination_path", type: "string",
                                  description: "Absolute JPEG destination", isRequired: true)
    ]

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    private func parse(_ parameters: [String: String]) throws -> (UUID, String) {
        guard Set(parameters.keys) == Set(["camera_id", "destination_path"]),
              let rawCamera = parameters["camera_id"], let camera = UUID(uuidString: rawCamera),
              let path = parameters["destination_path"], path.utf8.count <= 512,
              path.hasPrefix("/"), path.utf8.allSatisfy({ (32...126).contains($0) && $0 != 92 }),
              path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg"),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ACTASnapshotActionError.invalidArguments
        }
        return (camera, path)
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<Snapshot> {
        let (camera, path) = try parse(parameters)
        try Task.checkCancellation()
        let frame = try await frames.captureFreshFrame(cameraID: camera)
        let instant = now()
        guard frame.cameraID == camera, instant.isFinite, frame.capturedUptime.isFinite,
              frame.capturedUptime >= 0, instant >= frame.capturedUptime,
              instant - frame.capturedUptime <= 2 else { throw ACTASnapshotActionError.staleFrame }
        guard frame.jpeg.count >= 4, frame.jpeg.count <= 8 * 1024 * 1024 else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        let bytes = Data([UInt8](frame.jpeg))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        let request = try await publisher.prepare(cameraID: camera, jpeg: bytes, destination: path)
        do {
            try Task.checkCancellation()
            let preview = request.preview
            let preparedAt = now()
            guard preview.cameraID == camera, preview.destinationPath == path,
                  preview.byteCount == bytes.count, preview.sha256 == digest,
                  preparedAt.isFinite, preparedAt >= frame.capturedUptime,
                  preparedAt - frame.capturedUptime <= 2,
                  let directory = preview.directoryIdentity else { throw ACTASnapshotActionError.invalidPreparation }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let encodedPath = String(decoding: try encoder.encode(path), as: UTF8.self)
            let summary = "Snapshot camera=\(camera.uuidString), frame=\(frame.frameID.uuidString), "
                + "captured_uptime=\(frame.capturedUptime), destination=\(encodedPath), "
                + "directory_device=\(directory.device), directory_inode=\(directory.inode), "
                + "bytes=\(preview.byteCount), sha256=\(preview.sha256). No overwrite."
            return ACTAPreparedConfirmation(
                snapshot: Snapshot(frameID: frame.frameID, capturedUptime: frame.capturedUptime, request: request),
                reviewSummary: summary
            )
        } catch {
            await publisher.cancel(request)
            throw error
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepared operator review is required.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: Snapshot) async throws -> ACTAActionResult {
        let (camera, path) = try parse(parameters)
        guard context.isConfirmed, snapshot.request.preview.cameraID == camera,
              snapshot.request.preview.destinationPath == path,
              snapshot.request.preview.directoryIdentity != nil else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Reviewed snapshot does not match.")
        }
        try Task.checkCancellation()
        do {
            try await publisher.publish(snapshot.request)
            guard try await publisher.verify(snapshot.request) else {
                return .failed(actionID: id, error: "VERIFICATION_FAILED: Publication could not be verified.")
            }
            return ACTAActionResult(actionID: id, success: true, summary: "Reviewed snapshot saved and verified.")
        } catch ACTASnapshotActionError.unsafePublication {
            return .failed(actionID: id, error: "UNAVAILABLE: Safe snapshot publication is not established; no file was written.")
        } catch {
            return .failed(actionID: id, error: "PUBLICATION_FAILED: Publication may be incomplete; reconcile before retrying.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let (camera, path) = try parse(parameters)
        guard context.isConfirmed else { return false }
        return try await publisher.verifyCurrent(cameraID: camera, destination: path)
    }
}
