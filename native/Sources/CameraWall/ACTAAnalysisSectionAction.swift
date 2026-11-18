import CameraCore
import Foundation

struct ACTAAnalysisSetSectionAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let lifecycleRevision: UUID
        let previousSection: String
        let refreshOnAppear: Bool
    }
    let id = "analysis.set_section"
    let title = "Set analysis tab"
    let description = "Select Chat, Schedule, or Alerts in the unique attached security center. This window-local setting does not open the panel. Switching away from Chat is unavailable while dictation is starting or recording. Schedule jobs are not refreshed by this action. Verification checks state, not rendering."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "section", type: "string", description: "Analysis tab",
                                  isRequired: true, allowedValues: ["chat", "schedule", "alerts"])
    ]
    let bridge: ACTACanvasFilterBridge

    private func section(_ parameters: [String: String]) throws -> VLMPanelSection {
        guard Set(parameters.keys) == ["section"] else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide section.")
        }
        switch parameters["section"] {
        case "chat": return .ask
        case "schedule": return .schedule
        case "alerts": return .alerts
        default: throw ConfigurationError.invalid("INVALID_ARGUMENT: section must be chat, schedule, or alerts.")
        }
    }

    func validate(parameters: [String: String]) throws {
        _ = try section(parameters)
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let value = try section(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                throw ConfigurationError.invalid("UNAVAILABLE: No unique active security center.")
            }
            guard state.analysisSection == value || state.analysisSection != .ask || !state.analysisVoiceBusy else {
                throw ConfigurationError.invalid("UNAVAILABLE: Dictation is starting or recording.")
            }
            let refreshEffect = state.analysisSection != value && value == .schedule
                ? " Schedule refresh on appearance will be disabled." : ""
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(lifecycleRevision: bridge.lifecycleRevision,
                    previousSection: state.analysisSection.rawValue,
                    refreshOnAppear: state.analysisScheduleRefreshOnAppear),
                reviewSummary: "Unique active security center: change analysis tab from \(state.analysisSection.rawValue) to \(value.rawValue).\(refreshEffect) The panel is not opened.")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let value = try section(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard bridge.lifecycleRevision == snapshot.lifecycleRevision, let state = bridge.activeState,
                  state.analysisSection.rawValue == snapshot.previousSection,
                  state.analysisScheduleRefreshOnAppear == snapshot.refreshOnAppear else {
                return .failed(actionID: id, error: "STALE_REVIEW: Analysis tab or window changed.")
            }
            guard state.analysisSection == value || state.analysisSection != .ask || !state.analysisVoiceBusy else {
                return .failed(actionID: id, error: "UNAVAILABLE: Dictation is starting or recording.")
            }
            if state.analysisSection != value {
                if value == .schedule { state.analysisScheduleRefreshOnAppear = false }
                state.analysisSection = value
            }
            bridge.recordAnalysisWrite(to: state, section: value)
            guard state.analysisSection == value else {
                return .failed(actionID: id, error: "Analysis tab state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Analysis tab state updated in this window; rendering was not verified.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try section(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active security center.")
            }
            guard state.analysisSection == value || state.analysisSection != .ask || !state.analysisVoiceBusy else {
                return .failed(actionID: id, error: "UNAVAILABLE: Dictation is starting or recording.")
            }
            if state.analysisSection != value {
                if value == .schedule { state.analysisScheduleRefreshOnAppear = false }
                state.analysisSection = value
            }
            bridge.recordAnalysisWrite(to: state, section: value)
            guard state.analysisSection == value else {
                return .failed(actionID: id, error: "Analysis tab state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Analysis tab state updated in this window; rendering was not verified.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let value = try section(parameters)
        return await MainActor.run { bridge.verifiesAnalysisSection(value) }
    }
}
