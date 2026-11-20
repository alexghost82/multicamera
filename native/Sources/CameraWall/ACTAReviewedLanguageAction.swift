import CameraCore
import Foundation

struct ACTAReviewedLanguageAction: ACTAPreparedConfirmationAction {
    @MainActor
    final class State {
        var receipt: (threadID: String, language: String, revision: UUID)?
    }

    @MainActor
    final class Ticket {
        let owner: State
        var used = false
        init(owner: State) { self.owner = owner }
    }

    struct ConfirmationSnapshot: Sendable {
        fileprivate let threadID: String
        fileprivate let requestedLanguage: String
        fileprivate let previousLanguage: String
        fileprivate let storedLanguage: String?
        fileprivate let revision: UUID
        fileprivate let ticket: Ticket
    }

    let id = "settings.update_system"
    let title = "Change interface language"
    let description = "Change only the interface language to en or ru after operator review. Other system settings are not supported by this action."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "language", type: "string", description: "Interface language",
                                  isRequired: true, allowedValues: ["en", "ru"])
    ]
    private let settings: LanguageSettings
    private let state: State

    @MainActor
    init(settings: LanguageSettings) {
        self.settings = settings
        self.state = State()
    }

    private func requested(_ parameters: [String: String]) throws -> AppLanguage {
        guard Set(parameters.keys) == ["language"], let value = parameters["language"],
              let language = AppLanguage(rawValue: value) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide language en or ru.")
        }
        return language
    }

    func validate(parameters: [String: String]) throws { _ = try requested(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let requestedLanguage = try requested(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            let revision = settings.reviewRevision
            let previous = settings.language.rawValue
            let stored = settings.storedLanguage
            guard settings.reviewRevision == revision, settings.language.rawValue == previous,
                  stored == previous || (stored == nil && previous == "en") else {
                throw ConfigurationError.invalid("UNAVAILABLE: Interface language changed outside this instance.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(threadID: context.threadID,
                    requestedLanguage: requestedLanguage.rawValue, previousLanguage: previous,
                    storedLanguage: stored, revision: revision, ticket: Ticket(owner: state)),
                reviewSummary: "Interface language: \(previous) -> \(requestedLanguage.rawValue). Other settings are unchanged.")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let requestedLanguage = try requested(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            state.receipt = nil
            guard snapshot.threadID == context.threadID, snapshot.requestedLanguage == requestedLanguage.rawValue else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            guard settings.language.rawValue == snapshot.previousLanguage,
                  let revision = settings.commitReviewedLanguage(requestedLanguage,
                      expectedRevision: snapshot.revision, expectedStoredLanguage: snapshot.storedLanguage) else {
                return .failed(actionID: id, error: "STALE_OR_WRITE_FAILED: Language changed or could not be saved; state may have changed.")
            }
            state.receipt = (context.threadID, requestedLanguage.rawValue, revision)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Interface language updated; rendering was not verified.",
                outputJSON: "{\"language\":\"\(requestedLanguage.rawValue)\"}")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let language = try requested(parameters)
        return await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard let receipt, receipt.threadID == context.threadID,
                  receipt.language == language.rawValue, settings.reviewRevision == receipt.revision,
                  settings.language == language, settings.storedLanguage == language.rawValue else { return false }
            return settings.reviewRevision == receipt.revision
        }
    }
}
