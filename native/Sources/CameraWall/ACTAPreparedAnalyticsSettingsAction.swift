import CameraCore
import Foundation

/// Cooperating writers must share a compare-and-commit boundary and invalidate
/// reviews on ABA. A thrown commit error may have an unknown outcome.
@MainActor
protocol ACTAAnalyticsSettingsMutationDomain: Sendable {
    func capture() throws -> ACTAAnalyticsSettingsObservation
    func commit(expected: ACTAAnalyticsSettingsObservation,
                replacement: VideoAnalyticsSettings) throws -> ACTAAnalyticsSettingsObservation?
}

struct ACTAAnalyticsSettingsObservation: Sendable, Equatable {
    let revision: UUID
    let memory: VideoAnalyticsSettings
    let persisted: VideoAnalyticsSettings
}

/// The inventory implementation must hold its shared, cross-process writer
/// exclusion throughout body, validate memory against persisted inventory, and
/// return nil for a missing camera. Reentrant inventory writes must fail and
/// revision must change on every write (ABA), including uncertain failures.
/// All camera writers must participate; a standalone snapshot is not enough.
@MainActor
protocol ACTAAnalyticsCameraInventory: Sendable {
    func withCamera<T>(id: UUID, _ body: (UUID) throws -> T) throws -> T?
}

fileprivate struct ACTAAnalyticsCameraObservation: Sendable, Equatable {
    let id: UUID
    let revision: UUID
    let settings: ACTAAnalyticsSettingsObservation
}

struct ACTAPreparedAnalyticsSettingsAction: ACTAPreparedConfirmationAction {
    enum Kind: String, CaseIterable, Sendable {
        case toggle = "analytics.set_global_toggle"
        case threshold = "analytics.set_threshold"
        case sampling = "analytics.set_sampling_fps"
        case overlay = "analytics.set_overlay"
        case profile = "analytics.set_sensitivity_profile"
        case executionMode = "analytics.set_execution_mode"
        case cameraOverride = "analytics.set_camera_override"
        case removeCameraOverride = "analytics.remove_camera_override"

        static let productionCases: [Kind] = [.toggle, .threshold, .sampling, .overlay, .profile, .executionMode]

        var requiresCamera: Bool { self == .cameraOverride || self == .removeCameraOverride }
    }

    @MainActor final class State {
        var busy = false
        fileprivate var receipt: (parameters: [String: String], threadID: String, observation: ACTAAnalyticsSettingsObservation, camera: ACTAAnalyticsCameraObservation?)?
    }
    @MainActor final class Ticket {
        let owner: State
        var used = false
        init(_ owner: State) { self.owner = owner }
    }
    struct ConfirmationSnapshot: Sendable {
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let before: ACTAAnalyticsSettingsObservation
        fileprivate let replacement: VideoAnalyticsSettings
        fileprivate let camera: ACTAAnalyticsCameraObservation?
        fileprivate let ticket: Ticket
    }

    let kind: Kind
    var id: String { kind.rawValue }
    var title: String { "Change Analytics Settings" }
    var description: String {
        let effects = "Review an analytics settings change. Applying it stops and may restart analytics; model readiness is not verified."
        if kind == .cameraOverride {
            return effects + " Changes one camera field; a missing override is created with defaults. The value is a string: true/false, profile, number, or inherit to clear an optional numeric override. Global inheritance can suppress the effect."
        }
        if kind == .removeCameraOverride {
            return effects + " Removes one camera override, including its restricted zones."
        }
        return kind == .executionMode
            ? effects + " This saves the mode only; it does not switch routing or verify workers."
            : effects
    }
    var classification: ACTAActionClassification { kind == .removeCameraOverride ? .destructive : .reversible }
    var parameters: [ACTAActionParameterSchema] {
        func field(_ name: String, _ type: String, required: Bool = false, values: [String]? = nil) -> ACTAActionParameterSchema {
            .init(name: name, type: type, description: name, isRequired: required, allowedValues: values)
        }
        switch kind {
        case .toggle: return [field("feature", "string", required: true, values: Self.toggles.keys.sorted()), field("enabled", "boolean", required: true)]
        case .threshold: return [field("parameter", "string", required: true, values: (Array(Self.doubles.keys) + Array(Self.integers.keys)).sorted()), field("value", "number", required: true)]
        case .sampling: return [field("fps", "number", required: true), field("idle_fps", "number"), field("boost_fps", "number")]
        case .overlay: return [field("layer", "string", required: true, values: Self.overlays.keys.sorted()), field("enabled", "boolean", required: true)]
        case .profile: return [field("profile", "string", required: true, values: AnalyticsSensitivityProfile.allCases.map(\.rawValue)), field("apply_values", "boolean")]
        case .executionMode: return [field("mode", "string", required: true, values: AnalyticsExecutionMode.allCases.map(\.rawValue))]
        case .cameraOverride: return [field("camera_id", "string", required: true),
            field("field", "string", required: true, values: (Array(Self.cameraToggles.keys) + ["sensitivityProfile", "customSamplingFPS", "customAlertCooldownSeconds"]).sorted()),
            .init(name: "value", type: "string", description: "true/false, profile name, finite number, or inherit to clear an optional numeric override.", isRequired: true)]
        case .removeCameraOverride: return [field("camera_id", "string", required: true)]
        }
    }

    private let domain: any ACTAAnalyticsSettingsMutationDomain
    private let cameraInventory: (any ACTAAnalyticsCameraInventory)?
    private let state: State
    @MainActor init(kind: Kind, domain: any ACTAAnalyticsSettingsMutationDomain,
                    cameraInventory: (any ACTAAnalyticsCameraInventory)? = nil) {
        self.kind = kind
        self.domain = domain
        self.cameraInventory = cameraInventory
        self.state = State()
    }

    private static var toggles: [String: WritableKeyPath<VideoAnalyticsSettings, Bool>] { [
        "global": \.globalEnabled, "person": \.enablePersonDetection, "pose": \.enablePoseEstimation,
        "fall": \.enableFallDetection, "behavior": \.enableBehaviorAnalysis,
        "inactivity": \.enableProlongedInactivity, "loitering": \.enableLoiteringDetection,
        "zone": \.enableZoneMonitoring, "unusual_movement": \.enableUnusualMovement,
        "crowd": \.enableCrowdActivity, "fight": \.enableFightDetection,
        "secondary_vlm": \.enableSecondaryVLMVerification, "sound": \.enableSoundAlert,
        "banner": \.enableVisualAlertBanner, "evidence": \.enableEvidenceRecording
    ] }
    private static var doubles: [String: WritableKeyPath<VideoAnalyticsSettings, Double>] { [
        "personConfidenceThreshold": \.personConfidenceThreshold, "poseKeypointConfidenceThreshold": \.poseKeypointConfidenceThreshold,
        "fallConfirmationSeconds": \.fallConfirmationSeconds, "personDownSeconds": \.personDownSeconds,
        "inactivityThresholdSeconds": \.inactivityThresholdSeconds, "loiteringThresholdSeconds": \.loiteringThresholdSeconds,
        "alertCooldownSeconds": \.alertCooldownSeconds, "preEventBufferSeconds": \.preEventBufferSeconds,
        "postEventBufferSeconds": \.postEventBufferSeconds
    ] }
    private static var integers: [String: WritableKeyPath<VideoAnalyticsSettings, Int>] { [
        "minimumVisibleKeypoints": \.minimumVisibleKeypoints, "maxEvidenceDiskQuotaMB": \.maxEvidenceDiskQuotaMB,
        "maxConcurrentInferenceTasks": \.maxConcurrentInferenceTasks
    ] }
    private static var overlays: [String: WritableKeyPath<AnalyticsOverlaySettings, Bool>] { [
        "showBoundingBoxes": \.showBoundingBoxes, "showPoseSkeleton": \.showPoseSkeleton,
        "showTrackID": \.showTrackID, "showBehaviorState": \.showBehaviorState,
        "showFallStatus": \.showFallStatus, "showConfidence": \.showConfidence,
        "showCriticalAlertMarker": \.showCriticalAlertMarker, "showRestrictedZones": \.showRestrictedZones
    ] }
    private static var cameraToggles: [String: WritableKeyPath<CameraAnalyticsOverride, Bool>] { [
        "inheritGlobalSettings": \.inheritGlobalSettings, "analyticsEnabled": \.analyticsEnabled,
        "personDetectionEnabled": \.personDetectionEnabled, "poseEstimationEnabled": \.poseEstimationEnabled,
        "fallDetectionEnabled": \.fallDetectionEnabled, "behaviorAnalysisEnabled": \.behaviorAnalysisEnabled,
        "inactivityDetectionEnabled": \.inactivityDetectionEnabled, "loiteringDetectionEnabled": \.loiteringDetectionEnabled,
        "zoneMonitoringEnabled": \.zoneMonitoringEnabled, "fightDetectionEnabled": \.fightDetectionEnabled,
        "secondaryVLMVerificationEnabled": \.secondaryVLMVerificationEnabled
    ] }

    private enum InputError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Invalid analytics settings request."
            case .unavailable: return "UNAVAILABLE: Complete analytics settings cannot be safely reviewed."
            }
        }
    }
    private func bool(_ raw: String?) throws -> Bool {
        switch raw { case "true": return true; case "false": return false; default: throw InputError.invalid }
    }
    private func number(_ raw: String?) throws -> Double {
        guard let raw, let value = Double(raw), value.isFinite else { throw InputError.invalid }
        return value
    }
    private func check(_ p: [String: String]) throws {
        let allowed = Set(parameters.map(\.name))
        guard Set(p.keys).isSubset(of: allowed), parameters.filter(\.isRequired).allSatisfy({ p[$0.name] != nil }) else { throw InputError.invalid }
        switch kind {
        case .toggle: guard Self.toggles[p["feature"] ?? ""] != nil else { throw InputError.invalid }; _ = try bool(p["enabled"])
        case .overlay: guard Self.overlays[p["layer"] ?? ""] != nil else { throw InputError.invalid }; _ = try bool(p["enabled"])
        case .threshold:
            let name = p["parameter"] ?? ""
            guard Self.doubles[name] != nil || Self.integers[name] != nil else { throw InputError.invalid }
            let value = try number(p["value"])
            if Self.integers[name] != nil && (value.rounded() != value || !(0...65536).contains(value)) { throw InputError.invalid }
        case .sampling:
            _ = try number(p["fps"])
            if p["idle_fps"] != nil { _ = try number(p["idle_fps"]) }
            if p["boost_fps"] != nil { _ = try number(p["boost_fps"]) }
        case .profile:
            guard AnalyticsSensitivityProfile(rawValue: p["profile"] ?? "") != nil else { throw InputError.invalid }
            if p["apply_values"] != nil { _ = try bool(p["apply_values"]) }
        case .executionMode:
            guard AnalyticsExecutionMode(rawValue: p["mode"] ?? "") != nil else { throw InputError.invalid }
        case .cameraOverride:
            guard UUID(uuidString: p["camera_id"] ?? "") != nil, let field = p["field"], let value = p["value"] else { throw InputError.invalid }
            if Self.cameraToggles[field] != nil { _ = try bool(value) }
            else if field == "sensitivityProfile" {
                guard AnalyticsSensitivityProfile(rawValue: value) != nil else { throw InputError.invalid }
            } else if field == "customSamplingFPS" || field == "customAlertCooldownSeconds" {
                if value != "inherit" { _ = try number(value) }
            } else { throw InputError.invalid }
        case .removeCameraOverride:
            guard UUID(uuidString: p["camera_id"] ?? "") != nil else { throw InputError.invalid }
        }
    }
    func validate(parameters: [String: String]) throws { try check(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    private func checked(_ observation: ACTAAnalyticsSettingsObservation) throws -> VideoAnalyticsSettings {
        guard observation.memory == observation.persisted else { throw InputError.unavailable }
        try observation.memory.validate()
        guard observation.memory.clamped() == observation.memory else { throw InputError.unavailable }
        return observation.memory
    }

    private func cameraEffects(before: VideoAnalyticsSettings, after: VideoAnalyticsSettings, id: UUID) -> String {
        let old = before.effectiveConfiguration(for: id, cameraYOLOEnabled: true)
        let new = after.effectiveConfiguration(for: id, cameraYOLOEnabled: true)
        var changes: [String] = []
        func add<T: Equatable>(_ name: String, _ key: KeyPath<EffectiveCameraAnalyticsConfig, T>) {
            if old[keyPath: key] != new[keyPath: key] {
                changes.append("\(name): \(old[keyPath: key]) -> \(new[keyPath: key])")
            }
        }
        add("analyticsEnabled", \.analyticsEnabled)
        add("personDetectionEnabled", \.personDetectionEnabled)
        add("poseEstimationEnabled", \.poseEstimationEnabled)
        add("fallDetectionEnabled", \.fallDetectionEnabled)
        add("behaviorAnalysisEnabled", \.behaviorAnalysisEnabled)
        add("inactivityDetectionEnabled", \.inactivityDetectionEnabled)
        add("loiteringDetectionEnabled", \.loiteringDetectionEnabled)
        add("zoneMonitoringEnabled", \.zoneMonitoringEnabled)
        add("unusualMovementEnabled", \.unusualMovementEnabled)
        add("crowdActivityEnabled", \.crowdActivityEnabled)
        add("fightDetectionEnabled", \.fightDetectionEnabled)
        add("secondaryVLMVerificationEnabled", \.secondaryVLMVerificationEnabled)
        add("samplingFPS", \.samplingFPS)
        add("idleSamplingFPS", \.idleSamplingFPS)
        add("activeFallBoostFPS", \.activeFallBoostFPS)
        add("personConfidenceThreshold", \.personConfidenceThreshold)
        add("poseKeypointConfidenceThreshold", \.poseKeypointConfidenceThreshold)
        add("fallConfirmationSeconds", \.fallConfirmationSeconds)
        add("personDownSeconds", \.personDownSeconds)
        add("inactivityThresholdSeconds", \.inactivityThresholdSeconds)
        add("loiteringThresholdSeconds", \.loiteringThresholdSeconds)
        add("minimumVisibleKeypoints", \.minimumVisibleKeypoints)
        add("alertCooldownSeconds", \.alertCooldownSeconds)
        if old.restrictedZones != new.restrictedZones {
            changes.append("restrictedZones: \(old.restrictedZones.count) -> \(new.restrictedZones.count)")
        }
        return "Computed effective changes assuming camera analytics is enabled: " +
            (changes.isEmpty ? "none" : changes.joined(separator: ", ")) +
            ". Actual camera state and model readiness are not verified."
    }

    private func replacement(_ p: [String: String], before: VideoAnalyticsSettings) throws -> (VideoAnalyticsSettings, String) {
        try check(p)
        var next = before
        let summary: String
        switch kind {
        case .toggle:
            let key = Self.toggles[p["feature"]!]!, value = try bool(p["enabled"])
            summary = "\(p["feature"]!): \(before[keyPath: key]) -> \(value)"
            next[keyPath: key] = value
        case .overlay:
            let key = Self.overlays[p["layer"]!]!, value = try bool(p["enabled"])
            summary = "\(p["layer"]!): \(before.overlaySettings[keyPath: key]) -> \(value)"
            next.overlaySettings[keyPath: key] = value
        case .threshold:
            let name = p["parameter"]!, value = try number(p["value"])
            if let key = Self.doubles[name] {
                summary = "\(name): \(before[keyPath: key]) -> \(value)"
                next[keyPath: key] = value
            } else {
                let key = Self.integers[name]!
                summary = "\(name): \(before[keyPath: key]) -> \(Int(value))"
                next[keyPath: key] = Int(value)
            }
        case .sampling:
            next.analyticsSamplingFPS = try number(p["fps"])
            if let value = p["idle_fps"] { next.idleCameraSamplingFPS = try number(value) }
            if let value = p["boost_fps"] { next.activeFallBoostFPS = try number(value) }
            summary = "FPS/idle/boost: \(before.analyticsSamplingFPS)/\(before.idleCameraSamplingFPS)/\(before.activeFallBoostFPS) -> \(next.analyticsSamplingFPS)/\(next.idleCameraSamplingFPS)/\(next.activeFallBoostFPS)"
        case .profile:
            let profile = AnalyticsSensitivityProfile(rawValue: p["profile"]!)!
            if try bool(p["apply_values"] ?? "true") { next.applySensitivityProfile(profile) }
            else { next.sensitivityProfile = profile }
            summary = "Profile: \(before.sensitivityProfile.rawValue) -> \(profile.rawValue); applying preset values: \(p["apply_values"] ?? "true"). Thresholds: person \(before.personConfidenceThreshold) -> \(next.personConfidenceThreshold), pose \(before.poseKeypointConfidenceThreshold) -> \(next.poseKeypointConfidenceThreshold), fall \(before.fallConfirmationSeconds) -> \(next.fallConfirmationSeconds), down \(before.personDownSeconds) -> \(next.personDownSeconds), inactivity \(before.inactivityThresholdSeconds) -> \(next.inactivityThresholdSeconds), keypoints \(before.minimumVisibleKeypoints) -> \(next.minimumVisibleKeypoints)"
        case .executionMode:
            let mode = AnalyticsExecutionMode(rawValue: p["mode"]!)!
            next.executionMode = mode
            summary = "Configured execution mode: \(before.executionMode.rawValue) -> \(mode.rawValue). Saving this value does not verify distributed workers or change routing."
        case .cameraOverride:
            let id = UUID(uuidString: p["camera_id"]!)!, field = p["field"]!, value = p["value"]!
            var camera = before.cameraOverrides[id] ?? CameraAnalyticsOverride(cameraID: id)
            let existed = before.cameraOverrides[id] != nil
            let old: String
            if let key = Self.cameraToggles[field] {
                old = String(camera[keyPath: key]); camera[keyPath: key] = try bool(value)
            } else if field == "sensitivityProfile" {
                old = camera.sensitivityProfile.rawValue
                camera.sensitivityProfile = AnalyticsSensitivityProfile(rawValue: value)!
            } else if field == "customSamplingFPS" {
                old = camera.customSamplingFPS.map(String.init(describing:)) ?? "inherit"
                camera.customSamplingFPS = value == "inherit" ? nil : try number(value)
            } else {
                old = camera.customAlertCooldownSeconds.map(String.init(describing:)) ?? "inherit"
                camera.customAlertCooldownSeconds = value == "inherit" ? nil : try number(value)
            }
            next.cameraOverrides[id] = camera
            summary = "Camera \(id.uuidString), \(existed ? "existing override" : "new override with defaults"), \(field): \(old) -> \(value). Inherit global settings: \(camera.inheritGlobalSettings). \(cameraEffects(before: before, after: next, id: id))"
        case .removeCameraOverride:
            let id = UUID(uuidString: p["camera_id"]!)!
            guard let removed = next.cameraOverrides.removeValue(forKey: id) else { throw InputError.invalid }
            summary = "Camera \(id.uuidString): remove override and \(removed.restrictedZones.count) restricted zone(s). \(cameraEffects(before: before, after: next, id: id))"
        }
        try next.validate()
        guard next.clamped() == next else { throw InputError.invalid }
        return (next, summary)
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try await MainActor.run {
            try Task.checkCancellation()
            try check(parameters)
            let camera: ACTAAnalyticsCameraObservation?
            if kind.requiresCamera {
                guard let inventory = cameraInventory,
                      let id = UUID(uuidString: parameters["camera_id"]!),
                      let captured = try inventory.withCamera(id: id, { revision in
                          ACTAAnalyticsCameraObservation(id: id, revision: revision, settings: try domain.capture())
                      }) else { throw InputError.unavailable }
                camera = captured
            } else { camera = nil }
            let before = try camera?.settings ?? domain.capture()
            let (next, summary) = try replacement(parameters, before: checked(before))
            return .init(snapshot: .init(parameters: parameters, threadID: context.threadID, before: before,
                                          replacement: next, camera: camera, ticket: Ticket(state)),
                         reviewSummary: "\(summary). Analytics is stopped and may restart; ongoing analysis may be interrupted. Model readiness and crash durability are not verified.")
        }
    }
    func executeConfirmed(parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            guard snapshot.parameters == parameters, snapshot.threadID == context.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            guard !state.busy, state.receipt == nil else { return .failed(actionID: id, error: "ACTION_BUSY: Update awaits verification.") }
            state.busy = true
            defer { state.busy = false }
            let committed: ACTAAnalyticsSettingsObservation?
            do {
                if let camera = snapshot.camera {
                    guard let inventory = cameraInventory else { throw InputError.unavailable }
                    committed = try inventory.withCamera(id: camera.id) { revision in
                        guard revision == camera.revision else { return nil }
                        return try domain.commit(expected: snapshot.before, replacement: snapshot.replacement)
                    } ?? nil
                } else {
                    committed = try domain.commit(expected: snapshot.before, replacement: snapshot.replacement)
                }
            }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let committed else { return .failed(actionID: id, error: "STALE_REVIEW: Analytics settings changed.") }
            do {
                let readback: ACTAAnalyticsSettingsObservation?
                if let camera = snapshot.camera, let inventory = cameraInventory {
                    readback = try inventory.withCamera(id: camera.id) { revision in
                        guard revision == camera.revision else { return nil }
                        return try domain.capture()
                    } ?? nil
                } else { readback = try domain.capture() }
                guard committed.revision != snapshot.before.revision,
                      try checked(committed) == snapshot.replacement, readback == committed else {
                    return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
                }
            } catch { return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.") }
            state.receipt = (parameters, context.threadID, committed, snapshot.camera)
            return .init(actionID: id, success: true, summary: "Analytics settings updated and read back; model readiness and crash durability are not verified.")
        }
    }
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard !state.busy, let receipt, receipt.parameters == parameters, receipt.threadID == context.threadID else { return false }
            if let camera = receipt.camera {
                guard let inventory = cameraInventory else { return false }
                return (try? inventory.withCamera(id: camera.id) { revision in
                    guard revision == camera.revision else { return false }
                    return try domain.capture() == receipt.observation
                }) == true
            }
            return (try? domain.capture()) == receipt.observation
        }
    }
}
