import CameraCore
import Foundation

struct ACTASystemLanguageAction: ACTAActionProtocol {
    private let systemAction: SettingsUpdateSystemAction
    private let languageSettings: LanguageSettings

    init(settingsProvider: any ACTASystemSettingsProvider, languageSettings: LanguageSettings) {
        self.systemAction = SettingsUpdateSystemAction(settingsProvider: settingsProvider)
        self.languageSettings = languageSettings
    }

    var id: String { systemAction.id }
    var title: String { systemAction.title }
    var description: String { systemAction.description + " Interface language must be updated in a separate call." }
    var classification: ACTAActionClassification { systemAction.classification }
    var parameters: [ACTAActionParameterSchema] {
        systemAction.parameters + [
            ACTAActionParameterSchema(name: "language", type: "string",
                                      description: "Interface language", allowedValues: ["en", "ru"])
        ]
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool {
        systemAction.requiresConfirmation(parameters: withoutLanguage(parameters))
    }

    func validate(parameters: [String: String]) throws {
        if let value = parameters["language"], AppLanguage(rawValue: value) == nil {
            throw ConfigurationError.invalid("Invalid interface language.")
        }
        if parameters["language"] != nil, !withoutLanguage(parameters).isEmpty {
            throw ConfigurationError.invalid("Update interface language separately from other system settings.")
        }
        try systemAction.validate(parameters: withoutLanguage(parameters))
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let value = parameters["language"] else {
            return try await systemAction.execute(parameters: parameters, context: context)
        }
        guard let language = AppLanguage(rawValue: value) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Invalid interface language.")
        }
        try validate(parameters: parameters)
        await MainActor.run { languageSettings.setLanguage(language) }
        return ACTAActionResult(actionID: id, success: true,
                                summary: "Interface language updated: \(value)",
                                outputJSON: "{\"updated\": true}")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let value = parameters["language"] else {
            return try await systemAction.verify(parameters: parameters, context: context)
        }
        guard let language = AppLanguage(rawValue: value) else { return false }
        let systemParameters = withoutLanguage(parameters)
        if !systemParameters.isEmpty,
           try await systemAction.verify(parameters: systemParameters, context: context) == false { return false }
        return await MainActor.run {
            languageSettings.language == language && languageSettings.storedLanguage == value
        }
    }

    private func withoutLanguage(_ parameters: [String: String]) -> [String: String] {
        parameters.filter { $0.key != "language" }
    }
}
