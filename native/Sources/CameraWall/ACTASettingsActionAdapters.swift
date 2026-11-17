import CameraCore
import Foundation

/// Finite, patch-based contracts. Codable round trips keep each existing store's format and validation.
struct WallSettingsAction: ACTAActionProtocol {
    enum Kind: String, CaseIterable, Sendable {
        case get = "settings.get_section"
        case fall = "settings.update_runtime_fall", storage = "settings.update_runtime_storage", crop = "settings.update_runtime_crop"
        case events = "settings.update_events_alerts", memory = "settings.update_memory_policy", schedules = "settings.update_schedules"
        case saveRule = "settings.save_alert_rule", removeRule = "settings.remove_alert_rule"
    }
    let kind: Kind
    unowned let model: WallModel
    var id: String { kind.rawValue }
    var title: String { id }
    var description: String {
        switch kind {
        case .get: return "Inspect current settings owned by a section. URLs are redacted; no keys/media/bookmarks. Configuration is not a model/health benchmark. identity section is not supported yet."
        case .fall: return "Patch advanced fall tracking settings; the four common confidence/duration fields belong to analytics actions instead. Applies the existing GUI runtime service."
        case .storage: return "Patch storage cleanup policy after review. The janitor may remove data later; saving is not proof that cleanup ran."
        case .crop: return "Patch capture scheduler/crop selection settings through the existing GUI runtime service."
        case .events: return "Patch person-count alert thresholds and critical sound preferences. Does not fabricate an alert."
        case .memory: return "Patch retainFullFrames/retentionDays after review; feature enablement is a separate action. Sampled frames still have a fixed seven-day store cap."
        case .schedules: return "Patch periodic analysis settings after review. camera_ids is a comma-separated list of configured UUIDs, empty clears it. No inference completion is certified."
        case .saveRule: return "Create or edit a periodic-analysis alert condition after review. Omit rule_id to create; read schedules section for IDs. Does not grant tool permissions."
        case .removeRule: return "Remove one saved periodic-analysis alert rule by UUID after review."
        }
    }
    var classification: ACTAActionClassification {
        switch kind {
        case .get: return .inspect
        case .storage, .memory, .schedules, .saveRule, .removeRule: return .securitySensitive
        case .fall, .crop: return .serviceAffecting
        case .events: return .reversible
        }
    }
    static let fallIntegers: Set<String> = ["minimumConfirmingSamples", "minimumBaselineSamples", "recoverySamples", "maximumTracks"]
    static let fallExcluded: Set<String> = ["fallPersistenceSeconds", "personDownSeconds", "primaryConfidence", "keypointConfidence"]
    static let storageIntegers: Set<String> = ["maxCropsPerIdentity", "trackImageRetentionDays", "logRetentionDays"]
    static let cropKeys: Set<String> = ["bootstrapSeconds", "intervalSeconds", "movementFraction", "inheritMaxAge", "inheritMinIoU", "staleTrackTTL"]

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw ConfigurationError.invalid("Settings object serialization failed.")
        }
        return fields
    }
    static func fields<T: Encodable>(_ defaults: T, integers: Set<String> = [], booleans: Set<String> = [], excluding: Set<String> = []) -> [ACTAActionParameterSchema] {
        // All inputs are fixed Codable structs. A schema encoding failure must not enable an arbitrary field.
        let keys = (try? object(defaults).keys.sorted()) ?? []
        return keys.filter { !excluding.contains($0) }.map {
            ACTAActionParameterSchema(name: $0, type: booleans.contains($0) ? "boolean" : integers.contains($0) ? "integer" : "number", description: $0)
        }
    }
    var parameters: [ACTAActionParameterSchema] {
        func field(_ name: String, _ type: String, _ required: Bool = false, _ values: [String]? = nil) -> ACTAActionParameterSchema {
            ACTAActionParameterSchema(name: name, type: type, description: name, isRequired: required, allowedValues: values)
        }
        switch kind {
        case .get: return [field("section", "string", true, ["general", "cameras", "models", "advanced", "runtime", "analytics", "ai", "schedules", "missions", "events", "memory", "features", "permissions", "showcase", "identity", "system"])]
        case .fall: return Self.fields(FallDetectorConfiguration(), integers: Self.fallIntegers, excluding: Self.fallExcluded)
        case .storage: return Self.fields(ACTAStorageJanitorPolicy(), integers: Self.storageIntegers, booleans: ["dataSaverEnabled"])
        case .crop: return Self.fields(ACTACaptureScheduler.Config()) + [field("cropWindowSeconds", "number"), field("cropTopK", "integer"), field("cropImprovementRatio", "number")]
        case .events: return Self.fields(OperationsPreferences(), integers: ["personThreshold", "holdSeconds", "cooldownSeconds"], booleans: ["personCountAlertsEnabled", "criticalSoundEnabled"])
        case .memory: return [field("retainFullFrames", "boolean"), field("retentionDays", "integer")]
        case .schedules: return [field("scheduleEnabled", "boolean"), field("intervalSeconds", "integer"), field("analyzeAllEnabledCameras", "boolean"), field("camera_ids", "string")]
        case .saveRule: return [field("rule_id", "string"), field("condition", "string"), field("enabled", "boolean"), field("cooldownSeconds", "integer"), field("priority", "string", false, ["normal", "critical"])]
        case .removeRule: return [field("rule_id", "string", true)]
        }
    }
    func validate(parameters: [String: String]) throws {
        guard kind == .get || !parameters.isEmpty else { throw ConfigurationError.invalid("Specify at least one settings change.") }
        if let condition = parameters["condition"] {
            guard !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, condition.count <= 500 else {
                throw ConfigurationError.invalid("Alert condition requires 1...500 characters.")
            }
        }
        if kind == .saveRule, parameters["rule_id"] == nil, parameters["condition"] == nil {
            throw ConfigurationError.invalid("A new alert rule requires a condition.")
        }
        if let ruleID = parameters["rule_id"], UUID(uuidString: ruleID) == nil {
            throw ConfigurationError.invalid("Alert rule ID must be a UUID.")
        }
    }
    static func patch<T: Codable>(_ value: T, parameters: [String: String], schema: [ACTAActionParameterSchema]) throws -> T {
        var fields = try object(value)
        for (name, input) in parameters {
            guard fields[name] != nil, let field = schema.first(where: { $0.name == name }) else {
                throw ConfigurationError.invalid("Unknown settings field.")
            }
            switch field.type {
            case "boolean": fields[name] = input == "true"
            case "integer":
                guard let number = Int(input) else { throw ConfigurationError.invalid("Settings field requires an integer.") }
                fields[name] = number
            case "number":
                guard let number = Double(input), number.isFinite else { throw ConfigurationError.invalid("Settings field requires a finite number.") }
                fields[name] = number
            default: throw ConfigurationError.invalid("Unsupported settings field type.")
            }
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            try validate(parameters: parameters)
            func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            func result(_ value: String) -> ACTAActionResult {
                ACTAActionResult(actionID: id, success: true, summary: "Settings saved and verified; runtime work completion is not certified.", outputJSON: value)
            }
            if kind == .get { return try readSection(parameters["section"] ?? "") }
            switch kind {
            case .fall, .storage, .crop:
                var next = model.runtimePreferences
                switch kind {
                case .fall: next.fall = try Self.patch(next.fall, parameters: parameters, schema: self.parameters)
                case .storage: next.storage = try Self.patch(next.storage, parameters: parameters, schema: self.parameters)
                default:
                    next.capture = try Self.patch(next.capture, parameters: parameters.filter { Self.cropKeys.contains($0.key) }, schema: self.parameters)
                    if let value = parameters["cropWindowSeconds"].flatMap(Double.init) { next.cropWindowSeconds = value }
                    if let value = parameters["cropTopK"].flatMap(Int.init) { next.cropTopK = value }
                    if let value = parameters["cropImprovementRatio"].flatMap(Double.init) { next.cropImprovementRatio = value }
                }
                try next.validate()
                try model.saveRuntimePreferences(next)
                guard try AdvancedRuntimePreferences.load(from: model.runtimePreferencesURL) == next,
                      model.runtimePreferences == next, model.actaAnalytics.janitorPolicy == next.storage else {
                    throw ConfigurationError.invalid("Runtime settings persistence verification failed.")
                }
                return result(try json(next))
            case .events:
                let next = try Self.patch(model.operationsPreferences, parameters: parameters, schema: self.parameters)
                try next.validate()
                try model.saveOperationsPreferences(next)
                guard try OperationsPreferencesStore.load(from: model.operationsPreferencesURL) == next, model.operationsPreferences == next else {
                    throw ConfigurationError.invalid("Operations settings persistence verification failed.")
                }
                return result(try json(next))
            case .memory:
                var next = try model.featurePolicySnapshotChecked()
                if let value = parameters["retainFullFrames"] { next.retainFullFrames = value == "true" }
                if let value = parameters["retentionDays"].flatMap(Int.init) { next.retentionDays = value }
                try next.validate()
                try model.saveFeaturePolicy(next)
                guard try model.featurePolicySnapshotChecked() == next else { throw ConfigurationError.invalid("Feature policy persistence verification failed.") }
                return result("{\"policy\":\(try json(next)),\"sampled_frame_retention_days_cap\":\(CameraMemoryStore.retentionDays)}")
            case .schedules, .saveRule, .removeRule:
                var next = model.vlmPreferences
                guard Set(next.alertRules.map(\.id)).count == next.alertRules.count else {
                    throw ConfigurationError.invalid("Alert rule IDs are ambiguous; reload a valid configuration.")
                }
                if kind == .schedules {
                    if let value = parameters["scheduleEnabled"] { next.scheduleEnabled = value == "true" }
                    if let value = parameters["intervalSeconds"].flatMap(Int.init) { next.intervalSeconds = value }
                    if let value = parameters["analyzeAllEnabledCameras"] { next.analyzeAllEnabledCameras = value == "true" }
                    if let raw = parameters["camera_ids"] {
                        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                        let ids = parts.compactMap(UUID.init(uuidString:))
                        guard ids.count == parts.count, Set(ids).count == ids.count, ids.allSatisfy({ id in model.config.cameras.contains { $0.id == id } }) else {
                            throw ConfigurationError.invalid("Schedule camera IDs must be unique configured UUIDs.")
                        }
                        next.scheduledCameraIDs = Set(ids)
                    }
                    guard !next.scheduleEnabled || next.analyzeAllEnabledCameras || !next.scheduledCameraIDs.isEmpty else {
                        throw ConfigurationError.invalid("Select at least one camera for enabled scheduled analysis.")
                    }
                } else if kind == .removeRule {
                    guard let ruleID = parameters["rule_id"].flatMap(UUID.init(uuidString:)), next.alertRules.contains(where: { $0.id == ruleID }) else {
                        throw ConfigurationError.invalid("Alert rule does not exist.")
                    }
                    next.alertRules.removeAll { $0.id == ruleID }
                } else {
                    let ruleID = parameters["rule_id"].flatMap(UUID.init(uuidString:))
                    var rule: VLMAlertRule
                    if let ruleID {
                        guard let existing = next.alertRules.first(where: { $0.id == ruleID }) else { throw ConfigurationError.invalid("Alert rule does not exist.") }
                        rule = existing
                    } else { rule = VLMAlertRule(condition: parameters["condition"] ?? "") }
                    if let value = parameters["condition"] { rule.condition = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if let value = parameters["enabled"] { rule.enabled = value == "true" }
                    if let value = parameters["cooldownSeconds"].flatMap(Int.init) { rule.cooldownSeconds = value }
                    if let value = parameters["priority"].flatMap(OperationsAlertReview.Priority.init(rawValue:)) { rule.priority = value }
                    if let index = next.alertRules.firstIndex(where: { $0.id == rule.id }) { next.alertRules[index] = rule }
                    else { next.alertRules.append(rule) }
                }
                try next.validate()
                try model.saveVLMPreferences(next)
                guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == next, model.vlmPreferences == next else {
                    throw ConfigurationError.invalid("Schedule settings persistence verification failed.")
                }
                // Do not return unrelated endpoint configuration to the model.
                return result(try scheduleJSON(next))
            case .get: return .unsupported(actionID: id)
            }
        }
    }
    @MainActor private func scheduleJSON(_ value: VLMPreferences) throws -> String {
        let object: [String: Any] = ["scheduleEnabled": value.scheduleEnabled, "intervalSeconds": value.intervalSeconds,
            "analyzeAllEnabledCameras": value.analyzeAllEnabledCameras, "scheduledCameraIDs": value.scheduledCameraIDs.map(\.uuidString).sorted(),
            "alertRules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value.alertRules))]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    @MainActor private func readSection(_ section: String) throws -> ACTAActionResult {
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        func object(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
        let output: String
        switch section {
        case "general", "system":
            _ = try model.cameraConfigurationChecked()
            output = try object(["columns": model.config.columns, "detectionThreshold": model.config.detectionThreshold,
                "detectionFPS": model.config.detectionFPS, "staleAfterMilliseconds": model.config.staleAfterMilliseconds,
                "apiPort": model.config.apiPort, "rtspPort": model.config.rtspPort, "go2rtcPath": model.config.go2rtcPath,
                "running": model.running, "connecting": model.connecting, "health_verified": false])
        case "advanced", "runtime":
            guard try AdvancedRuntimePreferences.load(from: model.runtimePreferencesURL) == model.runtimePreferences else {
                throw ConfigurationError.invalid("Runtime preferences changed on disk; reload them before making changes.")
            }
            output = try json(model.runtimePreferences)
        case "features", "permissions": output = try json(model.featurePolicySnapshotChecked())
        case "memory": output = "{\"policy\":\(try json(model.featurePolicySnapshotChecked())),\"sampled_frame_retention_days_cap\":\(CameraMemoryStore.retentionDays)}"
        case "analytics":
            guard try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL) == model.localAnalyticsEngine.settings else {
                throw ConfigurationError.invalid("Analytics settings changed on disk; reload them before inspecting.")
            }
            output = try json(model.localAnalyticsEngine.settings)
        case "events":
            guard try OperationsPreferencesStore.load(from: model.operationsPreferencesURL) == model.operationsPreferences else {
                throw ConfigurationError.invalid("Operations preferences changed on disk; reload them before making changes.")
            }
            output = try json(model.operationsPreferences)
        case "schedules":
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == model.vlmPreferences else {
                throw ConfigurationError.invalid("AI preferences changed on disk; reload them before making changes.")
            }
            output = try scheduleJSON(model.vlmPreferences)
        case "models":
            let url = model.configURL.deletingLastPathComponent().appendingPathComponent("model-preferences.json")
            guard try ModelSelectionPreferences.load(from: url) == model.modelPreferences else {
                throw ConfigurationError.invalid("Model preferences changed on disk; reload them before inspecting.")
            }
            output = "{\"configuration\":\(try json(model.modelPreferences)),\"readiness_verified\":false}"
        case "missions": output = try json(CameraMissionStore.loadDocument(from: model.missionStoreURL).missions)
        case "showcase": output = try object(["configured_url": model.localShowcaseURL.map { actaRedactedStreamURL($0.absoluteString) } ?? "", "status": model.localShowcaseStatus, "health_verified": false])
        case "cameras":
            _ = try model.cameraConfigurationChecked()
            output = try object(["cameras": model.config.cameras.map { camera -> [String: Any] in
            ["camera_id": camera.id.uuidString, "name": camera.name, "enabled": camera.enabled,
             "substream": actaRedactedStreamURL(camera.substream), "mainstream": camera.mainstream.map(actaRedactedStreamURL) ?? "",
             "device_id": camera.localDeviceID ?? "", "display_id": camera.screenDisplayID ?? "", "file_path": camera.fileURL?.path ?? ""] }])
        case "ai":
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == model.vlmPreferences else {
                throw ConfigurationError.invalid("AI preferences changed on disk; reload them before making changes.")
            }
            let ai = model.vlmPreferences
            output = try object(["backend": ai.actaBackendMode.rawValue, "model_path": ai.model,
                "vllm_url": actaRedactedStreamURL(ai.actaVLLMBaseURL), "vllm_model": ai.actaVLLMModelName,
                "openai_url": actaRedactedStreamURL(ai.actaOpenAIBaseURL), "backup_url": actaRedactedStreamURL(ai.actaBackupRelayURL),
                "language": ai.actaPreferredLanguage.rawValue, "spoken_briefing_configured": ai.actaSpokenBriefingEnabled,
                "blur_faces": ai.privacyBlurFacesInCloud, "blur_plates": ai.privacyBlurPlatesInCloud,
                "daily_budget": ai.dailyBudgetLimitUSD, "monthly_budget": ai.monthlyBudgetLimitUSD, "checkpoint_compatibility_verified": false])
        default: return .unsupported(actionID: id)
        }
        return ACTAActionResult(actionID: id, success: true, summary: "Read current section configuration; health/model compatibility is not certified.", outputJSON: output)
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}
