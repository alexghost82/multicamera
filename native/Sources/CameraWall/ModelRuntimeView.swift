import SwiftUI
import Combine

private struct CircularUsageGauge: View {
    let title: String
    let value: Int?
    let detail: String
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(ACTATheme.border, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(value ?? 0) / 100)
                    .stroke(value == nil ? ACTATheme.textMuted : ACTATheme.secondaryAccent,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\($0)%" } ?? "--")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ACTATheme.textPrimary)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(ACTATheme.textPrimary)
                Text(detail).font(.system(size: 10)).foregroundStyle(ACTATheme.textSecondary).lineLimit(1)
            }
        }
        .frame(width: 108)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.localized("%@, %@", arguments: [title, value.map { "\($0)%" } ?? detail]))
    }
}

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
                            HStack(spacing: 7) {
                                indicator(state, service: service)
                                    .frame(width: 16, height: 16)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.localized(service.title))
                                        .foregroundStyle(ACTATheme.textPrimary)
                                    Text(stateLabel(state, service: service))
                                        .font(.system(size: 11))
                                        .foregroundStyle(ACTATheme.textSecondary)
                                }
                            }
                            .frame(width: 126)
                            .frame(minHeight: 40, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(language.localized("Model details"))
                        .accessibilityLabel("\(language.localized(service.title)), \(stateLabel(state, service: service))")
                    }
                    CircularUsageGauge(title: language.localized("RAM"), value: hostMemoryUsage?.percentage,
                                       detail: language.localized("Host"), language: language)
                    CircularUsageGauge(title: language.localized("GPU"), value: nil,
                                       detail: language.localized("Unavailable"), language: language)
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
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.sidebar)
        .onAppear { hostMemoryUsage = HostTelemetry.readMemoryUsage() }
        .onReceive(telemetryTimer) { _ in hostMemoryUsage = HostTelemetry.readMemoryUsage() }
        .popover(item: $selectedService) { service in
            let state = runtime.states[service] ?? .waiting
            VStack(alignment: .leading, spacing: 12) {
                Text(language.localized(service.title)).font(.headline)
                Label(stateLabel(state, service: service), systemImage: symbol(state))
                if service == .qwen, !runtime.qwenModelPath.isEmpty {
                    Text(URL(fileURLWithPath: runtime.qwenModelPath).lastPathComponent)
                        .font(.caption).textSelection(.enabled)
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
        }
    }

    private func symbol(_ state: LocalModelState) -> String {
        switch state {
        case .waiting: return "clock"
        case .loading: return "hourglass"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ state: LocalModelState) -> Color {
        switch state {
        case .waiting: return ACTATheme.textSecondary
        case .loading: return ACTATheme.warning
        case .ready: return ACTATheme.success
        case .failed: return ACTATheme.danger
        }
    }
}