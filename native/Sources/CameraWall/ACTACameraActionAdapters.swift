import Foundation
import CameraCore
import SwiftUI

func actaAuditArguments(_ arguments: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: arguments.map { key, value in
        let sensitive = ["password", "secret", "token", "key", "credential"].contains { key.lowercased().contains($0) }
        return (key, sensitive ? "[redacted]" : value.contains("://") ? actaRedactedStreamURL(value) : value)
    })
}

func actaActionAuditArguments(_ actionID: String, _ arguments: [String: String]) -> [String: String] {
    var result = actaAuditArguments(arguments)
    if ["incident.list", "search_tracked_objects"].contains(actionID), arguments["query"] != nil {
        result["query"] = "[redacted]"
    }
    if ["alert.vlm_review", "incident.update_note", "incident.transition_status"].contains(actionID), arguments["note"] != nil {
        result["note"] = "[redacted]"
    }
    return result
}

func actaReviewArguments(_ actionID: String, _ arguments: [String: String]) -> [String: String] {
    var result = actaAuditArguments(arguments)
    if ["alert.vlm_review", "incident.update_note", "incident.transition_status"].contains(actionID), let note = arguments["note"] {
        result["note"] = note
    }
    return result
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

@MainActor
private final class CameraReconnectActionService {
    private weak var model: WallModel?
    private var inFlight = false
    private var receipt: (request: String, camera: Camera, session: CameraSession, file: Bool)?

    init(model: WallModel) { self.model = model }

    func reconnect(_ request: String, actionID: String) async throws -> ACTAActionResult {
        guard !inFlight, receipt == nil else {
            return .failed(actionID: actionID, error: "ACTION_BUSY: A reconnect is executing or awaiting verification.")
        }
        guard let model else { return .failed(actionID: actionID, error: "UNAVAILABLE: Camera wall is unavailable.") }
        try Task.checkCancellation()
        _ = try model.cameraConfigurationChecked()
        guard let camera = actaResolveCamera(request, model: model) else {
            return .failed(actionID: actionID, error: "NOT_FOUND: Camera does not exist or its name is ambiguous.")
        }
        guard camera.localDeviceID == nil, camera.screenDisplayID == nil else {
            return .failed(actionID: actionID, error: "UNSUPPORTED: Local camera and screen reconnect are not supported by this action.")
        }
        guard model.running, !model.connecting, camera.enabled else {
            return .failed(actionID: actionID, error: "UNAVAILABLE: Camera wall must be running and the camera enabled.")
        }
        inFlight = true
        defer { inFlight = false }
        let isFile = camera.fileURL != nil
        let session: CameraSession
        let current: Camera
        if isFile {
            (session, current) = try model.reconnectFileScheduled(camera)
            if Task.isCancelled {
                model.discardFileReconnect(session, cameraID: camera.id)
                throw CancellationError()
            }
        } else {
            model.notice = "Reconnecting network camera; waiting for a fresh frame."
            session = try await model.reconnectNetworkVerified(camera)
            try Task.checkCancellation()
            current = camera
        }
        guard try valid(camera: current, session: session, model: model, file: isFile) else {
            return .failed(actionID: actionID, error: "RECONNECT_NOT_VERIFIED: The replacement session is no longer current.")
        }
        receipt = (request, current, session, isFile)
        return ACTAActionResult(actionID: actionID, success: true,
            summary: isFile
                ? "File restart scheduled and replacement session verified; playback and frames were not verified."
                : "Network camera reconnected and a fresh frame verified; continued availability is not guaranteed.")
    }

    func verify(_ request: String) throws -> Bool {
        defer { receipt = nil }
        guard !inFlight, let model, let receipt, receipt.request == request else { return false }
        return try valid(camera: receipt.camera, session: receipt.session, model: model, file: receipt.file)
    }

    private func valid(camera: Camera, session: CameraSession, model: WallModel, file: Bool) throws -> Bool {
        _ = try model.cameraConfigurationChecked()
        guard model.running, !model.connecting, camera.enabled, model.config.cameras.contains(camera),
              model.tiles[camera.id]?.session === session else { return false }
        if file {
            return !session.isStopped && camera.fileURL != nil
                && camera.localDeviceID == nil && camera.screenDisplayID == nil
        }
        let frame = session.snapshot()
        let now = ContinuousClock.now
        guard frame.pixel != nil,
              let evidence = frame.reconnectEvidence, evidence.attemptID == session.attemptID,
              evidence.sequence > 0, evidence.receivedAt <= now else { return false }
        return evidence.receivedAt.duration(to: now) <= .seconds(2)
    }
}

public struct CameraReconnectAction: ACTAActionProtocol {
    public let id = "camera.reconnect"
    public let title = "Reconnect Camera"
    public let description = "Reconnect an enabled network camera with fresh-frame verification, or schedule a file restart and verify its replacement session (not playback). Local cameras and screen sources are unsupported."
    public let classification = ACTAActionClassification.serviceAffecting
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or name", isRequired: true)
    ]

    private let service: CameraReconnectActionService

    @MainActor init(model: WallModel) { service = CameraReconnectActionService(model: model) }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let camera = parameters["camera_id"], !camera.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Specify a camera UUID or name.")
        }
        return try await service.reconnect(camera, actionID: id)
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let camera = parameters["camera_id"] else { return false }
        return try await service.verify(camera)
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
        try await MainActor.run {
            try model.setGridColumnsChecked(clamped)
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
    func loadConfiguration() async throws -> WallConfiguration { try model.cameraConfigurationChecked() }
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
func registerAllWallActions(registry: ACTAActionRegistry, model: WallModel, languageSettings: LanguageSettings? = nil) async {
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
    await registry.register(ACTACanvasSetFilterAction(bridge: model.canvasFilterBridge,
        locationGroups: { [weak model] in
            model.map { model in
                Set(model.config.cameras.filter(\.enabled).map { camera in
                    ACTACanvasFilterState.locationGroup(camera.location)
                })
            }
        }, inventoryRevision: { [weak model] in model?.cameraInventoryRevision }))
    await registry.register(ACTACanvasSetArrangeModeAction(bridge: model.canvasFilterBridge))
    await registry.register(ACTACanvasSetPresentationAction(bridge: model.canvasFilterBridge))
    await registry.register(ACTACanvasSelectCamerasAction(bridge: model.canvasFilterBridge,
        enabledCameraIDs: { [weak model] in model?.config.cameras.filter(\.enabled).map(\.id) },
        inventoryRevision: { [weak model] in model?.cameraInventoryRevision }))

    let settings = WallSystemSettingsProvider(model: model)
    let features = WallFeaturePreferencesProvider(model: model)
    let analytics = WallAnalyticsSettingsProvider(model: model)

    // Core Settings Actions
    for kind in WallSettingsAction.Kind.allCases {
        await registry.register(WallSettingsAction(kind: kind, model: model))
    }
    await registry.register(WallAIBudgetAction(model: model))
    await registry.register(WallAIConfigAction(model: model))
    await registry.register(ACTASetAPIKeyAction())
    await registry.register(ACTAClearAPIKeyAction())
    await registry.register(ACTAToggleShowcaseAction(model: model))
    await registry.register(ACTAUpdateModelsAction(model: model))
    await registry.register(ACTAReloadModelsAction(model: model))
    if let languageSettings {
        await registry.register(ACTASystemLanguageAction(settingsProvider: settings, languageSettings: languageSettings))
    } else {
        await registry.register(SettingsUpdateSystemAction(settingsProvider: settings))
    }
    await registry.register(SettingsUpdateFeatureTogglesAction(featureProvider: features))
    await registry.register(SettingsUpdatePermissionsAction(featureProvider: features))

    // Core Analytics Actions
    for kind in WallAnalyticsAction.Kind.allCases {
        await registry.register(WallAnalyticsAction(kind: kind, model: model))
    }
    await registry.register(AnalyticsSetGlobalToggleAction(analyticsProvider: analytics))

    // Core Incident Actions
    await registry.register(WallOperationalAction(specification: IncidentListAction(), model: model))
    await registry.register(ACTAIncidentGetAction(provider: ACTAEngineIncidentReadProvider(engine: model.localAnalyticsEngine)))
    await registry.register(WallOperationalAction(specification: IncidentTransitionStatusAction(), model: model))
    await registry.register(WallOperationalAction(specification: IncidentUpdateNoteAction(), model: model))
    await registry.register(WallOperationalAction(specification: IncidentDeleteEvidenceAction(), model: model))
    await registry.register(ACTAAlertListAction(provider: ACTAWallAlertReadProvider(model: model)))
    let alertMutations = ACTAWallAlertMutationProvider(model: model)
    await registry.register(ACTAAlertMutationAction(kind: .acknowledge, provider: alertMutations))
    await registry.register(ACTAAlertMutationAction(kind: .review, provider: alertMutations))
    await registry.register(ACTAISAPIReadAction(provider: ACTAWallISAPIReadProvider(model: model)))
    await registry.register(ACTAReIDCalibrationAction(provider: ACTAWallReIDCalibrationProvider(model: model)))
    await registry.register(ACTAUpdateReIDCalibrationAction(bridge: .shared))
    await registry.register(ACTARunHealthCheckAction(model: model))
    await registry.register(ACTARetryModelLoadingAction(model: model))
    await registry.register(ACTAAnalysisSetSectionAction(bridge: model.canvasFilterBridge))

    await registry.unregister(actionID: "memory.toggle_pin")
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
