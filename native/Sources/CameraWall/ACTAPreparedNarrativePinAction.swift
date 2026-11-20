import CameraCore
import Foundation

/// Every participating writer must share the same coordination boundary;
/// older versions and unrelated writers must be closed. Revisions change on
/// every chapter write, including ABA and delete/recreate. `preservedFields`
/// is an exact representation of all fields other than pin, not a hash.
/// Commit must change only the pin. Readback does not establish crash durability.
@MainActor
protocol ACTANarrativePinReviewDomain: Sendable {
    func capture(chapterID: UUID) throws -> ACTANarrativePinObservation?
    func commit(chapterID: UUID, expected: ACTANarrativePinObservation,
                pinned: Bool) throws -> ACTANarrativePinObservation?
}

struct ACTANarrativePinRevision: Sendable, Equatable {
    let generation: UUID
    let sequence: UInt64
}

struct ACTANarrativePinObservation: Sendable, Equatable {
    let chapterID: UUID
    let revision: ACTANarrativePinRevision
    let pinned: Bool
    let operatorMarked: Bool
    let preservedFields: Data
}

/// Pinning an unmarked chapter is refused: the existing GUI store also marks it.
struct ACTAPreparedNarrativePinAction: ACTAPreparedConfirmationAction {
    @MainActor
    final class State {
        var receipt: (parameters: [String: String], threadID: String, observation: ACTANarrativePinObservation)?
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
        fileprivate let before: ACTANarrativePinObservation
        fileprivate let ticket: Ticket
    }

    let id = "memory.toggle_pin"
    let title = "Set narrative chapter pin"
    let description = "Review and set a chapter's pin without changing its other fields."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "chapter_id", type: "string", description: "Chapter UUID", isRequired: true),
        ACTAActionParameterSchema(name: "pinned", type: "boolean", description: "Desired pin state", isRequired: true)
    ]
    private let domain: any ACTANarrativePinReviewDomain
    private let state: State

    @MainActor
    init(domain: any ACTANarrativePinReviewDomain) {
        self.domain = domain
        self.state = State()
    }

    private func parse(_ parameters: [String: String]) throws -> (UUID, Bool) {
        guard Set(parameters.keys) == ["chapter_id", "pinned"],
              let raw = parameters["chapter_id"], let id = UUID(uuidString: raw),
              let pinned = parameters["pinned"], pinned == "true" || pinned == "false" else {
            throw PinError.invalid
        }
        return (id, pinned == "true")
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (chapterID, pinned) = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            let captured: ACTANarrativePinObservation?
            do { captured = try domain.capture(chapterID: chapterID) }
            catch { throw PinError.unavailable }
            guard let before = captured, before.chapterID == chapterID,
                  !pinned || before.operatorMarked else { throw PinError.unavailable }
            let summary = "Chapter \(chapterID.uuidString): pin \(before.pinned) -> \(pinned). Operator attribution and all other fields remain unchanged. Readback does not establish crash durability."
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(parameters: parameters, threadID: context.threadID,
                                               before: before, ticket: Ticket(owner: state)),
                reviewSummary: summary)
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            guard context.isConfirmed, parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request, thread or approval changed.")
            }
            let (chapterID, pinned) = try parse(parameters)
            guard state.receipt == nil else {
                return .failed(actionID: id, error: "ACTION_BUSY: A previous update awaits verification.")
            }
            let committed: ACTANarrativePinObservation?
            do { committed = try domain.commit(chapterID: chapterID, expected: snapshot.before, pinned: pinned) }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let committed else {
                return .failed(actionID: id, error: "STALE_REVIEW: Chapter changed.")
            }
            do {
                guard committed.chapterID == chapterID, committed.revision != snapshot.before.revision,
                      committed.pinned == pinned, committed.operatorMarked == snapshot.before.operatorMarked,
                      committed.preservedFields == snapshot.before.preservedFields,
                      try domain.capture(chapterID: chapterID) == committed else {
                    return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
                }
            } catch {
                return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
            }
            state.receipt = (parameters, context.threadID, committed)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Pin updated and read back; crash durability is not verified.",
                outputJSON: "{\"pinned\":\(pinned)}")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard context.isConfirmed, let receipt, receipt.parameters == parameters,
                  receipt.threadID == context.threadID else { return false }
            return (try? domain.capture(chapterID: receipt.observation.chapterID)) == receipt.observation
        }
    }

    private enum PinError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Provide a chapter UUID and boolean pin."
            case .unavailable: return "UNAVAILABLE: Chapter or reversible pin operation is unavailable."
            }
        }
    }
}
