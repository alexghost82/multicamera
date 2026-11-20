import CameraCore
import Foundation

/// All incident, audit, GUI, engine and external writers must participate in
/// one atomic capture/commit boundary. Revision must change on every relevant
/// write, including ABA and replacement. Capture fails for missing, ambiguous,
/// inconsistent or unreadable state. Commit compares the entire observation
/// and, only if still active, atomically acknowledges it and records the audit
/// without other effects. A thrown error may mean an unknown outcome.
@MainActor
protocol ACTAIncidentAcknowledgeDomain: Sendable {
    func capture(incidentID: UUID) throws -> ACTAIncidentAcknowledgeObservation?
    func acknowledge(expected: ACTAIncidentAcknowledgeObservation) throws -> ACTAIncidentAcknowledgeObservation?
}

struct ACTAIncidentAcknowledgeObservation: Equatable, Sendable {
    let revision: UUID
    let incidentID: UUID
    let cameraID: UUID
    let status: SafetyIncidentStatus
}

/// Not registered: existing incident and audit writers do not provide this contract.
struct ACTAPreparedIncidentAcknowledgeAction: ACTAPreparedConfirmationAction {
    @MainActor final class State {
        var receipt: (parameters: [String: String], threadID: String, observation: ACTAIncidentAcknowledgeObservation)?
    }
    @MainActor final class Ticket {
        let owner: State
        var used = false
        init(owner: State) { self.owner = owner }
    }
    struct ConfirmationSnapshot: Sendable {
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let before: ACTAIncidentAcknowledgeObservation
        fileprivate let ticket: Ticket
    }

    let id = "incident.transition_status"
    let title = "Acknowledge Incident"
    let description = "Review and acknowledge an active incident without changing its note."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "incident_id", type: "string", description: "Incident UUID", isRequired: true),
        ACTAActionParameterSchema(name: "status", type: "string", description: "Only acknowledged is supported", isRequired: true, allowedValues: ["acknowledged"])
    ]
    private let domain: any ACTAIncidentAcknowledgeDomain
    private let state: State

    @MainActor init(domain: any ACTAIncidentAcknowledgeDomain) {
        self.domain = domain
        self.state = State()
    }

    private func parse(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["incident_id", "status"],
              let value = parameters["incident_id"], let id = UUID(uuidString: value),
              parameters["status"] == "acknowledged" else { throw ActionError.invalid }
        return id
    }
    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let incidentID = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let before = try domain.capture(incidentID: incidentID),
                  before.incidentID == incidentID, before.status == .active else { throw ActionError.unavailable }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(parameters: parameters, threadID: context.threadID,
                                               before: before, ticket: Ticket(owner: state)),
                reviewSummary: "Incident \(incidentID.uuidString), camera \(before.cameraID.uuidString): ACTIVE -> ACKNOWLEDGED. Note is unchanged; audit is recorded. Readback does not establish crash durability.")
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
            let committed: ACTAIncidentAcknowledgeObservation?
            do { committed = try domain.acknowledge(expected: snapshot.before) }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let committed else { return .failed(actionID: id, error: "STALE_REVIEW: Incident changed.") }
            do {
                guard committed.revision != snapshot.before.revision,
                      committed.incidentID == snapshot.before.incidentID,
                      committed.cameraID == snapshot.before.cameraID, committed.status == .acknowledged,
                      try domain.capture(incidentID: committed.incidentID) == committed else {
                    return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
                }
            } catch { return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.") }
            state.receipt = (parameters, context.threadID, committed)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Acknowledgement read back; crash durability is not verified.",
                outputJSON: "{\"incident_id\":\"\(committed.incidentID.uuidString)\",\"status\":\"acknowledged\"}")
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
            return (try? domain.capture(incidentID: receipt.observation.incidentID)) == receipt.observation
        }
    }
    private enum ActionError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Provide an incident UUID and acknowledged status."
            case .unavailable: return "UNAVAILABLE: Active incident cannot be safely reviewed."
            }
        }
    }
}
