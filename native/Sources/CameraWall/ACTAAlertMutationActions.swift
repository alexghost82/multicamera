import CameraCore
import Foundation

@MainActor
protocol ACTAAlertMutationProvider: ACTAAlertReadProvider {
    func reviewAlert(id: UUID, priority: OperationsAlertReview.Priority?,
                     status: OperationsAlertReview.Status, note: String?) throws
    func reviewHistory(id: UUID) throws -> [OperationsAlertReview]
}

@MainActor
final class ACTAWallAlertMutationProvider: ACTAAlertMutationProvider {
    private weak var model: WallModel?
    private let reader: ACTAWallAlertReadProvider

    init(model: WallModel) {
        self.model = model
        self.reader = ACTAWallAlertReadProvider(model: model)
    }

    func readAlertSnapshot() throws -> ACTAAlertReadSnapshot {
        try reader.readAlertSnapshot()
    }

    func reviewAlert(id: UUID, priority: OperationsAlertReview.Priority?,
                     status: OperationsAlertReview.Status, note: String?) throws {
        guard let model else { throw ACTAAlertReadProviderError.unavailable }
        try model.updateOperationsAlertReview(id, priority: priority, status: status, note: note)
    }

    func reviewHistory(id: UUID) throws -> [OperationsAlertReview] {
        guard let model else { throw ACTAAlertReadProviderError.unavailable }
        return try model.operationsAlertReviewAudit(id)
    }
}

private enum AlertMutationError: LocalizedError {
    case invalid
    var errorDescription: String? { "INVALID_ARGUMENT: Invalid alert mutation parameters." }
}

struct ACTAAlertMutationAction: ACTAActionProtocol {
    enum Kind: String, Sendable {
        case acknowledge = "alert.vlm_acknowledge"
        case review = "alert.vlm_review"
    }

    let kind: Kind
    let provider: any ACTAAlertMutationProvider
    var id: String { kind.rawValue }
    var title: String { kind == .acknowledge ? "Acknowledge VLM alert" : "Review VLM alert" }
    var description: String {
        "Update a local VLM alert using the alerts queue service; verify the GUI and persisted state."
    }
    let classification = ACTAActionClassification.reversible
    func requiresConfirmation(parameters: [String: String]) -> Bool { kind == .review }
    var parameters: [ACTAActionParameterSchema] {
        let alert = ACTAActionParameterSchema(name: "alert_id", type: "string", description: "Alert UUID", isRequired: true)
        switch kind {
        case .acknowledge:
            return [alert, ACTAActionParameterSchema(name: "acknowledged", type: "boolean",
                                                    description: "Acknowledge or restore to open", isRequired: true)]
        case .review:
            return [alert,
                    ACTAActionParameterSchema(name: "status", type: "string", description: "Review status",
                                              isRequired: true, allowedValues: ["open", "acknowledged", "resolved"]),
                    ACTAActionParameterSchema(name: "priority", type: "string", description: "Review priority",
                                              allowedValues: ["normal", "critical"]),
                    ACTAActionParameterSchema(name: "note", type: "string", description: "Operator note, up to 2000 characters")]
        }
    }

    private struct Arguments {
        let alertID: UUID
        let status: OperationsAlertReview.Status
        let priority: OperationsAlertReview.Priority?
        let note: String?
    }

    private func parse(_ parameters: [String: String]) throws -> Arguments {
        guard Set(parameters.keys).isSubset(of: Set(self.parameters.map(\.name))),
              let rawID = parameters["alert_id"], let alertID = UUID(uuidString: rawID) else {
            throw AlertMutationError.invalid
        }
        switch kind {
        case .acknowledge:
            let status: OperationsAlertReview.Status
            switch parameters["acknowledged"] {
            case "true", "1": status = .acknowledged
            case "false", "0": status = .open
            default: throw AlertMutationError.invalid
            }
            return Arguments(alertID: alertID, status: status, priority: nil, note: nil)
        case .review:
            guard let raw = parameters["status"], let status = OperationsAlertReview.Status(rawValue: raw) else {
                throw AlertMutationError.invalid
            }
            let priority: OperationsAlertReview.Priority?
            if let raw = parameters["priority"] {
                guard let value = OperationsAlertReview.Priority(rawValue: raw) else { throw AlertMutationError.invalid }
                priority = value
            } else { priority = nil }
            let note = parameters["note"]
            guard (note?.count ?? 0) <= 2000,
                  status != .resolved || (note.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true) else {
                throw AlertMutationError.invalid
            }
            return Arguments(alertID: alertID, status: status, priority: priority, note: note)
        }
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let args = try parse(parameters)
        try Task.checkCancellation()
        return try await MainActor.run {
            let before: ACTAAlertReadSnapshot
            let history: [OperationsAlertReview]
            do {
                before = try provider.readAlertSnapshot()
                let matching = before.alerts.filter { $0.id == args.alertID }
                guard matching.count == 1, let alert = matching.first else {
                    return .failed(actionID: id, error: "NOT_FOUND: Alert is missing or ambiguous.")
                }
                let previous = before.reviews[args.alertID]
                if kind == .acknowledge && previous?.status == .resolved {
                    return .failed(actionID: id, error: "INVALID_STATE: Resolved alerts must be reopened through review.")
                }
                history = try provider.reviewHistory(id: args.alertID)
                let expectedPriority = args.priority ?? previous?.priority ?? alert.priority
                let expectedNote = (args.note ?? previous?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard args.status != .resolved || !expectedNote.isEmpty else {
                    return .failed(actionID: id, error: "INVALID_ARGUMENT: Resolving an alert requires a note.")
                }
                try Task.checkCancellation()
                try provider.reviewAlert(id: args.alertID, priority: args.priority, status: args.status, note: args.note)
                let after = try provider.readAlertSnapshot()
                let afterHistory = try provider.reviewHistory(id: args.alertID)
                guard after.alerts.filter({ $0.id == args.alertID }) == [alert],
                      let review = after.reviews[args.alertID],
                      review.status == args.status, review.priority == expectedPriority, review.note == expectedNote,
                      (after.acknowledgements[args.alertID] != nil) == (args.status != .open),
                      afterHistory.count == history.count + 1,
                      Array(afterHistory.dropLast()) == history, afterHistory.last == review else {
                    return .failed(actionID: id, error: "VERIFICATION_FAILED: Alert state or review history did not match.")
                }
                return ACTAActionResult(actionID: id, success: true, summary: "Alert state saved and verified.")
            } catch is CancellationError {
                throw CancellationError()
            } catch ACTAAlertReadProviderError.unavailable {
                return .failed(actionID: id, error: "UNAVAILABLE: Alert state is unavailable.")
            } catch {
                return .failed(actionID: id, error: "SOURCE_ERROR: Alert update or verification failed; state may have changed.")
            }
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let args = try parse(parameters)
        return try await MainActor.run {
            let snapshot = try provider.readAlertSnapshot()
            guard snapshot.alerts.filter({ $0.id == args.alertID }).count == 1,
                  let review = snapshot.reviews[args.alertID],
                  review.status == args.status,
                  args.priority == nil || review.priority == args.priority,
                  args.note == nil || review.note == args.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (snapshot.acknowledgements[args.alertID] != nil) == (args.status != .open),
                  try provider.reviewHistory(id: args.alertID).last == review else { return false }
            return true
        }
    }
}
