import CameraCore
import Foundation

private enum MissionListReadError: Error {
    case unavailable, storage
}

private struct MissionListMetadata: Encodable {
    enum ExecutionState: String, Encodable {
        case idle, queued, running
    }

    let id: UUID
    let enabled: Bool
    let execution_state: ExecutionState
}

/// Reads the same main-actor state used by the GUI, after checking it against storage.
/// External writers are not synchronized with this snapshot.
struct ACTAScopedMissionListAction: ACTAActionProtocol {
    let id = "mission.list"
    let title = "List Mission Metadata"
    let description = "List saved mission IDs, enabled flags, and current execution states."
    let classification = ACTAActionClassification.inspect
    let parameters: [ACTAActionParameterSchema] = []
    private weak var model: WallModel?

    @MainActor
    init(model: WallModel) {
        self.model = model
    }

    private struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: No parameters are accepted." }
    }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw InvalidArguments() }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try validate(parameters: parameters)
            try Task.checkCancellation()
            let rows = try await read()
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(Output(missions: rows))
            return ACTAActionResult(actionID: id, success: true, summary: "Mission metadata retrieved.",
                                    outputJSON: String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch is InvalidArguments {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: No parameters are accepted.")
        } catch MissionListReadError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Mission service is not connected.")
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Mission read failed.")
        }
    }

    @MainActor
    private func read() throws -> [MissionListMetadata] {
        guard let model, model.featurePreferences.enabledFeatures.contains(.scheduledMissions) else {
            throw MissionListReadError.unavailable
        }
        guard FileManager.default.fileExists(atPath: model.missionStoreURL.path) else {
            throw MissionListReadError.storage
        }
        let document = try model.missionDocumentChecked()
        guard FileManager.default.fileExists(atPath: model.missionStoreURL.path),
              document.missions.count <= CameraMissionStore.maximumMissions else {
            throw MissionListReadError.storage
        }
        return try document.missions.map { mission in
            guard let state = MissionListMetadata.ExecutionState(rawValue: model.missionExecutionStatus(mission.id)) else {
                throw MissionListReadError.storage
            }
            return MissionListMetadata(id: mission.id, enabled: mission.enabled, execution_state: state)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private struct Output: Encodable {
        let missions: [MissionListMetadata]
    }
}
