import AppKit
import SwiftUI
import CameraCore

struct AnalysisSidebarSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(SidebarContentBounds())
            .background(ACTATheme.sidebar, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(ACTATheme.textPrimary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false))
    }
}

struct SidebarContentBounds: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: max(0, geometry.size.width), height: max(0, geometry.size.height), alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(.interaction, RoundedRectangle(cornerRadius: 16))
        }
    }
}

private enum ACTASection: String, CaseIterable, Identifiable {
    case settings
    case cameras
    case events
    case timeline
    case memory
    case identities
    case crossCameraIdentity
    case localShowcase
    case analysis
    case map
    case reports

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .settings: "Settings"
        case .cameras: "Cameras"
        case .events: "Events"
        case .timeline: "Timeline"
        case .memory: "Memory"
        case .identities: "Tracked objects"
        case .crossCameraIdentity: "Cross-camera identity"
        case .localShowcase: "Local Showcase"
        case .analysis: "AI Analysis"
        case .map: "Map"
        case .reports: "Reports"
        }
    }

    var localizationKey: String {
        switch self {
        case .settings: "Settings"
        case .cameras: "Cameras"
        case .events: "Events"
        case .timeline: "Timeline"
        case .memory: "Memory"
        case .identities: "Tracked objects"
        case .crossCameraIdentity: "Cross-camera identity"
        case .localShowcase: "Local Showcase"
        case .analysis: "AI Analysis"
        case .map: "Map"
        case .reports: "Reports"
        }
    }

    var icon: String {
        switch self {
        case .settings: "gearshape"
        case .cameras: "video"
        case .events: "bell"
        case .timeline: "clock"
        case .memory: "clock.arrow.circlepath"
        case .identities: "person.crop.rectangle.stack"
        case .crossCameraIdentity: "person.2.crop.square.stack"
        case .localShowcase: "rectangle.on.rectangle.angled"
        case .analysis: "sparkles"
        case .map: "map"
        case .reports: "chart.bar.xaxis"
        }
    }
}

private enum ACTACameraScope: String, CaseIterable, Identifiable {
    case all = "All cameras"
    case live = "Live"
    case offline = "Offline"

    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

private enum ACTACameraPresentation: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
    var title: LocalizedStringKey { self == .grid ? "Grid" : "List" }
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

private struct CameraLocationGroup: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct ACTASecurityCenterView: View {
    @ObservedObject var model: WallModel
    @ObservedObject var languageSettings: LanguageSettings
    var addNetworkCamera: () -> Void
    var addLocalCamera: () -> Void
    var addScreenCapture: () -> Void
    var addVideoFile: () -> Void
    var importSources: () -> Void
    var showCameraManager: () -> Void
    var exportDiagnostics: () -> Void
    var resetLayout: () -> Void
    var editCamera: (Camera) -> Void
    var removeCamera: (Camera) -> Void

    @AppStorage("ACTA.favoriteCameraIDs") private var favoritesStorage = ""
    @State private var section: ACTASection = .cameras
    @State private var requestedSettings = ACTASettingsSection.general
    @State private var cameraScope: ACTACameraScope = .all
    @State private var presentation: ACTACameraPresentation = .grid
    @State private var referenceColumns = 4
    @State private var arrangeCameras = false
    @State private var locationFilter: String?
    @State private var searchText = ""
    @State private var alertsOnly = false
    @State private var favoritesOnly = false
    @State private var selectedCameraIDs: Set<UUID>?
    @State private var cameraPickerPresented = false
    @State private var aiChatPresented = false
    @State private var safetyIncidentsPresented = false
    @State private var cameraPickerSearch = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedAlert: VLMAlert?
    @State private var alertReviewNote = ""
    @State private var alertReviewError = ""
    @State private var alertReviewAudit: [OperationsAlertReview] = []
    @State private var alertClipFrames: [Data] = []
    @State private var alertClipFrameIndex = 0
    @State private var alertClipError = ""
    @State private var watchText = ""
    @State private var watchCameraIDs = Set<UUID>()
    @State private var watchForever = false
    @State private var watchTTLMinutes = 120
    @State private var watchError = ""
    @FocusState private var searchFocused: Bool

    private let sidebarWidth: CGFloat = 260
    private let collapsedSidebarWidth: CGFloat = 64
    private let outerPadding: CGFloat = 12
    private var favoriteIDs: Set<UUID> {
        Set(favoritesStorage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private var enabledCameras: [Camera] { model.config.cameras.filter(\.enabled) }
    private var onlineCameras: [Camera] {
        enabledCameras.filter { model.tiles[$0.id]?.stale == false }
    }
    private var offlineCount: Int { max(0, enabledCameras.count - onlineCameras.count) }
    private var latestAlerts: [VLMAlert] { model.vlmAlerts.sorted { $0.createdAt > $1.createdAt } }
    private var operationsQueueAlerts: [VLMAlert] {
        OperationsAlertQueue.ordered(model.vlmAlerts, reviews: model.operationsAlertReviews,
                                    acknowledgements: model.operationsAlertAcknowledgements)
    }
    private var latestISAPIEvents: [ISAPIEventRecord] { model.isapiEvents.sorted { $0.receivedAt > $1.receivedAt } }
    private var locationGroups: [CameraLocationGroup] {
        let grouped = Dictionary(grouping: enabledCameras) { camera in
            let location = camera.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return location.isEmpty ? "Other" : location
        }
        return grouped.map { CameraLocationGroup(name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var selectedCameraCount: Int {
        guard let selectedCameraIDs else { return enabledCameras.count }
        return enabledCameras.filter { selectedCameraIDs.contains($0.id) }.count
    }
    private var cameraPickerCameras: [Camera] {
        enabledCameras.filter {
            cameraPickerSearch.isEmpty || "\($0.name) \($0.location ?? "")".localizedCaseInsensitiveContains(cameraPickerSearch)
        }
    }

    private var filteredCameras: [Camera] {
        enabledCameras.filter { camera in
            guard cameraScope == .all || (cameraScope == .live) == (model.tiles[camera.id]?.stale == false) else { return false }
            let location = camera.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard locationFilter == nil || (locationFilter == "Other" ? location?.isEmpty != false : location == locationFilter) else { return false }
            guard !favoritesOnly || favoriteIDs.contains(camera.id) else { return false }
                    guard !alertsOnly || model.vlmAlerts.contains(where: { $0.cameraID == camera.id })
                        || model.isapiEvents.contains(where: { $0.cameraID == camera.id }) else { return false }
            guard selectedCameraIDs == nil || selectedCameraIDs?.contains(camera.id) == true else { return false }
            return searchText.isEmpty || "\(camera.name) \(camera.location ?? "")".localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                DashboardView {
                    sidebar(collapsed: false)
                } header: {
                    referenceHeader
                } metrics: {
                    ModelRuntimeView(runtime: model.modelRuntime, vlmBusy: model.vlmBusy, retry: model.prepareModels)
                } filters: {
                    if section == .cameras { referenceFilters }
                } content: {
                    mainContent
                } analytics: {
                    if section == .cameras { activityStrip }
                    else { statusFooter }
                }
                if cameraPickerPresented {
                    cameraPickerPanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if aiChatPresented {
                    aiChatPanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(ACTATheme.background)
            .animation(reduceMotion ? nil : Animation.snappy(duration: 0.24), value: cameraPickerPresented)
            .animation(reduceMotion ? nil : Animation.snappy(duration: 0.24), value: aiChatPresented)
        }
        .environment(\.openUnifiedChat, { context in
            if model.actaQuestionDraft.isEmpty { model.actaQuestionDraft = context }
            openAIChat()
        })
        .environment(\.openACTASettings, { target in
            requestedSettings = target
            openSettings()
        })
        .background(Button("Settings", action: openSettings).keyboardShortcut(",", modifiers: .command).hidden().accessibilityHidden(true))
        .frame(minWidth: 1280, minHeight: 800)
        .foregroundStyle(ACTATheme.textPrimary)
        .preferredColorScheme(.dark)
        .sheet(item: $selectedAlert) { alert in
            alertDetail(alert)
        }
    }

    private func sidebar(collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "triangle.fill").foregroundColor(.neonBlue).glow(color: .neonBlue)
                Text("A C T A").font(.title2).bold().foregroundColor(.white)
            }
            .padding(.top, 40).padding(.horizontal, 20)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach([ACTASection.cameras, .events, .analysis, .timeline, .map, .reports, .settings]) { destination in
                        sidebarButton(destination, collapsed: false)
                    }
                    Menu {
                        ForEach([ACTASection.memory, .identities, .crossCameraIdentity, .localShowcase]) { destination in
                            Button(destination.title) { section = destination }
                        }
                        Button("Settings", action: openSettings)
                    } label: {
                        InactiveMenuButton(icon: "square.stack.3d.down.right", title: languageSettings.localized("Systems"))
                    }.menuStyle(.borderlessButton)
                    Divider().background(Color.white.opacity(0.1)).padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("LOCATIONS").font(.caption).foregroundColor(.gray)
                            Spacer()
                            Button(action: showCameraManager) { Image(systemName: "plus").foregroundColor(.gray) }.buttonStyle(.plain)
                        }.padding(.horizontal, 20)
                        locationButton(name: "All Locations", count: enabledCameras.count, icon: "circle.grid.2x2.fill", collapsed: false, localizeName: true)
                        ForEach(locationGroups) { group in
                            locationButton(name: group.name, count: group.count, icon: locationIcon(for: group.name), collapsed: false)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            statusPanel(collapsed: false)
        }
        .frame(width: 260).frame(maxHeight: .infinity)
        .background(Color.panelBackground)
    }

    private func openSettings() {
        section = .settings; cameraPickerPresented = false; aiChatPresented = false
    }

    private var actaLogo: NSImage? {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("acta-logo.png"),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        guard let resourceURL = Bundle.module.url(forResource: "acta-logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: resourceURL)
    }

    private func logoMark(size: CGFloat) -> some View {
        Group {
            if let actaLogo {
                Image(nsImage: actaLogo).resizable().scaledToFit()
            } else {
                Image(systemName: "a.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(ACTATheme.primary)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func statusPanel(collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(offlineCount == 0 && model.running ? ACTATheme.success : ACTATheme.warning)
                    .frame(width: 8, height: 8)
                    .actaStatusGlow(offlineCount == 0 && model.running ? ACTATheme.success : ACTATheme.warning)
                if !collapsed {
                    Text(LocalizedStringKey(model.running ? "Online" : "Disconnected"))
                        .font(.system(size: ACTAType.caption, weight: .semibold))
                        .foregroundStyle(model.running ? ACTATheme.success : ACTATheme.warning)
                }
            }
            if !collapsed {
                Text(languageSettings.localized("%lld / %lld Cameras", arguments: [onlineCameras.count, enabledCameras.count]))
                    .font(.system(size: ACTAType.caption, weight: .medium).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
                    .lineLimit(1)
                Text(LocalizedStringKey(offlineCount == 0 && model.running ? "All systems operational" : "Check camera connections"))
                    .font(.system(size: ACTAType.metadata))
                    .foregroundStyle(ACTATheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ACTATheme.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func locationButton(name: String, count: Int, icon: String, collapsed: Bool, localizeName: Bool = false) -> some View {
        let displayName = localizeName ? languageSettings.localized(name) : name
        let selected = locationFilter == (name == "All Locations" ? nil : name)
        return Button {
            section = .cameras
            locationFilter = name == "All Locations" ? nil : name
            cameraScope = .all
            alertsOnly = false
            favoritesOnly = false
        } label: {
            HStack(spacing: ACTASpacing.regular) {
                Image(systemName: icon).frame(width: 18)
                if !collapsed {
                    Text(displayName).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.system(size: ACTAType.metadata, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? ACTATheme.background : ACTATheme.textMuted)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 24, minHeight: 22)
                        .background(selected ? ACTATheme.primary : ACTATheme.surfaceElevated, in: Capsule())
                }
            }
            .font(.system(size: ACTAType.caption, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? ACTATheme.textPrimary : ACTATheme.textSecondary)
            .frame(height: 36)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ACTATheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 2).fill(ACTATheme.primary).frame(width: 3, height: 22) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(languageSettings.localized("%@, %lld cameras", arguments: [displayName, count]))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func locationIcon(for name: String) -> String {
        switch name.localizedLowercase {
        case "front door", "entrance": "door.left.hand.open"
        case "garage": "car.side"
        case "backyard", "garden": "tree"
        case "driveway": "car"
        case "interior", "inside": "square.dashed"
        default: "mappin.and.ellipse"
        }
    }

    private func sidebarButton(_ destination: ACTASection, collapsed: Bool) -> some View {
        let isSelected = section == destination || (destination == .analysis && aiChatPresented)
        return Button {
            if destination == .analysis {
                if aiChatPresented { aiChatPresented = false }
                else { openAIChat() }
            } else {
                section = destination
            }
        } label: {
            if isSelected {
                ActiveMenuButton(icon: destination.icon, title: languageSettings.localized(destination.localizationKey))
            } else {
                InactiveMenuButton(icon: destination.icon, title: languageSettings.localized(destination.localizationKey))
            }
        }
        .buttonStyle(.plain)
        .help(destination.title)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func settingsSidebarButton(collapsed: Bool) -> some View {
        Button(action: openSettings) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: ACTAType.body))
                    .frame(width: 20)
                if !collapsed {
                    Text("Settings")
                        .font(.system(size: ACTAType.body, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(ACTATheme.textSecondary)
            .frame(height: 48)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? languageSettings.localized("Settings") : "")
        .accessibilityLabel("Settings")
    }

    private func sidebarBadge(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: ACTAType.metadata, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var referenceHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(languageSettings.localized("Security Center"))
                    .font(.title2).bold().foregroundColor(.white).lineLimit(1)
                Text(languageSettings.localized("Intelligent monitoring and analysis"))
                    .font(.subheadline).foregroundColor(.gray).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField(languageSettings.localized("Search cameras and locations…"), text: $searchText)
                    .textFieldStyle(.plain).foregroundColor(.white).focused($searchFocused)
                Text("⌘K").font(.caption).padding(4).background(Color.white.opacity(0.1)).cornerRadius(4).foregroundColor(.gray)
            }
            .padding(.horizontal, 12).frame(minWidth: 160, idealWidth: 320, maxWidth: 320).frame(height: 40)
            .background(Color.panelBackground).cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.1), lineWidth: 1))
            HStack(spacing: 12) {
                Button { cameraPickerPresented.toggle(); aiChatPresented = false } label: { HeaderIconButton(icon: "square.grid.2x2") }
                    .help("Choose cameras")
                Button { section = .events } label: { HeaderIconButton(icon: "bell", showBadge: !model.vlmAlerts.isEmpty) }
                    .help("Notifications")
                Button(action: openSettings) { HeaderIconButton(icon: "gearshape") }.help("Settings")
                Button(action: openSettings) {
                    HStack { Text(languageSettings.language.buttonTitle); Image(systemName: "chevron.down") }
                        .font(.subheadline).foregroundColor(.white).padding(.horizontal, 12).frame(height: 40)
                        .background(Color.panelBackground).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                }
                moreMenu
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
        }
        .padding(.top, 4)
    }

    private var referenceFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { cameraScope = .all; locationFilter = nil; alertsOnly = false; favoritesOnly = false } label: {
                    FilterTag(title: languageSettings.localized("All cameras"), isActive: cameraScope == .all && locationFilter == nil)
                }
                ForEach(LocalModelService.allCases, id: \.self) { service in
                    FilterTag(title: languageSettings.localized(service.title), isActive: false)
                }
                Button(action: addNetworkCamera) {
                    Image(systemName: "plus").foregroundColor(.gray).padding(8).background(Color.panelBackground).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                }.help("Add network camera")
                Spacer(minLength: 8)
                cameraToolbar(compact: true)
            }.buttonStyle(.plain)
        }.frame(height: 40)
    }

    private func header(compact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(languageSettings.localized("Security Center"))
                        .font(.system(size: ACTAType.heading, weight: .bold))
                        .lineLimit(1)
                    Text(languageSettings.localized("Intelligent monitoring and analysis"))
                        .font(.system(size: ACTAType.caption))
                        .foregroundStyle(ACTATheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                if !compact {
                    DateTimeReadout().fixedSize(horizontal: true, vertical: false)
                    Button { model.running ? model.stop() : model.start() } label: {
                        Label(languageSettings.localized(model.running ? "Live" : "Connect"), systemImage: "circle.fill")
                            .font(.system(size: ACTAType.caption, weight: .medium))
                            .foregroundStyle(model.running ? ACTATheme.success : ACTATheme.warning)
                    }
                    .buttonStyle(.plain)
                    .help(languageSettings.localized(model.running ? "Disconnect cameras" : "Connect cameras"))
                }
                cameraPickerButton(compact: compact)
                notificationsButton
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 40, height: 40)
                        .background(ACTATheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(languageSettings.localized("Settings"))
                .accessibilityLabel(languageSettings.localized("Settings"))
                Button(action: openSettings) {
                    Text(languageSettings.language.buttonTitle)
                        .font(.system(size: ACTAType.caption, weight: .semibold))
                        .frame(width: 48, height: 40)
                        .background(ACTATheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(languageSettings.localized(languageSettings.language.switchLabelKey))
                .accessibilityLabel(languageSettings.localized(languageSettings.language.switchLabelKey))
                moreMenu
            }
            .frame(height: 56)
            if section == .cameras {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        searchField(compact: false)
                        cameraToolbar(compact: true)
                    }
                }
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ACTATheme.border, lineWidth: 1))
        .padding(8)
    }

    private var notificationsButton: some View {
        let count = model.vlmAlerts.count + model.isapiEvents.count
        return Button { section = .events } label: {
            Image(systemName: count > 0 ? "bell.badge" : "bell")
                .frame(width: 40, height: 40)
                .background(ACTATheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(languageSettings.localized("Notifications"))
        .accessibilityLabel(languageSettings.localized("Notifications"))
        .accessibilityValue(String(count))
    }

    private func searchField(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(ACTATheme.textMuted)
            TextField("Search cameras, locations…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search cameras and locations")
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear camera search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: compact ? 150 : 204, height: 40)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.controlBorder, lineWidth: 1))
    }

    private func cameraToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            Button(action: addNetworkCamera) {
                Image(systemName: "video.badge.plus")
                    .frame(width: 40, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized("Add network camera"))
            .accessibilityLabel(languageSettings.localized("Add network camera"))

            Picker("", selection: $presentation) {
                ForEach(ACTACameraPresentation.allCases) { mode in
                    Image(systemName: mode.icon).tag(mode)
                        .accessibilityLabel(mode.title)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: compact ? 80 : 84, height: 40)
            .help("Switch between grid and list")
            .accessibilityLabel("Camera view")

            Menu {
                Picker("Camera status", selection: $cameraScope) {
                    ForEach(ACTACameraScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(cameraScope.title)
                        .font(.system(size: ACTAType.caption, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: ACTAType.metadata, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(width: compact ? 96 : 136, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .help("Filter cameras by status")
            .accessibilityLabel("Camera status filter")

            Button { alertsOnly.toggle() } label: {
                Image(systemName: alertsOnly ? "bell.badge.fill" : "bell")
                    .foregroundStyle(alertsOnly ? ACTATheme.warning : ACTATheme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(alertsOnly ? ACTATheme.warning.opacity(0.12) : ACTATheme.surface,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized(alertsOnly ? "Show all cameras" : "Show cameras with stored AI alerts"))
            .accessibilityLabel(languageSettings.localized(alertsOnly ? "Clear AI alert filter" : "Filter to cameras with AI alerts"))

            Menu {
                ForEach(1...4, id: \.self) { columns in
                    let title = languageSettings.localized("%lld × %lld", arguments: [columns, columns])
                    Button {
                        referenceColumns = columns
                        model.setGridColumns(columns)
                    } label: {
                        if referenceColumns == columns {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
                Divider()
                Button(languageSettings.localized("Custom…"), action: openSettings)
            } label: {
                Image(systemName: "square.grid.2x2")
                    .frame(width: 40, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
            .help(languageSettings.localized("Select camera grid layout"))
            .accessibilityLabel(languageSettings.localized("Camera grid layout"))

            Button(action: resetLayout) {
                Image(systemName: "rectangle.3.group")
                    .frame(width: 40, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized("Fit cameras to window"))
            .accessibilityLabel(languageSettings.localized("Fit cameras to window"))

            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 40, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized("Enter or exit full screen"))
            .accessibilityLabel(languageSettings.localized("Enter or exit full screen"))

            Button { favoritesOnly.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                    if !compact { Text("Favorites").font(.system(size: ACTAType.caption, weight: .medium)) }
                }
                .foregroundStyle(favoritesOnly ? ACTATheme.warning : ACTATheme.textSecondary)
                .padding(.horizontal, 12)
                .frame(width: compact ? 40 : 112, height: 40)
                    .background(favoritesOnly ? ACTATheme.warning.opacity(0.12) : ACTATheme.surface,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized(favoritesOnly ? "Show all cameras" : "Show favorite cameras"))
            .accessibilityLabel(languageSettings.localized(favoritesOnly ? "Show all cameras" : "Show favorites"))
        }
    }

    private func cameraPickerButton(compact: Bool) -> some View {
        Button(action: toggleCameraPicker) {
            HStack(spacing: 8) {
                Image(systemName: "video.badge.ellipsis")
                if !compact { Text("Cameras").font(.system(size: ACTAType.caption, weight: .medium)) }
                Text("\(selectedCameraCount)")
                    .font(.system(size: ACTAType.metadata, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(ACTATheme.primary.opacity(0.22), in: Capsule())
            }
            .foregroundStyle(cameraPickerPresented ? ACTATheme.textPrimary : ACTATheme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(cameraPickerPresented ? ACTATheme.primary.opacity(0.18) : ACTATheme.surface.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Select cameras shown in the wall")
        .accessibilityLabel("Select cameras")
        .accessibilityValue(languageSettings.localized("%lld selected", arguments: [selectedCameraCount]))
        .accessibilityAddTraits(cameraPickerPresented ? .isSelected : [])
    }

    private var cameraPickerPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: ACTASpacing.regular) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Select cameras")
                        .font(.system(size: ACTAType.body, weight: .semibold))
                    Text(languageSettings.localized("%lld of %lld selected", arguments: [selectedCameraCount, enabledCameras.count]))
                        .font(.system(size: ACTAType.caption, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button { toggleCameraPicker() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ACTAType.metadata, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Close camera selection")
                .accessibilityLabel("Close camera selection")
            }

            HStack(spacing: 8) {
                Button("Select all") { selectedCameraIDs = Set(enabledCameras.map(\.id)) }
                    .buttonStyle(.plain)
                Spacer()
                Button("Clear") { selectedCameraIDs = [] }
                    .buttonStyle(.plain)
                    .foregroundStyle(ACTATheme.textSecondary)
            }
            .font(.system(size: ACTAType.caption, weight: .semibold))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ACTATheme.textMuted)
                TextField("Search cameras", text: $cameraPickerSearch)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search cameras to select")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(ACTATheme.surface.opacity(0.66), in: RoundedRectangle(cornerRadius: 9))

            Group {
                if enabledCameras.isEmpty {
                    ContentUnavailableView("No cameras available", systemImage: "video",
                                           description: Text("Add or enable cameras to select them."))
                } else if cameraPickerCameras.isEmpty {
                    ContentUnavailableView.search(text: cameraPickerSearch)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(locationGroups) { group in
                                let cameras = cameraPickerCameras.filter { cameraLocation($0) == group.name }
                                if !cameras.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name.uppercased())
                                            .font(.system(size: ACTAType.metadata, weight: .semibold))
                                            .foregroundStyle(ACTATheme.textMuted)
                                            .padding(.horizontal, 12)
                                        ForEach(cameras) { camera in cameraPickerRow(camera) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(14)
        .modifier(SidebarContentBounds())
        .frame(width: 296)
        .frame(maxHeight: .infinity)
        .background(ACTATheme.sidebar.opacity(0.42), in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ACTATheme.textPrimary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onExitCommand { toggleCameraPicker() }
        .accessibilityLabel("Camera selection panel")
    }

    private func cameraPickerRow(_ camera: Camera) -> some View {
        let isSelected = selectedCameraIDs?.contains(camera.id) ?? true
        return Button {
            var selection = selectedCameraIDs ?? Set(enabledCameras.map(\.id))
            if isSelected { selection.remove(camera.id) } else { selection.insert(camera.id) }
            selectedCameraIDs = selection
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(model.tiles[camera.id]?.stale == false ? ACTATheme.success : ACTATheme.textMuted)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.name)
                        .font(.system(size: ACTAType.caption, weight: .medium))
                        .foregroundStyle(ACTATheme.textPrimary)
                        .lineLimit(1)
                    Text(LocalizedStringKey(model.tiles[camera.id]?.stale == false ? "Live" : "Offline"))
                        .font(.system(size: ACTAType.metadata, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: ACTAType.body, weight: .regular))
                    .foregroundStyle(isSelected ? ACTATheme.primary : ACTATheme.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? ACTATheme.primary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func cameraLocation(_ camera: Camera) -> String {
        let location = camera.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return location.isEmpty ? "Other" : location
    }

    private func toggleCameraPicker() {
        if !cameraPickerPresented, selectedCameraIDs == nil {
            selectedCameraIDs = Set(enabledCameras.map(\.id))
        }
        aiChatPresented = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            cameraPickerPresented.toggle()
        }
    }

    private func openAIChat() {
        cameraPickerPresented = false
        section = .cameras
        aiChatPresented = true
    }

    private var aiChatPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: ACTASpacing.regular) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Analysis")
                        .font(.system(size: ACTAType.body, weight: .semibold))
                    Text("Live video and history of all cameras")
                        .font(.system(size: ACTAType.metadata, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button { aiChatPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ACTAType.metadata, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Close AI chat")
                .accessibilityLabel("Close AI chat")
            }
            .padding(.horizontal, 14)
            .frame(height: 58)

            Rectangle().fill(ACTATheme.border).frame(height: 1)

            VLMPanel(model: model, languageSettings: languageSettings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(AnalysisSidebarSurface())
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onExitCommand { aiChatPresented = false }
        .accessibilityLabel("AI analysis chat panel")
    }

    private var moreMenu: some View {
        Menu {
            Button(languageSettings.localized(model.running ? "Disconnect cameras" : "Connect cameras")) {
                model.running ? model.stop() : model.start()
            }
            Divider()
            Button("Network camera", systemImage: "video.badge.plus", action: addNetworkCamera)
            Button("Mac / iPhone camera", systemImage: "web.camera", action: addLocalCamera)
            Button("Capture screen", systemImage: "display", action: addScreenCapture)
            Button("Open video file", systemImage: "film", action: addVideoFile)
            Button("Import RTSP sources", systemImage: "square.and.arrow.down", action: importSources)
            Button("Manage cameras", systemImage: "list.bullet", action: showCameraManager)
            Button("Ask AI about cameras", systemImage: "sparkles", action: openAIChat)
            Divider()
            Toggle("Arrange cameras", isOn: $arrangeCameras)
            Button("Reset window layout", systemImage: "square.grid.3x3", action: resetLayout)
            Button("Export diagnostics", systemImage: "chart.bar.xaxis", action: exportDiagnostics)
            Button("Settings", systemImage: "gearshape", action: openSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: ACTAType.body, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    @ViewBuilder
    private var mainContent: some View {
        switch section {
        case .settings:
            SettingsHubView(model: model, languageSettings: languageSettings,
                manageCameras: showCameraManager, addNetworkCamera: addNetworkCamera,
                addLocalCamera: addLocalCamera, addScreenCapture: addScreenCapture,
                addVideoFile: addVideoFile, editCamera: editCamera, watchRules: AnyView(operationsWatchPanel), initialSection: requestedSettings)
                .id(requestedSettings)
        case .cameras:
            camerasContent
        case .events:
            eventsContent
        case .timeline:
            timelineContent
        case .memory:
            CameraMemoryView(model: model)
        case .identities:
            IdentityHistoryView(model: model)
        case .crossCameraIdentity:
            CrossCameraIdentityView()
        case .localShowcase:
            LocalShowcaseView(model: model)
        case .analysis:
            analysisContent
        case .map:
            emptyPage(title: "No camera locations", icon: "map",
                      description: "Location coordinates are not stored for these cameras.",
                      actionTitle: "Back to cameras") { section = .cameras }
        case .reports:
            reportsContent
        }
    }

    private var camerasContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
            if model.config.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras added", systemImage: "video")
                } description: {
                    Text("Add a network camera or a Mac / iPhone camera to begin.")
                } actions: {
                    Button("Add camera", action: addNetworkCamera)
                        .buttonStyle(.borderedProminent).tint(ACTATheme.actionFill)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredCameras.isEmpty {
                ContentUnavailableView.search(text: searchText.isEmpty ? "active filters" : searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        Button("Clear filters") {
                            searchText = ""
                            cameraScope = .all
                            locationFilter = nil
                            alertsOnly = false
                            favoritesOnly = false
                        }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 24)
                    }
            } else if presentation == .grid {
                VideoCanvas(model: model, cameras: filteredCameras, arrangeCameras: arrangeCameras, preferredColumns: model.config.columns,
                            edit: editCamera, remove: removeCamera)
                    .padding(8)
            } else {
                cameraList
            }
            }
        }
        .background(ACTATheme.background)
    }

    private var liveTimelineRail: some View {
        let hours = [0, 6, 12, 18]
        return HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(hours, id: \.self) { hoursAgo in
                    Text(Date.now.addingTimeInterval(Double(-hoursAgo) * 60 * 60)
                        .formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                        .font(.system(size: ACTAType.metadata, weight: .medium).monospacedDigit())
                        .foregroundStyle(hoursAgo == 0 ? ACTATheme.textPrimary : ACTATheme.textMuted)
                    if hoursAgo != hours.last { Spacer(minLength: 0) }
                }
            }
            .frame(width: 54)
            .frame(maxHeight: .infinity)

            ZStack {
                Capsule().fill(ACTATheme.border).frame(width: 2)
                VStack(spacing: 0) {
                    Circle().fill(ACTATheme.primary).frame(width: 12, height: 12)
                    Spacer(minLength: 0)
                    Circle().fill(ACTATheme.primary.opacity(0.82)).frame(width: 10, height: 10)
                    Spacer(minLength: 0)
                    Circle().fill(ACTATheme.primary.opacity(0.72)).frame(width: 10, height: 10)
                    Spacer(minLength: 0)
                    Circle().fill(ACTATheme.primary.opacity(0.62)).frame(width: 10, height: 10)
                }
                .padding(.vertical, 2)
            }
            .frame(width: 12)
            .frame(maxHeight: .infinity)
        }
        .padding(.leading, 8)
        .padding(.vertical, 16)
        .frame(width: 88)
        .overlay(alignment: .trailing) { Rectangle().fill(ACTATheme.border).frame(width: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("24-hour live time scale")
    }

    private var cameraList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredCameras) { camera in
                    if let tile = model.tiles[camera.id] {
                        ACTACameraListRow(camera: camera, tile: tile,
                            isFavorite: favoriteIDs.contains(camera.id),
                            toggleFavorite: { toggleFavorite(camera) },
                            expand: { model.toggleExpanded(camera) },
                            edit: { editCamera(camera) },
                            reconnect: { model.reconnect(camera) },
                            snapshot: { model.snapshot(camera) },
                            remove: { removeCamera(camera) },
                            toggleYOLO: { model.setYOLOEnabled(for: camera.id, enabled: $0) },
                            toggleAIChat: { model.setAIChatEnabled(for: camera.id, enabled: $0) })
                    }
                }
            }
            .padding(outerPadding)
        }
        .accessibilityLabel("Live camera list")
    }

    private var eventsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                pageHeading("Events", subtitle: "Camera events and local AI alerts")
                Spacer()
                OpenSettingsButton(section: .events)
                Button(action: exportOperationsReport) { Label("Export operations report", systemImage: "square.and.arrow.up") }
            }
            if model.featurePreferences.enabledFeatures.contains(.independentWatcher) {
                localMonitorPanel
            }
            HStack {
                Button { safetyIncidentsPresented = true } label: {
                    Label(languageSettings.localized("Safety incidents (%lld)", arguments: [model.localAnalyticsEngine.incidents.count]), systemImage: "exclamationmark.shield")
                }
                .sheet(isPresented: $safetyIncidentsPresented) {
                    SafetyIncidentCenterView(engine: model.localAnalyticsEngine, languageSettings: languageSettings)
                }
                Spacer()
            }
            if latestAlerts.isEmpty && latestISAPIEvents.isEmpty {
                emptyPage(title: "No events", icon: "bell",
                          description: "Enable ISAPI events for a network camera or configure scheduled AI alerts.",
                          actionTitle: "Manage cameras", action: showCameraManager)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !latestISAPIEvents.isEmpty {
                            Text("CAMERA EVENTS")
                                .font(.system(size: ACTAType.metadata, weight: .semibold))
                                .foregroundStyle(ACTATheme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                            ForEach(latestISAPIEvents) { event in isapiEventRow(event) }
                        }
                        if !latestAlerts.isEmpty {
                            Text("AI ALERTS")
                                .font(.system(size: ACTAType.metadata, weight: .semibold))
                                .foregroundStyle(ACTATheme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                            ForEach(operationsQueueAlerts) { alert in alertRow(alert) }
                        }
                    }
                }
            }
        }
        .padding(ACTASpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ACTATheme.background)
    }

    private var localMonitorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Local monitor: \(languageSettings.localized(model.localMonitorSnapshot.verdict.rawValue.capitalized))",
                      systemImage: model.localMonitorSnapshot.verdict == .fault ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                    .font(.system(size: ACTAType.body, weight: .semibold))
                    .accessibilityValue(languageSettings.localized(model.localMonitorSnapshot.verdict.rawValue))
                Spacer()
                if let checkedAt = model.localMonitorSnapshot.checkedAt {
                    Text(checkedAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                        .font(.system(size: ACTAType.metadata).monospacedDigit())
                        .foregroundStyle(ACTATheme.textMuted)
                }
                Button {
                    model.runLocalOperationsMonitorCheck()
                } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }
                .help("Run the local read-only health checks now")
            }
            ForEach(model.localMonitorSnapshot.probes) { probe in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: probe.status == .down ? "xmark.circle.fill" : (probe.status == .warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(languageSettings.localizedMessage(probe.label)) · \(languageSettings.localized(probe.status.rawValue.capitalized))")
                            .font(.system(size: ACTAType.metadata, weight: .medium))
                        Text(languageSettings.localizedMessage(probe.detail)).font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !model.localMonitorHistory.isEmpty {
                DisclosureGroup("Recent monitor events · \(model.localMonitorHistory.count)") {
                    ForEach(Array(model.localMonitorHistory.suffix(10).reversed())) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(languageSettings.localizedMessage(event.label)) · \(languageSettings.localized(event.kind.rawValue.capitalized))")
                                .font(.system(size: ACTAType.metadata, weight: .medium))
                            Text("\(event.occurredAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)) · \(languageSettings.localizedMessage(event.detail))")
                                .font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("Runs only while this app is open. Read-only; no auto-restart, LaunchAgent, tunnel or external checks.")
                .font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
    }

    private var operationsWatchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Standing visual watches", systemImage: "eye")
                    .font(.system(size: ACTAType.body, weight: .semibold))
                Spacer()
                Text("Local descriptions · one alert per track")
                    .font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textMuted)
            }
            TextField("Describe visible details to watch for", text: $watchText, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Visual watch condition")
            HStack {
                Menu {
                    Button("All enabled cameras") { watchCameraIDs = [] }
                    Divider()
                    ForEach(enabledCameras) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { watchCameraIDs.contains(camera.id) },
                            set: { selected in
                                if selected { watchCameraIDs.insert(camera.id) }
                                else { watchCameraIDs.remove(camera.id) }
                            }
                        ))
                    }
                } label: {
                    Label(watchCameraIDs.isEmpty ? "All cameras" : "\(watchCameraIDs.count) cameras",
                          systemImage: "video")
                }
                .accessibilityLabel("Camera scope for watch rule")
                Toggle("No expiry", isOn: $watchForever)
                    .toggleStyle(.checkbox)
                if !watchForever {
                    Stepper("\(watchTTLMinutes) min", value: $watchTTLMinutes, in: 1...43_200, step: 30)
                        .accessibilityLabel("Watch expiry in minutes")
                }
                Spacer()
                Button(action: addWatchRule) {
                    Label("Add watch", systemImage: "plus")
                }
                .disabled(watchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || OperationsWatchMatcher.terms(watchText).isEmpty
                          || OperationsWatchMatcher.terms(watchText).count > OperationsWatchRule.maximumTerms)
                .help("Match all entered terms only against recent local descriptions")
            }
            if !watchError.isEmpty {
                Text(languageSettings.localizedMessage(watchError)).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.danger)
                    .accessibilityLabel("Watch rule error: \(watchError)")
            }
            if model.operationsWatchRules.isEmpty {
                Text("No active watch rules.").font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textSecondary)
            } else {
                ForEach(model.operationsWatchRules) { rule in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.text).font(.system(size: ACTAType.caption, weight: .medium))
                            let scope = rule.cameraIDs.isEmpty ? languageSettings.localized("All enabled cameras") : languageSettings.localized("%lld selected cameras", arguments: [rule.cameraIDs.count])
                            let expiry = rule.expiresAt.map { languageSettings.localized("Expires %@", arguments: [$0.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)]) } ?? languageSettings.localized("No expiry")
                            Text("\(scope) · \(expiry) · \(rule.firedTrackIDs.count) tracks alerted")
                                .font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textMuted)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            do { try model.cancelOperationsWatch(rule.id); watchError = "" }
                            catch { watchError = error.localizedDescription }
                        } label: {
                            Image(systemName: "xmark.circle")
                                .frame(width: 32, height: 32)
                        }
                        .help("Cancel this local watch")
                        .accessibilityLabel("Cancel watch: \(rule.text)")
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                }
            }
            Text("Rules use exact visible description terms; they do not identify a person or infer intent. Forever rules can be cancelled here.")
                .font(.system(size: ACTAType.metadata)).foregroundStyle(ACTATheme.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
    }

    private func addWatchRule() {
        do {
            try model.addOperationsWatch(
                text: watchText, cameraIDs: watchCameraIDs,
                ttlMinutes: watchTTLMinutes, forever: watchForever
            )
            watchText = ""
            watchCameraIDs = []
            watchError = ""
        } catch { watchError = error.localizedDescription }
    }

    private func isapiEventRow(_ event: ISAPIEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(event.cameraName, systemImage: "video")
                    .font(.system(size: ACTAType.body, weight: .semibold))
                Spacer()
                Text((event.occurredAt ?? event.receivedAt).formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                    .font(.system(size: ACTAType.metadata, weight: .medium).monospacedDigit())
                    .foregroundStyle(ACTATheme.textMuted)
            }
            HStack(spacing: 8) {
                Text(event.eventType)
                    .font(.system(size: ACTAType.caption, weight: .semibold))
                if let state = event.eventState {
                    Text(languageSettings.localized(state.capitalized))
                        .font(.system(size: ACTAType.metadata, weight: .semibold))
                        .foregroundStyle(state.lowercased() == "active" ? ACTATheme.warning : ACTATheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(ACTATheme.surfaceElevated, in: Capsule())
                }
                if let channel = event.channelID {
                    Text(languageSettings.localized("Channel %lld", arguments: [channel])).font(.system(size: ACTAType.metadata))
                }
            }
            if let detail = event.eventDescription, !detail.isEmpty {
                Text(detail).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.textSecondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(languageSettings.localized(
            "Camera event: %@, %@, camera %@",
            arguments: [event.eventType, languageSettings.localized(event.eventState ?? "unknown state"), event.cameraName]
        ))
    }

    private var timelineContent: some View {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let recent = latestAlerts.filter { $0.createdAt >= cutoff }
        return VStack(alignment: .leading, spacing: 16) {
            pageHeading("AI activity timeline", subtitle: "Alert timestamps · last 24 hours")
            if recent.isEmpty {
                ContentUnavailableView("No AI alerts in this period", systemImage: "clock",
                                       description: Text("Recorded video playback is not configured."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    alertTimeline(recent)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(recent) { alert in alertRow(alert) }
                        }
                    }
                }
            }
        }
        .padding(ACTASpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ACTATheme.background)
    }

    private func alertTimeline(_ alerts: [VLMAlert]) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(ACTATheme.border).frame(height: 2)
                    ForEach(alerts) { alert in
                        let age = min(1, max(0, Date().timeIntervalSince(alert.createdAt) / (24 * 60 * 60)))
                        Button { selectedAlert = alert } label: {
                            Circle().fill(ACTATheme.danger).frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                        .help("\(alert.cameraName) · \(alert.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))")
                        .accessibilityLabel(languageSettings.localized(
                            "AI alert for %@ at %@",
                            arguments: [alert.cameraName, alert.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale)]
                        ))
                        .offset(x: max(0, geometry.size.width * (1 - age) - 5), y: -4)
                    }
                }
            }
            .frame(height: 12)
            HStack {
                Text(Date.now.addingTimeInterval(-24 * 60 * 60).formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                Spacer()
                Text("Now")
            }
            .font(.system(size: ACTAType.metadata, weight: .medium).monospacedDigit())
            .foregroundStyle(ACTATheme.textSecondary)
        }
        .padding(16)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var analysisContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeading("AI Analysis", subtitle: "Local Qwen vision model")
            HStack(spacing: 12) {
                Image(systemName: "cpu").font(.system(size: ACTAType.heading)).foregroundStyle(ACTATheme.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qwen3.5-9B-4bit").font(.system(size: ACTAType.body, weight: .semibold))
                    Text(languageSettings.localizedMessage(model.vlmStatus)).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Button("Open AI analysis", action: openAIChat).buttonStyle(.borderedProminent).tint(ACTATheme.actionFill)
            }
            .padding(16)
            .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            Text("\(languageSettings.localized(model.vlmPreferences.scheduleEnabled ? "Scheduled checks enabled" : "Scheduled checks off")) · \(languageSettings.localized("%lld active alert conditions", arguments: [model.vlmPreferences.alertRules.filter(\.enabled).count]))")
                .font(.system(size: ACTAType.caption, weight: .medium))
                .foregroundStyle(ACTATheme.textSecondary)
            Spacer()
        }
        .padding(ACTASpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ACTATheme.background)
    }

    private var reportsContent: some View {
        let cameraIDs = Set(model.vlmAlerts.map(\.cameraID))
        let latest = latestAlerts.first
        return VStack(alignment: .leading, spacing: 16) {
            pageHeading("Reports", subtitle: "Summary of stored local AI alerts")
            if model.vlmAlerts.isEmpty {
                emptyPage(title: "No report data yet", icon: "chart.bar.xaxis",
                          description: "Reports use real AI alerts stored by CameraWall.",
                          actionTitle: "Configure AI analysis", action: openAIChat)
            } else {
                HStack(spacing: 12) {
                    reportMetric("Stored alerts", value: "\(model.vlmAlerts.count)")
                    reportMetric("Cameras with alerts", value: "\(cameraIDs.count)")
                    reportMetric("Latest alert", value: latest?.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale) ?? "—")
                }
                Text("Alert history is limited to the most recent 100 records. Optional alert lookbacks are local JPEG frames and expire after seven days; no continuous video is stored.")
                    .font(.system(size: ACTAType.caption))
                    .foregroundStyle(ACTATheme.textSecondary)
                Spacer()
            }
        }
        .padding(ACTASpacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ACTATheme.background)
    }

    private func reportMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: ACTAType.caption, weight: .medium)).foregroundStyle(ACTATheme.textSecondary)
            Text(value).font(.system(size: 21, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var activityStrip: some View {
        ACTAActivitySummaryView(alerts: latestAlerts, incidents: model.localAnalyticsEngine.incidents,
            hardwareEvents: latestISAPIEvents, openEvents: { section = .events }, openAlert: { selectedAlert = $0 })
            .equatable()
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(offlineCount == 0 && model.running ? ACTATheme.success : ACTATheme.warning)
                .frame(width: 7, height: 7)
            Text(LocalizedStringKey(model.running ? "Connected" : "Disconnected"))
            Text("·")
            Text(languageSettings.localized("%lld/%lld online", arguments: [onlineCameras.count, enabledCameras.count]))
                .monospacedDigit()
            Spacer()
            if !model.notice.isEmpty { Text(languageSettings.localizedMessage(model.notice)).lineLimit(1) }
            if model.detectionEnabled { Text(languageSettings.localizedMessage(model.detectionStatus)).lineLimit(1) }
            if model.expanded != nil {
                Button("All cameras") { model.expanded = nil }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .font(.system(size: ACTAType.metadata, weight: .medium))
        .foregroundStyle(ACTATheme.textSecondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(ACTATheme.sidebar)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: ACTAType.heading, weight: .semibold))
            Text(LocalizedStringKey(subtitle)).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.textSecondary)
        }
    }

    private func emptyPage(title: String, icon: String, description: String,
                           actionTitle: String, action: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(LocalizedStringKey(title), systemImage: icon)
        } description: {
            Text(LocalizedStringKey(description))
        } actions: {
            Button(LocalizedStringKey(actionTitle), action: action).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func alertRow(_ alert: VLMAlert) -> some View {
        Button { selectedAlert = alert } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(ACTATheme.danger)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(alert.cameraName).font(.system(size: ACTAType.body, weight: .semibold))
                        Spacer()
                        Text(alert.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                            .font(.system(size: ACTAType.metadata, weight: .medium).monospacedDigit())
                            .foregroundStyle(ACTATheme.textMuted)
                    }
                    Text(alert.condition).font(.system(size: ACTAType.caption, weight: .medium))
                    Text(alert.evidence).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.textSecondary)
                        .lineLimit(2)
                    if let review = model.operationsAlertReviews[alert.id] {
                        Label("\(languageSettings.localized(review.priority.rawValue.capitalized)) · \(languageSettings.localized(review.status.rawValue.capitalized))",
                              systemImage: review.priority == .critical ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.system(size: ACTAType.metadata, weight: .medium))
                            .foregroundStyle(review.priority == .critical ? ACTATheme.warning : ACTATheme.textSecondary)
                    } else if let acknowledgedAt = model.operationsAlertAcknowledgements[alert.id] {
                        Label("Acknowledged · \(acknowledgedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                            .font(.system(size: ACTAType.metadata, weight: .medium))
                            .foregroundStyle(ACTATheme.success)
                    } else if alert.priority == .critical {
                        Label("Critical · Open", systemImage: "exclamationmark.triangle")
                            .font(.system(size: ACTAType.metadata, weight: .medium))
                            .foregroundStyle(ACTATheme.warning)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(languageSettings.localized(
            "AI alert: %@, camera %@, %@",
            arguments: [alert.condition, alert.cameraName, alert.evidence]
        ))
    }

    private func alertDetail(_ alert: VLMAlert) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Label(alert.cameraName, systemImage: "video")
                .font(.system(size: ACTAType.heading, weight: .semibold))
            Text(alert.condition).font(.system(size: ACTAType.body, weight: .medium))
            Text(alert.evidence).font(.system(size: ACTAType.body)).foregroundStyle(ACTATheme.textSecondary)
            if let watchID = alert.watchID, let trackID = alert.sourceTrackID {
                Label("Local watch · track \(trackID.uuidString)", systemImage: "eye")
                    .font(.system(size: ACTAType.metadata, weight: .medium))
                    .textSelection(.enabled)
                    .accessibilityLabel("Local watch alert for per-camera track \(trackID.uuidString), rule \(watchID.uuidString)")
            }
            Text(alert.createdAt.formatted(date: .complete, time: .shortened, locale: languageSettings.locale))
                .font(.system(size: ACTAType.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(ACTATheme.textMuted)
            if model.featurePreferences.enabledFeatures.contains(.operationalAlerts) {
                if alert.clipID != nil {
                    DisclosureGroup("Local lookback frames · 8 seconds") {
                        VStack(alignment: .leading, spacing: 12) {
                            if alertClipFrames.isEmpty {
                                Button {
                                    loadAlertClip(alert)
                                } label: {
                                    Label("Load saved frames", systemImage: "play.rectangle")
                                }
                                .help("Load this locally stored alert sequence; it expires within seven days")
                            } else if alertClipFrameIndex < alertClipFrames.count,
                                      let image = NSImage(data: alertClipFrames[alertClipFrameIndex]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .accessibilityLabel("Alert lookback frame \(alertClipFrameIndex + 1) of \(alertClipFrames.count)")
                                HStack {
                                    Button {
                                        alertClipFrameIndex = max(0, alertClipFrameIndex - 1)
                                    } label: { Label("Previous", systemImage: "chevron.left") }
                                    .disabled(alertClipFrameIndex == 0)
                                    Text("Frame \(alertClipFrameIndex + 1) of \(alertClipFrames.count)")
                                        .font(.system(size: ACTAType.metadata).monospacedDigit())
                                    Button {
                                        alertClipFrameIndex = min(alertClipFrames.count - 1, alertClipFrameIndex + 1)
                                    } label: { Label("Next", systemImage: "chevron.right") }
                                    .disabled(alertClipFrameIndex >= alertClipFrames.count - 1)
                                    Spacer()
                                    Button("Delete clip", role: .destructive) {
                                        do {
                                            try model.deleteAlertClip(for: alert.id)
                                            alertClipFrames = []
                                            alertClipError = ""
                                        } catch { alertClipError = error.localizedDescription }
                                    }
                                }
                            }
                            if !alertClipError.isEmpty {
                                Text(languageSettings.localizedMessage(alertClipError)).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.danger)
                                    .accessibilityLabel("Clip error: \(alertClipError)")
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                Picker("Operator priority", selection: Binding(
                    get: { model.operationsAlertReviews[alert.id]?.priority ?? alert.priority },
                    set: { priority in applyAlertReview(alert.id, priority: priority) }
                )) {
                    Text("Normal").tag(OperationsAlertReview.Priority.normal)
                    Text("Critical").tag(OperationsAlertReview.Priority.critical)
                }
                LabeledContent("Operator note") {
                    TextField("Note", text: $alertReviewNote, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Operator note")
                }
                HStack {
                    Button {
                        applyAlertReview(alert.id, note: alertReviewNote)
                    } label: { Label("Save note", systemImage: "square.and.arrow.down") }
                    .disabled(alertReviewNote.count > 2000)
                    if model.operationsAlertReviews[alert.id]?.status == .resolved {
                        Button { applyAlertReview(alert.id, status: .open) } label: {
                            Label("Reopen", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button { applyAlertReview(alert.id, status: .resolved, note: alertReviewNote) } label: {
                            Label("Resolve", systemImage: "checkmark.seal")
                        }
                        .disabled(alertReviewNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || alertReviewNote.count > 2000)
                    }
                }
                if !alertReviewError.isEmpty {
                    Text(languageSettings.localizedMessage(alertReviewError)).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.danger)
                        .accessibilityLabel("Alert review error: \(alertReviewError)")
                }
                DisclosureGroup("Recent review history") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(alertReviewAudit.suffix(100).enumerated()), id: \.offset) { _, review in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(review.updatedAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)) · \(languageSettings.localized(review.priority.rawValue)) · \(languageSettings.localized(review.status.rawValue))")
                                    if !review.note.isEmpty { Text(review.note).textSelection(.enabled) }
                                }
                                .font(.system(size: ACTAType.caption))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack {
                if model.featurePreferences.enabledFeatures.contains(.operationalAlerts),
                   model.operationsAlertReviews[alert.id]?.status != .resolved {
                    Button(model.operationsAlertAcknowledgements[alert.id] == nil ? "Acknowledge" : "Undo acknowledgement") {
                        if model.operationsAlertAcknowledgements[alert.id] == nil {
                            model.acknowledgeVLMAlert(alert.id)
                        } else {
                            model.unacknowledgeVLMAlert(alert.id)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(ACTATheme.actionFill)
                }
                Spacer()
                Button("Close") { selectedAlert = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        }
        .frame(width: 440, height: min(640, max(320, (NSScreen.main?.visibleFrame.height ?? 740) - 100)))
        .background(ACTATheme.background)
        .onAppear {
            alertReviewNote = model.operationsAlertReviews[alert.id]?.note ?? ""
            alertReviewError = ""
            loadAlertReviewAudit(alert.id)
            alertClipFrames = []
            alertClipFrameIndex = 0
            alertClipError = ""
        }
        .onChange(of: model.operationsAlertReviews[alert.id]) { _, _ in loadAlertReviewAudit(alert.id) }
    }

    private func loadAlertClip(_ alert: VLMAlert) {
        do {
            alertClipFrames = try model.alertClipFrames(for: alert)
            alertClipFrameIndex = 0
            alertClipError = ""
        } catch { alertClipError = "Saved lookback frames are unavailable or expired" }
    }

    private func loadAlertReviewAudit(_ alertID: UUID) {
        do { alertReviewAudit = try model.operationsAlertReviewAudit(alertID) }
        catch { alertReviewError = error.localizedDescription }
    }

    private func applyAlertReview(
        _ id: UUID, priority: OperationsAlertReview.Priority? = nil,
        status: OperationsAlertReview.Status? = nil, note: String? = nil
    ) {
        do {
            try model.updateOperationsAlertReview(id, priority: priority, status: status, note: note)
            alertReviewError = ""
        } catch { alertReviewError = error.localizedDescription }
    }

    private func exportOperationsReport() {
        let panel = NSSavePanel()
        InterfaceLocalization.configure(panel, title: "Export operations report", language: languageSettings.language)
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "CameraWall-operations.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(model.operationsReportHTML().utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { model.notice = "Operations report could not be exported" }
    }

    private func toggleFavorite(_ camera: Camera) {
        var favorites = favoriteIDs
        if favorites.contains(camera.id) { favorites.remove(camera.id) }
        else { favorites.insert(camera.id) }
        favoritesStorage = favorites.map(\.uuidString).sorted().joined(separator: ",")
    }
}

private struct DateTimeReadout: View {
    @Environment(\.locale) private var locale
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year(.twoDigits).locale(locale)))
            }
            .font(.system(size: ACTAType.caption, weight: .medium))
            .foregroundStyle(ACTATheme.textSecondary)
            Text(Date.now, style: .time)
                .font(.system(size: 21, weight: .bold).monospacedDigit())
                .foregroundStyle(ACTATheme.textPrimary)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current date and time")
    }
}

private struct ACTACameraListRow: View {
    let camera: Camera
    @ObservedObject var tile: TileState
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let expand: () -> Void
    let edit: () -> Void
    let reconnect: () -> Void
    let snapshot: () -> Void
    let remove: () -> Void
    let toggleYOLO: (Bool) -> Void
    let toggleAIChat: (Bool) -> Void

    @Environment(\.locale) private var locale
    private var appLanguage: AppLanguage { locale.appLanguage }

    var body: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                VideoView(frame: tile.frame, stale: tile.stale)
                if tile.stale {
                    Label("OFFLINE", systemImage: "video.slash")
                        .font(.system(size: ACTAType.metadata, weight: .bold))
                        .foregroundStyle(ACTATheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ACTATheme.surfaceElevated, in: Capsule())
                        .padding(8)
                }
            }
            .frame(width: 216, height: 122)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text(camera.name).font(.system(size: ACTAType.body, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Circle().fill(tile.stale ? ACTATheme.textMuted : ACTATheme.success).frame(width: 8, height: 8)
                    Text(LocalizedStringKey(tile.stale ? "Offline" : "Live"))
                        .font(.system(size: ACTAType.caption, weight: .medium))
                        .foregroundStyle(tile.stale ? ACTATheme.textSecondary : ACTATheme.success)
                    if !tile.stale {
                        Text("· \(tile.frame.width)×\(tile.frame.height)")
                        Text("· \(tile.frame.measuredFPS.formatted(.number.precision(.fractionLength(1)))) FPS")
                    }
                }
                .font(.system(size: ACTAType.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(ACTATheme.textSecondary)
                if !tile.objects.isEmpty {
                    Text(appLanguage.localized("%lld objects detected", arguments: [tile.objects.count]))
                        .font(.system(size: ACTAType.caption, weight: .medium))
                        .foregroundStyle(ACTATheme.primary)
                }
            }
            Spacer(minLength: 8)
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? ACTATheme.warning : ACTATheme.textSecondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help(appLanguage.localized(isFavorite ? "Remove from favorites" : "Add to favorites"))
            .accessibilityLabel(appLanguage.localized(isFavorite ? "Remove %@ from favorites" : "Add %@ to favorites", arguments: [camera.name]))
            Menu {
                Button("Open camera", systemImage: "arrow.up.left.and.arrow.down.right", action: expand)
                Button("Edit", systemImage: "pencil", action: edit)
                Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
                Button("Snapshot", systemImage: "camera", action: snapshot).disabled(tile.stale)
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 40, height: 40)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(appLanguage.localized("Actions for %@", arguments: [camera.name]))
        }
        .padding(12)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
    }
}