import CameraCore
import Foundation

// This action is deliberately not registered. A production provider must coordinate
// every layout writer, including other processes, and all unfinished GUI gestures.
@MainActor
protocol ACTACanvasTileFrameTransaction: AnyObject {
    // Atomically validate the target and gesture state, merge with the latest layout,
    // persist it, and publish the same runtime layout. Failure must leave both
    // runtime and durable state unchanged, including on partial I/O failure.
    func setFrame(_ frame: VideoTileFrame, for cameraID: UUID) -> ACTACanvasTileFrameOutcome

    // Check the receipt and both runtime and persisted state under the same coordination.
    func verifies(_ receipt: UUID, frame: VideoTileFrame, for cameraID: UUID) -> Bool
}

enum ACTACanvasTileFrameOutcome {
    case written(UUID)
    case busy
    case unavailable
    case conflict
    case failed
}

@MainActor
final class ACTACanvasTileFrameActionState {
    let transaction: any ACTACanvasTileFrameTransaction
    let gestures: ACTACanvasGestureTracker
    var receipt: (id: UUID, cameraID: UUID, frame: VideoTileFrame)?

    init(transaction: any ACTACanvasTileFrameTransaction, gestures: ACTACanvasGestureTracker? = nil) {
        self.transaction = transaction
        self.gestures = gestures ?? .shared
    }
}

struct ACTACanvasSetTileFrameAction: ACTAActionProtocol {
    let id = "canvas.set_tile_frame"
    let title = "Set camera tile frame"
    let description = "Set the saved frame for an enabled camera; verification checks the coordinated runtime and persisted layout, not rendering."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Enabled camera UUID", isRequired: true),
        ACTAActionParameterSchema(name: "x", type: "number", description: "Left coordinate", isRequired: true),
        ACTAActionParameterSchema(name: "y", type: "number", description: "Top coordinate", isRequired: true),
        ACTAActionParameterSchema(name: "width", type: "number", description: "Tile width", isRequired: true),
        ACTAActionParameterSchema(name: "height", type: "number", description: "Tile height", isRequired: true)
    ]
    let state: ACTACanvasTileFrameActionState

    private func parse(_ parameters: [String: String]) throws -> (UUID, VideoTileFrame) {
        guard Set(parameters.keys) == ["camera_id", "x", "y", "width", "height"],
              let rawID = parameters["camera_id"], let cameraID = UUID(uuidString: rawID),
              let x = parameters["x"].flatMap(Double.init),
              let y = parameters["y"].flatMap(Double.init),
              let width = parameters["width"].flatMap(Double.init),
              let height = parameters["height"].flatMap(Double.init) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide a camera UUID and complete numeric frame.")
        }
        let frame = VideoTileFrame(x: x, y: y, width: width, height: height)
        guard frame.isValid else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Tile frame is outside supported bounds.")
        }
        return (cameraID, frame)
    }

    func validate(parameters: [String: String]) throws {
        _ = try parse(parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let (cameraID, frame) = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            state.receipt = nil
            guard !state.gestures.hasActiveGestures else {
                return .failed(actionID: id, error: "ACTION_BUSY: A layout gesture is in progress.")
            }
            switch state.transaction.setFrame(frame, for: cameraID) {
            case .written(let receipt):
                state.receipt = (receipt, cameraID, frame)
                guard state.transaction.verifies(receipt, frame: frame, for: cameraID) else {
                    state.receipt = nil
                    return .failed(actionID: id, error: "Tile frame readback failed.")
                }
                return ACTAActionResult(actionID: id, success: true,
                    summary: "Saved tile frame updated; rendering was not verified.")
            case .busy:
                return .failed(actionID: id, error: "ACTION_BUSY: A layout gesture or write is in progress.")
            case .unavailable:
                return .failed(actionID: id, error: "UNAVAILABLE: Camera or coordinated layout is unavailable.")
            case .conflict:
                return .failed(actionID: id, error: "CONFLICT: Layout changed; retry with current state.")
            case .failed:
                return .failed(actionID: id, error: "Could not save tile frame.")
            }
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let (cameraID, frame) = try parse(parameters)
        return await MainActor.run {
            guard let receipt = state.receipt, receipt.cameraID == cameraID, receipt.frame == frame else { return false }
            return state.transaction.verifies(receipt.id, frame: frame, for: cameraID)
        }
    }
}
