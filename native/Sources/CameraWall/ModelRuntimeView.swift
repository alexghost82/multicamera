import SwiftUI
import Combine

struct ModelRuntimeView: View {
    @ObservedObject var runtime: LocalModelRuntime
    let vlmBusy: Bool
    let retry: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedService: LocalModelService?
    @State private var hostMemoryUsage: HostMemoryUsage?
    private let telemetryTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var language: AppLanguage { locale.appLanguage }
    private var loading: Bool { runtime.states.values.contains(.loading) }
    private var allReady: Bool { runtime.states.values.allSatisfy { $0 == .ready } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(LocalModelService.allCases, id: \.self) { service in
                        let state = runtime.states[service] ?? .waiting
                        Button { selectedService = service } label: {
                            AIModuleCell(icon: referenceIcon(service), title: language.localized(service.title),
                                         status: stateLabel(state, service: service),
                                         isProcessing: state == .loading || (service == .qwen && vlmBusy), statusColor: color(state))

                        }
                        .buttonStyle(.plain)
                        .help(language.localized(service.title) + " · " + stateLabel(state, service: service))
                        .accessibilityLabel("\(language.localized(service.title)), \(stateLabel(state, service: service))")
                    }
                    CircularProgressView(value: nil, title: language.localized("GPU"), color: .neonYellow)
                        .help(language.localized("Unavailable"))
                    CircularProgressView(value: hostMemoryUsage.map { Double($0.percentage) / 100 },
                                         title: language.localized("RAM"), color: .neonYellow)
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(allReady ? .neonGreen : .neonYellow)
                        VStack(alignment: .leading) {
                            Text(language.localized("Systems")).lineLimit(1).fixedSize()
                            Text(language.localized(allReady ? "Ready" : "Loading")).foregroundColor(allReady ? .neonGreen : .neonYellow).lineLimit(1).fixedSize()
                        }.font(.caption).foregroundColor(.white)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Color.panelBackground).cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))

                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: retry) { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                .buttonStyle(.plain)
                .foregroundStyle(ACTATheme.textPrimary)
                .disabled(loading || allReady)
                .opacity(loading || allReady ? 0.4 : 1)
                .help(language.localized("Retry model loading"))
                .accessibilityLabel(language.localized("Retry model loading"))
        }
        .font(.system(size: ACTAType.caption, weight: .medium))
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.background)
        .onAppear { hostMemoryUsage = HostTelemetry.readMemoryUsage() }
        .onReceive(telemetryTimer) { _ in hostMemoryUsage = HostTelemetry.readMemoryUsage() }
        .popover(item: $selectedService) { service in
            let state = runtime.states[service] ?? .waiting
            VStack(alignment: .leading, spacing: 12) {
                Text(language.localized(service.title)).font(.headline)
                Label(stateLabel(state, service: service), systemImage: symbol(state))
                if service == .qwen, !runtime.qwenModelPath.isEmpty {
                    Text(URL(fileURLWithPath: runtime.qwenModelPath).lastPathComponent)
                        .font(.system(size: ACTAType.caption)).textSelection(.enabled)
                }
                if case .failed(let reason) = state {
                    ScrollView {
                        Text(language.localized(reason)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    Button(action: retry) { Label("Retry model loading", systemImage: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .padding(16)
            .frame(width: 340, alignment: .leading)
        }
    }

    private func referenceIcon(_ service: LocalModelService) -> String {
        if service == .qwen { return "cpu" }
        let title = service.title.lowercased()
        if title.contains("pose") { return "figure.walk" }
        if title.contains("seg") { return "square.stack.3d.up" }
        if title.contains("vehicle") { return "car" }
        if title.contains("reid") { return "person.crop.square" }
        return "cube.box"
    }

    private func stateLabel(_ state: LocalModelState, service: LocalModelService) -> String {
        language.localized(service == .qwen && state == .ready && vlmBusy ? "Busy" : state.label)
    }

    @ViewBuilder
    private func indicator(_ state: LocalModelState, service: LocalModelService) -> some View {
        if !reduceMotion && (state == .loading || (service == .qwen && state == .ready && vlmBusy)) {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: symbol(state))
                .foregroundStyle(color(state))
                .actaStatusGlow(color(state), enabled: state == .ready)
        }
    }

    private func symbol(_ state: LocalModelState) -> String {
        switch state {
        case .waiting: return "clock"
        case .disabled: return "pause.circle"
        case .loading: return "hourglass"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ state: LocalModelState) -> Color {
        switch state {
        case .waiting: return ACTATheme.textSecondary
        case .disabled: return ACTATheme.textMuted
        case .loading: return ACTATheme.warning
        case .ready: return ACTATheme.success
        case .failed: return ACTATheme.danger
        }
    }
}