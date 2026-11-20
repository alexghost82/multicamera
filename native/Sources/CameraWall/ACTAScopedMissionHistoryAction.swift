import CameraCore
import Foundation

struct ACTAScopedMissionHistoryAction: ACTAActionProtocol {
    let id = "mission.history"
    let title = "Read mission run metadata"
    let description = "Read recent run IDs, status and times for one saved mission. Does not expose summaries, consultation text or camera identifiers."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "mission_id", type: "string", description: "Mission UUID", isRequired: true),
        ACTAActionParameterSchema(name: "limit", type: "integer", description: "Maximum number of runs, 1...50")
    ]
    private weak var model: WallModel?

    @MainActor
    init(model: WallModel) { self.model = model }

    private struct InputError: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: Provide a mission UUID and optional limit from 1 to 50." }
    }

    private func parse(_ parameters: [String: String]) throws -> (UUID, Int) {
        guard Set(parameters.keys).isSubset(of: ["mission_id", "limit"]),
              let raw = parameters["mission_id"], let missionID = UUID(uuidString: raw) else { throw InputError() }
        let limit: Int
        if let rawLimit = parameters["limit"] {
            guard let value = Int(rawLimit), (1...50).contains(value) else { throw InputError() }
            limit = value
        } else {
            limit = 20
        }
        return (missionID, limit)
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }

    private struct Run: Encodable {
        let id: UUID
        let status: String
        let occurred_at: String
    }

    private struct Output: Encodable { let runs: [Run] }
    private enum ReadError: Error { case unavailable, storage, notFound }

    @MainActor
    private func read(missionID: UUID, limit: Int) throws -> [Run] {
        guard let model, model.featurePreferences.enabledFeatures.contains(.scheduledMissions) else {
            throw ReadError.unavailable
        }
        guard FileManager.default.fileExists(atPath: model.missionStoreURL.path) else { throw ReadError.storage }
        let document = try model.missionDocumentChecked()
        guard FileManager.default.fileExists(atPath: model.missionStoreURL.path) else { throw ReadError.storage }
        let runs = document.runs.filter { $0.missionID == missionID }
        guard document.missions.contains(where: { $0.id == missionID }) || !runs.isEmpty else {
            throw ReadError.notFound
        }
        return runs.sorted {
            $0.occurredAt == $1.occurredAt ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt > $1.occurredAt
        }.prefix(limit).map {
            Run(id: $0.id, status: $0.status.rawValue, occurred_at: $0.occurredAt.ISO8601Format())
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            let (missionID, limit) = try parse(parameters)
            try Task.checkCancellation()
            let runs = try await read(missionID: missionID, limit: limit)
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(Output(runs: runs))
            return ACTAActionResult(actionID: id, success: true, summary: "Mission run metadata retrieved.",
                                    outputJSON: String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch is InputError {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Provide a mission UUID and optional limit from 1 to 50.")
        } catch ReadError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Mission service is not connected.")
        } catch ReadError.notFound {
            return .failed(actionID: id, error: "NOT_FOUND: Mission has no saved record or runs.")
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Mission history read failed.")
        }
    }
}
