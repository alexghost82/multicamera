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
    @ObservedObject var windowState: ACTACanvasFilterState
    @ObservedObject private var voiceInput: LocalVoiceInput
    @ObservedObject private var voiceOutput = LocalVoiceOutput.shared
    @State private var draft = VLMPreferences()
    @State private var operationsDraft = OperationsPreferences()
    @State private var voiceDraft: LocalVoiceDraft?
    @State private var voiceDraftNotice: String?
    @State private var voiceLanguage = LocalVoiceLanguage.interface
    @State private var questionUsesVoice = false
    @State private var speakVoiceAnswers = true
    @State private var dictationStartedAt: Date?
    @State private var lastDictationDuration: TimeInterval?
    @State private var bargeIn = LocalVoiceBargeInCoordinator()
    @State private var saveError = ""
    @State private var descriptionJobs: [CameraFeatureJob] = []
    @State private var alertClearConfirmation: VLMAlertClearConfirmation?
    @State private var showAlertClearConfirmation = false

    init(model: WallModel, languageSettings: LanguageSettings, windowState: ACTACanvasFilterState) {
        self.model = model
        self.languageSettings = languageSettings
        self.windowState = windowState
        self.voiceInput = windowState.analysisVoiceInput
    }

    private var enabledCameras: [Camera] { model.config.cameras.filter(\.enabled) }

    var body: some View {
        AnalysisPanelViewport {
            AnalysisPanelTabs(selection: Binding(
                get: { windowState.analysisSection },
                set: { windowState.selectAnalysisSectionFromGUI($0) }
            ), alertCount: model.vlmAlerts.count)

            Group {
                switch windowState.analysisSection {
                case .ask:
                    actaAgentHistoryView(voiceOwner: windowState.analysisChatLifecycle)
                        .id(windowState.analysisChatLifecycle)
                case .schedule: scheduleTab
                case .alerts: alertsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: ACTAType.body))
        .onAppear {
            voiceLanguage = model.navigationBridge.voiceDictationLanguage
        }
        .onChange(of: voiceLanguage) { _, newValue in
            if model.navigationBridge.voiceDictationLanguage != newValue {
                model.navigationBridge.voiceDictationLanguage = newValue
            }
        }
        .onReceive(model.navigationBridge.$voiceDictationLanguage) { target in
            if voiceLanguage != target {
                voiceLanguage = target
            }
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

    private func actaAgentHistoryView(voiceOwner: UUID) -> some View {
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
                                if msg.role == "assistant" {
                                    Button {
                                        speakAnswer(msg.text, owner: voiceOwner, interruptActiveSpeech: true)
                                    } label: { Image(systemName: "speaker.wave.2") }
                                    .disabled(voiceInput.isBusy)
                                    .help("Read answer aloud")
                                    .accessibilityLabel("Read answer aloud")
                                }
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
                    if let preview = model.actaAnswerPreview {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Draft response — unverified and may change")
                                .font(.system(size: ACTAType.caption, weight: .semibold))
                            Text(preview)
                                .font(.system(size: ACTAType.body))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(model.actaBrokerReviews) { controller in
                        ACTABrokerReviewView(controller: controller, voiceInput: voiceInput,
                            voiceAllowed: model.featurePreferences.allowVoiceInput && !voiceOutput.isBusy,
                            voiceLocaleIdentifier: voiceLanguage.localeIdentifier(interfaceLocale: languageSettings.locale),
                            onResult: { result, _ in
                                model.finishACTABrokerReview(controller, result: result)
                            },
                            onOutcome: { _, voiceConfirmed, outcome in
                                if voiceConfirmed, speakVoiceAnswers, model.featurePreferences.allowVoiceInput,
                                   windowState.analysisSection == .ask, windowState.analysisChatLifecycle == voiceOwner,
                                   model.activeACTAThreadID == controller.review.threadID {
                                    let locale = voiceLanguage.localeIdentifier(interfaceLocale: languageSettings.locale)
                                    let status = LocalVoiceReviewStatus.message(
                                        outcome: outcome,
                                        operationID: controller.review.operationID,
                                        localeIdentifier: locale
                                    )
                                    speakAnswer(status, owner: voiceOwner, interruptActiveSpeech: true)
                                }
                            })
                        .padding(8)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !model.actaChatActions.isEmpty {
                        Text("Historical proposals cannot be reviewed safely. Create a new request.")
                            .font(.system(size: ACTAType.caption))
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
            HStack(spacing: 8) {
                let perms = LocalVoiceStatusDescriptor.currentSystemPermissions()
                let descriptor = LocalVoiceStatusDescriptor.resolve(
                    allowVoiceInput: model.featurePreferences.allowVoiceInput,
                    isRecording: voiceInput.isRecording,
                    isFinalizing: voiceInput.isFinalizing,
                    isSpeaking: voiceOutput.isBusy,
                    microphoneAuthorized: perms.microphoneNotDenied,
                    speechAuthorized: perms.speechNotDenied
                )
                Label(languageSettings.localized(descriptor.localizationKey), systemImage: descriptor.systemImage)
                    .font(.system(size: ACTAType.metadata))
                    .foregroundStyle(
                        descriptor == .microphoneDenied || descriptor == .speechDenied
                            ? ACTATheme.danger
                            : (descriptor == .listening || descriptor == .speaking ? Color.accentColor : .secondary)
                    )
                Spacer()
                if voiceOutput.isOwned(by: voiceOwner) {
                    Button("Stop speaking") {
                        bargeIn.cancelPending()
                        voiceOutput.stop(owner: voiceOwner)
                    }
                    .font(.system(size: ACTAType.caption))
                }
            }
            Toggle("Speak voice answers automatically", isOn: $speakVoiceAnswers)
                .font(.system(size: ACTAType.caption))
            HStack(alignment: .bottom, spacing: 8) {
            Button {
                if voiceInput.isOwned(by: voiceOwner) {
                    if let started = dictationStartedAt {
                        lastDictationDuration = Date().timeIntervalSince(started)
                    }
                    dictationStartedAt = nil
                    voiceInput.finishAndWaitForFinal(owner: voiceOwner)
                } else if windowState.analysisSection == .ask && model.featurePreferences.allowVoiceInput {
                    let locale = voiceLanguage.localeIdentifier(interfaceLocale: languageSettings.locale)
                    bargeIn.bargeInToDictation(
                        voiceOutput: voiceOutput,
                        voiceInput: voiceInput,
                        localeIdentifier: locale,
                        owner: voiceOwner,
                        onBeforeStart: {
                            voiceDraftNotice = nil
                            dictationStartedAt = Date()
                            lastDictationDuration = nil
                            voiceDraft = LocalVoiceDraft(originalText: model.actaQuestionDraft, originallyUsedVoice: questionUsesVoice)
                        }
                    )
                }
            } label: { Image(systemName: voiceInput.isOwned(by: voiceOwner) ? "stop.fill" : "mic") }
            .disabled(voiceInput.isFinalizing || (voiceInput.isBusy && !voiceInput.isOwned(by: voiceOwner)) ||
                      ((windowState.analysisSection != .ask || !model.featurePreferences.allowVoiceInput) && !voiceInput.isOwned(by: voiceOwner)))
            .help(voiceOutput.isBusy ? "Interrupt speech and start local dictation" :
                  (voiceInput.isOwned(by: voiceOwner) ? "Stop local dictation" : "Start local dictation"))
            .accessibilityLabel(voiceOutput.isBusy ? "Interrupt speech and start local dictation" :
                                (voiceInput.isOwned(by: voiceOwner) ? "Stop local dictation" : "Start local dictation"))
            Menu {
                Picker("Dictation language", selection: $voiceLanguage) {
                    ForEach(LocalVoiceLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
            } label: {
                Image(systemName: "character.bubble")
            }
            .disabled(voiceInput.isBusy || !model.featurePreferences.allowVoiceInput)
            .help("Dictation language")
            .accessibilityLabel("Dictation language")
            if voiceInput.isOwned(by: voiceOwner) {
                Button {
                    voiceInput.cancel(owner: voiceOwner)
                    if let voiceDraft {
                        if voiceDraft.canRestore(model.actaQuestionDraft) {
                            model.actaQuestionDraft = voiceDraft.originalText
                            questionUsesVoice = voiceDraft.originallyUsedVoice
                        } else {
                            voiceDraftNotice = "Dictation cancelled; edited text was kept."
                        }
                    }
                    voiceDraft = nil
                } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Cancel dictation")
                .accessibilityLabel("Cancel dictation")
            }
            AnalysisQuestionComposer(
                question: $model.actaQuestionDraft,
                sendDisabled: voiceInput.isBusy || model.actaAgentBusy || model.actaQuestionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                promptLabel: "Ask about live video or history of all cameras…",
                inputIdentifier: "acta-question-input", sendIdentifier: "acta-send-question",
                submit: submitHistoryQuestion
            )
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            }
            if let voiceError = voiceInput.errorMessage { Text(languageSettings.localizedMessage(voiceError)).foregroundStyle(ACTATheme.danger) }
            if let voiceError = voiceOutput.errorMessage { Text(languageSettings.localizedMessage(voiceError)).foregroundStyle(ACTATheme.danger) }
            if voiceInput.isFinalizing { Text("Finalizing dictation…").foregroundStyle(.secondary) }
            if let voiceDraftNotice { Text(languageSettings.localizedMessage(voiceDraftNotice)).foregroundStyle(.secondary) }
        }
        .onChange(of: voiceInput.transcript) { _, text in
            if voiceInput.transcriptOwner == voiceOwner, let draft = voiceDraft {
                if draft.canRestore(model.actaQuestionDraft) {
                    if !text.isEmpty { questionUsesVoice = true }
                    if let rendered = voiceDraft?.render(text) { model.actaQuestionDraft = rendered }
                } else {
                    voiceDraftNotice = "Dictation update skipped; edited text was kept."
                }
            }
        }
        .onChange(of: model.actaVoiceAnswer) { _, answer in
            guard speakVoiceAnswers, model.featurePreferences.allowVoiceInput,
                  let answer, answer.owner == voiceOwner,
                  answer.threadID == model.activeACTAThreadID else { return }
            speakAnswer(answer.text, owner: voiceOwner)
        }
        .onChange(of: model.activeACTAThreadID) { _, _ in
            bargeIn.cancelPending()
            voiceOutput.stop(owner: voiceOwner)
        }
        .onDisappear {
            bargeIn.cancelPending()
            dictationStartedAt = nil
            voiceInput.stop(owner: voiceOwner)
            voiceOutput.stop(owner: voiceOwner)
        }
    }

    private func speakAnswer(_ text: String, owner: UUID, interruptActiveSpeech: Bool = false) {
        guard !voiceInput.isAttemptActive, !model.canvasFilterBridge.hasActiveVoiceInput else {
            voiceDraftNotice = "Stop dictation or speech before speaking."
            return
        }
        let sanitized = LocalVoiceSpeechSanitizer.sanitize(text)
        guard !sanitized.isEmpty else { return }
        voiceDraftNotice = nil
        let locale = voiceLanguage.localeIdentifier(interfaceLocale: languageSettings.locale)
        if interruptActiveSpeech {
            voiceOutput.interruptAndSpeak(sanitized, localeIdentifier: locale, owner: owner)
        } else {
            guard !voiceOutput.isAttemptActive else {
                voiceDraftNotice = "Stop dictation or speech before speaking."
                return
            }
            voiceOutput.speak(sanitized, localeIdentifier: locale, owner: owner)
        }
    }

    private func submitHistoryQuestion() {
        guard !voiceInput.isBusy else { return }
        let rawDraft = model.actaQuestionDraft
        let questionToSend: String
        if questionUsesVoice {
            switch LocalVoiceTranscriptGuard.evaluate(rawDraft, durationSeconds: lastDictationDuration) {
            case .accepted(let cleaned):
                questionToSend = cleaned
            case .rejectedAccidentalActivation:
                voiceDraftNotice = "Voice input was too brief and ignored as an accidental tap."
                return
            case .rejectedNoise:
                voiceDraftNotice = "Only background noise was heard; repeat your request clearly."
                return
            case .rejectedEmpty:
                return
            }
        } else {
            let trimmed = rawDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            questionToSend = trimmed
        }
        if model.askACTAAgent(question: questionToSend, input: questionUsesVoice ? .voice : .chat,
                              voiceAnswerOwner: questionUsesVoice ? windowState.analysisChatLifecycle : nil) {
            bargeIn.cancelPending()
            voiceOutput.stop(owner: windowState.analysisChatLifecycle)
            model.actaQuestionDraft = ""
            questionUsesVoice = false
            voiceDraft = nil
            lastDictationDuration = nil
        }
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
        .onAppear {
            if windowState.analysisScheduleRefreshOnAppear { refreshDescriptionQueue() }
            windowState.analysisScheduleRefreshOnAppear = true
        }
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
                Button("Clear all", role: .destructive) {
                    do {
                        guard let confirmation = try model.prepareVLMAlertsClear() else {
                            let message = "Alerts changed or could not be verified. Review them again before clearing."
                            model.notice = message
                            model.error = message
                            return
                        }
                        alertClearConfirmation = confirmation
                        showAlertClearConfirmation = true
                    } catch {
                        let message = "Alerts changed or could not be verified. Review them again before clearing."
                        model.notice = message
                        model.error = message
                    }
                }
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
        .alert(languageSettings.localized("Clear all local alerts?"), isPresented: $showAlertClearConfirmation) {
            Button(languageSettings.localized("Cancel"), role: .cancel) { alertClearConfirmation = nil }
            Button(languageSettings.localized("Clear all"), role: .destructive) {
                if let confirmation = alertClearConfirmation {
                    model.clearVLMAlerts(confirmed: confirmation)
                }
                alertClearConfirmation = nil
            }
        } message: {
            Text(languageSettings.localized("This clears the listed alerts and their clips. When operational alerts are enabled, it also clears all local reviews, acknowledgements and review history. A failure may leave a partial result."))
        }
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
