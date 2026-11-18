import CameraCore
import Foundation

struct ACTACanvasSetArrangeModeAction: ACTAActionProtocol {
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

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try enabled(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active security center.")
            }
            state.arrangeCameras = value
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
