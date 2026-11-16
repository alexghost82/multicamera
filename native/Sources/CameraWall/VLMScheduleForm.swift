import AppKit
import SwiftUI
import CameraCore

struct VLMScheduleForm<QueueContent: View>: View {
    @Binding var draft: VLMPreferences
    @Binding var operations: OperationsPreferences
    let cameras: [Camera]
    @Binding var descriptionsEnabled: Bool
    let descriptionQueue: QueueContent
    let errorMessage: String
    let save: () -> Void
    var localizationBundle: Bundle = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StableSidebarScroll {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Scheduled analysis") {
                            Toggle(isOn: $draft.scheduleEnabled) { localized("Enable scheduled analysis") }
                            counter("Per-camera interval: \(draft.intervalSeconds) seconds",
                                value: $draft.intervalSeconds, range: 15...3600, step: 15)
                            Toggle(isOn: $draft.analyzeAllEnabledCameras) { localized("All enabled cameras") }
                            if !draft.analyzeAllEnabledCameras {
                                ForEach(cameras) { camera in
                                    Toggle(isOn: Binding(
                                        get: { draft.scheduledCameraIDs.contains(camera.id) },
                                        set: { selected in
                                            if selected { draft.scheduledCameraIDs.insert(camera.id) }
                                            else { draft.scheduledCameraIDs.remove(camera.id) }
                                        }
                                    )) {
                                        Text(camera.name).lineLimit(2).truncationMode(.middle)
                                    }
                                    .help(camera.name)
                                }
                            }
                        }
                        section("Track descriptions") {
                            Toggle(isOn: $descriptionsEnabled) { localized("Automatically describe new tracks") }
                            note("Uses saved local crops and the bundled MLX model. No images are sent to an external service.")
                            if descriptionsEnabled { descriptionQueue }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                localized("Alert conditions").font(.headline)
                                Spacer(minLength: 8)
                                Button { draft.alertRules.append(VLMAlertRule(condition: "")) } label: {
                                    Image(systemName: "plus").frame(width: 24, height: 24)
                                }
                                .help("Add condition")
                                .accessibilityLabel("Add condition")
                                .disabled(draft.alertRules.count >= 20)
                            }
                            ForEach(draft.alertRules.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("", text: $draft.alertRules[index].condition, prompt: localized("Observable condition"), axis: .vertical)
                                        .lineLimit(2...5)
                                        .frame(minWidth: 0, maxWidth: .infinity)
                                    TextField("Rule cooldown seconds", value: $draft.alertRules[index].cooldownSeconds, format: .number)
                                    HStack(spacing: 8) {
                                        Toggle("Enable alert condition", isOn: $draft.alertRules[index].enabled)
                                            .labelsHidden()
                                            .accessibilityLabel("Enable alert condition")
                                        Picker("Priority", selection: $draft.alertRules[index].priority) {
                                            localized("Normal").tag(OperationsAlertReview.Priority.normal)
                                            localized("Critical").tag(OperationsAlertReview.Priority.critical)
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(minWidth: 0, maxWidth: .infinity)
                                        .accessibilityLabel("Operator priority for alert condition")
                                        Button { draft.alertRules.remove(at: index) } label: {
                                            Image(systemName: "minus.circle").frame(width: 24, height: 24)
                                        }
                                        .help("Remove condition")
                                        .accessibilityLabel("Remove alert condition")
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Label { localized("Alerts require operator review") } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.system(size: ACTAType.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.system(size: ACTAType.caption)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button(action: save) { localized("Save settings") }
                    .buttonStyle(.borderedProminent).tint(ACTATheme.actionFill)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func localized(_ key: LocalizedStringKey) -> Text {
        Text(key, bundle: localizationBundle)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            localized(title).font(.headline)
            content()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        localized(text).font(.system(size: ACTAType.caption)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func counter(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        HStack(spacing: 8) {
            localized(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text(title))
        }
    }
}

private struct StableSidebarScroll<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> SidebarScrollContainer {
        let view = SidebarScrollContainer()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SidebarScrollContainer, context: Context) {
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.update(content: AnyView(content
            .environment(\.locale, context.environment.locale)
            .environment(\.colorScheme, context.environment.colorScheme)))
    }
}

private final class SidebarScrollContainer: NSScrollView {
    private let contentState = SidebarHostedState()
    private let canvas = SidebarDocumentView()
    private lazy var host = NSHostingView(rootView: SidebarHostedRoot(state: contentState))
    private var hostHeight: NSLayoutConstraint?
    private var sizing = false
    private var pendingContent: AnyView?
    private var updateScheduled = false

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        horizontalScrollElasticity = .none
        host.sizingOptions = [.intrinsicContentSize]
        documentView = canvas
        canvas.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        let height = host.heightAnchor.constraint(equalToConstant: 1)
        hostHeight = height
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            host.topAnchor.constraint(equalTo: canvas.topAnchor),
            host.widthAnchor.constraint(equalTo: canvas.widthAnchor),
            height
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(content: AnyView) {
        pendingContent = content
        scheduleContentUpdate()
    }

    private func scheduleContentUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            let width = self.contentView.bounds.width
            if width > 0, self.contentState.width != width { self.contentState.width = width }
            let height = self.contentView.bounds.height
            if self.contentState.minimumHeight != height { self.contentState.minimumHeight = height }
            if let content = self.pendingContent {
                self.pendingContent = nil
                self.contentState.content = content
            }
            self.needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        guard !sizing, contentView.bounds.width > 0 else { return }
        sizing = true
        defer { sizing = false }
        let width = contentView.bounds.width
        if contentState.width != width || contentState.minimumHeight != contentView.bounds.height {
            scheduleContentUpdate()
        }
        host.layoutSubtreeIfNeeded()
        let height = ceil(max(contentView.bounds.height, host.intrinsicContentSize.height))
        let size = NSSize(width: width, height: height)
        if canvas.frame.size != size { canvas.setFrameSize(size) }
        if hostHeight?.constant != height { hostHeight?.constant = height }
        canvas.layoutSubtreeIfNeeded()
    }
}

private final class SidebarDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SidebarHostedState: ObservableObject {
    @Published var content = AnyView(EmptyView())
    @Published var width: CGFloat = 360
    @Published var minimumHeight: CGFloat = 0
}

private struct SidebarHostedRoot: View {
    @ObservedObject var state: SidebarHostedState

    var body: some View {
        state.content
            .frame(width: state.width, alignment: .topLeading)
            .frame(minHeight: state.minimumHeight, alignment: .topLeading)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}