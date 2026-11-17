import SwiftUI
import CameraCore

enum VLMPanelSection: String, CaseIterable, Identifiable {
    case ask = "Chat"
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
    @State private var questionBeforeVoice = ""
    @State private var saveError = ""
    @State private var descriptionJobs: [CameraFeatureJob] = []
    @StateObject private var voiceInput = LocalVoiceInput()

    private var enabledCameras: [Camera] { model.config.cameras.filter(\.enabled) }

    var body: some View {
        AnalysisPanelViewport {
            AnalysisPanelTabs(selection: $activeSection, alertCount: model.vlmAlerts.count)

            Group {
                switch activeSection {
                case .ask: actaAgentHistoryView
                case .schedule: scheduleTab
                case .alerts: alertsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: ACTAType.body))
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            draft = model.vlmPreferences
            operationsDraft = model.operationsPreferences
        }
    }

    private var actaAgentHistoryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(languageSettings.localizedMessage(model.actaAgentStatus), systemImage: model.actaAgentBusy ? "hourglass" : "brain.head.profile")
                    .font(.system(size: ACTAType.caption))
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
                            .font(.system(size: ACTAType.caption))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(width: 160)
                    .help("Choose conversation")
                    .accessibilityLabel("Choose conversation")
                }
            }
            .frame(height: 40)
            .fixedSize(horizontal: false, vertical: true)

            Button("New conversation", systemImage: "plus.bubble") { model.selectACTAChatThread(UUID().uuidString) }
            if !model.actaThreadFocusEntries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.actaThreadFocusEntries, id: \.refID) { focus in
                            Text("\(focus.kind): \(focus.refID)")
                                .font(.system(size: ACTAType.metadata))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                }
            }

            ScrollViewReader { proxy in
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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(msg.role == "user" ? "Operator" : "ACTA Agent")
                                    .font(.system(size: ACTAType.caption, weight: .semibold))
                                Spacer()
                                Text(msg.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                                    .font(.system(size: ACTAType.metadata)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .monospacedDigit()
                            }
                            Text(msg.text)
                                .font(.system(size: ACTAType.body))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let references = msg.structuredAnswer?.evidenceReferences, !references.isEmpty {
                                DisclosureGroup(languageSettings.localized("Sources (%lld)", arguments: [references.count])) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(references) { source in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(source.cameraName ?? source.cameraID ?? source.kind)
                                                    .font(.system(size: ACTAType.caption, weight: .medium))
                                                if let occurredAt = source.occurredAt {
                                                    Text(occurredAt).font(.system(size: ACTAType.metadata)).foregroundStyle(.secondary)
                                                }
                                                Text(source.recordID).font(.system(size: ACTAType.metadata, design: .monospaced))
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                                .font(.system(size: ACTAType.caption))
                            }
                        }
                        .padding(10)
                        .background(msg.role == "user" ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .id(msg.messageID)
                    }
                    ForEach(model.actaChatActions, id: \.actionID) { action in
                        let requiresTokenReview = action.actionID.hasPrefix("CONFIRM-")
                        VStack(alignment: .leading, spacing: 8) {
                            Label(requiresTokenReview ? languageSettings.localized("Review proposed action") : (action.title.isEmpty ? "Proposed Action: \(action.actionType)" : action.title), systemImage: "bolt.shield")
                                .font(.system(size: ACTAType.caption, weight: .semibold))
                            Text(action.actionType)
                                .font(.system(size: ACTAType.metadata))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            DisclosureGroup {
                                let values = actaAuditArguments(action.parameters)
                                ForEach(values.keys.sorted(), id: \.self) { key in
                                    Text(verbatim: "\(key): \(values[key] ?? "")")
                                        .font(.system(size: ACTAType.caption))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } label: {
                                Text("Action details")
                            }
                            .accessibilityIdentifier("acta-action-details-\(action.actionID)")
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
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            .onChange(of: model.actaChatMessages.last?.messageID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear { if let id = model.actaChatMessages.last?.messageID { proxy.scrollTo(id, anchor: .bottom) } }
            }
            if model.actaAgentBusy {
                Button("Cancel request") { model.cancelACTAAgent() }
            }
            HStack(alignment: .bottom, spacing: 8) {
            Button {
                if voiceInput.isRecording { voiceInput.stop() }
                else if model.featurePreferences.allowVoiceInput {
                    questionBeforeVoice = model.actaQuestionDraft
                    Task { await voiceInput.start(localeIdentifier: languageSettings.locale.identifier) }
                }
            } label: { Image(systemName: voiceInput.isRecording ? "stop.fill" : "mic") }
            .disabled(!model.featurePreferences.allowVoiceInput && !voiceInput.isRecording)
            .help(voiceInput.isRecording ? "Stop local dictation" : "Start local dictation")
            AnalysisQuestionComposer(
                question: $model.actaQuestionDraft,
                sendDisabled: model.actaAgentBusy || model.actaQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                promptLabel: "Ask about live video or history of all cameras…",
                inputIdentifier: "acta-question-input", sendIdentifier: "acta-send-question",
                submit: submitHistoryQuestion
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            }
            if let voiceError = voiceInput.errorMessage { Text(languageSettings.localizedMessage(voiceError)).foregroundStyle(ACTATheme.danger) }
        }
        .onChange(of: voiceInput.transcript) { _, text in
            if voiceInput.isRecording { model.actaQuestionDraft = [questionBeforeVoice, text].filter { !$0.isEmpty }.joined(separator: " ") }
        }
        .onDisappear { voiceInput.stop() }
    }

    private func submitHistoryQuestion() {
        let trimmed = model.actaQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if model.askACTAAgent(question: trimmed) { model.actaQuestionDraft = "" }
    }

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            OpenSettingsButton(section: .schedules)
            Text("Scheduled analysis settings are in Settings.").foregroundStyle(.secondary)
            descriptionQueue
            Spacer()
        }.padding(16)
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
            .font(.system(size: ACTAType.caption))
            .padding(.vertical, 8)
        }
        .onAppear(perform: refreshDescriptionQueue)
    }

    private func refreshDescriptionQueue() {
        do { descriptionJobs = try model.recentDescriptionJobs() }
        catch { saveError = "Could not load description jobs: \(error.localizedDescription)" }
    }

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(alert.cameraName).font(.headline)
                            Spacer()
                            Text(alert.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                                .font(.system(size: ACTAType.caption)).foregroundStyle(.secondary)
                        }
                        Text(alert.condition).font(.system(size: ACTAType.caption, weight: .medium))
                        Text(alert.evidence).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .padding(.top, 8)
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
