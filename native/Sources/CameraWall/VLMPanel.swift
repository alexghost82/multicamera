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
    @State private var useUnifiedACTAAgent = true
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
        .font(.system(size: 13))
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
                Label(languageSettings.localizedMessage(model.vlmStatus), systemImage: model.vlmBusy || model.manualVLMBusy ? "hourglass" : "cpu")
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
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if voiceInput.isRecording {
                Label("Listening locally. Review the text before sending.", systemImage: "waveform")
                    .font(.system(size: 12))
                    .accessibilityLabel("Local dictation is recording")
                    .accessibilityValue(voiceInput.transcript)
            }
            if let errorMessage = voiceInput.errorMessage {
                Text(languageSettings.localizedMessage(errorMessage))
                    .font(.system(size: 12))
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
                    .font(.system(size: 12, weight: .semibold))
                Text(message.cameraNames.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(message.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Research Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Research Mode", selection: $useUnifiedACTAAgent) {
                    Text("ACTA Agent").tag(true)
                    Text("Track history").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .frame(height: 28)
            }
            .fixedSize(horizontal: false, vertical: true)

            if useUnifiedACTAAgent {
                actaAgentHistoryView
            } else {
                AnalysisHistoryPage(status: languageSettings.localizedMessage(model.trackResearchStatus), busy: model.trackResearchBusy,
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
                    sendDisabled: model.trackResearchBusy || historyQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
            }
        }
        .padding(.top, 8)
        .onAppear { model.reloadOperatorActions() }
    }

    private var actaAgentHistoryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(languageSettings.localizedMessage(model.actaAgentStatus), systemImage: model.actaAgentBusy ? "hourglass" : "brain.head.profile")
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(languageSettings.localizedMessage(model.actaAgentStatus))
                if !model.actaChatThreads.isEmpty {
                    Menu {
                        ForEach(model.actaChatThreads, id: \.threadID) { thread in
                            Button(thread.title.isEmpty && thread.threadID == "default"
                                   ? languageSettings.localized("Main conversation")
                                   : (thread.title.isEmpty ? thread.threadID : thread.title)) {
                                model.selectACTAChatThread(thread.threadID)
                            }
                        }
                    } label: {
                        Label(model.activeACTAThreadID == "default"
                              ? languageSettings.localized("Main conversation") : model.activeACTAThreadID,
                              systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(width: 132)
                    .help("Choose conversation")
                    .accessibilityLabel("Choose conversation")
                }
            }
            .frame(height: 40)
            .fixedSize(horizontal: false, vertical: true)

            if !model.actaThreadFocusEntries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.actaThreadFocusEntries, id: \.refID) { focus in
                            Text("\(focus.kind): \(focus.refID)")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.actaChatMessages.isEmpty {
                        AnalysisPanelEmptyState(
                            title: "Ask the Unified Multi-Memory Agent",
                            icon: "brain.head.profile",
                            detail: "Searches chronological memory frames, narrative chapters, identity dossiers, tracked objects, vehicle OCR, and operational alerts."
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    ForEach(model.actaChatMessages, id: \.messageID) { msg in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(msg.role == "user" ? "Operator" : "ACTA Agent")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(msg.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .monospacedDigit()
                            }
                            Text(msg.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let references = msg.structuredAnswer?.evidenceReferences, !references.isEmpty {
                                DisclosureGroup(languageSettings.localized("Sources (%lld)", arguments: [references.count])) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(references) { source in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(source.cameraName ?? source.cameraID ?? source.kind)
                                                    .font(.system(size: 12, weight: .medium))
                                                if let occurredAt = source.occurredAt {
                                                    Text(occurredAt).font(.system(size: 11)).foregroundStyle(.secondary)
                                                }
                                                Text(source.recordID).font(.system(size: 11, design: .monospaced))
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                                .font(.system(size: 12))
                            }
                        }
                        .padding(10)
                        .background(msg.role == "user" ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    ForEach(model.actaChatActions, id: \.actionID) { action in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(action.title.isEmpty ? "Proposed Action: \(action.actionType)" : action.title, systemImage: "bolt.shield")
                                .font(.system(size: 12, weight: .semibold))
                            Text(action.actionType)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button {
                                    model.reviewACTAChatAction(action.actionID, confirmed: true)
                                } label: {
                                    Label("Confirm", systemImage: "checkmark")
                                }
                                Button(role: .destructive) {
                                    model.reviewACTAChatAction(action.actionID, confirmed: false)
                                } label: {
                                    Label("Reject", systemImage: "xmark")
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AnalysisQuestionComposer(
                question: $historyQuestion,
                sendDisabled: model.actaAgentBusy || historyQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                promptLabel: "Ask about saved camera history…",
                inputIdentifier: "acta-question-input", sendIdentifier: "acta-send-question",
                submit: submitHistoryQuestion
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
    }

    private func operatorActionRow(_ action: CameraOperatorAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Describe tracks", systemImage: "text.viewfinder")
                .font(.system(size: 12, weight: .semibold))
            ForEach(action.trackIDs, id: \.self) { trackID in
                Text(trackID.uuidString).font(.system(size: 12)).textSelection(.enabled)
            }
            Text(action.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)).font(.system(size: 12)).foregroundStyle(.secondary)
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
                    .font(.system(size: 12, weight: .medium))
                if let reviewedAt = action.reviewedAt {
                    Text(reviewedAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(action.jobIDs, id: \.self) { jobID in
                    Text("Job: \(jobID.uuidString)").font(.system(size: 12)).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func historyMessageRow(_ message: TrackResearchMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(message.role == .operatorMessage ? "Operator" : "Local history assistant"))
                .font(.system(size: 12, weight: .semibold))
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.role == .assistant {
                if message.citedTrackIDs.isEmpty && message.citedScanIDs.isEmpty {
                    Text("No verified track citations")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(message.citedTrackIDs, id: \.self) { trackID in
                        if let record = model.recentTracks.first(where: { $0.trackID == trackID }) {
                            Label("\(record.cameraName) · \(record.label) · \(trackID.uuidString.prefix(8))",
                                  systemImage: "quote.opening")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Saved track: \(trackID.uuidString.prefix(8))", systemImage: "quote.opening")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(message.citedScanIDs, id: \.self) { scanID in
                    Label("Saved scan: \(scanID.uuidString.prefix(8))", systemImage: "quote.opening")
                        .font(.system(size: 11))
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
        let trimmed = historyQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if useUnifiedACTAAgent {
            guard !model.actaAgentBusy else { return }
            if model.askACTAAgent(question: trimmed) { historyQuestion = "" }
        } else {
            guard !model.trackResearchBusy else { return }
            if model.askTrackResearch(question: historyQuestion) { historyQuestion = "" }
        }
    }

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("ACTA ONWAY Hybrid AI & Analytics") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("AI Backend", selection: $draft.actaBackendMode) {
                        ForEach(ACTAAIBackendMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("Analytics Language", selection: $draft.actaPreferredLanguage) {
                        ForEach(ACTAPromptLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    TextField("Local vLLM URL", text: $draft.actaVLLMBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Local vLLM Model", text: $draft.actaVLLMModelName)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Spoken Tactical Briefing (18s)", isOn: $draft.actaSpokenBriefingEnabled)
                    HStack {
                        Label(
                            model.actaHealthStatus.isHealthy ? "Engine Healthy" : "Circuit Open",
                            systemImage: model.actaHealthStatus.isHealthy ? "checkmark.shield" : "exclamationmark.triangle"
                        )
                        Spacer()
                        Text(String(format: "Latency: %.0f ms · Spend: $%.2f", model.actaHealthStatus.ewmaLatencyMs, model.actaBudgetSnapshot.dailySpendUSD))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
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
            .font(.system(size: 12))
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
                                .font(.system(size: 12)).foregroundStyle(.secondary)
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
