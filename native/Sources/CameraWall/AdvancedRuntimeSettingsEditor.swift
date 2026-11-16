import SwiftUI
import CameraCore

struct AdvancedRuntimeSettingsEditor: View {
    @ObservedObject var model: WallModel
    @State private var draft: AdvancedRuntimePreferences
    @State private var error = ""
    @State private var saved = false
    init(model: WallModel) { self.model = model; _draft = State(initialValue: model.runtimePreferences) }
    static let numbers: [SettingsNumberField<FallDetectorConfiguration>] = [
        .init(title: "Torso angle threshold degrees", path: \.torsoAngleThresholdDegrees),
        .init(title: "Aspect ratio threshold", path: \.aspectRatioThreshold),
        .init(title: "Height collapse threshold", path: \.heightCollapseThreshold),
        .init(title: "Sitting height threshold", path: \.sittingHeightThreshold),
        .init(title: "Crouching height threshold", path: \.crouchingHeightThreshold),
        .init(title: "Low frame rate threshold", path: \.lowFrameRateThreshold),
        .init(title: "Low frame rate persistence seconds", path: \.lowFrameRatePersistenceSeconds),
        .init(title: "Velocity feature minimum f p s", path: \.velocityFeatureMinimumFPS),
        .init(title: "Walking speed body heights per second", path: \.walkingSpeedBodyHeightsPerSecond),
        .init(title: "Running speed body heights per second", path: \.runningSpeedBodyHeightsPerSecond),
        .init(title: "Controlled sit before lie seconds", path: \.controlledSitBeforeLieSeconds),
        .init(title: "Controlled lie down max drop speed body heights per second", path: \.controlledLieDownMaxDropSpeedBodyHeightsPerSecond),
        .init(title: "Ema alpha", path: \.emaAlpha),
        .init(title: "Low confidence floor", path: \.lowConfidenceFloor),
        .init(title: "Match io u threshold", path: \.matchIoUThreshold),
        .init(title: "Relink maximum gap seconds", path: \.relinkMaximumGapSeconds),
        .init(title: "Relink maximum diagonal ratio", path: \.relinkMaximumDiagonalRatio),
        .init(title: "Frame interval smoothing", path: \.frameIntervalSmoothing)
    ]
    static let integers: [SettingsIntegerField<FallDetectorConfiguration>] = [
        .init(title: "Minimum confirming samples", path: \.minimumConfirmingSamples),
        .init(title: "Minimum baseline samples", path: \.minimumBaselineSamples),
        .init(title: "Recovery samples", path: \.recoverySamples),
        .init(title: "Maximum tracks", path: \.maximumTracks)
    ]
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Advanced fall tracking") {
                    Text("Common confidence and confirmation thresholds are in Video analytics.").foregroundStyle(.secondary)
                    SettingsFields(value: $draft.fall, numbers: Self.numbers, integers: Self.integers)
                }
                Section("Storage cleanup") {
                    TextField("Media disk limit (MB)", value: $draft.storage.maxMediaDiskMB, format: .number)
                    TextField("Minimum free disk (GB)", value: $draft.storage.minFreeDiskGB, format: .number)
                    TextField("Crops per identity", value: $draft.storage.maxCropsPerIdentity, format: .number)
                    Toggle("Data saver", isOn: $draft.storage.dataSaverEnabled)
                    TextField("Track image retention days", value: $draft.storage.trackImageRetentionDays, format: .number)
                    TextField("Log retention days", value: $draft.storage.logRetentionDays, format: .number)
                }
                Section("Capture and crop selection") {
                    TextField("Bootstrap seconds", value: $draft.capture.bootstrapSeconds, format: .number)
                    TextField("Capture interval seconds", value: $draft.capture.intervalSeconds, format: .number)
                    TextField("Movement fraction", value: Binding(get: { Double(draft.capture.movementFraction) }, set: { draft.capture.movementFraction = CGFloat($0) }), format: .number)
                    TextField("Inheritance maximum age", value: $draft.capture.inheritMaxAge, format: .number)
                    TextField("Inheritance minimum IoU", value: Binding(get: { Double(draft.capture.inheritMinIoU) }, set: { draft.capture.inheritMinIoU = CGFloat($0) }), format: .number)
                    TextField("Stale track TTL", value: $draft.capture.staleTrackTTL, format: .number)
                    TextField("Crop window seconds", value: $draft.cropWindowSeconds, format: .number)
                    TextField("Best crops per window", value: $draft.cropTopK, format: .number)
                    TextField("Crop improvement ratio", value: $draft.cropImprovementRatio, format: .number)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do { try model.saveRuntimePreferences(draft); error = ""; saved = true }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
    }
}
