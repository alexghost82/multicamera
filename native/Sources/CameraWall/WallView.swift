import SwiftUI
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import CameraCore
import UniformTypeIdentifiers

struct WallView: View {
    @ObservedObject var model: WallModel
    @ObservedObject var languageSettings: LanguageSettings
    @State private var editor: Camera?
    @State private var showLocalCamera = false
    @State private var showScreenCapture = false
    @State private var showSettings = false
    @State private var showCameras = false
    @State private var showVideoFileImporter = false
    @State private var removeCamera: Camera?

    var body: some View {
        ACTASecurityCenterView(
            model: model,
            languageSettings: languageSettings,
            addNetworkCamera: { editor = Camera(name: languageSettings.localized("Camera %@", arguments: [String(model.config.cameras.count + 1)]), substream: "") },
            addLocalCamera: { showLocalCamera = true },
            addScreenCapture: { showScreenCapture = true },
            addVideoFile: { showVideoFileImporter = true },
            importSources: { model.importSources() },
            showCameraManager: { showCameras = true },
            exportDiagnostics: { model.exportDiagnostics() },
            resetLayout: { model.resetLayout() },
            showSettings: { showSettings = true },
            editCamera: { editor = $0 },
            removeCamera: { removeCamera = $0 }
        )
        .sheet(item: $editor) { camera in
            if camera.fileURL != nil { VideoFileCameraEditor(model: model, camera: camera) }
            else if camera.screenDisplayID != nil { ScreenCaptureCameraEditor(model: model, camera: camera) }
            else if camera.localDeviceID != nil { LocalCameraEditor(model: model, original: camera) }
            else { CameraEditor(model: model, camera: camera) }
        }
        .sheet(isPresented: $showLocalCamera) { LocalCameraEditor(model: model, original: nil) }
        .sheet(isPresented: $showScreenCapture) { ScreenCaptureCameraEditor(model: model, camera: nil) }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $showCameras) { CameraManager(model: model) }
        .fileImporter(
            isPresented: $showVideoFileImporter,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.addVideoFile(url) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.error = "Cannot open video file. \(error.localizedDescription)"
                }
            }
        }
        .alert("CameraWall", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(languageSettings.localizedMessage(model.error ?? "")) }
        .confirmationDialog("Remove camera?", isPresented: Binding(get: { removeCamera != nil }, set: { if !$0 { removeCamera = nil } })) {
            Button("Remove", role: .destructive) { if let camera = removeCamera { model.remove(camera) }; removeCamera = nil }
        }
        .environment(\.locale, languageSettings.locale)
    }
}

struct CameraManager: View {
    @ObservedObject var model: WallModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var editor: Camera?
    private var appLanguage: AppLanguage { locale.appLanguage }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cameras").font(.title2)
            List(model.config.cameras) { camera in
                HStack {
                    Image(systemName: camera.enabled ? "video" : "video.slash")
                    Text(camera.name).lineLimit(1)
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { camera.enabled }, set: { model.setEnabled(camera, enabled: $0) }))
                        .toggleStyle(.switch).fixedSize().accessibilityLabel(appLanguage.localized("Enable %@", arguments: [camera.name]))
                    Button { editor = camera } label: { Image(systemName: "pencil") }
                        .help(appLanguage.localized("Edit camera")).accessibilityLabel(appLanguage.localized("Edit %@", arguments: [camera.name]))
                }.padding(.vertical, 4)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 600, height: 480)
        .sheet(item: $editor) { camera in
            if camera.fileURL != nil { VideoFileCameraEditor(model: model, camera: camera) }
            else if camera.screenDisplayID != nil { ScreenCaptureCameraEditor(model: model, camera: camera) }
            else if camera.localDeviceID != nil { LocalCameraEditor(model: model, original: camera) }
            else { CameraEditor(model: model, camera: camera) }
        }
    }
}

struct ScreenCaptureCameraEditor: View {
    @ObservedObject var model: WallModel
    let camera: Camera?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var displays: [SCDisplay] = []
    @State private var selectedDisplayID: UInt32?
    @State private var name: String
    @State private var error = ""

    init(model: WallModel, camera: Camera?) {
        self.model = model
        self.camera = camera
        _name = State(initialValue: camera?.name ?? AppLanguage.current.localized("Screen"))
        _selectedDisplayID = State(initialValue: camera?.screenDisplayID.flatMap(UInt32.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen capture source").font(.title2)
            Form {
                TextField("Name", text: $name)
                Picker("Display", selection: $selectedDisplayID) {
                    ForEach(displays, id: \.displayID) { display in
                        Text("Display \(display.displayID) · \(display.width)×\(display.height)")
                            .tag(Optional(display.displayID))
                    }
                }
                .accessibilityLabel("Screen display to capture")
            }
            Text("Capture starts only when this source is enabled and connected. CameraWall requests Screen Recording permission when you add the source.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty { Text(locale.appLanguage.localizedMessage(error)).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Refresh displays") { Task { await loadDisplays() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(camera == nil ? "Add display" : "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedDisplayID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await loadDisplays() }
    }

    @MainActor
    private func loadDisplays() async {
        do {
            displays = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).displays
            if selectedDisplayID == nil { selectedDisplayID = displays.first?.displayID }
            error = displays.isEmpty ? "No shareable displays are available." : ""
        } catch {
            self.error = "Allow screen access in System Settings, then refresh displays."
        }
    }

    private func save() {
        guard let selectedDisplayID else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            error = "Grant Screen Recording permission, then press Add again."
            return
        }
        var updated = camera ?? Camera(name: name, substream: "", screenDisplayID: String(selectedDisplayID))
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.substream = ""
        updated.mainstream = nil
        updated.localDeviceID = nil
        updated.screenDisplayID = String(selectedDisplayID)
        do {
            try model.saveScreenCamera(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct VideoFileCameraEditor: View {
    @ObservedObject var model: WallModel
    let camera: Camera
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var name: String
    @State private var error = ""

    init(model: WallModel, camera: Camera) {
        self.model = model
        self.camera = camera
        _name = State(initialValue: camera.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Video file").font(.title2)
            Form {
                TextField("Name", text: $name)
                LabeledContent("File", value: camera.fileURL?.lastPathComponent ?? "")
            }
            if !error.isEmpty { Text(locale.appLanguage.localizedMessage(error)).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = camera
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        try model.saveVideoFileCamera(updated)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct CameraTile: View {
    let camera: Camera
    @ObservedObject var tile: TileState
    let expanded: Bool
    let expand: () -> Void
    let edit: () -> Void
    let reconnect: () -> Void
    let snapshot: () -> Void
    let remove: () -> Void
    var activate: () -> Void = {}
    var isFavorite = false
    var toggleFavorite: () -> Void = {}
    var toggleYOLO: (Bool) -> Void = { _ in }
    var toggleAIChat: (Bool) -> Void = { _ in }
    @Environment(\.locale) private var locale

    private var appLanguage: AppLanguage { locale.appLanguage }

    var body: some View {
        ZStack {
            VideoView(frame: tile.frame, stale: tile.stale)
            if !tile.stale && !tile.objects.isEmpty {
                DetectionOverlay(objects: tile.objects, imageSize: tile.detectionImageSize)
            }
            if tile.stale {
                VStack(spacing: 4) {
                    Image(systemName: "wifi.slash").font(.title3)
                    Text(tile.frame.pixel == nil ? appLanguage.localizedMessage(tile.frame.message) : appLanguage.localized("Stale frame"))
                        .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                }
                .foregroundStyle(ACTATheme.textSecondary)
                .padding(4)
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(tile.stale ? ACTATheme.textMuted : ACTATheme.success).frame(width: 9, height: 9)
                    Text(camera.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ACTATheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isFavorite ? ACTATheme.warning : ACTATheme.textPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(appLanguage.localized(isFavorite ? "Remove from favorites" : "Add to favorites"))
                    .accessibilityLabel(appLanguage.localized(isFavorite ? "Remove %@ from favorites" : "Add %@ to favorites", arguments: [camera.name]))
                    Menu {
                        Button("Edit", systemImage: "pencil", action: edit)
                        Button(LocalizedStringKey(expanded ? "All cameras" : "Expand"), systemImage: "arrow.up.left.and.arrow.down.right", action: expand)
                        Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
                        Button("Snapshot", systemImage: "camera", action: snapshot).disabled(tile.stale)
                        Divider()
                        Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    } label: {
                        Image(systemName: "ellipsis")
                            .rotationEffect(.degrees(90))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ACTATheme.textPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(appLanguage.localized("Actions for %@", arguments: [camera.name]))
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if tile.stale {
                        Label("OFFLINE", systemImage: "wifi.slash")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ACTATheme.textPrimary)
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        Text(Date.now, style: .time)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                        Label("LIVE", systemImage: "circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ACTATheme.textPrimary)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(ACTATheme.danger, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Toggle("YOLO", isOn: Binding(get: { camera.yoloEnabled }, set: toggleYOLO))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 10, weight: .medium))
                        .help(appLanguage.localized("Run YOLO26 on %@", arguments: [camera.name]))
                        .accessibilityLabel(appLanguage.localized("Run YOLO26 on %@", arguments: [camera.name]))
                    Toggle("AI", isOn: Binding(get: { camera.aiChatEnabled }, set: toggleAIChat))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 10, weight: .medium))
                        .help(appLanguage.localized("Include %@ in AI chat", arguments: [camera.name]))
                        .accessibilityLabel(appLanguage.localized("Include %@ in AI chat", arguments: [camera.name]))
                    Spacer()
                    Button(action: expand) {
                        Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ACTATheme.textPrimary)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(appLanguage.localized(expanded ? "Return to all cameras" : "Expand camera"))
                    .accessibilityLabel(expanded ? appLanguage.localized("Return to all cameras") : appLanguage.localized("Expand %@", arguments: [camera.name]))
                }
            }
            .padding(7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: expand)
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(camera.name)
        .accessibilityValue(tile.stale ? appLanguage.localized("No live video") : appLanguage.localized("Live, %lld detected objects", arguments: [tile.objects.count]))
        .help(tile.stale ? appLanguage.localizedMessage(tile.frame.message) : "\(tile.frame.width)x\(tile.frame.height) · \(tile.frame.measuredFPS.formatted(.number.precision(.fractionLength(1)))) FPS · \(camera.localDeviceID == nil ? "VideoToolbox" : "AVFoundation")")
        .background(ACTATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
    }
}

struct CameraEditor: View {
    @ObservedObject var model: WallModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State var camera: Camera
    @State private var ip = ""
    @State private var username = ""
    @State private var password = ""
    @State private var location = ""
    @State private var message = ""
    @State private var keychainLoaded = false
    @State private var busy = false
    @State private var status = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?
    private enum Field { case ip, user, password }
    private var appLanguage: AppLanguage { locale.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(camera.substream.isEmpty ? "Add camera" : "Camera")).font(.title2)
            Form {
                TextField("Location", text: $location)
                TextField("IP", text: $ip).focused($focusedField, equals: .ip)
                TextField("User", text: $username).focused($focusedField, equals: .user)
                SecureField("Password", text: $password).focused($focusedField, equals: .password)
                Toggle("Monitor Hikvision ISAPI events", isOn: $camera.isapiEventsEnabled)
                if camera.isapiEventsEnabled {
                    Toggle("Use HTTPS", isOn: Binding(get: { camera.isapiHTTPS }, set: { enabled in
                        if camera.isapiPort == (enabled ? 80 : 443) {
                            camera.isapiPort = enabled ? 443 : 80
                        }
                        camera.isapiHTTPS = enabled
                    }))
                    TextField("ISAPI port", value: $camera.isapiPort, format: .number.grouping(.never))
                    if let monitorStatus = model.isapiMonitorStatus[camera.id] {
                        LabeledContent("Event monitor", value: monitorStatus)
                    }
                    if !camera.isapiHTTPS {
                        Text("HTTP does not encrypt camera credentials or events. Use HTTPS when supported and keep camera traffic on a trusted network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(busy || !keychainLoaded)
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(appLanguage.localizedMessage(status)).font(.callout) }
                    .accessibilityElement(children: .combine)
            }
            if !message.isEmpty {
                Text(appLanguage.localizedMessage(message)).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(appLanguage.localized("Error: %@", arguments: [message]))
            }
            HStack {
                Spacer()
                Button("Cancel") { saveTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(camera.substream.isEmpty ? "Add" : "Save")) {
                    message = ""
                    do { _ = try CameraAddress(ip) }
                    catch { message = error.localizedDescription; focusedField = .ip; return }
                    let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
                    camera.location = trimmedLocation.isEmpty ? nil : trimmedLocation
                    busy = true
                    saveTask = Task { @MainActor in
                        defer { busy = false }
                        do {
                            try await model.save(ip: ip, credentials: Credentials(username: username, password: password),
                                                 original: camera, progress: { status = $0 })
                            dismiss()
                        } catch is CancellationError {
                        } catch {
                            message = error is ConfigurationError ? error.localizedDescription : "Cannot detect the camera. Check the IP, credentials and network connection."
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!keychainLoaded || busy)
            }
        }.padding(24).frame(width: 600)
        .onAppear {
            location = camera.location ?? ""
            do {
                if let url = URLComponents(string: camera.substream), let host = url.host {
                    ip = host
                    if url.scheme == "onvif", let port = url.port { ip += ":\(port)" }
                }
                if let credentials = try CameraKeychain.read(camera.id) { username = credentials.username; password = credentials.password }
                keychainLoaded = true
                focusedField = .ip
            } catch { message = error.localizedDescription }
        }
        .onDisappear { saveTask?.cancel() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: WallModel
    @StateObject private var draft: WallSettingsDraft

    init(model: WallModel) {
        self.model = model
        let bundled = Go2RTC.executablePath(configuredPath: "", bundleURL: Bundle.main.bundleURL)
        _draft = StateObject(wrappedValue: WallSettingsDraft(configuration: model.config,
            bundledRelayPath: bundled.isEmpty ? nil : bundled))
    }

    var body: some View {
        SettingsForm(draft: draft, save: model.applySettings)
    }
}

@MainActor
final class WallSettingsDraft: ObservableObject {
    @Published var configuration: WallConfiguration
    @Published var staleMilliseconds: String
    let bundledRelayPath: String?

    var confidencePercent: Int { Int((configuration.detectionThreshold * 100).rounded()) }

    init(configuration: WallConfiguration, bundledRelayPath: String? = nil) {
        self.configuration = configuration
        self.staleMilliseconds = String(configuration.staleAfterMilliseconds)
        self.bundledRelayPath = bundledRelayPath
    }

    func submit(
        save: (WallConfiguration) throws -> Void,
        fileIsExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws {
        guard let stale = Int(staleMilliseconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              (200...30000).contains(stale) else {
            throw ConfigurationError.invalid("Stale threshold must be a whole number between 200 and 30000 ms.")
        }
        var next = configuration
        next.staleAfterMilliseconds = stale
        next.go2rtcPath = next.go2rtcPath.trimmingCharacters(in: .whitespacesAndNewlines)
        try next.validate()
        guard fileIsExecutable(bundledRelayPath ?? next.go2rtcPath) else {
            throw ConfigurationError.invalid("Select an existing executable file for go2rtc.")
        }
        try save(next)
    }
}

struct SettingsForm: View {
    @ObservedObject var draft: WallSettingsDraft
    let save: (WallConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var message = ""
    private var appLanguage: AppLanguage { locale.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2)
            Form {
                TextField("go2rtc executable", text: Binding(
                    get: { draft.bundledRelayPath ?? draft.configuration.go2rtcPath },
                    set: { draft.configuration.go2rtcPath = $0 }
                ))
                .disabled(draft.bundledRelayPath != nil)
                .help(appLanguage.localized(draft.bundledRelayPath == nil ? "Path to the local go2rtc executable" : "The app uses its bundled go2rtc helper"))
                .accessibilityIdentifier("settings.relayPath")
                Stepper("Columns: \(draft.configuration.columns)", value: $draft.configuration.columns, in: 1...16)
                    .help(appLanguage.localized("Automatic grid columns; saved manual window positions are preserved"))
                    .accessibilityIdentifier("settings.columns")
                TextField("Stale threshold (ms)", text: $draft.staleMilliseconds)
                    .accessibilityIdentifier("settings.staleThreshold")
                LabeledContent("YOLO confidence: \(draft.confidencePercent)%") {
                    Slider(value: Binding(
                        get: { draft.configuration.detectionThreshold },
                        set: { draft.configuration.detectionThreshold = ($0 * 100).rounded() / 100 }
                    ), in: 0.1...0.9, step: 0.05)
                        .accessibilityLabel("YOLO confidence threshold")
                        .accessibilityValue(Text("\(draft.confidencePercent)%"))
                        .accessibilityIdentifier("settings.yoloConfidence")
                }
                Stepper("Detection FPS per camera: \(Int(draft.configuration.detectionFPS))", value: $draft.configuration.detectionFPS, in: 1...5)
                    .accessibilityIdentifier("settings.detectionFPS")
            }.textFieldStyle(.roundedBorder)
            if !message.isEmpty {
                Text(appLanguage.localizedMessage(message)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try draft.submit(save: save)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.save")
            }
        }.padding(24).frame(width: 600)
    }
}

struct LocalCameraEditor: View {
    @ObservedObject var model: WallModel
    let original: Camera?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var devices: [AVCaptureDevice] = []
    @State private var selectedID = ""
    @State private var name = ""
    @State private var location = ""
    @State private var message = ""
    private var appLanguage: AppLanguage { locale.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(original == nil ? "Add Mac / iPhone camera" : "Local camera")).font(.title2)
            Text("Select your Mac camera or an iPhone available through Continuity Camera.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                TextField("Location", text: $location)
                Picker("Camera", selection: $selectedID) {
                    Text("Select a camera").tag("")
                    ForEach(devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                    if !selectedID.isEmpty && !devices.contains(where: { $0.uniqueID == selectedID }) {
                        Text("Saved camera (unavailable)").tag(selectedID)
                    }
                }
            }
            Text("For iPhone, enable Continuity Camera in Settings → General → AirPlay & Continuity. Use the same Apple Account on both devices, with Wi-Fi and Bluetooth enabled, and keep the iPhone nearby and locked.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if devices.isEmpty { Text("No cameras found. Connect a camera, then refresh.").font(.callout) }
            if !message.isEmpty { Text(appLanguage.localizedMessage(message)).foregroundStyle(.red) }
            HStack {
                Button("Refresh cameras") { refreshDevices() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(original == nil ? "Add" : "Save")) {
                    let deviceName = devices.first(where: { $0.uniqueID == selectedID })?.localizedName ?? "Local camera"
                    var camera = original ?? Camera(name: deviceName, substream: "")
                    camera.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? deviceName : name
                    let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
                    camera.location = trimmedLocation.isEmpty ? nil : trimmedLocation
                    camera.localDeviceID = selectedID
                    do {
                        try model.saveLocalCamera(camera)
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID.isEmpty)
            }
        }
        .padding(24).frame(width: 560)
        .task {
            selectedID = original?.localDeviceID ?? ""
            name = original?.name ?? ""
            location = original?.location ?? ""
            refreshDevices()
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.wasConnectedNotification) {
                refreshDevices()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.wasDisconnectedNotification) {
                refreshDevices()
            }
        }
    }

    private func refreshDevices() {
        devices = CameraSession.localDevices()
    }
}
