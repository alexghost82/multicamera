import Foundation

/// A snapshot of applied global configuration, not engine health or unsaved editor drafts.
public struct ACTAAnalyticsSettingsSnapshot: Encodable, Sendable {
    public enum ExecutionMode: String, Encodable, Sendable {
        case local, distributed
    }
    public enum Sensitivity: String, Encodable, Sendable {
        case conservative, balanced, highSensitivity, custom
    }

    public struct Overlays: Encodable, Sendable {
        public let showBoundingBoxes: Bool
        public let showPoseSkeleton: Bool
        public let showTrackID: Bool
        public let showBehaviorState: Bool
        public let showFallStatus: Bool
        public let showConfidence: Bool
        public let showCriticalAlertMarker: Bool
        public let showRestrictedZones: Bool

        public init(settings: AnalyticsOverlaySettings) {
            showBoundingBoxes = settings.showBoundingBoxes
            showPoseSkeleton = settings.showPoseSkeleton
            showTrackID = settings.showTrackID
            showBehaviorState = settings.showBehaviorState
            showFallStatus = settings.showFallStatus
            showConfidence = settings.showConfidence
            showCriticalAlertMarker = settings.showCriticalAlertMarker
            showRestrictedZones = settings.showRestrictedZones
        }
    }

    public struct Advanced: Encodable, Sendable {
        public let personConfidenceThreshold: Double
        public let poseKeypointConfidenceThreshold: Double
        public let analyticsSamplingFPS: Double
        public let idleCameraSamplingFPS: Double
        public let activeFallBoostFPS: Double
        public let fallConfirmationSeconds: Double
        public let personDownSeconds: Double
        public let inactivityThresholdSeconds: Double
        public let loiteringThresholdSeconds: Double
        public let minimumVisibleKeypoints: Int
        public let alertCooldownSeconds: Double
        public let preEventBufferSeconds: Double
        public let postEventBufferSeconds: Double
        public let maxEvidenceDiskQuotaMB: Int
        public let maxConcurrentInferenceTasks: Int

        public init(settings: VideoAnalyticsSettings) {
            personConfidenceThreshold = settings.personConfidenceThreshold
            poseKeypointConfidenceThreshold = settings.poseKeypointConfidenceThreshold
            analyticsSamplingFPS = settings.analyticsSamplingFPS
            idleCameraSamplingFPS = settings.idleCameraSamplingFPS
            activeFallBoostFPS = settings.activeFallBoostFPS
            fallConfirmationSeconds = settings.fallConfirmationSeconds
            personDownSeconds = settings.personDownSeconds
            inactivityThresholdSeconds = settings.inactivityThresholdSeconds
            loiteringThresholdSeconds = settings.loiteringThresholdSeconds
            minimumVisibleKeypoints = settings.minimumVisibleKeypoints
            alertCooldownSeconds = settings.alertCooldownSeconds
            preEventBufferSeconds = settings.preEventBufferSeconds
            postEventBufferSeconds = settings.postEventBufferSeconds
            maxEvidenceDiskQuotaMB = settings.maxEvidenceDiskQuotaMB
            maxConcurrentInferenceTasks = settings.maxConcurrentInferenceTasks
        }
    }

    public let globalEnabled: Bool
    public let executionMode: ExecutionMode
    public let sensitivity: Sensitivity
    public let personDetection: Bool
    public let poseEstimation: Bool
    public let fallDetection: Bool
    public let behaviorAnalysis: Bool
    public let inactivityDetection: Bool
    public let loiteringDetection: Bool
    public let zoneMonitoring: Bool
    public let unusualMovement: Bool
    public let crowdActivity: Bool
    public let fightDetection: Bool
    public let secondaryVerification: Bool
    public let soundAlert: Bool
    public let visualAlert: Bool
    public let evidenceRecording: Bool
    public let overlays: Overlays
    public let advanced: Advanced

    public init(globalEnabled: Bool, executionMode: ExecutionMode, sensitivity: Sensitivity,
                personDetection: Bool, poseEstimation: Bool, fallDetection: Bool, behaviorAnalysis: Bool,
                inactivityDetection: Bool, loiteringDetection: Bool, zoneMonitoring: Bool,
                unusualMovement: Bool, crowdActivity: Bool, fightDetection: Bool,
                secondaryVerification: Bool, soundAlert: Bool, visualAlert: Bool, evidenceRecording: Bool,
                overlays: Overlays, advanced: Advanced) {
        self.globalEnabled = globalEnabled
        self.executionMode = executionMode
        self.sensitivity = sensitivity
        self.personDetection = personDetection
        self.poseEstimation = poseEstimation
        self.fallDetection = fallDetection
        self.behaviorAnalysis = behaviorAnalysis
        self.inactivityDetection = inactivityDetection
        self.loiteringDetection = loiteringDetection
        self.zoneMonitoring = zoneMonitoring
        self.unusualMovement = unusualMovement
        self.crowdActivity = crowdActivity
        self.fightDetection = fightDetection
        self.secondaryVerification = secondaryVerification
        self.soundAlert = soundAlert
        self.visualAlert = visualAlert
        self.evidenceRecording = evidenceRecording
        self.overlays = overlays
        self.advanced = advanced
    }
}

public enum ACTAAnalyticsSettingsReadError: Error, Sendable {
    case unavailable
}

/// Providers must read the current applied runtime configuration or throw.
public protocol ACTAAnalyticsSettingsReadProvider: Sendable {
    func appliedGlobalSettings() async throws -> ACTAAnalyticsSettingsSnapshot
}

/// Opt-in broker action; camera overrides, editor drafts and effective status are excluded.
public struct ACTAScopedAnalyticsSettingsAction: ACTAActionProtocol {
    public let id = "analytics.get_settings"
    public let title = "Get Applied Global Analytics Settings"
    public let description = "Read applied global analytics switches, mode, profile, overlays and advanced values; not camera overrides, unsaved edits or engine health."
    public let classification = ACTAActionClassification.inspect
    public let parameters: [ACTAActionParameterSchema] = []
    private let provider: (any ACTAAnalyticsSettingsReadProvider)?

    public init(provider: (any ACTAAnalyticsSettingsReadProvider)? = nil) {
        self.provider = provider
    }

    private struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: No parameters are accepted." }
    }

    public func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw InvalidArguments() }
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard parameters.isEmpty else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: No parameters are accepted.")
        }
        guard let provider else {
            return .failed(actionID: id, error: "UNAVAILABLE: Analytics settings are not connected.")
        }
        do {
            try Task.checkCancellation()
            let snapshot = try await provider.appliedGlobalSettings()
            try Task.checkCancellation()
            let output = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Applied global analytics settings retrieved.",
                                    outputJSON: output)
        } catch is CancellationError {
            throw CancellationError()
        } catch ACTAAnalyticsSettingsReadError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Analytics settings are not connected.")
        } catch {
            return .failed(actionID: id, error: "READ_ERROR: Analytics settings read failed.")
        }
    }
}
