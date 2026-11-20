import CameraCore
import Foundation

/// Isolated contract, not implemented by WallModel. All memory, persisted
/// configuration and effect writers must share one serialization boundary.
/// The revision changes on every relevant write, including ABA. Capture reads
/// complete memory and persisted configurations or throws. Commit compares the
/// entire observation atomically and returns nil without writing if stale.
/// It changes only the supplied configuration and performs no other effects;
/// errors may have an unknown outcome. Neither readback nor this contract alone
/// establishes crash durability.
@MainActor
protocol ACTACanvasColumnsDomain: Sendable {
    func capture() throws -> ACTACanvasColumnsObservation
    func commit(expected: ACTACanvasColumnsObservation, replacement: Data) throws -> ACTACanvasColumnsObservation?
}

struct ACTACanvasColumnsObservation: Sendable, Equatable {
    let revision: UUID
    let memory: Data
    let persisted: Data
}

/// Deliberately unregistered: applySettings also resets detection state, filters
/// tile objects and may start the relay. Existing writers are not coordinated by
/// ACTACanvasColumnsDomain, so this is not a WallModel production adapter.
struct ACTAPreparedCanvasColumnsAction: ACTAPreparedConfirmationAction {
    @MainActor
    final class State {
        var receipt: (parameters: [String: String], threadID: String, observation: ACTACanvasColumnsObservation)?
    }

    @MainActor
    final class Ticket {
        let owner: State
        var used = false
        init(owner: State) { self.owner = owner }
    }

    struct ConfirmationSnapshot: Sendable {
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let before: ACTACanvasColumnsObservation
        fileprivate let replacement: Data
        fileprivate let ticket: Ticket
    }

    let id = "canvas.set_columns"
    let title = "Set Canvas Grid Columns"
    let description = "Review and change grid columns in an isolated configuration domain."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "columns", type: "integer", description: "Columns count (1...16)", isRequired: true)
    ]
    private let domain: any ACTACanvasColumnsDomain
    private let state: State

    @MainActor
    init(domain: any ACTACanvasColumnsDomain) {
        self.domain = domain
        self.state = State()
    }

    private func columns(_ parameters: [String: String]) throws -> Int {
        guard Set(parameters.keys) == ["columns"], let raw = parameters["columns"],
              let value = Int(raw), (1...16).contains(value) else { throw ColumnsError.invalid }
        return value
    }

    func validate(parameters: [String: String]) throws { _ = try columns(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    private func encoded(_ config: WallConfiguration, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                         : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    /// Strict encodings reject duplicate, unknown and omitted fields as well as
    /// unsupported formatting instead of silently dropping serialized data.
    private func checkedConfiguration(_ data: Data) throws -> WallConfiguration {
        let config = try JSONDecoder().decode(WallConfiguration.self, from: data)
        try config.validate()
        guard try data == encoded(config) || data == encoded(config, pretty: true) else { throw ColumnsError.unavailable }
        return config
    }

    private func checkedObservation(_ observation: ACTACanvasColumnsObservation) throws -> WallConfiguration {
        let memory = try checkedConfiguration(observation.memory)
        let persisted = try checkedConfiguration(observation.persisted)
        guard try encoded(memory) == encoded(persisted) else { throw ColumnsError.unavailable }
        return memory
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let value = try columns(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            let before = try domain.capture()
            let current = try checkedObservation(before)
            var draft = current
            draft.columns = value
            let next = try current.applyingSettings(from: draft)
            let replacement = try encoded(next)
            let summary = "Grid columns: \(current.columns) -> \(value). All other configuration fields are preserved. Isolated configuration only; no WallModel detection or relay effects. Persisted readback does not establish crash durability."
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(parameters: parameters, threadID: context.threadID,
                                               before: before, replacement: replacement, ticket: Ticket(owner: state)),
                reviewSummary: summary)
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        return try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            guard parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            let value = try columns(parameters)
            guard state.receipt == nil else {
                return .failed(actionID: id, error: "ACTION_BUSY: A previous update awaits verification.")
            }
            let committed: ACTACanvasColumnsObservation?
            do { committed = try domain.commit(expected: snapshot.before, replacement: snapshot.replacement) }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let committed else {
                return .failed(actionID: id, error: "STALE_REVIEW: Configuration changed.")
            }
            do {
                let expected = try checkedConfiguration(snapshot.replacement)
                guard committed.revision != snapshot.before.revision,
                      try encoded(checkedObservation(committed)) == encoded(expected),
                      try domain.capture() == committed else {
                    return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
                }
            } catch {
                return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
            }
            state.receipt = (parameters, context.threadID, committed)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Configuration updated and read back; crash durability is not verified.",
                outputJSON: "{\"columns\":\(value)}")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard let receipt, receipt.parameters == parameters, receipt.threadID == context.threadID else { return false }
            return (try? domain.capture()) == receipt.observation
        }
    }

    private enum ColumnsError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Columns must be an integer from 1 through 16."
            case .unavailable: return "UNAVAILABLE: Complete configuration cannot be safely reviewed."
            }
        }
    }
}
