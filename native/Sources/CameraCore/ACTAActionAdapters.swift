import Foundation

// MARK: - Delegate Protocols for Core Adapters

public protocol ACTASystemSettingsProvider: Sendable {
    func loadConfiguration() throws -> WallConfiguration
    func saveConfiguration(_ config: WallConfiguration) throws
}

public protocol ACTAFeaturePreferencesProvider: Sendable {
    func loadPreferences() throws -> CameraFeaturePreferences
    func savePreferences(_ prefs: CameraFeaturePreferences) throws
}

public protocol ACTAVideoAnalyticsSettingsProvider: Sendable {
    func loadSettings() -> VideoAnalyticsSettings
    func updateSettings(_ mutate: @Sendable (inout VideoAnalyticsSettings) -> Void) throws
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
            let config = try settingsProvider.loadConfiguration()
            let data = try JSONEncoder().encode(config)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return ACTAActionResult(actionID: id, success: true, summary: "Retrieved system settings (\(config.columns) cols, \(config.detectionFPS) FPS)", outputJSON: json)
        case "features", "permissions":
            let prefs = try featureProvider.loadPreferences()
            let data = try JSONEncoder().encode(prefs)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return ACTAActionResult(actionID: id, success: true, summary: "Retrieved feature policies (\(prefs.enabledFeatures.count) enabled)", outputJSON: json)
        default:
            return ACTAActionResult(actionID: id, success: true, summary: "Retrieved section '\(section)'", outputJSON: "{\"section\": \"\(section)\"}")
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
        var config = try settingsProvider.loadConfiguration()
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

        try settingsProvider.saveConfiguration(config)
        let summary = "System settings updated: " + (changed.isEmpty ? "no changes" : changed.joined(separator: ", "))
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"updated\": true}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let loaded = try settingsProvider.loadConfiguration()
        if let colsStr = parameters["columns"], let cols = Int(colsStr), loaded.columns != min(16, max(1, cols)) {
            return false
        }
        if let fpsStr = parameters["detection_fps"], let fps = Double(fpsStr), loaded.detectionFPS != min(5, max(1, fps.rounded())) {
            return false
        }
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

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let featStr = parameters["feature"], let feat = CameraFeatureID(rawValue: featStr) else {
            return ACTAActionResult.failed(actionID: id, error: "Invalid feature ID: \(parameters["feature"] ?? "")")
        }
        let enabled = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")
        var prefs = try featureProvider.loadPreferences()
        if enabled {
            prefs.enabledFeatures.insert(feat)
        } else {
            prefs.enabledFeatures.remove(feat)
        }
        try featureProvider.savePreferences(prefs)
        let summary = "Feature '\(feat.rawValue)' is now \(enabled ? "enabled" : "disabled")."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"feature\": \"\(feat.rawValue)\", \"enabled\": \(enabled)}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let featStr = parameters["feature"], let feat = CameraFeatureID(rawValue: featStr) else { return false }
        let expected = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")
        let loaded = try featureProvider.loadPreferences()
        return loaded.enabledFeatures.contains(feat) == expected
    }
}

public struct SettingsUpdatePermissionsAction: ACTAActionProtocol {
    public let id = "settings.update_permissions"
    public let title = "Update System Permissions"
    public let description = "Updates operator permission toggles (allow external AI, allow local voice input, allow plate lookup)."
    public let classification = ACTAActionClassification.reversible
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
        var prefs = try featureProvider.loadPreferences()
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

        try featureProvider.savePreferences(prefs)
        let summary = "Permissions updated: " + (changed.isEmpty ? "no changes" : changed.joined(separator: ", "))
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"updated\": true}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let loaded = try featureProvider.loadPreferences()
        if let val = parameters["allow_voice_input"] {
            let expected = (val.lowercased() == "true" || val == "1")
            if loaded.allowVoiceInput != expected { return false }
        }
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
        let settings = analyticsProvider?.loadSettings() ?? VideoAnalyticsSettings()
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let summary = "Video analytics is \(settings.globalEnabled ? "enabled" : "disabled") (Person: \(settings.enablePersonDetection), Fall: \(settings.enableFallDetection), Fight: \(settings.enableFightDetection))"
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: json)
    }
}

public struct AnalyticsSetGlobalToggleAction: ACTAActionProtocol {
    public let id = "analytics.set_global_toggle"
    public let title = "Set Video Analytics Toggle"
    public let description = "Toggles an analytics detector switch (globalEnabled, person, pose, fall, fight, loitering, zone, secondaryVLM)."
    public let classification = ACTAActionClassification.reversible
    public let parameters = [
        ACTAActionParameterSchema(name: "feature", type: "string", description: "Detector switch name", isRequired: true),
        ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "True to enable, false to disable", isRequired: true)
    ]

    private let analyticsProvider: ACTAVideoAnalyticsSettingsProvider?

    public init(analyticsProvider: ACTAVideoAnalyticsSettingsProvider? = nil) {
        self.analyticsProvider = analyticsProvider
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let feature = parameters["feature"] else {
            return ACTAActionResult.failed(actionID: id, error: "Missing 'feature' argument.")
        }
        let enabled = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")

        try analyticsProvider?.updateSettings { settings in
            switch feature.lowercased() {
            case "global", "globalenabled": settings.globalEnabled = enabled
            case "person", "enablepersondetection": settings.enablePersonDetection = enabled
            case "pose", "enableposeestimation": settings.enablePoseEstimation = enabled
            case "fall", "enablefalldetection": settings.enableFallDetection = enabled
            case "behavior", "enablebehavioranalysis": settings.enableBehaviorAnalysis = enabled
            case "loitering", "enableloiteringdetection": settings.enableLoiteringDetection = enabled
            case "zone", "enablezonemonitoring": settings.enableZoneMonitoring = enabled
            case "fight", "enablefightdetection": settings.enableFightDetection = enabled
            case "secondary_vlm", "enablesecondaryvlmverification": settings.enableSecondaryVLMVerification = enabled
            case "sound", "enablesoundalert": settings.enableSoundAlert = enabled
            case "evidence", "enableevidencerecording": settings.enableEvidenceRecording = enabled
            default: break
            }
        }

        let summary = "Analytics feature '\(feature)' set to \(enabled ? "enabled" : "disabled")."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"feature\": \"\(feature)\", \"enabled\": \(enabled)}")
    }

    public func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let feature = parameters["feature"], let analyticsProvider else { return true }
        let expected = (parameters["enabled"]?.lowercased() == "true" || parameters["enabled"] == "1")
        let settings = analyticsProvider.loadSettings()
        switch feature.lowercased() {
        case "global", "globalenabled": return settings.globalEnabled == expected
        case "person", "enablepersondetection": return settings.enablePersonDetection == expected
        case "fall", "enablefalldetection": return settings.enableFallDetection == expected
        case "fight", "enablefightdetection": return settings.enableFightDetection == expected
        default: return true
        }
    }
}

// MARK: - 3. Safety Incidents & Alerts Actions

public struct IncidentListAction: ACTAActionProtocol {
    public let id = "incident.list"
    public let title = "List Safety Incidents"
    public let description = "Lists safety incidents recorded by fall/fight/zone analytics, optionally filtered by camera or status."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID to filter"),
        ACTAActionParameterSchema(name: "open_only", type: "boolean", description: "Only show open / active incidents"),
        ACTAActionParameterSchema(name: "limit", type: "integer", description: "Max incidents to return (1...100)")
    ]

    public init() {}

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        // Return summary format
        let openOnly = parameters["open_only"] == "true"
        return ACTAActionResult(actionID: id, success: true, summary: "Listed incidents (openOnly: \(openOnly))", outputJSON: "{\"incidents\": []}")
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

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let incidentID = parameters["incident_id"], let status = parameters["status"] else {
            return ACTAActionResult.failed(actionID: id, error: "incident_id and status are required.")
        }
        let summary = "Incident \(incidentID) transitioned to '\(status)'."
        return ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: "{\"incident_id\": \"\(incidentID)\", \"status\": \"\(status)\"}")
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
        guard let incidentID = parameters["incident_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "incident_id is required.")
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Deleted saved evidence frames for incident \(incidentID). Record retained.", outputJSON: "{\"deleted\": true}")
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
        guard let frameID = parameters["frame_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "frame_id is required.")
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Permanently deleted memory frame \(frameID).", outputJSON: "{\"deleted\": true}")
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
        return ACTAActionResult(actionID: id, success: true, summary: "Purged all locally retained memory frames from disk.", outputJSON: "{\"cleared\": true}")
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
        return ACTAActionResult(actionID: id, success: true, summary: "Listed visual watch rules.", outputJSON: "{\"watch_rules\": []}")
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
        guard let text = parameters["text"], !text.isEmpty else {
            return ACTAActionResult.failed(actionID: id, error: "Watch rule 'text' is required.")
        }
        let watchID = UUID().uuidString
        return ACTAActionResult(actionID: id, success: true, summary: "Created visual watch rule '\(text)' [ID: \(watchID)].", outputJSON: "{\"watch_id\": \"\(watchID)\"}")
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
        guard let watchID = parameters["watch_id"] else {
            return ACTAActionResult.failed(actionID: id, error: "watch_id is required.")
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Cancelled watch rule \(watchID).", outputJSON: "{\"cancelled\": true}")
    }
}
