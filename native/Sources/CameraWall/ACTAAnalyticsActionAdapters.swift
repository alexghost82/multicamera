import CameraCore
import Foundation

/// Finite parameter contracts for the existing AnalyticsSettingsEditor service.
struct WallAnalyticsAction: ACTAActionProtocol {
    enum Kind: String, CaseIterable, Sendable {
        case profile = "analytics.set_sensitivity_profile"
        case removeOverride = "analytics.remove_camera_override"
        case editZone = "analytics.update_restricted_zone"
        case get = "analytics.get_settings"
        case threshold = "analytics.set_threshold"
        case sampling = "analytics.set_sampling_fps"
        case overlay = "analytics.set_overlay"
        case cameraOverride = "analytics.set_camera_override"
        case zone = "analytics.set_restricted_zone"
        case removeZone = "analytics.remove_restricted_zone"
    }
    let kind: Kind
    unowned let model: WallModel
    var id: String { kind.rawValue }
    var title: String { id }
    var description: String {
        switch kind {
        case .profile: return "Select a global sensitivity profile; apply_values defaults to true and applies its threshold preset."
        case .removeOverride: return "Remove a configured camera's complete override including zones; requires confirmation."
        case .editZone: return "Edit a zone by UUID: rename, enabled, hold time, severity, or one polygon point operation. Coordinates must be within [0,1]."
        case .get: return "Read live analytics settings, or a configured camera's override and effective settings."
        case .threshold: return "Set one named analytics numeric threshold. Values outside the service limits are rejected."
        case .sampling: return "Set analytics sampling rates; idle <= fps <= boost, boost <= 15. Does not claim measured throughput."
        case .overlay: return "Enable or disable one analytics display layer."
        case .cameraOverride: return "Update one configured camera's analytics override. inherit=true preserves dormant overrides and zones."
        case .zone: return "Create or update a named rectangular restricted zone with normalized coordinates; preserves existing zone ID and policy."
        case .removeZone: return "Remove exactly one named restricted zone from a configured camera."
        }
    }
    var classification: ACTAActionClassification { kind == .get ? .inspect : kind == .removeOverride ? .destructive : .reversible }

    static let thresholds: [String: WritableKeyPath<VideoAnalyticsSettings, Double>] = [
        "personConfidenceThreshold": \.personConfidenceThreshold,
        "poseKeypointConfidenceThreshold": \.poseKeypointConfidenceThreshold,
        "fallConfirmationSeconds": \.fallConfirmationSeconds,
        "personDownSeconds": \.personDownSeconds,
        "inactivityThresholdSeconds": \.inactivityThresholdSeconds,
        "loiteringThresholdSeconds": \.loiteringThresholdSeconds,
        "alertCooldownSeconds": \.alertCooldownSeconds,
        "preEventBufferSeconds": \.preEventBufferSeconds,
        "postEventBufferSeconds": \.postEventBufferSeconds
    ]
    static let integerThresholds: [String: WritableKeyPath<VideoAnalyticsSettings, Int>] = [
        "minimumVisibleKeypoints": \.minimumVisibleKeypoints,
        "maxEvidenceDiskQuotaMB": \.maxEvidenceDiskQuotaMB,
        "maxConcurrentInferenceTasks": \.maxConcurrentInferenceTasks
    ]
    static let overlays: [String: WritableKeyPath<AnalyticsOverlaySettings, Bool>] = [
        "showBoundingBoxes": \.showBoundingBoxes, "showPoseSkeleton": \.showPoseSkeleton,
        "showTrackID": \.showTrackID, "showBehaviorState": \.showBehaviorState,
        "showFallStatus": \.showFallStatus, "showConfidence": \.showConfidence,
        "showCriticalAlertMarker": \.showCriticalAlertMarker, "showRestrictedZones": \.showRestrictedZones
    ]

    static let cameraFlags: [String: WritableKeyPath<CameraAnalyticsOverride, Bool>] = [
        "personDetectionEnabled": \.personDetectionEnabled, "poseEstimationEnabled": \.poseEstimationEnabled,
        "fallDetectionEnabled": \.fallDetectionEnabled, "behaviorAnalysisEnabled": \.behaviorAnalysisEnabled,
        "inactivityDetectionEnabled": \.inactivityDetectionEnabled, "loiteringDetectionEnabled": \.loiteringDetectionEnabled,
        "zoneMonitoringEnabled": \.zoneMonitoringEnabled, "fightDetectionEnabled": \.fightDetectionEnabled,
        "secondaryVLMVerificationEnabled": \.secondaryVLMVerificationEnabled
    ]

    var parameters: [ACTAActionParameterSchema] {
        func field(_ name: String, _ type: String, _ required: Bool = false, _ allowed: [String]? = nil) -> ACTAActionParameterSchema {
            ACTAActionParameterSchema(name: name, type: type, description: name, isRequired: required, allowedValues: allowed)
        }
        switch kind {
        case .profile: return [field("profile", "string", true, AnalyticsSensitivityProfile.allCases.map(\.rawValue)), field("apply_values", "boolean")]
        case .removeOverride: return [field("camera_id", "string", true)]
        case .editZone: return [field("camera_id", "string", true), field("zone_id", "string", true),
            field("new_name", "string"), field("enabled", "boolean"), field("hold_seconds", "number"),
            field("severity", "string", false, SafetyIncidentSeverity.allCases.map(\.rawValue)),
            field("point_index", "integer"), field("point_x", "number"), field("point_y", "number"),
            field("append_point", "boolean"), field("remove_point", "boolean")]
        case .get: return [field("camera_id", "string")]
        case .threshold: return [field("parameter", "string", true,
            (Array(Self.thresholds.keys) + Array(Self.integerThresholds.keys)).sorted()), field("value", "number", true)]
        case .sampling: return [field("fps", "number", true), field("idle_fps", "number"), field("boost_fps", "number")]
        case .overlay: return [field("layer", "string", true, Self.overlays.keys.sorted()), field("enabled", "boolean", true)]
        case .cameraOverride: return [field("camera_id", "string", true), field("enabled", "boolean"),
            field("fps", "number"), field("inherit", "boolean"), field("clear_fps", "boolean"),
            field("cooldown_seconds", "number"), field("clear_cooldown", "boolean"),
            field("sensitivity_profile", "string", false, AnalyticsSensitivityProfile.allCases.map(\.rawValue))]
            + Self.cameraFlags.keys.sorted().map { field($0, "boolean") }
        case .zone: return [field("camera_id", "string", true), field("name", "string", true),
            field("x", "number", true), field("y", "number", true), field("width", "number", true), field("height", "number", true)]
        case .removeZone: return [field("camera_id", "string", true), field("name", "string", true)]
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool {
        // Storage retention and pre/post buffers affect private evidence; confirm either direction.
        kind == .removeOverride || kind == .threshold && ["preEventBufferSeconds", "postEventBufferSeconds", "maxEvidenceDiskQuotaMB"].contains(parameters["parameter"] ?? "")
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            let engine = model.localAnalyticsEngine
            var next = engine.settings
            func number(_ key: String) throws -> Double {
                guard let value = parameters[key].flatMap(Double.init), value.isFinite else {
                    throw ConfigurationError.invalid("INVALID_ARGUMENT: \(key) requires a finite number.")
                }
                return value
            }
            @MainActor func cameraID() throws -> UUID {
                guard let value = parameters["camera_id"], let id = UUID(uuidString: value),
                      model.config.cameras.contains(where: { $0.id == id }) else {
                    throw ConfigurationError.invalid("Camera UUID does not identify a configured camera.")
                }
                return id
            }
            func encoded<T: Encodable>(_ value: T) throws -> String {
                String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            }
            if kind == .get {
                if parameters["camera_id"] != nil {
                    let camera = try cameraID()
                    let override = next.cameraOverrides[camera] ?? CameraAnalyticsOverride(cameraID: camera)
                    let enabled = model.config.cameras.first { $0.id == camera }?.yoloEnabled ?? false
                    let effective = next.effectiveConfiguration(for: camera, cameraYOLOEnabled: enabled)
                    return ACTAActionResult(actionID: id, success: true, summary: "Read camera analytics configuration.",
                        outputJSON: "{\"override\":\(try encoded(override)),\"effective\":\(try encoded(effective))}")
                }
                return ACTAActionResult(actionID: id, success: true, summary: "Read global analytics configuration.", outputJSON: try encoded(next))
            }
            switch kind {
            case .profile:
                guard let profile = AnalyticsSensitivityProfile(rawValue: parameters["profile"] ?? "") else {
                    throw ConfigurationError.invalid("Unknown sensitivity profile.")
                }
                if parameters["apply_values"] != "false" { next.applySensitivityProfile(profile) }
                else { next.sensitivityProfile = profile }
            case .removeOverride:
                let camera = try cameraID()
                guard next.cameraOverrides.removeValue(forKey: camera) != nil else {
                    throw ConfigurationError.invalid("Camera override does not exist.")
                }
            case .editZone:
                let camera = try cameraID()
                guard let zoneID = parameters["zone_id"].flatMap(UUID.init(uuidString:)),
                      var override = next.cameraOverrides[camera],
                      let index = override.restrictedZones.firstIndex(where: { $0.id == zoneID }) else {
                    throw ConfigurationError.invalid("Zone UUID does not identify a zone on this camera.")
                }
                guard parameters.count > 2 else { throw ConfigurationError.invalid("Specify a zone change.") }
                var zone = override.restrictedZones[index]
                if let name = parameters["new_name"] {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty, clean.count <= 200,
                          !override.restrictedZones.contains(where: { $0.id != zoneID && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
                        throw ConfigurationError.invalid("Zone name is empty, too long or ambiguous.")
                    }
                    zone.name = clean
                }
                if let enabled = parameters["enabled"] { zone.enabled = enabled == "true" }
                if parameters["hold_seconds"] != nil { zone.holdSeconds = try number("hold_seconds") }
                if let severity = parameters["severity"].flatMap(SafetyIncidentSeverity.init(rawValue:)) { zone.severity = severity }
                let append = parameters["append_point"] == "true", remove = parameters["remove_point"] == "true"
                let hasCoordinates = parameters["point_x"] != nil || parameters["point_y"] != nil
                guard !(append && remove), !(append && parameters["point_index"] != nil), !(remove && hasCoordinates) else {
                    throw ConfigurationError.invalid("Conflicting polygon point operations.")
                }
                if append || remove || hasCoordinates || parameters["point_index"] != nil {
                    if append || hasCoordinates {
                        let x = try number("point_x"), y = try number("point_y")
                        guard (0...1).contains(x), (0...1).contains(y) else { throw ConfigurationError.invalid("Polygon coordinates must be within [0,1].") }
                        let point = NormalizedPoint(x: x, y: y)
                        if append {
                            guard zone.points.count < 64 else { throw ConfigurationError.invalid("A polygon cannot exceed 64 points.") }
                            zone.points.append(point)
                        } else {
                            guard let pointIndex = parameters["point_index"].flatMap(Int.init), zone.points.indices.contains(pointIndex) else {
                                throw ConfigurationError.invalid("Polygon point index does not exist.")
                            }
                            zone.points[pointIndex] = point
                        }
                    } else if remove {
                        guard let pointIndex = parameters["point_index"].flatMap(Int.init), zone.points.indices.contains(pointIndex), zone.points.count > 3 else {
                            throw ConfigurationError.invalid("A polygon requires at least three points and a valid point index.")
                        }
                        zone.points.remove(at: pointIndex)
                    } else { throw ConfigurationError.invalid("Point index requires coordinates or remove_point=true.") }
                }
                override.restrictedZones[index] = zone
                next.cameraOverrides[camera] = override
            case .threshold:
                let name = parameters["parameter"] ?? ""
                let value = try number("value")
                if let key = Self.thresholds[name] { next[keyPath: key] = value }
                else if let key = Self.integerThresholds[name] {
                    guard value.rounded() == value, (0...65536).contains(value) else {
                        throw ConfigurationError.invalid("Threshold requires an integer in the service range.")
                    }
                    next[keyPath: key] = Int(value)
                } else { throw ConfigurationError.invalid("Unknown threshold.") }
            case .sampling:
                next.analyticsSamplingFPS = try number("fps")
                if parameters["idle_fps"] != nil { next.idleCameraSamplingFPS = try number("idle_fps") }
                if parameters["boost_fps"] != nil { next.activeFallBoostFPS = try number("boost_fps") }
                guard next.activeFallBoostFPS <= 15 else { throw ConfigurationError.invalid("Boost FPS must not exceed 15 for this runtime.") }
            case .overlay:
                guard let key = Self.overlays[parameters["layer"] ?? ""] else { throw ConfigurationError.invalid("Unknown overlay.") }
                next.overlaySettings[keyPath: key] = parameters["enabled"] == "true"
            case .cameraOverride, .zone, .removeZone:
                let camera = try cameraID()
                var override = next.cameraOverrides[camera] ?? CameraAnalyticsOverride(cameraID: camera)
                if kind == .cameraOverride {
                    guard parameters.count > 1 else { throw ConfigurationError.invalid("Specify at least one override field.") }
                    let changes = Set(parameters.keys).subtracting(["camera_id", "inherit"])
                    guard !(parameters["inherit"] == "true" && !changes.isEmpty) else {
                        throw ConfigurationError.invalid("Do not combine inherit=true with dormant override changes.")
                    }
                    guard !(parameters["clear_fps"] == "true" && parameters["fps"] != nil),
                          !(parameters["clear_cooldown"] == "true" && parameters["cooldown_seconds"] != nil) else {
                        throw ConfigurationError.invalid("Do not set and clear the same override in one action.")
                    }
                    if let value = parameters["inherit"] { override.inheritGlobalSettings = value == "true" }
                    else if !changes.isEmpty { override.inheritGlobalSettings = false }
                    if let value = parameters["enabled"] { override.analyticsEnabled = value == "true" }
                    for (name, key) in Self.cameraFlags {
                        if let value = parameters[name] { override[keyPath: key] = value == "true" }
                    }
                    if parameters["fps"] != nil { override.customSamplingFPS = try number("fps") }
                    if parameters["clear_fps"] == "true" { override.customSamplingFPS = nil }
                    if parameters["cooldown_seconds"] != nil { override.customAlertCooldownSeconds = try number("cooldown_seconds") }
                    if parameters["clear_cooldown"] == "true" { override.customAlertCooldownSeconds = nil }
                    if let profile = parameters["sensitivity_profile"].flatMap(AnalyticsSensitivityProfile.init(rawValue:)) { override.sensitivityProfile = profile }
                } else {
                    let name = (parameters["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name.count <= 200 else { throw ConfigurationError.invalid("Zone name requires 1...200 characters.") }
                    let matches = override.restrictedZones.indices.filter { override.restrictedZones[$0].name.caseInsensitiveCompare(name) == .orderedSame }
                    guard matches.count <= 1 else { throw ConfigurationError.invalid("Zone name is ambiguous.") }
                    if kind == .removeZone {
                        guard let index = matches.first else { throw ConfigurationError.invalid("Zone does not exist.") }
                        override.restrictedZones.remove(at: index)
                    } else {
                        let x = try number("x"), y = try number("y"), width = try number("width"), height = try number("height")
                        guard x >= 0, y >= 0, width > 0, height > 0, x + width <= 1, y + height <= 1 else {
                            throw ConfigurationError.invalid("Zone rectangle must have positive dimensions and fit inside [0,1].")
                        }
                        if let index = matches.first {
                            // Preserve ID, enabled state, hold time and severity on geometric edits.
                            override.restrictedZones[index].points = RestrictedZoneRegion.rectangle(name: name,
                                x: x, y: y, width: width, height: height).points
                        } else {
                            override.restrictedZones.append(.rectangle(name: name, x: x, y: y, width: width, height: height))
                        }
                    }
                }
                next.cameraOverrides[camera] = override
            case .get: break
            }
            // updateSettings clamps GUI drafts; agent arguments must instead be rejected before any write.
            try next.validate()
            guard next.clamped() == next else { throw ConfigurationError.invalid("Requested settings would be clamped by the runtime.") }
            try engine.updateSettings(next)
            let persisted = try VideoAnalyticsSettingsStore.load(from: engine.settingsURL)
            guard persisted == next, engine.settings == next else { throw ConfigurationError.invalid("Analytics persistence verification failed.") }
            return ACTAActionResult(actionID: id, success: true, summary: "Analytics settings saved and verified.", outputJSON: try encoded(persisted))
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        // Execute checks complete runtime and persisted settings in one uninterrupted MainActor block.
        true
    }
}
