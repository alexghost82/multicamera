import CameraCore
import Foundation

struct ACTACanvasSetArrangeModeAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let lifecycleRevision: UUID
        let stateRevision: UUID
        let previous: Bool
        let parameters: [String: String]
        let threadID: String
    }
    let id = "canvas.set_arrange_mode"
    let title = "Set camera arrange mode"
    let description = "Set the Arrange cameras toggle in the unique attached security center. This window-local setting is not persisted; saved tile frames are used only in the grid when no camera is expanded. Verification checks the toggle state, not rendering or saved frames."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "Enable camera arrangement", isRequired: true)
    ]
    let bridge: ACTACanvasFilterBridge

    private func enabled(_ parameters: [String: String]) throws -> Bool {
        guard Set(parameters.keys) == ["enabled"] else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide enabled.")
        }
        switch parameters["enabled"] {
        case "true": return true
        case "false": return false
        default: throw ConfigurationError.invalid("INVALID_ARGUMENT: enabled must be a boolean.")
        }
    }

    func validate(parameters: [String: String]) throws {
        _ = try enabled(parameters)
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let requested = try enabled(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                throw ConfigurationError.invalid("UNAVAILABLE: No unique active security center.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(lifecycleRevision: bridge.lifecycleRevision,
                                               stateRevision: state.reviewRevision, previous: state.arrangeCameras,
                                               parameters: parameters, threadID: context.threadID),
                reviewSummary: "Unique active security center: change arrange mode from \(state.arrangeCameras) to \(requested). Saved tile frames are not changed.")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let value = try enabled(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearArrangeWrite()
            guard context.isConfirmed, parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            guard bridge.lifecycleRevision == snapshot.lifecycleRevision, let state = bridge.activeState,
                  state.reviewRevision == snapshot.stateRevision, state.arrangeCameras == snapshot.previous,
                  let revision = state.commitReviewed(expectedRevision: snapshot.stateRevision, isValid: {
                      !Task.isCancelled && bridge.lifecycleRevision == snapshot.lifecycleRevision && bridge.activeState === state
                  }, update: { $0.arrangeCameras = value }),
                  state.reviewRevision == revision, state.arrangeCameras == value,
                  bridge.lifecycleRevision == snapshot.lifecycleRevision, bridge.activeState === state else {
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Arrange mode or window changed.")
            }
            bridge.recordArrangeWrite(to: state)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Arrange toggle updated in this window; rendering and saved frames were not verified.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try enabled(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearArrangeWrite()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active security center.")
            }
            let lifecycle = bridge.lifecycleRevision
            guard state.commitReviewed(expectedRevision: state.reviewRevision, isValid: {
                !Task.isCancelled && bridge.lifecycleRevision == lifecycle && bridge.activeState === state
            }, update: { $0.arrangeCameras = value }) != nil else {
                bridge.clearArrangeWrite()
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Arrange mode or window changed.")
            }
            bridge.recordArrangeWrite(to: state)
            guard state.arrangeCameras == value else {
                return .failed(actionID: id, error: "Arrange mode state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Arrange toggle updated in this window; rendering and saved frames were not verified.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let value = try enabled(parameters)
        return await MainActor.run {
            bridge.arrangeWrittenActiveState?.arrangeCameras == value
        }
    }
}
