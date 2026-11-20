import SwiftUI
import CameraCore

struct AnalyticsSettingsEditor: View {
    @ObservedObject var engine: LocalVideoAnalyticsEngine
    let cameras: [Camera]
    @State private var draft: VideoAnalyticsSettings
    @State private var draftRevision: UUID
    @State private var cameraID: UUID?
    @State private var error = ""
    @State private var saved = false
    @State private var pendingOverrideRemoval: ACTAAnalyticsDraftDeletion.Override?
    @State private var confirmingOverrideRemoval = false
    @Environment(\.locale) private var locale

    init(engine: LocalVideoAnalyticsEngine, cameras: [Camera]) {
        self.engine = engine; self.cameras = cameras
        _draft = State(initialValue: engine.settings)
        _draftRevision = State(initialValue: engine.settingsWriteGate.revision)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Global video analytics") {
                    SettingsFields(value: $draft, switches: AnalyticsSettingsFields.switches)
                    Picker("Execution mode", selection: $draft.executionMode) {
                        ForEach(AnalyticsExecutionMode.allCases, id: \.self) { Text(locale.appLanguage.localized($0.rawValue)).tag($0) }
                    }
                    Picker("Sensitivity profile", selection: $draft.sensitivityProfile) {
                        ForEach(AnalyticsSensitivityProfile.allCases, id: \.self) { Text(locale.appLanguage.localized($0.rawValue)).tag($0) }
                    }
                    Button("Apply sensitivity profile") { draft.applySensitivityProfile(draft.sensitivityProfile) }
                }
                Section("Advanced analytics") {
                    SettingsFields(value: $draft, numbers: AnalyticsSettingsFields.numbers, integers: AnalyticsSettingsFields.integers)
                }
                Section("Video overlays") { SettingsFields(value: $draft.overlaySettings, switches: AnalyticsSettingsFields.overlays) }
                Section("Per-camera analytics") {
                    Picker("Camera", selection: $cameraID) {
                        Text("Select camera").tag(Optional<UUID>.none)
                        ForEach(cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let cameraID {
                        CameraAnalyticsSettingsEditor(value: cameraBinding(cameraID), onZoneRemoved: { saved = false }).id(cameraID)
                        if draft.cameraOverrides[cameraID] != nil {
                            Button("Remove camera override", role: .destructive) {
                                pendingOverrideRemoval = ACTAAnalyticsDraftDeletion.Override(cameraID: cameraID, settings: draft)
                                confirmingOverrideRemoval = pendingOverrideRemoval != nil
                                if pendingOverrideRemoval == nil { error = "The draft changed. Review it again." }
                            }
                        }
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do {
                    try draft.validate()
                    try engine.updateSettings(draft, expectedRevision: draftRevision)
                    draft = engine.settings
                    draftRevision = engine.settingsWriteGate.revision
                    saved = true
                    error = ""
                }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
        .confirmationDialog("Remove camera override?", isPresented: $confirmingOverrideRemoval,
                            presenting: pendingOverrideRemoval) { review in
            Button("Remove camera override", role: .destructive) {
                if review.apply(to: &draft) {
                    if cameraID == review.cameraID { cameraID = nil }
                    saved = false
                    error = ""
                } else {
                    error = "The draft changed. Review it again."
                }
                pendingOverrideRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingOverrideRemoval = nil }
        } message: { review in
            Text("This removes the override and all its restricted zones from the draft. Save to apply.")
            Text(review.cameraID.uuidString)
            Text("Restricted zones: \(review.reviewed.restrictedZones.count)")
        }
    }

    private func cameraBinding(_ id: UUID) -> Binding<CameraAnalyticsOverride> {
        Binding(get: { draft.cameraOverrides[id] ?? CameraAnalyticsOverride(cameraID: id) },
                set: { draft.cameraOverrides[id] = $0 })
    }
}

private struct CameraAnalyticsSettingsEditor: View {
    @Environment(\.locale) private var locale
    @Binding var value: CameraAnalyticsOverride
    let onZoneRemoved: () -> Void
    @State private var customFPS = false
    @State private var customCooldown = false
    var body: some View {
        SettingsFields(value: $value, switches: AnalyticsSettingsFields.cameraSwitches)
        Picker("Sensitivity profile", selection: $value.sensitivityProfile) {
            ForEach(AnalyticsSensitivityProfile.allCases, id: \.self) { Text(locale.appLanguage.localized($0.rawValue)).tag($0) }
        }
        Toggle("Override sampling FPS", isOn: Binding(get: { value.customSamplingFPS != nil }, set: { value.customSamplingFPS = $0 ? 4 : nil }))
        if value.customSamplingFPS != nil {
            TextField("Analytics sampling FPS", value: Binding(get: { value.customSamplingFPS ?? 4 }, set: { value.customSamplingFPS = $0 }), format: .number)
        }
        Toggle("Override alert cooldown", isOn: Binding(get: { value.customAlertCooldownSeconds != nil }, set: { value.customAlertCooldownSeconds = $0 ? 30 : nil }))
        if value.customAlertCooldownSeconds != nil {
            TextField("Alert cooldown seconds", value: Binding(get: { value.customAlertCooldownSeconds ?? 30 }, set: { value.customAlertCooldownSeconds = $0 }), format: .number)
        }
        RestrictedZoneSettingsEditor(zones: $value.restrictedZones, onZoneRemoved: onZoneRemoved)
    }
}

private struct RestrictedZoneSettingsEditor: View {
    @Environment(\.locale) private var locale
    @Binding var zones: [RestrictedZoneRegion]
    let onZoneRemoved: () -> Void
    @State private var pendingRemoval: ACTAAnalyticsDraftDeletion.Zone?
    @State private var confirmingRemoval = false
    @State private var removalError = false
    var body: some View {
        DisclosureGroup("Restricted zones") {
            ForEach($zones) { $zone in
                GroupBox {
                    TextField("Zone name", text: $zone.name)
                    Toggle("Enabled", isOn: $zone.enabled)
                    TextField("Zone hold seconds", value: $zone.holdSeconds, format: .number)
                    Picker("Severity", selection: $zone.severity) {
                        ForEach(SafetyIncidentSeverity.allCases, id: \.self) { Text(locale.appLanguage.localized($0.rawValue)).tag($0) }
                    }
                    Text("Normalized coordinates: 0 to 1").foregroundStyle(.secondary)
                    ForEach(zone.points.indices, id: \.self) { index in
                        HStack {
                            Text("\(index + 1)").monospacedDigit()
                            TextField("X", value: $zone.points[index].x, format: .number)
                            TextField("Y", value: $zone.points[index].y, format: .number)
                            Button { zone.points.remove(at: index) } label: { Image(systemName: "minus.circle") }.disabled(zone.points.count <= 3)
                        }
                    }
                    Button("Add polygon point") { zone.points.append(NormalizedPoint(x: 0.5, y: 0.5)) }
                    Button("Remove zone", role: .destructive) {
                        pendingRemoval = ACTAAnalyticsDraftDeletion.Zone(id: zone.id, zones: zones)
                        confirmingRemoval = pendingRemoval != nil
                        removalError = pendingRemoval == nil
                    }
                }
            }
            if removalError { Text("The draft changed. Review it again.").foregroundStyle(.red) }
            Button("Add restricted zone") { zones.append(.rectangle(name: "", x: 0.2, y: 0.2, width: 0.6, height: 0.6)) }
        }
        .confirmationDialog("Remove restricted zone?", isPresented: $confirmingRemoval,
                            presenting: pendingRemoval) { review in
            Button("Remove zone", role: .destructive) {
                removalError = !review.apply(to: &zones)
                if !removalError { onZoneRemoved() }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { review in
            Text("This removes the zone from the draft. Save to apply.")
            Text(review.zone.name)
        }
    }
}
