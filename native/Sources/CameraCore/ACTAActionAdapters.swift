import Foundation

// MARK: - Delegate Protocols for Core Adapters

public protocol ACTASystemSettingsProvider: Sendable {
    func loadConfiguration() async throws -> WallConfiguration
    func saveConfiguration(_ config: WallConfiguration) async throws
}

public protocol ACTAFeaturePreferencesProvider: Sendable {
    func loadPreferences() async throws -> CameraFeaturePreferences
    func savePreferences(_ prefs: CameraFeaturePreferences) async throws
}

public protocol ACTAVideoAnalyticsSettingsProvider: Sendable {
    func loadSettings() async -> VideoAnalyticsSettings
    func updateSettings(_ mutate: @Sendable (inout VideoAnalyticsSettings) -> Void) async throws
}

// Default file-based implementation for providers
public struct DefaultACTASystemSettingsProvider: ACTASystemSettingsProvider {
    private let url: URL
    public init(url: URL = ConfigurationStore.defaultURL) { self.url = url }
    public func loadConfiguration() throws -> WallConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return WallConfiguration() }
        return try ConfigurationStore.load(from: url)
    }
    public func saveConfiguration(_ config: WallConfiguration) throws {
        try ConfigurationStore.save(config, to: url)
    }
}

public struct DefaultACTAFeaturePreferencesProvider: ACTAFeaturePreferencesProvider {
    private let url: URL
    public init(url: URL = CameraFeaturePreferencesStore.defaultURL) { self.url = url }
    public func loadPreferences() throws -> CameraFeaturePreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return CameraFeaturePreferences() }
        return try CameraFeaturePreferencesStore.load(from: url)
    }
    public func savePreferences(_ prefs: CameraFeaturePreferences) throws {
        try CameraFeaturePreferencesStore.save(prefs, to: url)
    }
}

// MARK: - 1. Settings Actions

public struct SettingsGetSectionAction: ACTAActionProtocol {
    public let id = "settings.get_section"
    public let title = "Get Settings Section"
    public let description = "Inspects the current configuration values of any settings section."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(
            name: "section",
            type: "string",
            description: "Section name: general, cameras, models, advanced, analytics, ai, schedules, missions, events, memory, features, showcase, identity, system",
            isRequired: true
        )
    ]

    private let settingsProvider: ACTASystemSettingsProvider
    private let featureProvider: ACTAFeaturePreferencesProvider

    public init(
        settingsProvider: ACTASystemSettingsProvider = DefaultACTASystemSettingsProvider(),
        featureProvider: ACTAFeaturePreferencesProvider = DefaultACTAFeaturePreferencesProvider()
    ) {
        self.settingsProvider = settingsProvider
        self.featureProvider = featureProvider
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let section = (parameters["section"] ?? "general").lowercased()
        switch section {
        case "general", "system":
            let config = try await settingsProvider.loadConfiguration()
            // Camera configuration may contain stream credentials; disclose only this section.
            let values: [String: Double] = ["columns": Double(config.columns),
                "detectionThreshold": config.detectionThreshold, "detectionFPS": config.detectionFPS,
                "staleAfterMilliseconds": Double(config.staleAfterMilliseconds)]
            let data = try JSONEncoder().encode(values)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return ACTAActionResult(actionID: id, success: true, summary: "Retrieved system settings (\(config.columns) cols, \(config.detectionFPS) FPS)", outputJSON: json)
        case "features", "permissions":
            let prefs = try await featureProvider.loadPreferences()
            let data = try JSONEncoder().encode(prefs)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return ACTAActionResult(actionID: id, success: true, summary: "Retrieved feature policies (\(prefs.enabledFeatures.count) enabled)", outputJSON: json)
        default:
            return ACTAActionResult.unsupported(actionID: id)
        }
    }
}

public struct SettingsUpdateSystemAction: ACTAActionProtocol {
    public let id = "settings.update_system"
    public let title = "Update System Settings"
    public let description = "Updates general display and stream configuration (columns, detection threshold, FPS, ports)."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "columns", type: "integer", description: "Grid columns (1...16)"),
        ACTAActionParameterSchema(name: "detection_threshold", type: "number", description: "YOLO detection confidence threshold (0.1...0.9)"),
        ACTAActionParameterSchema(name: "detection_fps", type: "integer", description: "YOLO detection FPS (1...5)"),
        ACTAActionParameterSchema(name: "stale_threshold_ms", type: "integer", description: "Stale stream timeout in milliseconds (200...30000)")
    ]

    private let settingsProvider: ACTASystemSettingsProvider

    public init(settingsProvider: ACTASystemSettingsProvider = DefaultACTASystemSettingsProvider()) {
        self.settingsProvider = settingsProvider
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        var config = try await settingsProvider.loadConfiguration()
        var changed: [String] = []

        if let colsStr = parameters["columns"], let cols = Int(colsStr) {
            config.columns = min(16, max(1, cols))
            changed.append("columns=\(config.columns)")
        }
        if let threshStr = parameters["detection_threshold"], let thresh = Double(threshStr) {
            config.detectionThreshold = min(0.9, max(0.1, thresh))
            changed.append("detectionThreshold=\(config.detectionThreshold)")
        }
        if let fpsStr = parameters["detection_fps"], let fps = Double(fpsStr) {
            config.detectionFPS = min(5, max(1, fps.rounded()))
            changed.append("detectionFPS=\(config.detectionFPS)")
        }
        if let staleStr = parameters["stale_threshold_ms"], let stale = Int(staleStr) {
            config.staleAfterMilliseconds = min(30000, max(200, stale))
            changed.append("staleAfterMs=\(config.staleAfterMilliseconds)")
        }

        try await settingsProvider.saveConfiguration(config)
        let summary = "System settings updated: " + (changed.isEmpty ? "no changes" : changed.joined(separator: ", "))
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"updated\": true}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let loaded = try await settingsProvider.loadConfiguration()
        if let colsStr = parameters["columns"], let cols = Int(colsStr), loaded.columns != min(16, max(1, cols)) {
            return false
        }
        if let fpsStr = parameters["detection_fps"], let fps = Double(fpsStr), loaded.detectionFPS != min(5, max(1, fps.rounded())) {
            return false
        }
        if let value = parameters["detection_threshold"], let expected = Double(value), loaded.detectionThreshold != min(0.9, max(0.1, expected)) { return false }
        if let value = parameters["stale_threshold_ms"], let expected = Int(value), loaded.staleAfterMilliseconds != min(30000, max(200, expected)) { return false }
        return true
    }
}

public struct SettingsUpdateFeatureTogglesAction: ACTAActionProtocol {
    public let id = "settings.update_feature_toggles"
    public let title = "Update Feature Toggles"
    public let description = "Enables or disables an application feature by ID (e.g. chronologicalMemory, scheduledMissions, plateRecognition)."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "feature", type: "string", description: "Feature ID", isRequired: true, allowedValues: CameraFeatureID.allCases.map(\.rawValue)),
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "True to enable, false to disable", isRequired: true)
    ]

    private let featureProvider: ACTAFeaturePreferencesProvider

    public init(featureProvider: ACTAFeaturePreferencesProvider = DefaultACTAFeaturePreferencesProvider()) {
        self.featureProvider = featureProvider
    }

    public func requiresConfirmation(parameters: [String: String]) -> Bool {
        // Sharing, identity, retained observations and access policy are protected in either direction.
        let protected: Set<String> = ["publicShowcase", "accessControl", "independentWatcher",
            "chronologicalMemory", "crossCameraIdentity", "plateRecognition", "operatorActions"]
        return protected.contains(parameters["feature"] ?? "")
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let featStr = parameters["feature"], let feat = CameraFeatureID(rawValue: featStr) else {
            return ACTAActionResult.failed(actionID: id, error: "Invalid feature ID: \(parameters["feature"] ?? "")")
        }
        let enabled = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")
        var prefs = try await featureProvider.loadPreferences()
        if enabled {
            prefs.enabledFeatures.insert(feat)
        } else {
            prefs.enabledFeatures.remove(feat)
        }
        try await featureProvider.savePreferences(prefs)
        let summary = "Feature '\(feat.rawValue)' is now \(enabled ? "enabled" : "disabled")."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"feature\": \"\(feat.rawValue)\", \"enabled\": \(enabled)}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let featStr = parameters["feature"], let feat = CameraFeatureID(rawValue: featStr) else { return false }
        let expected = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")
        let loaded = try await featureProvider.loadPreferences()
        return loaded.enabledFeatures.contains(feat) == expected
    }
}

public struct SettingsUpdatePermissionsAction: ACTAActionProtocol {
    public let id = "settings.update_permissions"
    public let title = "Update System Permissions"
    public let description = "Updates operator permission toggles (allow external AI, allow local voice input, allow plate lookup)."
    public let classification = ACTAActionClassification.securitySensitive
    public let parameters = [
        ACTAActionParameterSchema(name: "allow_external_ai", type: "boolean", description: "Allow external OpenAI endpoints"),
        ACTAActionParameterSchema(name: "allow_voice_input", type: "boolean", description: "Allow local speech recognition microphone access"),
        ACTAActionParameterSchema(name: "allow_plate_lookup", type: "boolean", description: "Allow external vehicle registration lookup")
    ]

    private let featureProvider: ACTAFeaturePreferencesProvider

    public init(featureProvider: ACTAFeaturePreferencesProvider = DefaultACTAFeaturePreferencesProvider()) {
        self.featureProvider = featureProvider
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        var prefs = try await featureProvider.loadPreferences()
        var changed: [String] = []

        if let val = parameters["allow_external_ai"] {
            prefs.allowExternalAI = (val.lowercased() == "true" || val == "1")
            changed.append("allowExternalAI=\(prefs.allowExternalAI)")
        }
        if let val = parameters["allow_voice_input"] {
            prefs.allowVoiceInput = (val.lowercased() == "true" || val == "1")
            changed.append("allowVoiceInput=\(prefs.allowVoiceInput)")
        }
        if let val = parameters["allow_plate_lookup"] {
            prefs.allowPlateRegistryLookup = (val.lowercased() == "true" || val == "1")
            changed.append("allowPlateRegistryLookup=\(prefs.allowPlateRegistryLookup)")
        }

        try await featureProvider.savePreferences(prefs)
        let summary = "Permissions updated: " + (changed.isEmpty ? "no changes" : changed.joined(separator: ", "))
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"updated\": true}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let loaded = try await featureProvider.loadPreferences()
        if let val = parameters["allow_voice_input"] {
            let expected = (val.lowercased() == "true" || val == "1")
            if loaded.allowVoiceInput != expected { return false }
        }
        if let val = parameters["allow_external_ai"], loaded.allowExternalAI != (val == "true" || val == "1") { return false }
        if let val = parameters["allow_plate_lookup"], loaded.allowPlateRegistryLookup != (val == "true" || val == "1") { return false }
        return true
    }
}

// MARK: - 2. Video Analytics Actions

public struct AnalyticsGetSettingsAction: ACTAActionProtocol {
    public let id = "analytics.get_settings"
    public let title = "Get Video Analytics Settings"
    public let description = "Returns active video analytics detection switches, thresholds, FPS, and overlays."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Optional camera UUID for override inspection")
    ]

    private let analyticsProvider: ACTAVideoAnalyticsSettingsProvider?

    public init(analyticsProvider: ACTAVideoAnalyticsSettingsProvider? = nil) {
        self.analyticsProvider = analyticsProvider
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let analyticsProvider else { return .unsupported(actionID: id) }
        guard parameters["camera_id"] == nil else { return .unsupported(actionID: id) }
        let settings = await analyticsProvider.loadSettings()
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let summary = "Video analytics is \(settings.globalEnabled ? "enabled" : "disabled") (Person: \(settings.enablePersonDetection), Fall: \(settings.enableFallDetection), Fight: \(settings.enableFightDetection))"
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: json)
    }
}

public struct AnalyticsSetGlobalToggleAction: ACTAActionProtocol {
    public let id = "analytics.set_global_toggle"
    public let title = "Set Video Analytics Toggle"
    public let description = "Toggle a named global detector, alert display, sound or evidence recording flag. Evidence recording requires explicit operator confirmation."
    public let classification = ACTAActionClassification.reversible
    public static let toggles: [String: WritableKeyPath<VideoAnalyticsSettings, Bool>] = [
        "global": \.globalEnabled, "globalenabled": \.globalEnabled,
        "person": \.enablePersonDetection, "enablepersondetection": \.enablePersonDetection,
        "pose": \.enablePoseEstimation, "enableposeestimation": \.enablePoseEstimation,
        "fall": \.enableFallDetection, "enablefalldetection": \.enableFallDetection,
        "behavior": \.enableBehaviorAnalysis, "enablebehavioranalysis": \.enableBehaviorAnalysis,
        "inactivity": \.enableProlongedInactivity, "enableprolongedinactivity": \.enableProlongedInactivity,
        "loitering": \.enableLoiteringDetection, "enableloiteringdetection": \.enableLoiteringDetection,
        "zone": \.enableZoneMonitoring, "enablezonemonitoring": \.enableZoneMonitoring,
        "unusual_movement": \.enableUnusualMovement, "enableunusualmovement": \.enableUnusualMovement,
        "crowd": \.enableCrowdActivity, "enablecrowdactivity": \.enableCrowdActivity,
        "fight": \.enableFightDetection, "enablefightdetection": \.enableFightDetection,
        "secondary_vlm": \.enableSecondaryVLMVerification, "enablesecondaryvlmverification": \.enableSecondaryVLMVerification,
        "sound": \.enableSoundAlert, "enablesoundalert": \.enableSoundAlert,
        "banner": \.enableVisualAlertBanner, "enablevisualalertbanner": \.enableVisualAlertBanner,
        "evidence": \.enableEvidenceRecording, "enableevidencerecording": \.enableEvidenceRecording
    ]
    public let parameters = [
        ACTAActionParameterSchema(name: "feature", type: "string", description: "Detector/alert flag name", isRequired: true),
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "True to enable, false to disable", isRequired: true)
    ]
    private let analyticsProvider: ACTAVideoAnalyticsSettingsProvider?
    public init(analyticsProvider: ACTAVideoAnalyticsSettingsProvider? = nil) { self.analyticsProvider = analyticsProvider }
    public func requiresConfirmation(parameters: [String: String]) -> Bool {
        ["evidence", "enableevidencerecording"].contains((parameters["feature"] ?? "").lowercased())
    }
    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let analyticsProvider else { return .unsupported(actionID: id) }
        guard let key = Self.toggles[(parameters["feature"] ?? "").lowercased()] else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Unknown analytics feature.")
        }
        let enabled = parameters["enabled"] == "true" || parameters["enabled"] == "1"
        try await analyticsProvider.updateSettings { $0[keyPath: key] = enabled }
        return ACTAActionResult(actionID: id, success: true, summary: "Analytics flag updated.")
    }
    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let analyticsProvider, let key = Self.toggles[(parameters["feature"] ?? "").lowercased()] else { return false }
        let settings = await analyticsProvider.loadSettings()
        return settings[keyPath: key] == (parameters["enabled"] == "true" || parameters["enabled"] == "1")
    }
}

// MARK: - 3. Safety Incidents & Alerts Actions

public struct IncidentListAction: ACTAActionProtocol {
    public let id = "incident.list"
    public let title = "List Safety Incidents"
    public let description = "Lists safety incidents recorded by fall/fight/zone analytics, optionally filtered by camera, status or text."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID to filter"),
        ACTAActionParameterSchema(name: "open_only", type: "boolean", description: "Only show open / active incidents"),
        ACTAActionParameterSchema(name: "query", type: "string", description: "Case-insensitive text in camera name, localized title, explanation or operator notes"),
        ACTAActionParameterSchema(name: "limit", type: "integer", description: "Max incidents to return (1...100)")
    ]

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

public struct IncidentTransitionStatusAction: ACTAActionProtocol {
    public let id = "incident.transition_status"
    public let title = "Transition Incident Status"
    public let description = "Transitions a safety incident state (acknowledged, confirmed, resolved, false_positive, suppressed, active)."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "incident_id", type: "string", description: "UUID of incident", isRequired: true),
        ACTAActionParameterSchema(name: "status", type: "string", description: "Target status", isRequired: true, allowedValues: ["acknowledged", "confirmed", "resolved", "false_positive", "suppressed", "active"]),
        ACTAActionParameterSchema(name: "note", type: "string", description: "Operator transition note")
    ]

    public init() {}

    public func requiresConfirmation(parameters: [String: String]) -> Bool {
        parameters["status"] == "false_positive"
            || !(parameters["note"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func validate(parameters: [String: String]) throws {
        guard parameters["note"].map({ $0.count <= 4000 }) ?? true else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Incident note must be at most 4000 characters.")
        }
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

public struct IncidentUpdateNoteAction: ACTAActionProtocol {
    public let id = "incident.update_note"
    public let title = "Update Incident Note"
    public let description = "Replace or clear the operator note after explicit operator review, without changing incident status."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "incident_id", type: "string", description: "Incident UUID", isRequired: true),
        ACTAActionParameterSchema(name: "note", type: "string", description: "Replacement note, at most 4000 characters; empty clears it", isRequired: true, allowsEmpty: true)
    ]

    public init() {}
    public func requiresConfirmation(parameters: [String: String]) -> Bool { true }
    public func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys) == Set(["incident_id", "note"]),
              let value = parameters["incident_id"], UUID(uuidString: value) != nil,
              let note = parameters["note"],
              note.count <= 4000 else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide an incident UUID and a note of at most 4000 characters.")
        }
    }
    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

public struct IncidentDeleteEvidenceAction: ACTAActionProtocol {
    public let id = "incident.delete_evidence"
    public let title = "Delete Incident Evidence"
    public let description = "Permanently deletes recorded video/frame evidence associated with a safety incident."
    public let classification = ACTAActionClassification.destructive
    public let parameters = [
        ACTAActionParameterSchema(name: "incident_id", type: "string", description: "UUID of incident", isRequired: true)
    ]

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

// MARK: - 4. Memory & Narrative Actions

public struct MemoryDeleteFrameAction: ACTAActionProtocol {
    public let id = "memory.delete_frame"
    public let title = "Delete Sampled Memory Frame"
    public let description = "Deletes a specific sampled memory frame from local disk."
    public let classification = ACTAActionClassification.destructive
    public let parameters = [
        ACTAActionParameterSchema(name: "frame_id", type: "string", description: "UUID of frame", isRequired: true)
    ]

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

public struct MemoryClearAllFramesAction: ACTAActionProtocol {
    public let id = "memory.clear_all_frames"
    public let title = "Clear All Sampled Memory Frames"
    public let description = "Permanently purges all locally retained chronological memory frames."
    public let classification = ACTAActionClassification.destructive
    public let parameters: [ACTAActionParameterSchema] = []

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

// MARK: - 5. Watch Rules Actions

public struct WatchListAction: ACTAActionProtocol {
    public let id = "watch.list"
    public let title = "List Operations Watch Rules"
    public let description = "Lists active persistent visual watch rules."
    public let classification = ACTAActionClassification.inspect
    public let parameters: [ACTAActionParameterSchema] = []

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

public struct WatchCreateAction: ACTAActionProtocol {
    public let id = "watch.create"
    public let title = "Create Operations Watch Rule"
    public let description = "Creates a persistent visual watch rule on specific cameras or all cameras."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "text", type: "string", description: "Watch description or condition", isRequired: true),
        ACTAActionParameterSchema(name: "camera_ids", type: "string", description: "Comma-separated camera IDs, or empty for all"),
        ACTAActionParameterSchema(name: "ttl_minutes", type: "integer", description: "Expiration in minutes (omit for default)"),
        ACTAActionParameterSchema(name: "forever", type: "boolean", description: "True to keep rule active indefinitely")
    ]

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}

public struct WatchCancelAction: ACTAActionProtocol {
    public let id = "watch.cancel"
    public let title = "Cancel Operations Watch Rule"
    public let description = "Cancels an existing visual watch rule by ID."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "watch_id", type: "string", description: "UUID of watch rule to cancel", isRequired: true)
    ]

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        return .unsupported(actionID: id)
    }
}
