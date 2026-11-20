import CameraCore
import Foundation

struct WallAIConfigAction: ACTAActionProtocol {
    let id = "settings.update_ai_config"
    let title = "Update AI language (resets schedule and may prepare models)"
    let description = "Change the AI analytics prompt language using the settings save workflow, which may prepare models and reset the schedule. Backend, endpoints, models, credentials, speech, privacy and budgets are not supported by this action."
    let classification = ACTAActionClassification.securitySensitive
    unowned let model: WallModel
    let parameters = [
        ACTAActionParameterSchema(name: "language", type: "string",
            description: "AI analytics prompt language: ru, en, or he",
            isRequired: true, allowedValues: ACTAPromptLanguage.allCases.map(\.rawValue))
    ]

    private func language(_ parameters: [String: String]) throws -> ACTAPromptLanguage {
        guard parameters.count == 1, let raw = parameters["language"],
              let value = ACTAPromptLanguage(rawValue: raw) else {
            throw ConfigurationError.invalid("Specify exactly one supported AI analytics language: ru, en, or he.")
        }
        return value
    }

    func validate(parameters: [String: String]) throws { _ = try language(parameters) }

    @MainActor private func checkedState() throws -> (VLMPreferences, ACTAAIClient) {
        guard let client = model.actaAnalytics?.aiClient else {
            throw ConfigurationError.invalid("AI client is unavailable.")
        }
        let current = model.vlmPreferences
        let policy = try model.featurePolicySnapshotChecked()
        guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == current,
              client.configuration() == model.expectedACTAAIConfiguration(for: current, featurePreferences: policy) else {
            throw ConfigurationError.invalid("AI preferences, feature policy or runtime configuration changed; reload them before making changes.")
        }
        return (current, client)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try language(parameters)
        guard context.isConfirmed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            let (current, client) = try checkedState()
            var next = current
            next.actaPreferredLanguage = value
            try next.validate()
            try model.saveVLMPreferences(next)
            let policy = try model.featurePolicySnapshotChecked()
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == next,
                  model.vlmPreferences == next,
                  client.configuration() == model.expectedACTAAIConfiguration(for: next, featurePreferences: policy) else {
                throw ConfigurationError.invalid("AI language persistence or runtime verification failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "AI analytics language saved and verified for future requests.",
                outputJSON: "{\"language\":\"\(value.rawValue)\"}")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let value = try language(parameters)
        return try await MainActor.run {
            let (current, _) = try checkedState()
            return current.actaPreferredLanguage == value
        }
    }
}
