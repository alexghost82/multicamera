import CameraCore
import Foundation

protocol ACTAIncidentListReadProvider: Sendable {
    func incidents() async throws -> [SafetyIncident]
}

@MainActor
final class ACTAEngineIncidentListReadProvider: ACTAIncidentListReadProvider {
    private weak var engine: LocalVideoAnalyticsEngine?

    init(engine: LocalVideoAnalyticsEngine) {
        self.engine = engine
    }

    func incidents() async throws -> [SafetyIncident] {
        guard let engine else { throw ACTAIncidentReadProviderError.unavailable }
        let manager = engine.incidentManager
        guard engine.persistenceError == nil, manager.lastPersistenceError == nil else {
            throw ACTAIncidentReadProviderError.storageError
        }
        let result = manager.allIncidents()
        guard engine.persistenceError == nil, manager.lastPersistenceError == nil else {
            throw ACTAIncidentReadProviderError.storageError
        }
        return result
    }
}

struct ACTAScopedIncidentListAction: ACTAActionProtocol {
    let id = "incident.list"
    let title = "List Incident Metadata"
    let description = "List up to 50 incidents with IDs, type, severity, status, and timestamps; no camera IDs, text, or evidence."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "open_only", type: "boolean",
                                  description: "Only incidents with open status", isRequired: false),
        ACTAActionParameterSchema(name: "limit", type: "integer",
                                  description: "Maximum results, from 1 through 50", isRequired: false)
    ]
    private let provider: any ACTAIncidentListReadProvider

    init(provider: any ACTAIncidentListReadProvider) {
        self.provider = provider
    }

    func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys).isSubset(of: ["open_only", "limit"]),
              parameters["open_only"].map({ $0 == "true" || $0 == "false" }) ?? true,
              parameters["limit"].map({ Int($0).map { (1...50).contains($0) } ?? false }) ?? true else {
            throw ListError.invalid
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try validate(parameters: parameters)
            try Task.checkCancellation()
            let incidents = try await provider.incidents()
            try Task.checkCancellation()
            let openOnly = parameters["open_only"] == "true"
            let limit = parameters["limit"].flatMap(Int.init) ?? 20
            let payload = Output(incidents: incidents.lazy
                .filter { !openOnly || $0.status.isOpen }
                .prefix(limit).map(Metadata.init))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return ACTAActionResult(actionID: id, success: true, summary: "Incident metadata retrieved.",
                                    outputJSON: String(decoding: try encoder.encode(payload), as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch ListError.invalid {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Invalid incident list parameters.")
        } catch ACTAIncidentReadProviderError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Incident service is not connected.")
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Incident read failed.")
        }
    }

    private struct Output: Encodable {
        let incidents: [Metadata]
    }

    private struct Metadata: Encodable {
        let id: UUID
        let type: SafetyIncidentType
        let severity: SafetyIncidentSeverity
        let status: SafetyIncidentStatus
        let created_at: Date
        let updated_at: Date

        init(_ incident: SafetyIncident) {
            id = incident.id
            type = incident.type
            severity = incident.severity
            status = incident.status
            created_at = incident.createdAt
            updated_at = incident.updatedAt
        }
    }

    private enum ListError: LocalizedError {
        case invalid
        var errorDescription: String? { "INVALID_ARGUMENT: Invalid incident list parameters." }
    }
}
