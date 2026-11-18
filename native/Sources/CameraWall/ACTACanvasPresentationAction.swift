import CameraCore
import Foundation

struct ACTACanvasSetPresentationAction: ACTAActionProtocol {
    let id = "canvas.set_presentation"
    let title = "Set camera presentation"
    let description = "Set grid or list in the unique attached security center, even if another section is visible. This window-local setting is not persisted and does not change fullscreen or filters. Verification checks state, not rendering."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "mode", type: "string", description: "Camera presentation", isRequired: true, allowedValues: ["grid", "list"])
    ]
    let bridge: ACTACanvasFilterBridge

    private func mode(_ parameters: [String: String]) throws -> ACTACameraPresentation {
        guard Set(parameters.keys) == ["mode"], let value = parameters["mode"],
              let mode = ACTACameraPresentation(rawValue: value) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: mode must be grid or list.")
        }
        return mode
    }

    func validate(parameters: [String: String]) throws {
        _ = try mode(parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try mode(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active security center.")
            }
            state.presentation = value
            bridge.recordPresentationWrite(to: state)
            guard state.presentation == value else {
                return .failed(actionID: id, error: "Camera presentation state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera presentation state updated in this window; rendering was not verified.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let value = try mode(parameters)
        return await MainActor.run {
            bridge.presentationWrittenActiveState?.presentation == value
        }
    }
}
