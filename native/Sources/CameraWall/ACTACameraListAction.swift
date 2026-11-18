import CameraCore
import Foundation

struct ACTAScopedCameraListAction: ACTAActionProtocol {
    public let id = "camera.list"
    public let title = "List Cameras"
    public let description = "Read configured camera identifiers, names, enabled flags and source types. Does not certify connection or hardware readiness."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "include_disabled", type: "boolean", description: "Include disabled cameras (default: true)")
    ]

    private let snapshot: @MainActor @Sendable () throws -> [Camera]

    init(model: WallModel) {
        snapshot = { [weak model] in
            guard let model else { throw SnapshotError.unavailable }
            return model.config.cameras
        }
    }

    init(snapshot: @escaping @MainActor @Sendable () throws -> [Camera]) {
        self.snapshot = snapshot
    }

    private enum SnapshotError: Error { case unavailable }

    private struct CameraSummary: Encodable {
        let id: String
        let name: String
        let enabled: Bool
        let type: String
    }

    private struct Output: Encodable {
        let cameras: [CameraSummary]
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let includeDisabled = parameters["include_disabled"] != "false"
        let configured = try await snapshot()
        let sourceIDs = configured.flatMap { [$0.localDeviceID, $0.screenDisplayID].compactMap { $0 } }
            .filter { !$0.isEmpty }
        let cameras = configured.filter { includeDisabled || $0.enabled }
        let summaries = cameras.map { camera in
            let nameIsSensitive = camera.name.contains("/") || camera.name.contains("\\")
                || sourceIDs.contains { camera.name.localizedCaseInsensitiveContains($0) }
            return CameraSummary(id: camera.id.uuidString, name: nameIsSensitive ? "[redacted]" : camera.name, enabled: camera.enabled,
                type: camera.fileURL != nil ? "file" : camera.localDeviceID != nil ? "local_usb"
                    : camera.screenDisplayID != nil ? "screen" : "network_rtsp")
        }
        let data = try JSONEncoder().encode(Output(cameras: summaries))
        let summary = "Found \(cameras.count) cameras (\(cameras.filter(\.enabled).count) enabled)."
        return ACTAActionResult(actionID: id, success: true, summary: summary,
                                outputJSON: String(decoding: data, as: UTF8.self))
    }
}
