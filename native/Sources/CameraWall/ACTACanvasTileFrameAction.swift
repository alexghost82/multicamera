import CameraCore
import Foundation

// Not registered: advisory locking cannot coordinate legacy layout writers or
// gestures in other processes. The provider below is safe only for cooperating writers.
@MainActor
protocol ACTACanvasTileFrameTransaction: AnyObject {
    // Validate the target and gesture state, then persist and publish a layout.
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
final class ACTACanvasTileFrameProvider: ACTACanvasTileFrameTransaction {
    private weak var model: WallModel?
    private let gestures: ACTACanvasGestureTracker
    private struct Receipt {
        let id: UUID
        let cameraID: UUID
        let frame: VideoTileFrame
        let snapshot: ACTACanvasLayoutStore.Snapshot
        let lifecycleRevision: UUID
    }
    private var receipt: Receipt?

    init(model: WallModel, gestures: ACTACanvasGestureTracker? = nil) {
        self.model = model
        self.gestures = gestures ?? .shared
    }

    private func targetAvailable(_ id: UUID, in model: WallModel) -> Bool {
        guard model.canvasFilterBridge.activeState != nil,
              let config = try? model.cameraConfigurationChecked() else { return false }
        let matches = config.cameras.filter { $0.id == id }
        return matches.count == 1 && matches[0].enabled
    }

    func setFrame(_ frame: VideoTileFrame, for cameraID: UUID) -> ACTACanvasTileFrameOutcome {
        receipt = nil
        guard frame.isValid, let model, targetAvailable(cameraID, in: model) else { return .unavailable }
        guard !gestures.hasActiveGestures else { return .busy }
        guard let base = model.canvasLayoutSnapshot, model.layout == base.layout else { return .conflict }
        var next = base.layout
        next.frames[cameraID.uuidString] = frame
        do {
            let snapshot = try ACTACanvasLayoutStore(url: model.layoutURL).commit(next, expected: base)
            model.publishCanvasLayout(snapshot)
            let id = UUID()
            receipt = Receipt(id: id, cameraID: cameraID, frame: frame, snapshot: snapshot,
                              lifecycleRevision: model.canvasFilterBridge.lifecycleRevision)
            return .written(id)
        } catch ACTACanvasLayoutStore.Failure.busy {
            return .busy
        } catch ACTACanvasLayoutStore.Failure.conflict {
            return .conflict
        } catch {
            return .failed
        }
    }

    func verifies(_ id: UUID, frame: VideoTileFrame, for cameraID: UUID) -> Bool {
        guard let model, let receipt, receipt.id == id, receipt.cameraID == cameraID,
              receipt.frame == frame, !gestures.hasActiveGestures,
              receipt.lifecycleRevision == model.canvasFilterBridge.lifecycleRevision,
              targetAvailable(cameraID, in: model),
              model.canvasLayoutSnapshot == receipt.snapshot,
              model.layout == receipt.snapshot.layout,
              receipt.snapshot.layout.frames[cameraID.uuidString] == frame,
              let persisted = try? ACTACanvasLayoutStore(url: model.layoutURL).read() else { return false }
        return persisted == receipt.snapshot
    }
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
