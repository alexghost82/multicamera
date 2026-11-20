import CameraCore
import Foundation

/// All mission, scheduler, queue, GUI, history and external writers must share
/// an atomic capture/commit boundary. Revision changes on every relevant write,
/// including ABA and replacement. Capture rejects missing, ambiguous, unhealthy
/// or inconsistent state. Commit compares the entire observation atomically,
/// requires enabled and idle, and changes only enabled to false. It neither
/// starts nor cancels work and preserves all other data. Errors can mean an
/// unknown outcome; readback alone does not establish crash durability.
@MainActor
protocol ACTAMissionDisableDomain: Sendable {
    func capture(missionID: UUID) throws -> ACTAMissionDisableObservation?
    func disable(expected: ACTAMissionDisableObservation) throws -> ACTAMissionDisableObservation?
}

struct ACTAMissionDisableObservation: Equatable, Sendable {
    let revision: UUID
    let missionID: UUID
    let cameraID: UUID
    let enabled: Bool
    let idle: Bool
}

/// Not registered: the legacy mission store and scheduler lack this contract.
struct ACTAPreparedMissionDisableAction: ACTAPreparedConfirmationAction {
    @MainActor final class State {
        var receipt: (parameters: [String: String], threadID: String, observation: ACTAMissionDisableObservation)?
    }
    @MainActor final class Ticket {
        let owner: State
        var used = false
        init(owner: State) { self.owner = owner }
    }
    struct ConfirmationSnapshot: Sendable {
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let before: ACTAMissionDisableObservation
        fileprivate let ticket: Ticket
    }

    let id = "mission.edit"
    let title = "Disable Mission"
    let description = "Review and disable an idle scheduled mission; does not cancel an active run."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "mission_id", type: "string", description: "Mission UUID", isRequired: true),
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "Only false is supported", isRequired: true)
    ]
    private let domain: any ACTAMissionDisableDomain
    private let state: State

    @MainActor init(domain: any ACTAMissionDisableDomain) {
        self.domain = domain
        self.state = State()
    }

    private func parse(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["mission_id", "enabled"],
              let value = parameters["mission_id"], let id = UUID(uuidString: value),
              parameters["enabled"] == "false" else { throw ActionError.invalid }
        return id
    }
    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }
    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let missionID = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let before = try domain.capture(missionID: missionID), before.missionID == missionID,
                  before.enabled, before.idle else { throw ActionError.unavailable }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(parameters: parameters, threadID: context.threadID,
                                               before: before, ticket: Ticket(owner: state)),
                reviewSummary: "Mission \(missionID.uuidString), camera \(before.cameraID.uuidString): enabled -> disabled while idle. Future scheduled runs are disabled; existing work is not cancelled. Readback does not establish crash durability.")
        }
    }
    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        try await MainActor.run {
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            try Task.checkCancellation()
            guard context.isConfirmed, parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            _ = try parse(parameters)
            guard state.receipt == nil else { return .failed(actionID: id, error: "ACTION_BUSY: Awaiting verification.") }
            let committed: ACTAMissionDisableObservation?
            do { committed = try domain.disable(expected: snapshot.before) }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let committed else { return .failed(actionID: id, error: "STALE_REVIEW: Mission or scheduler changed.") }
            do {
                guard committed.revision != snapshot.before.revision,
                      committed.missionID == snapshot.before.missionID,
                      committed.cameraID == snapshot.before.cameraID, !committed.enabled, committed.idle,
                      try domain.capture(missionID: committed.missionID) == committed else {
                    return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
                }
            } catch { return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.") }
            state.receipt = (parameters, context.threadID, committed)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Mission disabled and read back; crash durability is not verified.",
                outputJSON: "{\"mission_id\":\"\(committed.missionID.uuidString)\",\"enabled\":false}")
        }
    }
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard context.isConfirmed, let receipt, receipt.parameters == parameters,
                  receipt.threadID == context.threadID else { return false }
            return (try? domain.capture(missionID: receipt.observation.missionID)) == receipt.observation
        }
    }
    private enum ActionError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Provide a mission UUID and enabled=false."
            case .unavailable: return "UNAVAILABLE: Enabled idle mission cannot be safely reviewed."
            }
        }
    }
}
