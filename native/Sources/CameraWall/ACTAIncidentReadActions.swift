import CameraCore
import Foundation

/// A provider must return nil only when the incident is absent from a healthy store.
protocol ACTAIncidentReadProvider: Sendable {
    func incident(id: UUID) async throws -> SafetyIncident?
}

enum ACTAIncidentReadProviderError: Error {
    case unavailable
    case storageError
}

/// Reads the same in-memory domain service as the incident center, without starting it.
@MainActor
final class ACTAEngineIncidentReadProvider: ACTAIncidentReadProvider {
    private weak var engine: LocalVideoAnalyticsEngine?

    init(engine: LocalVideoAnalyticsEngine) {
        self.engine = engine
    }

    func incident(id: UUID) async throws -> SafetyIncident? {
        guard let engine else { throw ACTAIncidentReadProviderError.unavailable }
        let manager = engine.incidentManager
        guard engine.persistenceError == nil, manager.lastPersistenceError == nil else {
            throw ACTAIncidentReadProviderError.storageError
        }
        let incident = manager.incident(id: id)
        guard engine.persistenceError == nil, manager.lastPersistenceError == nil else {
            throw ACTAIncidentReadProviderError.storageError
        }
        return incident
    }
}

private enum IncidentGetValidationError: LocalizedError {
    case invalidArgument

    var errorDescription: String? { "INVALID_ARGUMENT: Expected only incident_id as a UUID." }
}

struct ACTAIncidentGetAction: ACTAActionProtocol {
    let id = "incident.get"
    let title = "Get Incident"
    let description = "Read incident metadata and the suppression deadline by UUID; sensitive details and evidence are not exposed."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "incident_id", type: "string",
                                  description: "Incident UUID", isRequired: true)
    ]

    private let provider: (any ACTAIncidentReadProvider)?

    init(provider: (any ACTAIncidentReadProvider)? = nil) {
        self.provider = provider
    }

    func validate(parameters: [String: String]) throws {
        guard parameters.count == 1, let value = parameters["incident_id"],
              UUID(uuidString: value) != nil else {
            throw IncidentGetValidationError.invalidArgument
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try validate(parameters: parameters)
        } catch {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Expected only incident_id as a UUID.")
        }
        guard let value = parameters["incident_id"], let incidentID = UUID(uuidString: value) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Expected only incident_id as a UUID.")
        }
        guard let provider else {
            return .failed(actionID: id, error: "UNAVAILABLE: Incident service is not connected.")
        }

        do {
            try Task.checkCancellation()
            let found = try await provider.incident(id: incidentID)
            try Task.checkCancellation()
            guard let incident = found else {
                return .failed(actionID: id, error: "NOT_FOUND: Incident does not exist.")
            }
            guard incident.id == incidentID else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Incident read failed.")
            }
            // Free-form incident text, evidence paths, and provider errors never enter tool output.
            let payload = IncidentPayload(incident: incident)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let output = String(decoding: try encoder.encode(payload), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Incident retrieved.",
                                    outputJSON: output, verified: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch ACTAIncidentReadProviderError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Incident service is not connected.")
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Incident read failed.")
        }
    }
}

private struct IncidentPayload: Encodable {
    let incident: Metadata

    init(incident: SafetyIncident) {
        self.incident = Metadata(id: incident.id, camera_id: incident.cameraID,
                                 type: incident.type, severity: incident.severity,
                                 status: incident.status, created_at: incident.createdAt,
                                 updated_at: incident.updatedAt,
                                 suppressed_until: incident.suppressedUntil)
    }

    struct Metadata: Encodable {
        let id: UUID
        let camera_id: UUID
        let type: SafetyIncidentType
        let severity: SafetyIncidentSeverity
        let status: SafetyIncidentStatus
        let created_at: Date
        let updated_at: Date
        let suppressed_until: Date?
    }
}
