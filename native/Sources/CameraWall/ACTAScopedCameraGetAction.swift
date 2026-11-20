import CameraCore
import Foundation

/// Opt-in configuration snapshot. The host supplies a coherent snapshot; this action
/// neither registers itself nor establishes capture, connection, or device readiness.
struct ACTAScopedCameraGetAction: ACTAActionProtocol {
    let id = "camera.get"
    let title = "Get Camera Settings"
    let description = "Read minimal configured settings by camera UUID. Does not verify physical availability or connectivity."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string",
                                  description: "Camera UUID", isRequired: true)
    ]

    private let snapshot: (@MainActor @Sendable () throws -> [Camera])?

    init(snapshot: (@MainActor @Sendable () throws -> [Camera])? = nil) {
        self.snapshot = snapshot
    }

    private struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: Expected only camera_id as a UUID." }
    }

    func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys) == ["camera_id"],
              let value = parameters["camera_id"], UUID(uuidString: value) != nil else {
            throw InvalidArguments()
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try Task.checkCancellation()
            try validate(parameters: parameters)
            guard let value = parameters["camera_id"], let requestedID = UUID(uuidString: value) else {
                throw InvalidArguments()
            }
            guard let snapshot else {
                return .failed(actionID: id, error: "UNAVAILABLE: Camera settings provider is not connected.")
            }
            let matches = try await MainActor.run { () -> [CameraSettings] in
                try Task.checkCancellation()
                return try snapshot().filter { $0.id == requestedID }.map {
                    CameraSettings(id: $0.id, enabled: $0.enabled, yolo_enabled: $0.yoloEnabled,
                                   ai_chat_enabled: $0.aiChatEnabled, isapi_events_enabled: $0.isapiEventsEnabled)
                }
            }
            try Task.checkCancellation()
            guard !matches.isEmpty else {
                return .failed(actionID: id, error: "NOT_FOUND: Camera UUID does not exist.")
            }
            guard matches.count == 1, let camera = matches.first else {
                return .failed(actionID: id, error: "AMBIGUOUS: Camera UUID is duplicated.")
            }
            let data = try JSONEncoder().encode(Output(camera: camera))
            try Task.checkCancellation()
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera settings snapshot retrieved; availability and connectivity were not verified.",
                outputJSON: String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch is InvalidArguments {
            try Task.checkCancellation()
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Expected only camera_id as a UUID.")
        } catch {
            try Task.checkCancellation()
            return .failed(actionID: id, error: "STORAGE_ERROR: Camera settings read failed.")
        }
    }

    private struct Output: Encodable {
        let camera: CameraSettings
    }

    private struct CameraSettings: Encodable, Sendable {
        let id: UUID
        let enabled: Bool
        let yolo_enabled: Bool
        let ai_chat_enabled: Bool
        let isapi_events_enabled: Bool
    }
}
