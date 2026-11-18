import CameraCore
import Foundation

/// Opt-in model projection of the domain action; it is not registered by this type.
struct ACTAScopedIncidentGetAction: ACTAActionProtocol {
    let id = "incident.get"
    let title = "Get Incident"
    let description = "Read minimal incident metadata by incident UUID."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "incident_id", type: "string",
                                  description: "Incident UUID", isRequired: true)
    ]

    private let domainAction: ACTAIncidentGetAction

    init(domainAction: ACTAIncidentGetAction = ACTAIncidentGetAction()) {
        self.domainAction = domainAction
    }

    func validate(parameters: [String: String]) throws {
        try domainAction.validate(parameters: parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try validate(parameters: parameters)
        } catch {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Expected only incident_id as a UUID.")
        }
        guard let value = parameters["incident_id"], let requestedID = UUID(uuidString: value) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Expected only incident_id as a UUID.")
        }
        do {
            try Task.checkCancellation()
            let result = try await domainAction.execute(parameters: parameters, context: context)
            try Task.checkCancellation()
            guard result.success, result.verified, result.actionID == id,
                  !result.requiresOperatorConfirmation else {
                return domainFailure(result)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let projection = try decoder.decode(Output.self, from: Data(result.outputJSON.utf8))
            guard projection.incident.id == requestedID else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Incident read failed.")
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let output = String(decoding: try encoder.encode(projection), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Incident retrieved.",
                                    outputJSON: output, verified: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Incident read failed.")
        }
    }

    private func domainFailure(_ result: ACTAActionResult) -> ACTAActionResult {
        let code = result.error?.split(separator: ":", maxSplits: 1).first
        switch code {
        case "NOT_FOUND": return .failed(actionID: id, error: "NOT_FOUND: Incident does not exist.")
        case "UNAVAILABLE": return .failed(actionID: id, error: "UNAVAILABLE: Incident service is not connected.")
        case "INVALID_ARGUMENT": return .failed(actionID: id, error: "INVALID_ARGUMENT: Invalid incident UUID.")
        default: return .failed(actionID: id, error: "STORAGE_ERROR: Incident read failed.")
        }
    }

    private struct Output: Codable {
        let incident: Metadata
    }

    private struct Metadata: Codable {
        let id: UUID
        let type: SafetyIncidentType
        let severity: SafetyIncidentSeverity
        let status: SafetyIncidentStatus
        let created_at: Date
        let updated_at: Date
        let suppressed_until: Date?
    }
}
