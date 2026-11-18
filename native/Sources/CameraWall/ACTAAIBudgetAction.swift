import CameraCore
import Foundation

struct WallAIBudgetAction: ACTAActionProtocol {
    let id = "settings.update_ai_budget"
    let title = "Update AI privacy and budget (resets schedule and may prepare models)"
    let description = "Patch cloud face/plate blurring and AI budget preferences after operator approval, using the settings save workflow which may prepare models and reset the schedule. This does not grant external AI permission or guarantee billing limits."
    let classification = ACTAActionClassification.securitySensitive
    unowned let model: WallModel

    let parameters = [
        ACTAActionParameterSchema(name: "blurFaces", type: "boolean", description: "Blur faces before cloud requests"),
        ACTAActionParameterSchema(name: "blurPlates", type: "boolean", description: "Blur plates before cloud requests"),
        ACTAActionParameterSchema(name: "dailyBudgetUSD", type: "number", description: "Daily AI budget in USD"),
        ACTAActionParameterSchema(name: "monthlyBudgetUSD", type: "number", description: "Monthly AI budget in USD")
    ]

    private struct Patch {
        var blurFaces: Bool?
        var blurPlates: Bool?
        var daily: Double?
        var monthly: Double?

        init(_ parameters: [String: String]) throws {
            guard !parameters.isEmpty, Set(parameters.keys).isSubset(of: ["blurFaces", "blurPlates", "dailyBudgetUSD", "monthlyBudgetUSD"]) else {
                throw ConfigurationError.invalid("Specify at least one known AI privacy or budget field.")
            }
            func boolean(_ key: String) throws -> Bool? {
                guard let value = parameters[key] else { return nil }
                switch value {
                case "true": return true
                case "false": return false
                default: throw ConfigurationError.invalid("\(key) must be a boolean.")
                }
            }
            func number(_ key: String) throws -> Double? {
                guard let value = parameters[key] else { return nil }
                guard let number = Double(value), number.isFinite, number >= 0 else {
                    throw ConfigurationError.invalid("\(key) must be a finite nonnegative number.")
                }
                return number
            }
            blurFaces = try boolean("blurFaces")
            blurPlates = try boolean("blurPlates")
            daily = try number("dailyBudgetUSD")
            monthly = try number("monthlyBudgetUSD")
        }

        func applying(to preferences: VLMPreferences) -> VLMPreferences {
            var next = preferences
            if let blurFaces { next.privacyBlurFacesInCloud = blurFaces }
            if let blurPlates { next.privacyBlurPlatesInCloud = blurPlates }
            if let daily { next.dailyBudgetLimitUSD = daily }
            if let monthly { next.monthlyBudgetLimitUSD = monthly }
            return next
        }
    }

    func validate(parameters: [String: String]) throws { _ = try Patch(parameters) }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let patch = try Patch(parameters)
        guard context.isConfirmed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let client = model.actaAnalytics?.aiClient else {
                throw ConfigurationError.invalid("AI client is unavailable.")
            }
            let current = model.vlmPreferences
            let policy = try model.featurePolicySnapshotChecked()
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == current,
                  client.configuration() == WallModel.makeACTAAIConfiguration(from: current, featurePreferences: policy) else {
                throw ConfigurationError.invalid("AI preferences or runtime configuration changed; reload them before making changes.")
            }
            let next = patch.applying(to: current)
            try next.validate()
            try model.saveVLMPreferences(next)
            let savedPolicy = try model.featurePolicySnapshotChecked()
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == next,
                  model.vlmPreferences == next,
                  client.configuration() == WallModel.makeACTAAIConfiguration(from: next, featurePreferences: savedPolicy) else {
                throw ConfigurationError.invalid("AI preferences persistence or runtime verification failed.")
            }
            let output: [String: Any] = [
                "blurFaces": next.privacyBlurFacesInCloud, "blurPlates": next.privacyBlurPlatesInCloud,
                "dailyBudgetUSD": next.dailyBudgetLimitUSD, "monthlyBudgetUSD": next.monthlyBudgetLimitUSD
            ]
            return ACTAActionResult(actionID: id, success: true,
                summary: "Cloud privacy and budget preferences saved and verified; billing limits and request outcomes are not certified.",
                outputJSON: String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let patch = try Patch(parameters)
        return try await MainActor.run {
            guard let client = model.actaAnalytics?.aiClient else { return false }
            let current = model.vlmPreferences
            let stored = try VLMStore.loadPreferences(from: model.vlmPreferencesURL)
            let policy = try model.featurePolicySnapshotChecked()
            return patch.applying(to: current) == current
                && stored == current
                && client.configuration() == WallModel.makeACTAAIConfiguration(from: current, featurePreferences: policy)
        }
    }
}
