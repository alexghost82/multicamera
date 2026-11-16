import SwiftUI

struct AnalysisPanelViewport<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12, content: content)
                .frame(width: max(0, geometry.size.width - 24), height: max(0, geometry.size.height - 24), alignment: .topLeading)
                .padding(12)
        }
    }
}

struct AnalysisPanelTabs: View {
    @Binding var selection: VLMPanelSection
    let alertCount: Int
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) { button(.ask) }
            HStack(spacing: 4) { button(.schedule); button(.alerts) }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI analysis view")
    }

    private func button(_ tab: VLMPanelSection, compact: Bool = false) -> some View {
        Button { selection = tab } label: {
            Text(tab == .alerts ? locale.appLanguage.localized("Alerts (%lld)", arguments: [alertCount]) : locale.appLanguage.localized(tab.rawValue))
                .font(.system(size: ACTAType.caption, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: 32)
                .foregroundStyle(selection == tab ? Color.white : Color.primary)
                .background(selection == tab ? ACTATheme.actionFill : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
    }
}

struct AnalysisPanelEmptyState: View {
    let title: String
    let icon: String
    var detail: String?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(locale.appLanguage.localized(title)).font(.headline).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(locale.appLanguage.localized(detail)).font(.system(size: ACTAType.caption)).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AnalysisQuestionComposer: View {
    @Binding var question: String
    let sendDisabled: Bool
    var promptLabel = "Ask about the selected camera scene…"
    var inputIdentifier = "vlm-question-input"
    var sendIdentifier = "vlm-send-question"
    let submit: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(locale.appLanguage.localized(promptLabel))
                .font(.system(size: ACTAType.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $question, axis: .vertical)
                .font(.system(size: ACTAType.body))
                .lineLimit(3...3).textFieldStyle(.roundedBorder)
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityLabel(Text(locale.appLanguage.localized(promptLabel)))
                .accessibilityIdentifier(inputIdentifier)
                .onSubmit { if !sendDisabled { submit() } }
            HStack {
                Spacer(minLength: 0)
                Button(action: submit) {
                    Label(locale.appLanguage.localized("Send question"), systemImage: "arrow.up.circle.fill")
                        .font(.system(size: ACTAType.body, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .frame(minHeight: 32)
                        .foregroundStyle(Color.white)
                        .background(sendDisabled ? ACTATheme.surfaceElevated : ACTATheme.actionFill,
                            in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(sendIdentifier)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(sendDisabled)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

struct AnalysisHistoryPage<Messages: View>: View {
    let status: String
    let busy: Bool
    @Binding var persistHistory: Bool
    @Binding var allowActions: Bool
    @Binding var expandTerms: Bool
    @Binding var question: String
    let sendDisabled: Bool
    var errorMessage = ""
    var lastMessageID: UUID? = nil
    let clear: () -> Void
    let submit: () -> Void
    @ViewBuilder let messages: () -> Messages
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Label(status, systemImage: busy ? "hourglass" : "lock.doc")
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            Button(action: clear) { Text(locale.appLanguage.localized("Clear")) }.disabled(busy)
                        }
                        OpenSettingsButton(section: .features)
                        if !errorMessage.isEmpty {
                            Text(errorMessage).font(.system(size: ACTAType.caption)).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LazyVStack(alignment: .leading, spacing: 8, content: messages)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("history-messages-bottom")
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onAppear {
                    if lastMessageID != nil { proxy.scrollTo("history-messages-bottom", anchor: .bottom) }
                }
                .onChange(of: lastMessageID) { _, id in
                    if id != nil { proxy.scrollTo("history-messages-bottom", anchor: .bottom) }
                }
            }
            AnalysisQuestionComposer(question: $question, sendDisabled: sendDisabled,
                promptLabel: "Ask about saved camera history…",
                inputIdentifier: "history-question-input", sendIdentifier: "history-send-question", submit: submit)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .toggleStyle(.checkbox)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}