import AppKit
import SwiftUI
import CameraCore

struct LocalShowcaseView: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var errorMessage = ""

    private var enabled: Bool { model.featurePreferences.enabledFeatures.contains(.publicShowcase) }
    private var sharedCameras: [Camera] { model.config.cameras.filter { $0.enabled && $0.aiChatEnabled } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Showcase")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Loopback only · ephemeral token · no frame storage")
                        .font(.system(size: 12))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Toggle("Enable local showcase", isOn: Binding(
                    get: { enabled },
                    set: { value in
                        do { try model.setFeatureEnabled(.publicShowcase, enabled: value) }
                        catch { errorMessage = "Could not save local showcase setting" }
                    }
                ))
                .toggleStyle(.switch)
            }

            Text("The server binds to 127.0.0.1 and is not reachable from other devices or networks. The link contains a temporary bearer token. Only enabled cameras with AI chat enabled are exposed.")
                .font(.system(size: 12))
                .foregroundStyle(ACTATheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if enabled {
                ForEach(model.config.cameras.filter(\.enabled)) { camera in
                    Toggle(camera.name, isOn: Binding(
                        get: { camera.aiChatEnabled },
                        set: { model.setAIChatEnabled(for: camera.id, enabled: $0) }
                    ))
                    .toggleStyle(.switch)
                }

                HStack(spacing: 10) {
                    Button {
                        do { try model.startLocalShowcase() }
                        catch { errorMessage = "Local showcase could not start" }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(model.localShowcaseURL != nil || sharedCameras.isEmpty || !model.running)

                    Button(role: .destructive) {
                        model.stopLocalShowcase()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(model.localShowcaseURL == nil && model.localShowcaseStatus == "Stopped")

                    Text(locale.appLanguage.localizedMessage(model.localShowcaseStatus))
                        .font(.system(size: 12))
                        .foregroundStyle(ACTATheme.textSecondary)
                    Spacer()
                }

                if let url = model.localShowcaseURL {
                    HStack {
                        Link(destination: url) {
                            Label("Open Local Showcase", systemImage: "safari")
                        }
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                }
            }

            if !errorMessage.isEmpty {
                Text(locale.appLanguage.localizedMessage(errorMessage)).font(.system(size: 12)).foregroundStyle(ACTATheme.danger)
            }
            Spacer()
        }
        .padding(20)
        .onDisappear { model.stopLocalShowcase() }
    }
}