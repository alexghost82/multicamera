import SwiftUI
import CameraCore

struct SettingsBooleanField<Root>: Identifiable {
    let title: String
    let path: WritableKeyPath<Root, Bool>
    var id: String { title }
}
struct SettingsNumberField<Root>: Identifiable {
    let title: String
    let path: WritableKeyPath<Root, Double>
    var id: String { title }
}
struct SettingsIntegerField<Root>: Identifiable {
    let title: String
    let path: WritableKeyPath<Root, Int>
    var id: String { title }
}

enum AnalyticsSettingsFields {
    static let switches: [SettingsBooleanField<VideoAnalyticsSettings>] = [
        .init(title: "Enable video analytics", path: \.globalEnabled),
        .init(title: "Person detection", path: \.enablePersonDetection),
        .init(title: "Pose estimation", path: \.enablePoseEstimation),
        .init(title: "Fall detection", path: \.enableFallDetection),
        .init(title: "Behavior analysis", path: \.enableBehaviorAnalysis),
        .init(title: "Prolonged inactivity", path: \.enableProlongedInactivity),
        .init(title: "Loitering detection", path: \.enableLoiteringDetection),
        .init(title: "Restricted zone monitoring", path: \.enableZoneMonitoring),
        .init(title: "Unusual movement", path: \.enableUnusualMovement),
        .init(title: "Crowd activity", path: \.enableCrowdActivity),
        .init(title: "Fight detection", path: \.enableFightDetection),
        .init(title: "Secondary VLM verification", path: \.enableSecondaryVLMVerification),
        .init(title: "Sound alert", path: \.enableSoundAlert),
        .init(title: "Visual alert banner", path: \.enableVisualAlertBanner),
        .init(title: "Record incident evidence", path: \.enableEvidenceRecording)
    ]
    static let numbers: [SettingsNumberField<VideoAnalyticsSettings>] = [
        .init(title: "Person confidence threshold", path: \.personConfidenceThreshold),
        .init(title: "Pose keypoint confidence threshold", path: \.poseKeypointConfidenceThreshold),
        .init(title: "Analytics sampling FPS", path: \.analyticsSamplingFPS),
        .init(title: "Idle camera sampling FPS", path: \.idleCameraSamplingFPS),
        .init(title: "Active fall boost FPS", path: \.activeFallBoostFPS),
        .init(title: "Fall confirmation seconds", path: \.fallConfirmationSeconds),
        .init(title: "Person down seconds", path: \.personDownSeconds),
        .init(title: "Inactivity threshold seconds", path: \.inactivityThresholdSeconds),
        .init(title: "Loitering threshold seconds", path: \.loiteringThresholdSeconds),
        .init(title: "Alert cooldown seconds", path: \.alertCooldownSeconds),
        .init(title: "Pre-event buffer seconds", path: \.preEventBufferSeconds),
        .init(title: "Post-event buffer seconds", path: \.postEventBufferSeconds)
    ]
    static let integers: [SettingsIntegerField<VideoAnalyticsSettings>] = [
        .init(title: "Minimum visible keypoints", path: \.minimumVisibleKeypoints),
        .init(title: "Evidence disk quota (MB)", path: \.maxEvidenceDiskQuotaMB),
        .init(title: "Concurrent inference tasks", path: \.maxConcurrentInferenceTasks)
    ]
    static let overlays: [SettingsBooleanField<AnalyticsOverlaySettings>] = [
        .init(title: "Bounding boxes", path: \.showBoundingBoxes),
        .init(title: "Pose skeleton", path: \.showPoseSkeleton),
        .init(title: "Track ID", path: \.showTrackID),
        .init(title: "Behavior state", path: \.showBehaviorState),
        .init(title: "Fall status", path: \.showFallStatus),
        .init(title: "Confidence", path: \.showConfidence),
        .init(title: "Critical alert marker", path: \.showCriticalAlertMarker),
        .init(title: "Restricted zones", path: \.showRestrictedZones)
    ]
    static let cameraSwitches: [SettingsBooleanField<CameraAnalyticsOverride>] = [
        .init(title: "Inherit global settings", path: \.inheritGlobalSettings),
        .init(title: "Enable video analytics", path: \.analyticsEnabled),
        .init(title: "Person detection", path: \.personDetectionEnabled),
        .init(title: "Pose estimation", path: \.poseEstimationEnabled),
        .init(title: "Fall detection", path: \.fallDetectionEnabled),
        .init(title: "Behavior analysis", path: \.behaviorAnalysisEnabled),
        .init(title: "Prolonged inactivity", path: \.inactivityDetectionEnabled),
        .init(title: "Loitering detection", path: \.loiteringDetectionEnabled),
        .init(title: "Restricted zone monitoring", path: \.zoneMonitoringEnabled),
        .init(title: "Fight detection", path: \.fightDetectionEnabled),
        .init(title: "Secondary VLM verification", path: \.secondaryVLMVerificationEnabled)
    ]
}

struct SettingsFields<Root>: View {
    @Binding var value: Root
    var switches: [SettingsBooleanField<Root>] = []
    var numbers: [SettingsNumberField<Root>] = []
    var integers: [SettingsIntegerField<Root>] = []
    @Environment(\.locale) private var locale
    var body: some View {
        ForEach(switches) { field in
            Toggle(locale.appLanguage.localized(field.title), isOn: $value[dynamicMember: field.path])
                .accessibilityIdentifier("settings." + field.title)
        }
        ForEach(numbers) { field in
            TextField(locale.appLanguage.localized(field.title), value: $value[dynamicMember: field.path], format: .number.precision(.fractionLength(0...3)))
                .accessibilityIdentifier("settings." + field.title)
        }
        ForEach(integers) { field in
            TextField(locale.appLanguage.localized(field.title), value: $value[dynamicMember: field.path], format: .number)
                .accessibilityIdentifier("settings." + field.title)
        }
    }
}

struct SettingsSaveBar: View {
    let error: String
    let saved: Bool
    let save: () -> Void
    @Environment(\.locale) private var locale
    var body: some View {
        HStack {
            if !error.isEmpty { Text(locale.appLanguage.localizedMessage(error)).foregroundStyle(ACTATheme.danger).textSelection(.enabled) }
            else if saved { Label("Settings saved", systemImage: "checkmark.circle").foregroundStyle(ACTATheme.success) }
            Spacer()
            Button("Save settings", action: save).buttonStyle(.borderedProminent).tint(ACTATheme.actionFill)
                .accessibilityIdentifier("settings.saveSection")
        }.padding(16)
    }
}
