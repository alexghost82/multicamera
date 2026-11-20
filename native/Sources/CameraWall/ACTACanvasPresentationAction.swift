import CameraCore
import Foundation

struct ACTACanvasSetPresentationAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let lifecycleRevision: UUID
        let stateRevision: UUID
        let previousMode: String
        let parameters: [String: String]
        let threadID: String
    }
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

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let requested = try mode(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                throw ConfigurationError.invalid("UNAVAILABLE: No unique active security center.")
            }
            let previous = state.presentation.rawValue
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(lifecycleRevision: bridge.lifecycleRevision,
                                               stateRevision: state.reviewRevision, previousMode: previous,
                                               parameters: parameters, threadID: context.threadID),
                reviewSummary: "Unique active security center: change camera presentation from \(previous) to \(requested.rawValue).")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let value = try mode(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearPresentationWrite()
            guard context.isConfirmed, parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            guard bridge.lifecycleRevision == snapshot.lifecycleRevision, let state = bridge.activeState,
                  state.reviewRevision == snapshot.stateRevision, state.presentation.rawValue == snapshot.previousMode,
                  let revision = state.commitReviewed(expectedRevision: snapshot.stateRevision, isValid: {
                      !Task.isCancelled && bridge.lifecycleRevision == snapshot.lifecycleRevision && bridge.activeState === state
                  }, update: { $0.presentation = value }),
                  state.reviewRevision == revision, state.presentation == value,
                  bridge.lifecycleRevision == snapshot.lifecycleRevision, bridge.activeState === state else {
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Camera presentation or window changed.")
            }
            bridge.recordPresentationWrite(to: state)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera presentation state updated in this window; rendering was not verified.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try mode(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearPresentationWrite()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active security center.")
            }
            let lifecycle = bridge.lifecycleRevision
            guard state.commitReviewed(expectedRevision: state.reviewRevision, isValid: {
                !Task.isCancelled && bridge.lifecycleRevision == lifecycle && bridge.activeState === state
            }, update: { $0.presentation = value }) != nil else {
                bridge.clearPresentationWrite()
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Camera presentation or window changed.")
            }
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
