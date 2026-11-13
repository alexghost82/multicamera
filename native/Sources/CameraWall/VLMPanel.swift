import SwiftUI
import CameraCore

enum VLMPanelSection: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case history = "History"
    case schedule = "Schedule"
    case alerts = "Alerts"

    var id: String { rawValue }
}

struct VLMPanel: View {
    @ObservedObject var model: WallModel
    @ObservedObject var languageSettings: LanguageSettings
    @State private var draft = VLMPreferences()
    @State private var operationsDraft = OperationsPreferences()
    @State private var activeSection = VLMPanelSection.ask
    @State private var question = ""
    @State private var questionBeforeVoice = ""
    @State private var historyQuestion = ""
    @State private var historyError = ""
    @State private var saveError = ""
    @State private var descriptionJobs: [CameraFeatureJob] = []
    @StateObject private var voiceInput = LocalVoiceInput()

    private var enabledCameras: [Camera] { model.config.cameras.filter(\.enabled) }
    private var questionCameraIDs: Set<UUID> { Set(enabledCameras.filter(\.aiChatEnabled).map(\.id)) }

    var body: some View {
        AnalysisPanelViewport {
            AnalysisPanelTabs(selection: $activeSection, alertCount: model.vlmAlerts.count)

            Group {
                switch activeSection {
                case .ask: askTab
                case .history: historyTab
                case .schedule: scheduleTab
                case .alerts: alertsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            draft = model.vlmPreferences
            operationsDraft = model.operationsPreferences
        }
    }

    private var askTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(languageSettings.localizedMessage(model.vlmStatus), systemImage: model.vlmBusy ? "hourglass" : "cpu")
                    .lineLimit(1)
                Spacer()
                Button("Clear conversation") { model.vlmMessages = [] }
                    .disabled(model.vlmMessages.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.vlmMessages.isEmpty {
                            AnalysisPanelEmptyState(title: "Ask about a camera frame", icon: "text.bubble")
                                .frame(maxWidth: .infinity, minHeight: 220)
                        }
                        ForEach(model.vlmMessages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: model.vlmMessages.count) { _, _ in
                    if let id = model.vlmMessages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(enabledCameras) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { camera.aiChatEnabled },
                            set: { model.setAIChatEnabled(for: camera.id, enabled: $0) }
                        ))
                    }
                } label: {
                    Label(languageSettings.localized("%lld selected", arguments: [questionCameraIDs.count]), systemImage: "video")
                }
                .help("Choose cameras included in AI chat")
                .accessibilityLabel("Cameras included in AI chat")
                .disabled(enabledCameras.isEmpty)
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    if voiceInput.isRecording {
                        voiceInput.stop()
                    } else {
                        questionBeforeVoice = question
                        Task { await voiceInput.start(localeIdentifier: languageSettings.locale.identifier) }
                    }
                } label: {
                    Image(systemName: voiceInput.isRecording ? "stop.fill" : "mic")
                }
                .help(voiceInput.isRecording ? "Stop local dictation" : "Start local dictation")
                .accessibilityLabel(voiceInput.isRecording ? "Stop local dictation" : "Start local dictation")
                AnalysisQuestionComposer(question: $question,
                    sendDisabled: model.manualQuestionQueue.pending != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || questionCameraIDs.isEmpty,
                    submit: submitQuestion)
            }
            if model.manualQuestionQueue.pending != nil {
                Text(languageSettings.localized("Question queued after the current analysis"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if voiceInput.isRecording {
                Label("Listening locally. Review the text before sending.", systemImage: "waveform")
                    .font(.caption)
                    .accessibilityLabel("Local dictation is recording")
                    .accessibilityValue(voiceInput.transcript)
            }
            if let errorMessage = voiceInput.errorMessage {
                Text(languageSettings.localizedMessage(errorMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Dictation error: \(errorMessage)")
            }
        }
        .padding(.top, 8)
        .onChange(of: voiceInput.transcript) { _, transcript in
            question = LocalVoiceInput.mergeTranscript(transcript, with: questionBeforeVoice)
        }
        .onDisappear { voiceInput.cancel() }
    }

    private func messageRow(_ message: VLMChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(LocalizedStringKey(message.role == .operatorMessage ? "Operator" : "Qwen"))
                    .font(.caption.weight(.semibold))
                Text(message.cameraNames.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(message.role == .operatorMessage ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var historyTab: some View {
        AnalysisHistoryPage(status: languageSettings.localizedMessage(model.vlmStatus), busy: model.vlmBusy,
            persistHistory: Binding(
                get: { model.featurePreferences.enabledFeatures.contains(.historyResearch) },
                set: { enabled in
                    do { try model.setFeatureEnabled(.historyResearch, enabled: enabled); historyError = "" }
                    catch { historyError = error.localizedDescription }
                }
            ), allowActions: Binding(
                get: { model.featurePreferences.enabledFeatures.contains(.operatorActions) },
                set: { enabled in
                    do { try model.setFeatureEnabled(.operatorActions, enabled: enabled); historyError = "" }
                    catch { historyError = error.localizedDescription }
                }
            ), expandTerms: Binding(
                get: { model.featurePreferences.enabledFeatures.contains(.knowledgeSearch) },
                set: { enabled in
                    do { try model.setFeatureEnabled(.knowledgeSearch, enabled: enabled); historyError = "" }
                    catch { historyError = error.localizedDescription }
                }
            ), question: $historyQuestion,
            sendDisabled: model.vlmBusy || model.manualQuestionQueue.pending != nil || historyQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            errorMessage: languageSettings.localizedMessage(historyError),
            lastMessageID: model.trackResearchMessages.last?.id,
            clear: model.clearTrackResearchHistory, submit: submitHistoryQuestion) {
            if model.trackResearchMessages.isEmpty {
                AnalysisPanelEmptyState(title: "Ask about local track history", icon: "text.magnifyingglass",
                    detail: "Answers use saved tracks and automatic camera scans.")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
            ForEach(model.trackResearchMessages) { message in historyMessageRow(message) }
            if model.featurePreferences.enabledFeatures.contains(.operatorActions) {
                ForEach(model.operatorActions) { action in operatorActionRow(action) }
            }
        }
        .padding(.top, 8)
        .onAppear { model.reloadOperatorActions() }
    }

    private func operatorActionRow(_ action: CameraOperatorAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Describe tracks", systemImage: "text.viewfinder")
                .font(.caption.weight(.semibold))
            ForEach(action.trackIDs, id: \.self) { trackID in
                Text(trackID.uuidString).font(.caption).textSelection(.enabled)
            }
            Text(action.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)).font(.caption).foregroundStyle(.secondary)
            if action.status == .pending {
                HStack {
                    Button {
                        model.reviewOperatorAction(action.id, accept: true)
                    } label: {
                        Label("Confirm", systemImage: "checkmark")
                    }
                    .disabled(!model.featurePreferences.enabledFeatures.contains(.visionDescriptions))
                    .help("Confirm local track description jobs; track descriptions must be enabled")
                    Button(role: .destructive) {
                        model.reviewOperatorAction(action.id, accept: false)
                    } label: {
                        Label("Reject", systemImage: "xmark")
                    }
                }
            } else {
                Text(LocalizedStringKey(action.status == .applied ? "Confirmed" : "Rejected"))
                    .font(.caption.weight(.medium))
                if let reviewedAt = action.reviewedAt {
                    Text(reviewedAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(action.jobIDs, id: \.self) { jobID in
                    Text("Job: \(jobID.uuidString)").font(.caption).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func historyMessageRow(_ message: TrackResearchMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(message.role == .operatorMessage ? "Operator" : "Local history assistant"))
                .font(.caption.weight(.semibold))
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.role == .assistant {
                if message.citedTrackIDs.isEmpty && message.citedScanIDs.isEmpty {
                    Text("No verified track citations")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(message.citedTrackIDs, id: \.self) { trackID in
                        if let record = model.recentTracks.first(where: { $0.trackID == trackID }) {
                            Label("\(record.cameraName) · \(record.label) · \(trackID.uuidString.prefix(8))",
                                  systemImage: "quote.opening")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Saved track: \(trackID.uuidString.prefix(8))", systemImage: "quote.opening")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(message.citedScanIDs, id: \.self) { scanID in
                    Label("Saved scan: \(scanID.uuidString.prefix(8))", systemImage: "quote.opening")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .operatorMessage ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func submitHistoryQuestion() {
        guard !model.vlmBusy, model.manualQuestionQueue.pending == nil,
              !historyQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.askTrackResearch(question: historyQuestion) { historyQuestion = "" }
    }

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("GHOST ONWAY Hybrid AI & Analytics") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("AI Backend", selection: $draft.ghostBackendMode) {
                        ForEach(GhostAIBackendMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("Analytics Language", selection: $draft.ghostPreferredLanguage) {
                        ForEach(GhostPromptLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    TextField("Local vLLM URL", text: $draft.ghostVLLMBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Local vLLM Model", text: $draft.ghostVLLMModelName)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Spoken Tactical Briefing (18s)", isOn: $draft.ghostSpokenBriefingEnabled)
                    HStack {
                        Label(
                            model.ghostHealthStatus.isHealthy ? "Engine Healthy" : "Circuit Open",
                            systemImage: model.ghostHealthStatus.isHealthy ? "checkmark.shield" : "exclamationmark.triangle"
                        )
                        Spacer()
                        Text(String(format: "Latency: %.0f ms · Spend: $%.2f", model.ghostHealthStatus.ewmaLatencyMs, model.ghostBudgetSnapshot.dailySpendUSD))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .padding(6)
            }
            VLMScheduleForm(draft: $draft, operations: $operationsDraft, cameras: enabledCameras,
                descriptionsEnabled: Binding(
                    get: { model.featurePreferences.enabledFeatures.contains(.visionDescriptions) },
                    set: { enabled in
                        do { try model.setFeatureEnabled(.visionDescriptions, enabled: enabled) }
                        catch { saveError = error.localizedDescription }
                    }
                ), descriptionQueue: descriptionQueue,
                errorMessage: languageSettings.localizedMessage(saveError), save: saveSettings)
        }
        .padding(.top, 8)
    }

    private var descriptionQueue: some View {
        DisclosureGroup("Recent description jobs") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    refreshDescriptionQueue()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if descriptionJobs.isEmpty {
                    Text("No description jobs.").foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(descriptionJobs) { job in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(languageSettings.localized(job.status.rawValue.capitalized))
                                        .fontWeight(.medium)
                                    Text("Attempts: \(job.attempts) · \(job.updatedAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))")
                                        .foregroundStyle(.secondary)
                                    Text(job.id.uuidString).textSelection(.enabled)
                                    if let lastError = job.lastError {
                                        Text(languageSettings.localizedMessage(lastError)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                if job.status == .failed {
                                    Button {
                                        do { try model.retryDescriptionJob(job.id) }
                                        catch { saveError = error.localizedDescription }
                                        refreshDescriptionQueue()
                                    } label: {
                                        Image(systemName: "arrow.clockwise.circle")
                                    }
                                    .help("Retry this failed description job")
                                    .accessibilityLabel("Retry failed description job \(job.id.uuidString)")
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .font(.caption)
            .padding(.vertical, 8)
        }
        .onAppear(perform: refreshDescriptionQueue)
    }

    private func refreshDescriptionQueue() {
        do { descriptionJobs = try model.recentDescriptionJobs() }
        catch { saveError = "Could not load description jobs: \(error.localizedDescription)" }
    }

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local alerts").font(.headline)
                Spacer()
                Button("Clear all", role: .destructive) { model.clearVLMAlerts() }
                    .disabled(model.vlmAlerts.isEmpty)
            }
            if model.vlmAlerts.isEmpty {
                AnalysisPanelEmptyState(title: "No alerts", icon: "bell")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.vlmAlerts) { alert in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(alert.cameraName).font(.headline)
                            Spacer()
                            Text(alert.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(alert.condition).font(.subheadline.weight(.medium))
                        Text(alert.evidence).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    private func submitQuestion() {
        if model.askVLM(question: question, cameraIDs: questionCameraIDs) { question = "" }
    }

    private func saveSettings() {
        do {
            try model.saveVLMPreferences(draft)
            try model.saveOperationsPreferences(operationsDraft)
            draft = model.vlmPreferences
            operationsDraft = model.operationsPreferences
            saveError = ""
        } catch { saveError = error.localizedDescription }
    }
}
