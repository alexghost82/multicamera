import AppKit
import SwiftUI
import CameraCore

struct DiagnosticsSettingsEditor: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var workerJSON = ""
    @State private var workerURL = WorkerNodeConfigurationStore.defaultURL
    @State private var error = ""
    @State private var saved = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Diagnostics") {
                    HStack {
                        Button("Export diagnostics") {
                            ACTAOperationalExportUI.start(ACTAOperationalExports.diagnostics(model: model))
                        }
                        Button("Check now") { model.runLocalOperationsMonitorCheck() }
                        Button("Retry model loading") { model.prepareModels() }
                    }
                    Text(model.localAnalyticsEngine.stateReason).textSelection(.enabled)
                }
                GroupBox(locale.appLanguage.localized("Mission reports")) {
                    Button(locale.appLanguage.localized("Export reviewed mission PDF")) {
                        ACTAOperationalExportUI.start(ACTAOperationalExports.missionPDF(model: model))
                    }
                    .disabled(model.cameraMissionRuns.isEmpty)
                    Text(verbatim: locale.appLanguage.localized("Use this reviewed export. The older PDF button in the missions panel may replace an existing file without this review."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GroupBox("Worker node configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Worker role, addresses, ports, camera assignments, model path and trusted peers. Changes apply on the next worker launch.").foregroundStyle(.secondary)
                        HStack {
                            Text(workerURL.lastPathComponent)
                            Button("Open configuration") { open() }
                            Button("Reload") { load() }
                        }
                        TextEditor(text: $workerJSON).font(.system(.body, design: .monospaced)).frame(minHeight: 300)
                            .accessibilityLabel("Worker configuration JSON")
                        SettingsSaveBar(error: error, saved: saved) {
                            do {
                                let configuration = try JSONDecoder().decode(WorkerNodeConfiguration.self, from: Data(workerJSON.utf8))
                                try WorkerNodeConfigurationStore.save(configuration, to: workerURL)
                                error = ""; saved = true
                            } catch { self.error = error.localizedDescription; saved = false }
                        }
                    }.padding(8)
                }
            }.padding(16)
        }.onAppear { if FileManager.default.fileExists(atPath: workerURL.path) { load() } }
    }
    private func open() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { workerURL = url; load() }
    }
    private func load() {
        do {
            _ = try WorkerNodeConfigurationStore.load(from: workerURL)
            workerJSON = try String(contentsOf: workerURL, encoding: .utf8); error = ""; saved = false
        } catch { self.error = error.localizedDescription }
    }
}
