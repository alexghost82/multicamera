import CameraCore
import Foundation

enum ACTAAlertReadProviderError: Error {
    case unavailable
}

/// The integrator must supply one coherent, available GUI snapshot or throw.
/// Use unavailable for disabled/uninitialized sources; propagate other source failures.
/// A failed or uninitialized source must never be represented by empty collections.
@MainActor
protocol ACTAAlertReadProvider: Sendable {
    func readAlertSnapshot() throws -> ACTAAlertReadSnapshot
}

struct ACTAAlertReadSnapshot {
    let alerts: [VLMAlert]
    let reviews: [UUID: OperationsAlertReview]
    let acknowledgements: [UUID: Date]
}

@MainActor
final class ACTAWallAlertReadProvider: ACTAAlertReadProvider {
    private weak var model: WallModel?

    init(model: WallModel) { self.model = model }

    func readAlertSnapshot() throws -> ACTAAlertReadSnapshot {
        guard let model, model.actaVLMAlertsLoaded, model.actaAlertReviewsLoaded,
              model.featurePreferences.enabledFeatures.contains(.operationalAlerts),
              FileManager.default.fileExists(atPath: model.vlmAlertsURL.path) else {
            throw ACTAAlertReadProviderError.unavailable
        }
        let persistedAlerts = try JSONDecoder().decode([VLMAlert].self, from: Data(contentsOf: model.vlmAlertsURL))
        let persistedReviews = try model.actaReadOpenAlertState()
        guard persistedAlerts == model.vlmAlerts,
              persistedReviews.reviews == model.operationsAlertReviews,
              persistedReviews.acknowledgements == model.operationsAlertAcknowledgements else {
            throw ACTAAlertReadProviderError.unavailable
        }
        return ACTAAlertReadSnapshot(alerts: model.vlmAlerts, reviews: model.operationsAlertReviews,
                                     acknowledgements: model.operationsAlertAcknowledgements)
    }
}

private enum AlertListArgumentError: LocalizedError {
    case invalid
    var errorDescription: String? { "INVALID_ARGUMENT: Invalid alert list parameters." }
}

struct ACTAAlertListAction: ACTAActionProtocol {
    let provider: any ACTAAlertReadProvider
    let id = "alert.vlm_list"
    let title = "List VLM alerts"
    let description = "List minimal VLM alert metadata from an available local snapshot."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID"),
        ACTAActionParameterSchema(name: "unacknowledged_only", type: "boolean", description: "Only open alerts"),
        ACTAActionParameterSchema(name: "limit", type: "integer", description: "Maximum results, 1...100; default 50")
    ]

    private struct Arguments {
        let cameraID: UUID?
        let unacknowledgedOnly: Bool
        let limit: Int
    }

    private func parse(_ parameters: [String: String]) throws -> Arguments {
        guard Set(parameters.keys).isSubset(of: ["camera_id", "unacknowledged_only", "limit"]) else {
            throw AlertListArgumentError.invalid
        }
        let cameraID: UUID?
        if let value = parameters["camera_id"] {
            guard let id = UUID(uuidString: value) else { throw AlertListArgumentError.invalid }
            cameraID = id
        } else {
            cameraID = nil
        }
        let unacknowledgedOnly: Bool
        switch parameters["unacknowledged_only"] {
        case nil, "false", "0": unacknowledgedOnly = false
        case "true", "1": unacknowledgedOnly = true
        default: throw AlertListArgumentError.invalid
        }
        let limit: Int
        if let raw = parameters["limit"] {
            guard let value = Int(raw), (1...100).contains(value) else { throw AlertListArgumentError.invalid }
            limit = value
        } else {
            limit = 50
        }
        return Arguments(cameraID: cameraID, unacknowledgedOnly: unacknowledgedOnly, limit: limit)
    }

    func validate(parameters: [String: String]) throws {
        _ = try parse(parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let arguments = try parse(parameters)
        try Task.checkCancellation()
        return try await MainActor.run {
            let snapshot: ACTAAlertReadSnapshot
            do {
                snapshot = try provider.readAlertSnapshot()
            } catch is CancellationError {
                throw CancellationError()
            } catch ACTAAlertReadProviderError.unavailable {
                return .failed(actionID: id, error: "UNAVAILABLE: Alert snapshot is unavailable.")
            } catch {
                return .failed(actionID: id, error: "SOURCE_ERROR: Alert snapshot could not be read.")
            }
            try Task.checkCancellation()
            let ordered = OperationsAlertQueue.ordered(snapshot.alerts, reviews: snapshot.reviews,
                                                       acknowledgements: snapshot.acknowledgements)
            let selected = ordered.filter { alert in
                (arguments.cameraID == nil || alert.cameraID == arguments.cameraID)
                    && (!arguments.unacknowledgedOnly || OperationsAlertQueue.status(
                        for: alert.id, reviews: snapshot.reviews,
                        acknowledgements: snapshot.acknowledgements) == .open)
            }.prefix(arguments.limit)
            let rows = selected.map { alert in
                AlertRow(alertID: alert.id, cameraID: alert.cameraID, createdAt: alert.createdAt,
                         status: OperationsAlertQueue.status(for: alert.id, reviews: snapshot.reviews,
                                                            acknowledgements: snapshot.acknowledgements).rawValue,
                         priority: (snapshot.reviews[alert.id]?.priority ?? alert.priority).rawValue)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(AlertListOutput(alerts: rows)), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Listed VLM alert metadata.", outputJSON: json)
        }
    }

    private struct AlertListOutput: Encodable {
        let alerts: [AlertRow]
    }

    private struct AlertRow: Encodable {
        let alertID: UUID
        let cameraID: UUID
        let createdAt: Date
        let status: String
        let priority: String

        enum CodingKeys: String, CodingKey {
            case alertID = "alert_id", cameraID = "camera_id", createdAt = "created_at", status, priority
        }
    }
}
