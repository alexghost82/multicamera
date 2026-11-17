import Foundation
import CameraCore
import SwiftUI

func actaAuditArguments(_ arguments: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: arguments.map { key, value in
        let sensitive = ["password", "secret", "token", "key", "credential"].contains { key.lowercased().contains($0) }
        return (key, sensitive ? "[redacted]" : value.contains("://") ? actaRedactedStreamURL(value) : value)
    })
}

/// Credentials and query tokens must never enter tool output or model context.
func actaRedactedStreamURL(_ value: String) -> String {
    guard var components = URLComponents(string: value), components.scheme != nil,
          components.host != nil else { return "[redacted stream]" }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? "[redacted stream]"
}

@MainActor
func actaResolveCamera(_ value: String, model: WallModel) -> Camera? {
    if let uuid = UUID(uuidString: value) { return model.config.cameras.first { $0.id == uuid } }
    let exact = model.config.cameras.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
    guard exact.count <= 1 else { return nil }
    if let camera = exact.first { return camera }
    let matches = model.config.cameras.filter { $0.name.localizedCaseInsensitiveContains(value) }
    return matches.count == 1 ? matches.first : nil
}

// MARK: - Wall Model Action Adapters

public struct CameraListAction: ACTAActionProtocol {
    public let id = "camera.list"
    public let title = "List Cameras"
    public let description = "Read configured cameras, enabled flags, redacted streams and source types. Does not certify connection or hardware readiness."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "include_disabled", type: "boolean", description: "Include disabled cameras (default: true)")
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
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
                "substream": actaRedactedStreamURL(cam.substream),
                "mainstream": cam.mainstream.map(actaRedactedStreamURL) ?? "",
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

    init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let idOrName = parameters["camera_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'camera_id' parameter.")
        }

        let found = await MainActor.run {
            actaResolveCamera(idOrName, model: model)
        }

        guard let cam = found else {
            return ACTAActionResult.failed(actionID: id, error: "Camera does not exist or its name is ambiguous; specify a UUID.")
        }

        let dict: [String: Any] = [
            "id": cam.id.uuidString,
            "name": cam.name,
            "location": cam.location ?? "",
            "substream": actaRedactedStreamURL(cam.substream),
            "mainstream": cam.mainstream.map(actaRedactedStreamURL) ?? "",
            "enabled": cam.enabled,
            "yolo_enabled": cam.yoloEnabled,
            "ai_chat_enabled": cam.aiChatEnabled,
            "device_id": cam.localDeviceID ?? "", "display_id": cam.screenDisplayID ?? "",
            "file_path": cam.fileURL?.path ?? "", "isapi_events_enabled": cam.isapiEventsEnabled,
            "isapi_https": cam.isapiHTTPS, "isapi_port": cam.isapiPort
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return ACTAActionResult(actionID: id, success: true, summary: "Camera '\(cam.name)' details retrieved.", outputJSON: json)
    }
}

public struct CameraSetEnabledAction: ACTAActionProtocol {
    public let id = "camera.set_enabled"
    public let title = "Enable or Disable Camera"
    public let description = "Set the persisted camera enabled flag. May reconnect an already running wall; does not start a stopped wall or certify stream readiness. Enabling requires operator review."
    public let classification = ACTAActionClassification.serviceAffecting
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or name", isRequired: true),
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "True to enable, false to disable", isRequired: true)
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    public func requiresConfirmation(parameters: [String: String]) -> Bool { parameters["enabled"] == "true" || parameters["enabled"] == "1" }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            guard let value = parameters["camera_id"], let camera = actaResolveCamera(value, model: model) else {
                return .failed(actionID: id, error: "Camera does not exist or its name is ambiguous; specify a UUID.")
            }
            let enabled = parameters["enabled"] == "true"
            try model.setCameraEnabledChecked(camera, enabled: enabled)
            return ACTAActionResult(actionID: id, success: true, summary: "Camera enabled configuration saved and verified; stream readiness is not certified.",
                outputJSON: String(decoding: try JSONSerialization.data(withJSONObject: ["camera_id": camera.id.uuidString, "enabled": enabled, "connection_verified": false] as [String: Any]), as: UTF8.self))
        }
    }
    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }

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

    init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            guard let value = parameters["camera_id"], let camera = actaResolveCamera(value, model: model) else {
                return .failed(actionID: id, error: "Camera does not exist or its name is ambiguous; specify a UUID.")
            }
            try model.removeCameraChecked(camera.id)
            return ACTAActionResult(actionID: id, success: true, summary: "Camera configuration and credentials removed and verified.",
                outputJSON: String(decoding: try JSONEncoder().encode(["removed_id": camera.id.uuidString]), as: UTF8.self))
        }
    }
    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }

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

    init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let idOrName = parameters["camera_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'camera_id'.")
        }

        let targetCamera = await MainActor.run {
            actaResolveCamera(idOrName, model: model)
        }

        guard let cam = targetCamera else {
            return ACTAActionResult.failed(actionID: id, error: "Camera does not exist or its name is ambiguous; specify a UUID.")
        }

        await MainActor.run {
            model.reconnect(cam)
        }

        return ACTAActionResult(actionID: id, success: true, summary: "Reconnecting camera '\(cam.name)'.", outputJSON: "{\"status\": \"reconnecting\"}")
    }
}

struct CameraToggleExpandAction: ACTAActionProtocol {
    let id = "camera.toggle_expand"
    let title = "Toggle expanded camera"
    let description = "Toggle the selected camera's expanded canvas state. Verifies UI selection, not video connection completion."
    let classification = ACTAActionClassification.reversible
    let parameters = [ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or unique name", isRequired: true)]
    unowned let model: WallModel

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            guard !model.connecting else { return .failed(actionID: id, error: "ACTION_BUSY: Camera connection is in progress.") }
            guard let value = parameters["camera_id"], let camera = actaResolveCamera(value, model: model) else {
                return .failed(actionID: id, error: "Camera does not exist or its name is ambiguous; specify a UUID.")
            }
            let expected: UUID? = model.expanded == camera.id ? nil : camera.id
            model.toggleExpanded(camera)
            guard model.expanded == expected else { return .failed(actionID: id, error: "Canvas expansion verification failed.") }
            let data = try JSONEncoder().encode(["expanded_camera_id": model.expanded?.uuidString ?? ""])
            return ACTAActionResult(actionID: id, success: true, summary: "Canvas expansion state updated and verified.",
                outputJSON: String(decoding: data, as: UTF8.self))
        }
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        // UI selection was verified in execute without an intervening suspension.
        true
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

    init(model: WallModel) {
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

    init(model: WallModel) {
        self.model = model
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await MainActor.run {
            model.resetLayout()
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Canvas layout reset to default grid.", outputJSON: "{\"reset\": true}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try await MainActor.run {
            let persisted = try VideoWallLayout.load(from: model.layoutURL)
            return model.layout == VideoWallLayout() && persisted == VideoWallLayout()
        }
    }
}

// Providers bridge actions to the same MainActor methods used by SettingsHub.
// These providers do not create a second configuration store or a second engine.
@MainActor
struct WallSystemSettingsProvider: ACTASystemSettingsProvider {
    unowned let model: WallModel
    func loadConfiguration() async throws -> WallConfiguration { model.config }
    func saveConfiguration(_ config: WallConfiguration) async throws { try model.saveSystemSettings(config) }
}

@MainActor
struct WallFeaturePreferencesProvider: ACTAFeaturePreferencesProvider {
    unowned let model: WallModel
    func loadPreferences() async throws -> CameraFeaturePreferences { model.featurePreferences }
    func savePreferences(_ prefs: CameraFeaturePreferences) async throws {
        let changed = CameraFeatureID.allCases.filter {
            model.featurePreferences.enabledFeatures.contains($0) != prefs.enabledFeatures.contains($0)
        }
        // Each feature action changes one lifecycle; reject a batch rather than partially apply it.
        guard changed.count <= 1 else {
            throw ConfigurationError.invalid("Only one feature lifecycle can be changed per action.")
        }
        if let feature = changed.first {
            guard prefs.allowExternalAI == model.featurePreferences.allowExternalAI,
                  prefs.allowVoiceInput == model.featurePreferences.allowVoiceInput,
                  prefs.allowPlateRegistryLookup == model.featurePreferences.allowPlateRegistryLookup else {
                throw ConfigurationError.invalid("Feature and permission changes require separate actions.")
            }
            try model.setFeatureEnabled(feature, enabled: prefs.enabledFeatures.contains(feature))
            return
        }
        try model.saveFeaturePolicy(prefs)
    }
}

@MainActor
struct WallAnalyticsSettingsProvider: ACTAVideoAnalyticsSettingsProvider {
    unowned let model: WallModel
    func loadSettings() async -> VideoAnalyticsSettings { model.localAnalyticsEngine.settings }
    func updateSettings(_ mutate: @Sendable (inout VideoAnalyticsSettings) -> Void) async throws {
        var settings = model.localAnalyticsEngine.settings
        mutate(&settings)
        try model.localAnalyticsEngine.updateSettings(settings)
    }
}

// MARK: - Registration Helper

@MainActor
func registerAllWallActions(registry: ACTAActionRegistry, model: WallModel) async {
    for kind in WallCameraConfigurationAction.Kind.allCases {
        await registry.register(WallCameraConfigurationAction(kind: kind, model: model))
    }
    await registry.register(CameraListAction(model: model))
    await registry.register(CameraGetAction(model: model))
    await registry.register(CameraSetEnabledAction(model: model))
    await registry.register(CameraRemoveAction(model: model))
    await registry.register(CameraReconnectAction(model: model))
    await registry.register(CameraToggleExpandAction(model: model))
    await registry.register(CanvasSetColumnsAction(model: model))
    await registry.register(CanvasResetLayoutAction(model: model))

    let settings = WallSystemSettingsProvider(model: model)
    let features = WallFeaturePreferencesProvider(model: model)
    let analytics = WallAnalyticsSettingsProvider(model: model)

    // Core Settings Actions
    for kind in WallSettingsAction.Kind.allCases {
        await registry.register(WallSettingsAction(kind: kind, model: model))
    }
    await registry.register(SettingsUpdateSystemAction(settingsProvider: settings))
    await registry.register(SettingsUpdateFeatureTogglesAction(featureProvider: features))
    await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))

    // Core Analytics Actions
    for kind in WallAnalyticsAction.Kind.allCases {
        await registry.register(WallAnalyticsAction(kind: kind, model: model))
    }
    await registry.register(AnalyticsSetGlobalToggleAction(analyticsProvider: analytics))

    // Core Incident Actions
    await registry.register(WallOperationalAction(specification: IncidentListAction(), model: model))
    await registry.register(WallOperationalAction(specification: IncidentTransitionStatusAction(), model: model))
    await registry.register(WallOperationalAction(specification: IncidentDeleteEvidenceAction(), model: model))

    await registry.register(WallNarrativeAction(pin: true, model: model))
    await registry.register(WallNarrativeAction(pin: false, model: model))

    for kind in WallMissionAction.Kind.allCases {
        await registry.register(WallMissionAction(kind: kind, model: model))
    }

    // Core Memory Actions
    await registry.register(WallOperationalAction(specification: MemoryDeleteFrameAction(), model: model))
    await registry.register(MemoryClearAllFramesAction())

    // Core Watch Actions
    await registry.register(WallOperationalAction(specification: WatchListAction(), model: model))
    await registry.register(WallOperationalAction(specification: WatchCreateAction(), model: model))
    await registry.register(WallOperationalAction(specification: WatchCancelAction(), model: model))
}
