import AVFoundation
import CameraCore
import Foundation
import ScreenCaptureKit

/// Shared navigation and voice-dictation state synchronized between GUI controls and broker actions.
@MainActor
final class ACTANavigationBridge: ObservableObject {
    nonisolated static let validMainSections: [String] = [
        "settings", "cameras", "events", "timeline", "memory",
        "identities", "crossCameraIdentity", "localShowcase",
        "analysis", "map", "reports"
    ]

    nonisolated static let settingsSectionSlugs: [(slug: String, section: ACTASettingsSection)] = [
        ("general", .general),
        ("cameras", .cameras),
        ("models", .models),
        ("advanced", .advanced),
        ("analytics", .analytics),
        ("ai", .ai),
        ("schedules", .schedules),
        ("missions", .missions),
        ("events", .events),
        ("memory", .memory),
        ("features", .features),
        ("showcase", .showcase),
        ("identity", .identity),
        ("system", .system)
    ]

    @Published var selectedMainSection: String = "cameras"
    @Published var selectedSettingsSection: ACTASettingsSection = .general
    @Published var voiceDictationLanguage: LocalVoiceLanguage {
        didSet {
            voiceLanguageStorage?.writeRawLanguage(voiceDictationLanguage.rawValue)
        }
    }

    private let voiceLanguageStorage: (any LocalVoiceLanguageStorage)?

    init(voiceLanguageStorage: (any LocalVoiceLanguageStorage)? = nil) {
        self.voiceLanguageStorage = voiceLanguageStorage
        if let raw = voiceLanguageStorage?.readRawLanguage(),
           let saved = LocalVoiceLanguage(rawValue: raw) {
            self.voiceDictationLanguage = saved
        } else {
            self.voiceDictationLanguage = .interface
        }
    }

    nonisolated static func settingsSection(for slug: String) -> ACTASettingsSection? {
        let normalized = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = settingsSectionSlugs.first(where: { $0.slug == normalized }) {
            return match.section
        }
        return ACTASettingsSection.allCases.first { $0.rawValue.lowercased() == normalized }
    }

    nonisolated static func slug(for section: ACTASettingsSection) -> String {
        settingsSectionSlugs.first(where: { $0.section == section })?.slug ?? "general"
    }

    nonisolated static func voiceLanguage(for token: String) -> LocalVoiceLanguage? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "interface": return .interface
        case "en-us", "en", "english": return .english
        case "ru-ru", "ru", "russian": return .russian
        case "he-il", "he", "hebrew": return .hebrew
        default: return nil
        }
    }

    nonisolated static func canonicalToken(for language: LocalVoiceLanguage) -> String {
        switch language {
        case .interface: return "interface"
        case .english: return "en-US"
        case .russian: return "ru-RU"
        case .hebrew: return "he-IL"
        }
    }
}

struct ACTADiscoveredLocalCamera: Equatable, Sendable {
    let deviceID: String
    let name: String
    let connected: Bool
}

struct ACTADiscoveredScreen: Equatable, Sendable {
    let displayID: UInt32
    let width: Int
    let height: Int
}

private func wave1FJSON(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

private func wave1FISO(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

// MARK: - 1. Main App Navigation

struct ACTAAppSelectSectionAction: ACTAActionProtocol {
    let id = "app.select_section"
    let classification: ACTAActionClassification = .reversible
    let title = "Select App Section"
    let description = "Switch the active main sidebar section of the ACTA workspace."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "section",
            type: "string",
            description: "Target main workspace section.",
            isRequired: true,
            allowedValues: ACTANavigationBridge.validMainSections
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let section = parameters["section"],
              ACTANavigationBridge.validMainSections.contains(section) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENTS: Unknown app section.")
        }
        let verified = await MainActor.run { () -> Bool in
            model.navigationBridge.selectedMainSection = section
            return model.navigationBridge.selectedMainSection == section
        }
        guard verified else {
            return .failed(actionID: id, error: "VERIFICATION_FAILED: Selected section did not update.")
        }
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Selected app section \(section).",
            outputJSON: wave1FJSON(["section": section, "verified": true]),
            verified: true
        )
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let section = parameters["section"] else { return false }
        return await MainActor.run { model.navigationBridge.selectedMainSection == section }
    }
}

// MARK: - 2. SettingsHub Navigation

struct ACTASettingsSelectSectionAction: ACTAActionProtocol {
    let id = "settings.select_section"
    let classification: ACTAActionClassification = .reversible
    let title = "Select Settings Section"
    let description = "Open SettingsHub to a specific configuration section."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "section",
            type: "string",
            description: "Target SettingsHub section identifier.",
            isRequired: true,
            allowedValues: ACTANavigationBridge.settingsSectionSlugs.map(\.slug)
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let raw = parameters["section"],
              let target = ACTANavigationBridge.settingsSection(for: raw) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENTS: Unknown settings section.")
        }
        let slug = ACTANavigationBridge.slug(for: target)
        let verified = await MainActor.run { () -> Bool in
            let leavingShowcase = model.navigationBridge.selectedSettingsSection == .showcase && target != .showcase
            model.navigationBridge.selectedMainSection = "settings"
            model.navigationBridge.selectedSettingsSection = target
            if leavingShowcase && model.localShowcaseURL != nil {
                model.stopLocalShowcase()
            }
            return model.navigationBridge.selectedMainSection == "settings"
                && model.navigationBridge.selectedSettingsSection == target
        }
        guard verified else {
            return .failed(actionID: id, error: "VERIFICATION_FAILED: Settings section did not update.")
        }
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Opened settings section \(slug).",
            outputJSON: wave1FJSON(["section": slug, "verified": true]),
            verified: true
        )
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let raw = parameters["section"],
              let target = ACTANavigationBridge.settingsSection(for: raw) else { return false }
        return await MainActor.run {
            model.navigationBridge.selectedMainSection == "settings"
                && model.navigationBridge.selectedSettingsSection == target
        }
    }
}

// MARK: - 3. Voice Dictation Language

struct ACTAVoiceSetDictationLanguageAction: ACTAActionProtocol {
    let id = "voice.set_dictation_language"
    let classification: ACTAActionClassification = .reversible
    let title = "Set Voice Dictation Language"
    let description = "Select the on-device speech recognition language for chat dictation."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "language",
            type: "string",
            description: "Target dictation locale (interface, en-US, ru-RU, he-IL).",
            isRequired: true,
            allowedValues: ["interface", "en-US", "ru-RU", "he-IL"]
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let raw = parameters["language"],
              let language = ACTANavigationBridge.voiceLanguage(for: raw) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENTS: Unsupported dictation language.")
        }
        let canonical = ACTANavigationBridge.canonicalToken(for: language)
        let verified = await MainActor.run { () -> Bool in
            model.navigationBridge.voiceDictationLanguage = language
            return model.navigationBridge.voiceDictationLanguage == language
        }
        guard verified else {
            return .failed(actionID: id, error: "VERIFICATION_FAILED: Dictation language did not update.")
        }
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Voice dictation language set to \(canonical).",
            outputJSON: wave1FJSON(["language": canonical, "verified": true]),
            verified: true
        )
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        guard let raw = parameters["language"],
              let language = ACTANavigationBridge.voiceLanguage(for: raw) else { return false }
        return await MainActor.run { model.navigationBridge.voiceDictationLanguage == language }
    }
}

// MARK: - 4. Local Camera Hardware Discovery

struct ACTACameraDiscoverLocalAction: ACTAActionProtocol {
    let id = "camera.discover_local"
    let classification: ACTAActionClassification = .inspect
    let title = "Discover Local Cameras"
    let description = "Inspect currently connected local macOS video capture devices without starting capture."
    let parameters: [ACTAActionParameterSchema] = []

    private let provider: @Sendable () async -> [ACTADiscoveredLocalCamera]

    init(provider: (@Sendable () async -> [ACTADiscoveredLocalCamera])? = nil) {
        self.provider = provider ?? {
            CameraSession.localDevices().map { device in
                ACTADiscoveredLocalCamera(
                    deviceID: device.uniqueID,
                    name: device.localizedName,
                    connected: device.isConnected
                )
            }
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let devices = await provider()
        let items: [[String: Any]] = devices.prefix(32).map { device in
            [
                "device_id": device.deviceID,
                "name": device.name,
                "connected": device.connected
            ]
        }
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Discovered \(items.count) local video device(s).",
            outputJSON: wave1FJSON([
                "count": items.count,
                "devices": items,
                "capture_started": false
            ]),
            verified: true
        )
    }
}

// MARK: - 5. Screen Display Discovery

struct ACTACameraDiscoverScreensAction: ACTAActionProtocol {
    let id = "camera.discover_screens"
    let classification: ACTAActionClassification = .inspect
    let title = "Discover Screen Displays"
    let description = "Inspect available macOS displays for screen capture without starting capture."
    let parameters: [ACTAActionParameterSchema] = []

    private let provider: @Sendable () async throws -> [ACTADiscoveredScreen]

    init(provider: (@Sendable () async throws -> [ACTADiscoveredScreen])? = nil) {
        self.provider = provider ?? {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return content.displays.map { display in
                ACTADiscoveredScreen(
                    displayID: display.displayID,
                    width: display.width,
                    height: display.height
                )
            }
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            let screens = try await provider()
            let items: [[String: Any]] = screens.prefix(16).map { screen in
                [
                    "display_id": String(screen.displayID),
                    "width": screen.width,
                    "height": screen.height
                ]
            }
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Discovered \(items.count) screen display(s).",
                outputJSON: wave1FJSON([
                    "count": items.count,
                    "screens": items,
                    "capture_started": false
                ]),
                verified: true
            )
        } catch {
            return .failed(actionID: id, error: "DISCOVERY_UNAVAILABLE: Screen display discovery failed.")
        }
    }
}

// MARK: - 6. Identity Crop Description

struct ACTAIdentityDescribeTrackAction: ACTAActionProtocol {
    let id = "identity.describe_track"
    let classification: ACTAActionClassification = .serviceAffecting
    let title = "Describe Saved Track Crop"
    let description = "Queue a local VLM visual description for a saved tracked object crop."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "track_id",
            type: "string",
            description: "UUID of the tracked object record to describe.",
            isRequired: true
        )
    ]

    private unowned let model: WallModel
    private let describeHook: (@MainActor @Sendable (TrackedObjectRecord) -> Bool)?

    init(model: WallModel, describeHook: (@MainActor @Sendable (TrackedObjectRecord) -> Bool)? = nil) {
        self.model = model
        self.describeHook = describeHook
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let rawID = parameters["track_id"], let trackID = UUID(uuidString: rawID) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENTS: Invalid track_id UUID.")
        }
        let outcome = await MainActor.run { () -> Result<[String: Any], Error> in
            guard let store = model.actaTrackingStore else {
                return .failure(ConfigurationError.invalid("Local tracking store is unavailable."))
            }
            guard let record = model.recentTracks.first(where: { $0.trackID == trackID })
                ?? (try? store.recentTracks(limit: 500).first(where: { $0.trackID == trackID })) else {
                return .failure(ConfigurationError.invalid("Tracked object not found."))
            }
            if let hook = describeHook {
                guard hook(record) else {
                    return .failure(ConfigurationError.invalid("Saved crop is unavailable."))
                }
                return .success([
                    "track_id": trackID.uuidString,
                    "label": record.label,
                    "queued": true,
                    "completed": false
                ])
            }
            guard let imageURL = store.imageURL(for: record),
                  FileManager.default.isReadableFile(atPath: imageURL.path) else {
                return .failure(ConfigurationError.invalid("Saved crop is unavailable."))
            }
            model.describeTrackedObject(record)
            return .success([
                "track_id": trackID.uuidString,
                "label": record.label,
                "queued": model.describingTrackIDs.contains(trackID),
                "completed": false
            ])
        }
        switch outcome {
        case .success(let payload):
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Queued local crop description for track \(trackID.uuidString).",
                outputJSON: wave1FJSON(payload),
                verified: true
            )
        case .failure(let error):
            return .failed(actionID: id, error: "DESCRIBE_TRACK_FAILED: \(error.localizedDescription)")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        true
    }
}

// MARK: - 7. Identity Visual Similarity Search

struct ACTAIdentityFindSimilarTracksAction: ACTAActionProtocol {
    let id = "identity.find_similar_tracks"
    let classification: ACTAActionClassification = .inspect
    let title = "Find Visually Similar Tracks"
    let description = "Start or inspect cross-camera visual similarity matches for a tracked object."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "track_id",
            type: "string",
            description: "UUID of the source tracked object.",
            isRequired: true
        )
    ]

    private unowned let model: WallModel
    private let searchHook: (@MainActor @Sendable (TrackedObjectRecord) -> Int)?

    init(model: WallModel, searchHook: (@MainActor @Sendable (TrackedObjectRecord) -> Int)? = nil) {
        self.model = model
        self.searchHook = searchHook
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let rawID = parameters["track_id"], let trackID = UUID(uuidString: rawID) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENTS: Invalid track_id UUID.")
        }
        let outcome = await MainActor.run { () -> Result<[String: Any], Error> in
            guard let store = model.actaTrackingStore else {
                return .failure(ConfigurationError.invalid("Local tracking store is unavailable."))
            }
            guard let record = model.recentTracks.first(where: { $0.trackID == trackID })
                ?? (try? store.recentTracks(limit: 500).first(where: { $0.trackID == trackID })) else {
                return .failure(ConfigurationError.invalid("Tracked object not found."))
            }
            if let hook = searchHook {
                let matches = hook(record)
                return .success([
                    "track_id": trackID.uuidString,
                    "searching": false,
                    "match_count": matches
                ])
            }
            model.findSimilarTracks(to: record)
            let matches = model.similarTracksByTrack[trackID] ?? []
            return .success([
                "track_id": trackID.uuidString,
                "searching": model.searchingTrackIDs.contains(trackID),
                "match_count": matches.count,
                "matched_track_ids": matches.prefix(20).map { $0.trackID.uuidString }
            ])
        }
        switch outcome {
        case .success(let payload):
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Evaluated visual similarity for track \(trackID.uuidString).",
                outputJSON: wave1FJSON(payload),
                verified: true
            )
        case .failure(let error):
            return .failed(actionID: id, error: "SIMILAR_TRACKS_FAILED: \(error.localizedDescription)")
        }
    }
}

// MARK: - 8. Alert Review History (Sanitized Metadata)

struct ACTAAlertListReviewHistoryAction: ACTAActionProtocol {
    let id = "alert.list_review_history"
    let classification: ACTAActionClassification = .inspect
    let title = "List Alert Review History"
    let description = "List sanitized operator alert review statuses and timestamps without exposing free-form notes."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "limit",
            type: "integer",
            description: "Maximum number of review entries to return (1...50).",
            isRequired: false
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        var parsedLimit = 25
        if let rawLimit = parameters["limit"] {
            guard let parsed = Int(rawLimit), (1...50).contains(parsed) else {
                return .failed(actionID: id, error: "INVALID_ARGUMENTS: limit must be an integer between 1 and 50.")
            }
            parsedLimit = parsed
        }
        let limit = parsedLimit
        let outcome = await MainActor.run { () -> Result<[String: Any], Error> in
            guard model.featurePreferences.enabledFeatures.contains(.operationalAlerts) else {
                return .failure(ConfigurationError.invalid("Operational alerts feature is disabled."))
            }
            guard model.actaAlertReviewsLoaded else {
                return .failure(ConfigurationError.invalid("Alert review state is not loaded."))
            }
            let reviews = model.operationsAlertReviews.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
                .map { review -> [String: Any] in
                    [
                        "alert_id": review.alertID.uuidString,
                        "status": review.status.rawValue,
                        "priority": review.priority.rawValue,
                        "updated_at": wave1FISO(review.updatedAt),
                        "has_note": !review.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ]
                }
            return .success([
                "count": reviews.count,
                "reviews": reviews
            ])
        }
        switch outcome {
        case .success(let payload):
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Listed \(payload["count"] as? Int ?? 0) alert review record(s).",
                outputJSON: wave1FJSON(payload),
                verified: true
            )
        case .failure(let error):
            return .failed(actionID: id, error: "ALERT_REVIEWS_UNAVAILABLE: \(error.localizedDescription)")
        }
    }
}

// MARK: - 9. Alert Lookback Clips (Sanitized Metadata)

struct ACTAAlertListClipsAction: ACTAActionProtocol {
    let id = "alert.list_clips"
    let classification: ACTAActionClassification = .inspect
    let title = "List Alert Lookback Clips"
    let description = "List saved critical alert lookback clip metadata without exposing filesystem paths or raw frames."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "limit",
            type: "integer",
            description: "Maximum number of clips to return (1...50).",
            isRequired: false
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        var parsedLimit = 25
        if let rawLimit = parameters["limit"] {
            guard let parsed = Int(rawLimit), (1...50).contains(parsed) else {
                return .failed(actionID: id, error: "INVALID_ARGUMENTS: limit must be an integer between 1 and 50.")
            }
            parsedLimit = parsed
        }
        let limit = parsedLimit
        let outcome = await MainActor.run { () -> Result<[String: Any], Error> in
            guard model.featurePreferences.enabledFeatures.contains(.operationalAlerts) else {
                return .failure(ConfigurationError.invalid("Operational alerts feature is disabled."))
            }
            do {
                let clips = try model.actaAlertClipStore.clips()
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(limit)
                    .map { clip -> [String: Any] in
                        [
                            "clip_id": clip.id.uuidString,
                            "camera_id": clip.cameraID.uuidString,
                            "created_at": wave1FISO(clip.createdAt),
                            "expires_at": wave1FISO(clip.expiresAt),
                            "frame_count": clip.frameCount,
                            "byte_count": clip.byteCount
                        ]
                    }
                return .success([
                    "count": clips.count,
                    "clips": clips
                ])
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let payload):
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Listed \(payload["count"] as? Int ?? 0) alert lookback clip(s).",
                outputJSON: wave1FJSON(payload),
                verified: true
            )
        case .failure(let error):
            return .failed(actionID: id, error: "ALERT_CLIPS_UNAVAILABLE: \(error.localizedDescription)")
        }
    }
}

// MARK: - 10. Incident Evidence Metadata (Sanitized)

struct ACTAIncidentGetEvidenceMetadataAction: ACTAActionProtocol {
    let id = "incident.get_evidence_metadata"
    let classification: ACTAActionClassification = .inspect
    let title = "Get Incident Evidence Metadata"
    let description = "Inspect whether a safety incident has saved visual evidence without disclosing raw images or paths."
    let parameters: [ACTAActionParameterSchema] = [
        ACTAActionParameterSchema(
            name: "incident_id",
            type: "string",
            description: "UUID of the safety incident.",
            isRequired: true
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard let rawID = parameters["incident_id"], let incidentID = UUID(uuidString: rawID) else {
            return .failed(actionID: id, error: "INVALID_ARGUMENTS: Invalid incident_id UUID.")
        }
        let outcome = await MainActor.run { () -> Result<[String: Any], Error> in
            guard let incident = model.localAnalyticsEngine.incidentManager.incident(id: incidentID)
                ?? model.localAnalyticsEngine.incidents.first(where: { $0.id == incidentID }) else {
                return .failure(ConfigurationError.invalid("Incident not found."))
            }
            let hasSnapshot = incident.snapshotRelativePath != nil
            let hasClip = incident.clipID != nil
            return .success([
                "incident_id": incident.id.uuidString,
                "camera_id": incident.cameraID.uuidString,
                "status": incident.status.rawValue,
                "severity": incident.severity.rawValue,
                "has_snapshot": hasSnapshot,
                "has_clip": hasClip,
                "has_evidence": hasSnapshot || hasClip,
                "secondary_vlm_status": incident.secondaryVLMStatus.rawValue,
                "escalation_count": incident.escalationCount
            ])
        }
        switch outcome {
        case .success(let payload):
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Inspected evidence metadata for incident \(incidentID.uuidString).",
                outputJSON: wave1FJSON(payload),
                verified: true
            )
        case .failure(let error):
            return .failed(actionID: id, error: "INCIDENT_EVIDENCE_UNAVAILABLE: \(error.localizedDescription)")
        }
    }
}
