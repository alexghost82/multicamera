import AppKit
import SwiftUI
import CameraCore

/// Every durable application preference has one owner in this settings hierarchy.
enum ACTASettingsSection: String, CaseIterable, Identifiable {
    case general = "General and streams"
    case cameras = "Cameras and sources"
    case models = "AI models"
    case advanced = "Advanced runtime and cleanup"
    case analytics = "Video analytics"
    case ai = "AI backends and privacy"
    case schedules = "Scheduled analysis"
    case missions = "Scheduled local missions"
    case events = "Events and alerts"
    case memory = "Memory and storage"
    case features = "Features and access"
    case showcase = "Local Showcase"
    case identity = "ReID calibration"
    case system = "Diagnostics and worker nodes"
    var id: String { rawValue }
    var searchLabels: [String] {
        switch self {
        case .analytics: AnalyticsSettingsFields.switches.map(\.title) + AnalyticsSettingsFields.numbers.map(\.title) + AnalyticsSettingsFields.integers.map(\.title) + AnalyticsSettingsFields.overlays.map(\.title)
        case .features: CameraFeatureID.allCases.map(\.settingsTitle)
        case .advanced: AdvancedRuntimeSettingsEditor.numbers.map(\.title) + AdvancedRuntimeSettingsEditor.integers.map(\.title)
        case .models: LocalModelService.allCases.map(\.title)
        default: []
        }
    }
    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .cameras: "video"
        case .models: "cpu"
        case .advanced: "gearshape.2"
        case .analytics: "figure.walk"
        case .ai: "sparkles"
        case .schedules: "clock"
        case .missions: "calendar"
        case .events: "bell"
        case .memory: "internaldrive"
        case .features: "lock.shield"
        case .showcase: "rectangle.on.rectangle"
        case .identity: "person.2"
        case .system: "network"
        }
    }
}

struct SettingsHubView: View {
    @ObservedObject var model: WallModel
    @ObservedObject var languageSettings: LanguageSettings
    var manageCameras: () -> Void = {}
    var addNetworkCamera: () -> Void = {}
    var addLocalCamera: () -> Void = {}
    var addScreenCapture: () -> Void = {}
    var addVideoFile: () -> Void = {}
    var editCamera: (Camera) -> Void = { _ in }
    var watchRules: AnyView = AnyView(EmptyView())
    var initialSection: ACTASettingsSection = .general
    @State private var selection = ACTASettingsSection.general
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2).bold()
            HStack(spacing: 16) {
                VStack(spacing: 8) {
                    TextField("Find settings section", text: $search).textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(ACTASettingsSection.allCases.filter { search.isEmpty || ([$0.rawValue] + $0.searchLabels).contains { languageSettings.localized($0).localizedCaseInsensitiveContains(search) } }) { item in
                                Button { selection = item } label: {
                                    Label(languageSettings.localized(item.rawValue), systemImage: item.icon)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(selection == item ? ACTATheme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                                .accessibilityIdentifier("settings.section." + item.id)
                                .accessibilityAddTraits(selection == item ? .isSelected : [])
                            }
                        }
                    }
                }.frame(width: 232)
                VStack(alignment: .leading, spacing: 8) {
                    Text(languageSettings.localized(selection.rawValue)).font(.title3).bold().padding(.horizontal, 16)
                    selectedContent.id(selection)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(8).actaAppearance().accessibilityIdentifier("settings.hub")
        .onAppear { selection = initialSection }
    }

    @ViewBuilder private var selectedContent: some View {
        switch selection {
        case .general: SystemSettingsEditor(model: model, languageSettings: languageSettings)
        case .cameras: CameraSettingsEditor(model: model, manage: manageCameras, addNetwork: addNetworkCamera,
            addLocal: addLocalCamera, addScreen: addScreenCapture, addFile: addVideoFile, edit: editCamera)
        case .models: ModelsSettingsEditor(model: model)
        case .advanced: AdvancedRuntimeSettingsEditor(model: model)
        case .analytics: AnalyticsSettingsEditor(engine: model.localAnalyticsEngine, cameras: model.config.cameras)
        case .ai: AISettingsEditor(model: model)
        case .schedules: ScheduleSettingsEditor(model: model)
        case .missions: ScrollView { CameraMissionsPanel(model: model).padding(16) }
        case .events: EventsSettingsEditor(model: model, watchRules: watchRules)
        case .memory: FeaturePolicySettingsEditor(model: model, memoryOnly: true)
        case .features: FeaturePolicySettingsEditor(model: model, memoryOnly: false)
        case .showcase: LocalShowcaseView(model: model, settingsMode: true)
        case .identity: ReIDCalibrationView(model: model)
        case .system: DiagnosticsSettingsEditor(model: model)
        }
    }
}

struct SystemSettingsEditor: View {
    @ObservedObject var model: WallModel
    @ObservedObject var languageSettings: LanguageSettings
    @State private var draft: WallConfiguration
    @State private var error = ""
    @State private var saved = false
    init(model: WallModel, languageSettings: LanguageSettings) {
        self.model = model; self.languageSettings = languageSettings
        _draft = State(initialValue: model.config)
    }
    private var bundledRelayPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/go2rtc").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Interface") {
                    Picker("Interface language", selection: Binding(get: { languageSettings.language }, set: { languageSettings.setLanguage($0) })) {
                        Text("Русский").tag(AppLanguage.russian)
                        Text("English").tag(AppLanguage.english)
                    }
                    Stepper("Columns: \(draft.columns)", value: $draft.columns, in: 1...16)
                    TextField("Stale threshold (ms)", value: $draft.staleAfterMilliseconds, format: .number)
                }
                Section("Local camera relay") {
                    TextField("go2rtc executable", text: Binding(get: { bundledRelayPath ?? draft.go2rtcPath }, set: { draft.go2rtcPath = $0 }))
                        .disabled(bundledRelayPath != nil)
                    if bundledRelayPath != nil { Text("The app uses its bundled go2rtc helper").foregroundStyle(.secondary) }
                    TextField("Local API port", value: $draft.apiPort, format: .number)
                    TextField("Local RTSP port", value: $draft.rtspPort, format: .number)
                }
                Section("Object detection") {
                    TextField("YOLO confidence threshold", value: $draft.detectionThreshold, format: .number)
                    Stepper("Detection FPS per camera: \(Int(draft.detectionFPS))", value: $draft.detectionFPS, in: 1...5)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do {
                    guard FileManager.default.isExecutableFile(atPath: bundledRelayPath ?? draft.go2rtcPath) else {
                        throw ConfigurationError.invalid("Select an existing executable file for go2rtc.")
                    }
                    try model.saveSystemSettings(draft); saved = true; error = ""
                }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
    }
}

private struct CameraSettingsEditor: View {
    @ObservedObject var model: WallModel
    let manage: () -> Void
    let addNetwork: () -> Void
    let addLocal: () -> Void
    let addScreen: () -> Void
    let addFile: () -> Void
    let edit: (Camera) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Menu("Add camera") {
                    Button("Add network camera", action: addNetwork)
                    Button("Mac / iPhone camera", action: addLocal)
                    Button("Screen capture source", action: addScreen)
                    Button("Local video file", action: addFile)
                }
                ForEach(model.config.cameras) { camera in
                    GroupBox {
                        HStack { Text(camera.name).bold(); Spacer(); Button("Edit camera") { edit(camera) } }
                        Text(camera.location ?? "").foregroundStyle(.secondary)
                        Toggle("Enabled", isOn: Binding(get: { camera.enabled }, set: { model.setEnabled(camera, enabled: $0) }))
                        Toggle("YOLO", isOn: Binding(get: { camera.yoloEnabled }, set: { model.setYOLOEnabled(for: camera.id, enabled: $0) }))
                        Toggle("AI chat", isOn: Binding(get: { camera.aiChatEnabled }, set: { model.setAIChatEnabled(for: camera.id, enabled: $0) }))
                    }
                }
                if model.config.cameras.isEmpty { Text("No cameras added") }
                Button("Manage cameras", action: manage)
            }.padding(16)
        }
    }
}

private struct ModelsSettingsEditor: View {
    @ObservedObject var model: WallModel
    @ObservedObject private var runtime: LocalModelRuntime
    @State private var draft: ModelSelectionPreferences
    @State private var error = ""
    @State private var saved = false
    @Environment(\.locale) private var locale
    init(model: WallModel) { self.model = model; self.runtime = model.modelRuntime; _draft = State(initialValue: model.modelPreferences) }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(LocalModelService.allCases) { service in
                    Section(locale.appLanguage.localized(service.title)) {
                        Toggle("Model enabled", isOn: Binding(get: { draft.enabled.contains(service) }, set: { if $0 { draft.enabled.insert(service) } else { draft.enabled.remove(service) } }))
                        Text(locale.appLanguage.localized(runtime.states[service]?.label ?? "Waiting")).foregroundStyle(.secondary)
                        if case .failed(let reason) = runtime.states[service] {
                            Text(locale.appLanguage.localizedMessage(reason)).foregroundStyle(ACTATheme.danger).textSelection(.enabled)
                        }
                        TextField("Model path (empty uses bundled model)", text: Binding(get: { draft.paths[service] ?? "" }, set: { draft.paths[service] = $0 }))
                        HStack {
                            Button("Choose model") { choose(service) }
                            Button("Use bundled model") { draft.paths.removeValue(forKey: service) }
                        }
                        Text(service == .yolo ? "Core ML .mlmodelc" : service == .pose ? "Core ML .mlmodelc / .mlpackage / .mlmodel" : service == .qwen ? "Local MLX model directory" : "ONNX model with compatible inputs and outputs")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do { try model.saveModelPreferences(draft); saved = true; error = "" }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
    }
    private func choose(_ service: LocalModelService) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = service != .qwen
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { draft.paths[service] = url.path }
    }
}

private struct OpenACTASettingsKey: EnvironmentKey {
    static let defaultValue: (ACTASettingsSection) -> Void = { _ in }
}
extension EnvironmentValues {
    var openACTASettings: (ACTASettingsSection) -> Void {
        get { self[OpenACTASettingsKey.self] }
        set { self[OpenACTASettingsKey.self] = newValue }
    }
}
struct OpenSettingsButton: View {
    let section: ACTASettingsSection
    @Environment(\.openACTASettings) private var open
    @Environment(\.locale) private var locale
    var body: some View { Button(locale.appLanguage.localized("Settings"), systemImage: "gearshape") { open(section) } }
}
