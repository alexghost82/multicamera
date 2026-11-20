import CameraCore
import Foundation

struct ACTAReviewedMissionRunAction: ACTAPreparedConfirmationAction {
    @MainActor
    final class State {
        var receipt: (threadID: String, missionID: UUID, status: String)?
    }

    @MainActor
    final class Ticket {
        let owner: State
        let session: AnyObject?
        let reconnects: Int?
        var used = false
        init(_ owner: State, session: AnyObject?, reconnects: Int?) {
            self.owner = owner
            self.session = session
            self.reconnects = reconnects
        }
    }

    struct Snapshot: Sendable {
        fileprivate let threadID: String
        fileprivate let missionID: UUID
        fileprivate let missionBytes: Data
        fileprivate let cameraRevision: UUID
        fileprivate let missionRevision: UUID
        fileprivate let ticket: Ticket
    }

    let id = "mission.run_now"
    let title = "Run a scheduled mission"
    var description: String {
        allowCoordinatedLocalExecution
            ? "Queue one enabled idle scheduled mission for local execution after operator review. Verifies queue admission, not inference completion."
            : "Unavailable until mission scheduling is coordinated across application instances."
    }
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [ACTAActionParameterSchema(name: "mission_id", type: "string",
                                                description: "Mission UUID", isRequired: true)]
    private weak var model: WallModel?
    private let allowCoordinatedLocalExecution: Bool
    private let state: State

    @MainActor
    init(model: WallModel, allowCoordinatedLocalExecution: Bool = false) {
        self.model = model
        self.allowCoordinatedLocalExecution = allowCoordinatedLocalExecution
        self.state = State()
    }

    private func missionID(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["mission_id"], let value = parameters["mission_id"],
              let id = UUID(uuidString: value) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide a mission UUID.")
        }
        return id
    }

    func validate(parameters: [String: String]) throws { _ = try missionID(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    @MainActor
    private func checkedMission(_ id: UUID) throws -> CameraMission {
        guard let model, model.featurePreferences.enabledFeatures.contains(.scheduledMissions),
              FileManager.default.fileExists(atPath: model.missionStoreURL.path) else {
            throw ConfigurationError.invalid("UNAVAILABLE: Mission service is not ready.")
        }
        let document = try model.missionDocumentChecked()
        guard FileManager.default.fileExists(atPath: model.missionStoreURL.path),
              let mission = document.missions.first(where: { $0.id == id && $0.enabled }),
              model.config.cameras.contains(where: { $0.id == mission.cameraID && $0.enabled }),
              model.missionExecutionStatus(id) == "idle" else {
            throw ConfigurationError.invalid("UNAVAILABLE: An enabled idle mission and camera are required.")
        }
        return mission
    }

    private func encode(_ mission: CameraMission) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(mission)
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<Snapshot> {
        let id = try missionID(parameters)
        guard allowCoordinatedLocalExecution else {
            throw ConfigurationError.invalid("UNAVAILABLE: Mission execution is not coordinated across application instances.")
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let model else { throw ConfigurationError.invalid("UNAVAILABLE: Mission service is closed.") }
            let revision = model.missionReviewRevision
            let cameraRevision = model.cameraInventoryRevision
            let mission = try checkedMission(id)
            let bytes = try encode(mission)
            let session = model.tiles[mission.cameraID]?.session
            let reconnects = session?.snapshot().reconnects
            guard revision == model.missionReviewRevision, cameraRevision == model.cameraInventoryRevision else {
                throw ConfigurationError.invalid("STALE_REVIEW: Mission changed.")
            }
            let encoder = JSONEncoder()
            let name = String(decoding: try encoder.encode(mission.name), as: UTF8.self)
            let brief = String(decoding: try encoder.encode(mission.brief), as: UTF8.self)
            return .init(snapshot: Snapshot(threadID: context.threadID, missionID: id, missionBytes: bytes,
                                            cameraRevision: cameraRevision, missionRevision: revision,
                                            ticket: Ticket(state, session: session, reconnects: reconnects)),
                         reviewSummary: "Mission \(id.uuidString), camera \(mission.cameraID.uuidString). Name: \(name). Brief: \(brief). This queues local analysis and may process live frames; it does not confirm completion.")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: Snapshot) async throws -> ACTAActionResult {
        let id = try missionID(parameters)
        guard allowCoordinatedLocalExecution else {
            return .failed(actionID: self.id, error: "UNAVAILABLE: Mission execution is not coordinated across application instances.")
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: self.id, error: "CONFIRMATION_CONSUMED: Review already used.")
            }
            snapshot.ticket.used = true
            state.receipt = nil
            guard context.isConfirmed, snapshot.threadID == context.threadID, snapshot.missionID == id, let model,
                  snapshot.cameraRevision == model.cameraInventoryRevision,
                  snapshot.missionRevision == model.missionReviewRevision else {
                return .failed(actionID: self.id, error: "STALE_REVIEW: Mission or camera changed.")
            }
            let mission = try checkedMission(id)
            let session = model.tiles[mission.cameraID]?.session
            guard try encode(mission) == snapshot.missionBytes,
                  snapshot.ticket.session === session,
                  snapshot.ticket.reconnects == session?.snapshot().reconnects,
                  snapshot.cameraRevision == model.cameraInventoryRevision,
                  snapshot.missionRevision == model.missionReviewRevision else {
                return .failed(actionID: self.id, error: "STALE_REVIEW: Mission or camera changed.")
            }
            let status = try model.requestMissionRunChecked(id)
            guard ["queued", "running"].contains(status), model.missionExecutionStatus(id) == status else {
                return .failed(actionID: self.id, error: "READBACK_FAILED: Mission request outcome may be unknown.")
            }
            state.receipt = (context.threadID, id, status)
            return ACTAActionResult(actionID: self.id, success: true,
                summary: "Mission request accepted; analysis completion is not verified.",
                outputJSON: "{\"status\":\"\(status)\",\"completed\":false}")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let id = try missionID(parameters)
        return await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard context.isConfirmed, let receipt, let model,
                  receipt.threadID == context.threadID, receipt.missionID == id else {
                return false
            }
            let status = model.missionExecutionStatus(id)
            return status == receipt.status || (receipt.status == "queued" && status == "running")
        }
    }
}
