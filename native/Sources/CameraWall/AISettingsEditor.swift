import SwiftUI
import CameraCore

struct AISettingsEditor: View {
    @ObservedObject var model: WallModel
    @State private var draft: VLMPreferences
    @State private var error = ""
    @State private var saved = false
    init(model: WallModel) { self.model = model; _draft = State(initialValue: model.vlmPreferences) }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("AI backend") {
                    Picker("AI Backend", selection: $draft.actaBackendMode) {
                        ForEach(ACTAAIBackendMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("Local vLLM URL", text: $draft.actaVLLMBaseURL)
                    TextField("Local vLLM Model", text: $draft.actaVLLMModelName)
                    if draft.actaBackendMode == .localVLLM {
                        Stepper("Max parallel local vLLM requests: \(draft.actaVLLMMaxConcurrentRequests)", value: $draft.actaVLLMMaxConcurrentRequests, in: 1...16)
                        Toggle("Allow local MLX fallback if vLLM Metal is unavailable", isOn: $draft.actaVLLMAllowLocalMLXFallback)
                        HStack(spacing: 8) {
                            Text("Local vLLM Metal status: \(model.localVLLMTelemetry.state.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.localVLLMTelemetry.state == .running || model.localVLLMTelemetry.state == .starting {
                                Button("Stop local vLLM") { model.stopManagedLocalVLLM() }
                            } else {
                                Button("Start local vLLM") { model.startManagedLocalVLLM() }
                            }
                            Button("Check health") { model.refreshLocalVLLMHealth() }
                        }
                        if let ttft = model.localVLLMTelemetry.lastTTFTMs,
                           let tokS = model.localVLLMTelemetry.lastTokensPerSecond {
                            Text(String(format: "Last TTFT: %.0f ms · %.1f tok/s", ttft, tokS))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    TextField("OpenAI Responses URL", text: $draft.actaOpenAIBaseURL)
                    TextField("Backup relay URL", text: $draft.actaBackupRelayURL)
                    TextField("Cloud nano model", text: $draft.cloudNanoModel)
                    TextField("Cloud mini model", text: $draft.cloudMiniModel)
                    TextField("Cloud full model", text: $draft.cloudFullModel)
                    Picker("Analytics Language", selection: $draft.actaPreferredLanguage) {
                        ForEach(ACTAPromptLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Spoken Tactical Briefing (18s)", isOn: $draft.actaSpokenBriefingEnabled)
                }
                Section("API credentials") { AICredentialsSettingsEditor() }
                Section("Cloud privacy and budget") {
                    Toggle("Blur faces before cloud requests", isOn: $draft.privacyBlurFacesInCloud)
                    Toggle("Blur plates before cloud requests", isOn: $draft.privacyBlurPlatesInCloud)
                    TextField("Daily AI budget (USD)", value: $draft.dailyBudgetLimitUSD, format: .number)
                    TextField("Monthly AI budget (USD)", value: $draft.monthlyBudgetLimitUSD, format: .number)
                    Text("External requests require separate permission in Features and access.").foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do { try model.saveVLMPreferences(draft); error = ""; saved = true }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
    }
}

struct ScheduleSettingsEditor: View {
    @ObservedObject var model: WallModel
    @State private var draft: VLMPreferences
    @State private var operations: OperationsPreferences
    @State private var error = ""
    init(model: WallModel) {
        self.model = model; _draft = State(initialValue: model.vlmPreferences); _operations = State(initialValue: model.operationsPreferences)
    }
    var body: some View {
        VLMScheduleForm(draft: $draft, operations: $operations, cameras: model.config.cameras,
            descriptionsEnabled: Binding(get: { model.featurePreferences.enabledFeatures.contains(.visionDescriptions) }, set: {
                do { try model.setFeatureEnabled(.visionDescriptions, enabled: $0) }
                catch { self.error = error.localizedDescription }
            }), descriptionQueue: EmptyView(), errorMessage: error, save: {
                do { try model.saveVLMPreferences(draft); error = "" }
                catch { self.error = error.localizedDescription }
            }).padding(16)
    }
}

struct EventsSettingsEditor: View {
    @ObservedObject var model: WallModel
    var watchRules: AnyView = AnyView(EmptyView())
    @State private var draft: OperationsPreferences
    @State private var error = ""
    @State private var saved = false
    init(model: WallModel, watchRules: AnyView = AnyView(EmptyView())) { self.model = model; self.watchRules = watchRules; _draft = State(initialValue: model.operationsPreferences) }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Persistent visual watches") { watchRules }
                Section("Monitoring and alerts") {
                    feature("In-app health monitor", .independentWatcher)
                    feature("Enable local operations alerts", .operationalAlerts)
                    Toggle("Person-count alerts", isOn: $draft.personCountAlertsEnabled)
                    TextField("Person threshold", value: $draft.personThreshold, format: .number)
                    TextField("Hold seconds", value: $draft.holdSeconds, format: .number)
                    TextField("Cooldown seconds", value: $draft.cooldownSeconds, format: .number)
                    Toggle("Critical alert sound", isOn: $draft.criticalSoundEnabled)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do { try model.saveOperationsPreferences(draft); error = ""; saved = true }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
    }
    private func feature(_ title: LocalizedStringKey, _ id: CameraFeatureID) -> some View {
        Toggle(title, isOn: Binding(get: { model.featurePreferences.enabledFeatures.contains(id) }, set: {
            do { try model.setFeatureEnabled(id, enabled: $0) }
            catch { self.error = error.localizedDescription }
        }))
    }
}

struct FeaturePolicySettingsEditor: View {
    @ObservedObject var model: WallModel
    let memoryOnly: Bool
    @State private var draft: CameraFeaturePreferences
    @State private var error = ""
    @State private var saved = false
    @Environment(\.locale) private var locale
    init(model: WallModel, memoryOnly: Bool) {
        self.model = model; self.memoryOnly = memoryOnly; _draft = State(initialValue: model.featurePreferences)
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                if memoryOnly {
                    Section("Memory and storage") {
                        feature(.chronologicalMemory)
                        feature(.historyResearch)
                        Toggle("Retain sampled camera frames", isOn: $draft.retainFullFrames)
                        Stepper("Retention days: \(draft.retentionDays)", value: $draft.retentionDays, in: 1...365)
                        Text("Frame and evidence stores also enforce their own retention and disk quotas.").foregroundStyle(.secondary)
                    }
                } else {
                    Section("Features") {
                        ForEach(CameraFeatureID.allCases, id: \.self) { feature($0) }
                    }
                    Section("Permissions") {
                        Toggle("Allow external AI", isOn: $draft.allowExternalAI)
                        Toggle("Allow local voice input", isOn: $draft.allowVoiceInput)
                        Toggle("Allow plate registry lookup", isOn: $draft.allowPlateRegistryLookup)
                        Toggle("Allow public access", isOn: $draft.allowPublicAccess).disabled(!draft.allowPublicAccess)
                        Text("Public network access is not supported. Local showcase uses loopback only.").foregroundStyle(.secondary)
                        Text("Enabling permission does not start a server or send data.").foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            SettingsSaveBar(error: error, saved: saved) {
                do { try model.saveFeaturePolicy(draft); error = ""; saved = true }
                catch { self.error = error.localizedDescription; saved = false }
            }
        }
    }
    private func feature(_ id: CameraFeatureID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        Toggle(locale.appLanguage.localized(id.settingsTitle), isOn: Binding(get: { model.featurePreferences.enabledFeatures.contains(id) }, set: {
            do { try model.setFeatureEnabled(id, enabled: $0) }
            catch { self.error = error.localizedDescription }
        })).disabled(id == .additionalVideoSources || id == .accessControl)
        if id == .additionalVideoSources || id == .accessControl {
            Text("Reserved preference: no runtime control is implemented yet.").font(.caption).foregroundStyle(.secondary)
        }
        }
    }
}

extension CameraFeatureID {
    var settingsTitle: String {
        switch self {
        case .additionalVideoSources: "Additional video sources"
        case .enhancedDetection: "Motion-aware tracking"
        case .crossCameraIdentity: "Enable identity review"
        case .visionDescriptions: "Automatically describe new tracks"
        case .historyResearch: "Save research history"
        case .operatorActions: "Allow operator actions"
        case .chronologicalMemory: "Enable chronological memory"
        case .operationalAlerts: "Enable local operations alerts"
        case .scheduledMissions: "Enable missions"
        case .plateRecognition: "Save vehicle text locally"
        case .knowledgeSearch: "Expand search terms"
        case .independentWatcher: "In-app health monitor"
        case .publicShowcase: "Enable local showcase"
        case .accessControl: "Access control"
        }
    }
}

private struct AICredentialsSettingsEditor: View {
    @State private var primary = ""
    @State private var alert = ""
    @State private var result = ""
    @Environment(\.locale) private var locale
    var body: some View {
        SecureField("New primary API key", text: $primary)
        SecureField("New alert API key", text: $alert)
        Button("Save API keys in Keychain") {
            var ok = true
            if !primary.isEmpty { ok = ACTAKeychainStore.saveKey(primary) && ok }
            if !alert.isEmpty { ok = ACTAKeychainStore.saveKey(alert, account: ACTAKeychainStore.alertKeyAccount) && ok }
            if ok { primary = ""; alert = "" }
            result = ok ? "Settings saved" : "Could not save API keys"
        }.disabled(primary.isEmpty && alert.isEmpty)
        if !result.isEmpty { Text(locale.appLanguage.localizedMessage(result)) }
    }
}
