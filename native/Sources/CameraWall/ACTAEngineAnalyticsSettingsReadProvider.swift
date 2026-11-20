import CameraCore
import Foundation

/// Reads the engine currently owned by the model on the main actor.
struct ACTAEngineAnalyticsSettingsReadProvider: ACTAAnalyticsSettingsReadProvider {
    private let snapshot: @MainActor @Sendable () throws -> ACTAAnalyticsSettingsSnapshot

    @MainActor
    init(model: WallModel) {
        snapshot = { [weak model] in
            guard let model else { throw ACTAAnalyticsSettingsReadError.unavailable }
            let engine = model.localAnalyticsEngine
            guard try VideoAnalyticsSettingsStore.load(from: engine.settingsURL) == engine.settings else {
                throw ACTAAnalyticsSettingsReadError.unavailable
            }
            return Self.project(engine.settings)
        }
    }

    func appliedGlobalSettings() async throws -> ACTAAnalyticsSettingsSnapshot {
        try await snapshot()
    }

    static func project(_ settings: VideoAnalyticsSettings) -> ACTAAnalyticsSettingsSnapshot {
        let mode: ACTAAnalyticsSettingsSnapshot.ExecutionMode
        switch settings.executionMode {
        case .local: mode = .local
        case .distributed: mode = .distributed
        }
        let sensitivity: ACTAAnalyticsSettingsSnapshot.Sensitivity
        switch settings.sensitivityProfile {
        case .conservative: sensitivity = .conservative
        case .balanced: sensitivity = .balanced
        case .highSensitivity: sensitivity = .highSensitivity
        case .custom: sensitivity = .custom
        }
        return ACTAAnalyticsSettingsSnapshot(
            globalEnabled: settings.globalEnabled, executionMode: mode, sensitivity: sensitivity,
            personDetection: settings.enablePersonDetection, poseEstimation: settings.enablePoseEstimation,
            fallDetection: settings.enableFallDetection, behaviorAnalysis: settings.enableBehaviorAnalysis,
            inactivityDetection: settings.enableProlongedInactivity, loiteringDetection: settings.enableLoiteringDetection,
            zoneMonitoring: settings.enableZoneMonitoring, unusualMovement: settings.enableUnusualMovement,
            crowdActivity: settings.enableCrowdActivity, fightDetection: settings.enableFightDetection,
            secondaryVerification: settings.enableSecondaryVLMVerification, soundAlert: settings.enableSoundAlert,
            visualAlert: settings.enableVisualAlertBanner, evidenceRecording: settings.enableEvidenceRecording,
            overlays: .init(settings: settings.overlaySettings), advanced: .init(settings: settings))
    }
}
