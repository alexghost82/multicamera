import Foundation
import CameraCore
import SwiftUI

// MARK: - Wall Model Action Adapters

public struct CameraListAction: ACTAActionProtocol {
    public let id = "camera.list"
    public let title = "List Cameras"
    public let description = "Returns a list of all configured cameras, their status, streams, and types."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "include_disabled", type: "boolean", description: "Include disabled cameras (default: true)")
    ]

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let includeDisabled = parameters["include_disabled"] != "false"
        let cameras = await MainActor.run {
            model.config.cameras.filter { includeDisabled || $0.enabled }
        }

        let cameraSummaries: [[String: Any]] = cameras.map { cam in
            [
                "id": cam.id.uuidString,
                "name": cam.name,
                "enabled": cam.enabled,
                "substream": cam.substream,
                "mainstream": cam.mainstream ?? "",
                "yolo_enabled": cam.yoloEnabled,
                "ai_chat_enabled": cam.aiChatEnabled,
                "type": cam.fileURL != nil ? "file" : cam.localDeviceID != nil ? "local_usb" : cam.screenDisplayID != nil ? "screen" : "network_rtsp"
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: ["cameras": cameraSummaries])
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let summary = "Found \(cameras.count) cameras (\(cameras.filter(\.enabled).count) enabled)."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: json)
    }
}

public struct CameraGetAction: ACTAActionProtocol {
    public let id = "camera.get"
    public let title = "Get Camera Details"
    public let description = "Returns detailed configuration for a specific camera by name or UUID."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or name", isRequired: true)
    ]

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let idOrName = parameters["camera_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'camera_id' parameter.")
        }

        let found = await MainActor.run {
            model.config.cameras.first { $0.id.uuidString == idOrName || $0.name.localizedCaseInsensitiveContains(idOrName) }
        }

        guard let cam = found else {
            return ACTAActionResult.failed(actionID: id, error: "Camera '\(idOrName)' not found.")
        }

        let dict: [String: Any] = [
            "id": cam.id.uuidString,
            "name": cam.name,
            "location": cam.location ?? "",
            "substream": cam.substream,
            "mainstream": cam.mainstream ?? "",
            "enabled": cam.enabled,
            "yolo_enabled": cam.yoloEnabled,
            "ai_chat_enabled": cam.aiChatEnabled
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return ACTAActionResult(actionID: id, success: true, summary: "Camera '\(cam.name)' details retrieved.", outputJSON: json)
    }
}

public struct CameraSetEnabledAction: ACTAActionProtocol {
    public let id = "camera.set_enabled"
    public let title = "Enable or Disable Camera"
    public let description = "Toggles live streaming and processing for a camera."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or name", isRequired: true),
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "True to enable, false to disable", isRequired: true)
    ]

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let idOrName = parameters["camera_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'camera_id'.")
        }
        let enabled = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")

        let targetCamera = await MainActor.run {
            model.config.cameras.first { $0.id.uuidString == idOrName || $0.name.localizedCaseInsensitiveContains(idOrName) }
        }

        guard let cam = targetCamera else {
            return ACTAActionResult.failed(actionID: id, error: "Camera '\(idOrName)' not found.")
        }

        await MainActor.run {
            model.setEnabled(cam, enabled: enabled)
        }

        let summary = "Camera '\(cam.name)' is now \(enabled ? "enabled" : "disabled")."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"camera_id\": \"\(cam.id.uuidString)\", \"enabled\": \(enabled)}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let idOrName = parameters["camera_id"] else { return false }
        let expected = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")
        return await MainActor.run {
            guard let cam = model.config.cameras.first(where: { $0.id.uuidString == idOrName || $0.name.localizedCaseInsensitiveContains(idOrName) }) else { return false }
            return cam.enabled == expected
        }
    }
}

public struct CameraRemoveAction: ACTAActionProtocol {
    public let id = "camera.remove"
    public let title = "Remove Camera"
    public let description = "Permanently removes a camera and its stream bindings from ACTA. Requires confirmation."
    public let classification = ACTAActionClassification.destructive
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or exact name to remove", isRequired: true)
    ]

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let idOrName = parameters["camera_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'camera_id'.")
        }

        let targetCamera = await MainActor.run {
            model.config.cameras.first { $0.id.uuidString == idOrName || $0.name.localizedCaseInsensitiveContains(idOrName) }
        }

        guard let cam = targetCamera else {
            return ACTAActionResult.failed(actionID: id, error: "Camera '\(idOrName)' not found.")
        }

        await MainActor.run {
            model.remove(cam)
        }

        let summary = "Camera '\(cam.name)' [\(cam.id.uuidString)] has been permanently removed."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"removed_id\": \"\(cam.id.uuidString)\"}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let idOrName = parameters["camera_id"] else { return false }
        return await MainActor.run {
            !model.config.cameras.contains(where: { $0.id.uuidString == idOrName || $0.name.localizedCaseInsensitiveContains(idOrName) })
        }
    }
}

public struct CameraReconnectAction: ACTAActionProtocol {
    public let id = "camera.reconnect"
    public let title = "Reconnect Camera"
    public let description = "Restarts the stream connection and pipeline for a camera."
    public let classification = ACTAActionClassification.serviceAffecting
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or name", isRequired: true)
    ]

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let idOrName = parameters["camera_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'camera_id'.")
        }

        let targetCamera = await MainActor.run {
            model.config.cameras.first { $0.id.uuidString == idOrName || $0.name.localizedCaseInsensitiveContains(idOrName) }
        }

        guard let cam = targetCamera else {
            return ACTAActionResult.failed(actionID: id, error: "Camera '\(idOrName)' not found.")
        }

        await MainActor.run {
            model.reconnect(cam)
        }

        return ACTAActionResult(actionID: id, success: true, summary: "Reconnecting camera '\(cam.name)'.", outputJSON: "{\"status\": \"reconnecting\"}")
    }
}

public struct CanvasSetColumnsAction: ACTAActionProtocol {
    public let id = "canvas.set_columns"
    public let title = "Set Canvas Grid Columns"
    public let description = "Sets the number of columns in the multi-camera grid layout (1...16)."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "columns", type: "integer", description: "Columns count (1...16)", isRequired: true)
    ]

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let colStr = parameters["columns"], let cols = Int(colStr) else {
            return ACTAActionResult.failed(actionID: id, error: "Missing or invalid 'columns' integer.")
        }
        let clamped = min(16, max(1, cols))
        await MainActor.run {
            model.setGridColumns(clamped)
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Canvas layout updated to \(clamped) columns.", outputJSON: "{\"columns\": \(clamped)}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let colStr = parameters["columns"], let cols = Int(colStr) else { return false }
        let expected = min(16, max(1, cols))
        return await MainActor.run { model.config.columns == expected }
    }
}

public struct CanvasResetLayoutAction: ACTAActionProtocol {
    public let id = "canvas.reset_layout"
    public let title = "Reset Canvas Layout"
    public let description = "Resets all video tiles to their default automatic grid positions."
    public let classification = ACTAActionClassification.reversible
    public let parameters: [ACTAActionParameterSchema] = []

    private unowned let model: WallModel

    public init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await MainActor.run {
            model.resetLayout()
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Canvas layout reset to default grid.", outputJSON: "{\"reset\": true}")
    }
}

// MARK: - Registration Helper

@MainActor
public func registerAllWallActions(registry: ACTAActionRegistry, model: WallModel) async {
    await registry.register(CameraListAction(model: model))
    await registry.register(CameraGetAction(model: model))
    await registry.register(CameraSetEnabledAction(model: model))
    await registry.register(CameraRemoveAction(model: model))
    await registry.register(CameraReconnectAction(model: model))
    await registry.register(CanvasSetColumnsAction(model: model))
    await registry.register(CanvasResetLayoutAction(model: model))

    // Core Settings Actions
    await registry.register(SettingsGetSectionAction())
    await registry.register(SettingsUpdateSystemAction())
    await registry.register(SettingsUpdateFeatureTogglesAction())
    await registry.register(SettingsUpdatePermissionsAction())

    // Core Analytics Actions
    await registry.register(AnalyticsGetSettingsAction())
    await registry.register(AnalyticsSetGlobalToggleAction())

    // Core Incident Actions
    await registry.register(IncidentListAction())
    await registry.register(IncidentTransitionStatusAction())
    await registry.register(IncidentDeleteEvidenceAction())

    // Core Memory Actions
    await registry.register(MemoryDeleteFrameAction())
    await registry.register(MemoryClearAllFramesAction())

    // Core Watch Actions
    await registry.register(WatchListAction())
    await registry.register(WatchCreateAction())
    await registry.register(WatchCancelAction())
}
