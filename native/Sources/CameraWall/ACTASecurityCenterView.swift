import AppKit
import SwiftUI
import CameraCore

enum ACTATheme {
    static let background = Color(actaHex: 0x020B13)
    static let sidebar = Color(actaHex: 0x04111D)
    static let surface = Color(actaHex: 0x061827)
    static let surfaceElevated = Color(actaHex: 0x092135)
    static let surfaceHover = Color(actaHex: 0x102C3E)
    static let border = Color(actaHex: 0x24475B)
    static let borderActive = Color(actaHex: 0xFFD000)
    static let selected = Color(actaHex: 0xFFD000).opacity(0.14)
    static let primary = Color(actaHex: 0xFFD000)
    static let secondaryAccent = Color(actaHex: 0x00CBEF)
    static let textPrimary = Color(actaHex: 0xF5F8FC)
    static let textSecondary = Color(actaHex: 0xAAB8C7)
    static let textMuted = Color(actaHex: 0x748899)
    static let success = Color(actaHex: 0x16F228)
    static let danger = Color(actaHex: 0xFF263C)
    static let warning = Color(actaHex: 0xFFCC00)
}

struct AnalysisSidebarSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(SidebarContentBounds())
            .background(ACTATheme.sidebar, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(ACTATheme.textPrimary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false))
    }
}

struct SidebarContentBounds: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: max(0, geometry.size.width), height: max(0, geometry.size.height), alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .contentShape(.interaction, RoundedRectangle(cornerRadius: 18))
        }
    }
}

extension Color {
    init(actaHex: UInt32) {
        self.init(
            red: Double((actaHex >> 16) & 0xFF) / 255,
            green: Double((actaHex >> 8) & 0xFF) / 255,
            blue: Double(actaHex & 0xFF) / 255
        )
    }
}

private enum ACTASection: String, CaseIterable, Identifiable {
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
    var showSettings: () -> Void
    var editCamera: (Camera) -> Void
    var removeCamera: (Camera) -> Void

    @AppStorage("ACTA.favoriteCameraIDs") private var favoritesStorage = ""
    @State private var section: ACTASection = .cameras
    @State private var cameraScope: ACTACameraScope = .all
    @State private var presentation: ACTACameraPresentation = .grid
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

    private let sidebarWidth: CGFloat = 228
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
        GeometryReader { geometry in
            let collapsed = geometry.size.width < 1200
            HStack(spacing: 0) {
                sidebar(collapsed: collapsed)
                Rectangle().fill(ACTATheme.border).frame(width: 1)
                VStack(spacing: 0) {
                    header(compact: geometry.size.width < 1440 || cameraPickerPresented || aiChatPresented)
                    Rectangle().fill(ACTATheme.border).frame(height: 1)
                    ModelRuntimeView(runtime: model.modelRuntime, vlmBusy: model.vlmBusy, retry: model.prepareModels)
                    Rectangle().fill(ACTATheme.border).frame(height: 1)
                    mainContent
                    if section == .cameras { activityStrip }
                    if section != .cameras { statusFooter }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ACTATheme.background)
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
        .frame(minWidth: 1280, minHeight: 800)
        .foregroundStyle(ACTATheme.textPrimary)
        .preferredColorScheme(.dark)
        .sheet(item: $selectedAlert) { alert in
            alertDetail(alert)
        }
    }

    private func sidebar(collapsed: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                logoMark(size: collapsed ? 36 : 38)
                if !collapsed {
                    Text("A C T A")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ACTATheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, collapsed ? 13 : 14)
            .frame(height: 68)

            Rectangle().fill(ACTATheme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 4) {
                        ForEach(ACTASection.allCases) { destination in
                            sidebarButton(destination, collapsed: collapsed)
                        }
                    }

                    if !collapsed {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("LOCATIONS")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(ACTATheme.textMuted)
                                Spacer()
                                Button(action: showCameraManager) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .help("Manage cameras and locations")
                                .accessibilityLabel("Manage cameras and locations")
                            }
                            .padding(.leading, 14)
                            .padding(.trailing, 8)

                            locationButton(name: "All Locations", count: enabledCameras.count, icon: "square.grid.2x2", collapsed: false)
                            ForEach(locationGroups) { group in
                                locationButton(name: group.name, count: group.count, icon: locationIcon(for: group.name), collapsed: false)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }

            statusPanel(collapsed: collapsed)
        }
        .frame(width: collapsed ? collapsedSidebarWidth : sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(ACTATheme.sidebar)
        .overlay(Color.white.opacity(0.08).allowsHitTesting(false))
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
                    .frame(width: 10, height: 10)
                if !collapsed {
                    Text(LocalizedStringKey(model.running ? "Online" : "Disconnected"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.running ? ACTATheme.success : ACTATheme.warning)
                }
            }
            if !collapsed {
                Text(languageSettings.localized("%lld / %lld Cameras", arguments: [onlineCameras.count, enabledCameras.count]))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
                    .lineLimit(1)
                Text(LocalizedStringKey(offlineCount == 0 && model.running ? "All systems operational" : "Check camera connections"))
                    .font(.system(size: 11))
                    .foregroundStyle(ACTATheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ACTATheme.border, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func locationButton(name: String, count: Int, icon: String, collapsed: Bool) -> some View {
        let selected = locationFilter == (name == "All Locations" ? nil : name)
        return Button {
            section = .cameras
            locationFilter = name == "All Locations" ? nil : name
            cameraScope = .all
            alertsOnly = false
            favoritesOnly = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                if !collapsed {
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? ACTATheme.textPrimary : ACTATheme.textMuted)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 22)
                        .background(selected ? ACTATheme.primary : ACTATheme.surfaceElevated, in: Capsule())
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
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
        .accessibilityLabel(languageSettings.localized("%@, %lld cameras", arguments: [name, count]))
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
            HStack(spacing: 12) {
                Image(systemName: destination.icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)
                if !collapsed {
                    Text(destination.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if destination == .cameras && model.config.cameras.count > 0 {
                        sidebarBadge(model.config.cameras.count, color: ACTATheme.textMuted)
                    } else if destination == .events && (!model.vlmAlerts.isEmpty || !model.isapiEvents.isEmpty) {
                        sidebarBadge(model.vlmAlerts.count + model.isapiEvents.count, color: ACTATheme.danger)
                    }
                }
            }
            .foregroundStyle(isSelected ? ACTATheme.textPrimary : ACTATheme.textSecondary)
            .frame(height: 44)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ACTATheme.selected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if isSelected { RoundedRectangle(cornerRadius: 2).fill(ACTATheme.primary).frame(width: 3, height: 24) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? destination.title : "")
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func settingsSidebarButton(collapsed: Bool) -> some View {
        Button(action: showSettings) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 20)
                if !collapsed {
                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(ACTATheme.textSecondary)
            .frame(height: 44)
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
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Security Center")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                Text(languageSettings.localized("Intelligent monitoring and analysis"))
                    .font(.system(size: 11))
                    .foregroundStyle(ACTATheme.textSecondary)
                    .lineLimit(2)
                Button { model.running ? model.stop() : model.start() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.running ? ACTATheme.success : ACTATheme.warning)
                            .frame(width: 7, height: 7)
                        Text(LocalizedStringKey(model.running ? "Live" : "Connect"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.running ? ACTATheme.success : ACTATheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .help(languageSettings.localized(model.running ? "Disconnect cameras" : "Connect cameras"))
                .accessibilityLabel(languageSettings.localized(model.running ? "Disconnect cameras" : "Connect cameras"))
            }
            .frame(minWidth: compact ? 126 : 164, alignment: .leading)
            Spacer(minLength: compact ? 4 : 12)

            if section == .cameras {
                if !compact { DateTimeReadout().frame(height: 40).fixedSize(horizontal: true, vertical: false) }
                searchField(compact: compact)
                cameraToolbar(compact: compact)
            } else {
                if !compact { DateTimeReadout().frame(height: 40).fixedSize(horizontal: true, vertical: false) }
            }

            cameraPickerButton(compact: compact)
            notificationsButton
            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 40, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized("Settings"))
            .accessibilityLabel(languageSettings.localized("Settings"))
            Button(action: languageSettings.toggle) {
                Text(languageSettings.language.buttonTitle)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 48, height: 40)
                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(languageSettings.localized(languageSettings.language.switchLabelKey))
            .accessibilityLabel(languageSettings.localized(languageSettings.language.switchLabelKey))
            moreMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(ACTATheme.border, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
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
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 10)
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
                        model.setGridColumns(columns)
                    } label: {
                        if model.config.columns == columns {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
                Divider()
                Button(languageSettings.localized("Custom…"), action: showSettings)
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
                HStack(spacing: 7) {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                    if !compact { Text("Favorites").font(.system(size: 12, weight: .medium)) }
                }
                .foregroundStyle(favoritesOnly ? ACTATheme.warning : ACTATheme.textSecondary)
                .padding(.horizontal, 10)
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
            HStack(spacing: 7) {
                Image(systemName: "video.badge.ellipsis")
                if !compact { Text("Cameras").font(.system(size: 12, weight: .medium)) }
                Text("\(selectedCameraCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(ACTATheme.primary.opacity(0.22), in: Capsule())
            }
            .foregroundStyle(cameraPickerPresented ? ACTATheme.textPrimary : ACTATheme.textSecondary)
            .padding(.horizontal, 10)
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Select cameras")
                        .font(.system(size: 16, weight: .semibold))
                    Text(languageSettings.localized("%lld of %lld selected", arguments: [selectedCameraCount, enabledCameras.count]))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button { toggleCameraPicker() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
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
            .font(.system(size: 12, weight: .semibold))

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
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(ACTATheme.textMuted)
                                            .padding(.horizontal, 10)
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
        .background(ACTATheme.sidebar.opacity(0.42), in: RoundedRectangle(cornerRadius: 18))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ACTATheme.textPrimary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 10)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ACTATheme.textPrimary)
                        .lineLimit(1)
                    Text(LocalizedStringKey(model.tiles[camera.id]?.stale == false ? "Live" : "Offline"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSelected ? ACTATheme.primary : ACTATheme.textMuted)
            }
            .padding(.horizontal, 10)
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Analysis")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Ask about live camera scenes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer(minLength: 0)
                Button { aiChatPresented = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onExitCommand { aiChatPresented = false }
        .accessibilityLabel("AI analysis chat panel")
    }

    private var moreMenu: some View {
        Menu {
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
            Button("Settings", systemImage: "gearshape", action: showSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
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
            if presentation == .grid { liveTimelineRail }
            VStack(spacing: 0) {
            if model.config.cameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras added", systemImage: "video")
                } description: {
                    Text("Add a network camera or a Mac / iPhone camera to begin.")
                } actions: {
                    Button("Add camera", action: addNetworkCamera)
                        .buttonStyle(.borderedProminent)
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
                VideoCanvas(model: model, cameras: filteredCameras, arrangeCameras: arrangeCameras,
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
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
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
                Toggle("In-app health monitor", isOn: Binding(
                    get: { model.featurePreferences.enabledFeatures.contains(.independentWatcher) },
                    set: { enabled in
                        do { try model.setFeatureEnabled(.independentWatcher, enabled: enabled) }
                        catch { model.notice = "Could not save local monitor setting" }
                    }
                ))
                .toggleStyle(.switch)
                .help("Checks camera feeds, local relay and track storage while CameraWall is open. No restart or network access.")
                Toggle("Enable local operations alerts", isOn: Binding(
                    get: { model.featurePreferences.enabledFeatures.contains(.operationalAlerts) },
                    set: { enabled in
                        do { try model.setFeatureEnabled(.operationalAlerts, enabled: enabled) }
                        catch { model.notice = "Could not save alert acknowledgement setting" }
                    }
                ))
                .toggleStyle(.switch)
                .help("Enable local person-count alerts and acknowledgement of stored AI alerts")
                if !latestISAPIEvents.isEmpty {
                    Button(role: .destructive) { model.clearISAPIEvents() } label: {
                        Label("Clear camera events", systemImage: "trash")
                    }
                    .help("Delete saved Hikvision camera event metadata")
                }
            }
            HStack {
                Toggle("Critical alert sound", isOn: Binding(
                    get: { model.operationsPreferences.criticalSoundEnabled },
                    set: { enabled in
                        var preferences = model.operationsPreferences
                        preferences.criticalSoundEnabled = enabled
                        do { try model.saveOperationsPreferences(preferences) }
                        catch { model.notice = error.localizedDescription }
                    }
                ))
                .disabled(!model.featurePreferences.enabledFeatures.contains(.operationalAlerts))
                Toggle("Retain alert lookback frames", isOn: Binding(
                    get: { model.featurePreferences.retainFullFrames },
                    set: { enabled in
                        do { try model.setMemoryFrameRetentionEnabled(enabled) }
                        catch { model.notice = error.localizedDescription }
                    }
                ))
                .disabled(!model.featurePreferences.enabledFeatures.contains(.operationalAlerts))
                .help("Required in addition to operations-alert opt-in. Alert frames stay local for up to seven days.")
                Spacer()
                Button(action: exportOperationsReport) {
                    Label("Export operations report", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.featurePreferences.enabledFeatures.contains(.operationalAlerts))
            }
            if model.featurePreferences.enabledFeatures.contains(.independentWatcher) {
                localMonitorPanel
            }
            if model.featurePreferences.enabledFeatures.contains(.operationalAlerts) {
                operationsWatchPanel
            }
            CameraMissionsPanel(model: model)
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ACTATheme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                            ForEach(latestISAPIEvents) { event in isapiEventRow(event) }
                        }
                        if !latestAlerts.isEmpty {
                            Text("AI ALERTS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ACTATheme.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                            ForEach(operationsQueueAlerts) { alert in alertRow(alert) }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ACTATheme.background)
    }

    private var localMonitorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Local monitor: \(languageSettings.localized(model.localMonitorSnapshot.verdict.rawValue.capitalized))",
                      systemImage: model.localMonitorSnapshot.verdict == .fault ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityValue(languageSettings.localized(model.localMonitorSnapshot.verdict.rawValue))
                Spacer()
                if let checkedAt = model.localMonitorSnapshot.checkedAt {
                    Text(checkedAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                        .font(.system(size: 11).monospacedDigit())
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
                            .font(.system(size: 11, weight: .medium))
                        Text(languageSettings.localizedMessage(probe.detail)).font(.system(size: 11)).foregroundStyle(ACTATheme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !model.localMonitorHistory.isEmpty {
                DisclosureGroup("Recent monitor events · \(model.localMonitorHistory.count)") {
                    ForEach(Array(model.localMonitorHistory.suffix(10).reversed())) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(languageSettings.localizedMessage(event.label)) · \(languageSettings.localized(event.kind.rawValue.capitalized))")
                                .font(.system(size: 11, weight: .medium))
                            Text("\(event.occurredAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)) · \(languageSettings.localizedMessage(event.detail))")
                                .font(.system(size: 11)).foregroundStyle(ACTATheme.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("Runs only while this app is open. Read-only; no auto-restart, LaunchAgent, tunnel or external checks.")
                .font(.system(size: 10)).foregroundStyle(ACTATheme.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
    }

    private var operationsWatchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Standing visual watches", systemImage: "eye")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Local descriptions · one alert per track")
                    .font(.system(size: 10)).foregroundStyle(ACTATheme.textMuted)
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
                Text(languageSettings.localizedMessage(watchError)).font(.caption).foregroundStyle(ACTATheme.danger)
                    .accessibilityLabel("Watch rule error: \(watchError)")
            }
            if model.operationsWatchRules.isEmpty {
                Text("No active watch rules.").font(.system(size: 11)).foregroundStyle(ACTATheme.textSecondary)
            } else {
                ForEach(model.operationsWatchRules) { rule in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.text).font(.system(size: 12, weight: .medium))
                            let scope = rule.cameraIDs.isEmpty ? languageSettings.localized("All enabled cameras") : languageSettings.localized("%lld selected cameras", arguments: [rule.cameraIDs.count])
                            let expiry = rule.expiresAt.map { languageSettings.localized("Expires %@", arguments: [$0.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale)]) } ?? languageSettings.localized("No expiry")
                            Text("\(scope) · \(expiry) · \(rule.firedTrackIDs.count) tracks alerted")
                                .font(.system(size: 10)).foregroundStyle(ACTATheme.textMuted)
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
                .font(.system(size: 10)).foregroundStyle(ACTATheme.textMuted)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(event.cameraName, systemImage: "video")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text((event.occurredAt ?? event.receivedAt).formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(ACTATheme.textMuted)
            }
            HStack(spacing: 8) {
                Text(event.eventType)
                    .font(.system(size: 12, weight: .semibold))
                if let state = event.eventState {
                    Text(languageSettings.localized(state.capitalized))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(state.lowercased() == "active" ? ACTATheme.warning : ACTATheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(ACTATheme.surfaceElevated, in: Capsule())
                }
                if let channel = event.channelID {
                    Text(languageSettings.localized("Channel %lld", arguments: [channel])).font(.system(size: 11))
                }
            }
            if let detail = event.eventDescription, !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(ACTATheme.textSecondary).lineLimit(2)
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
        .padding(20)
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
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(ACTATheme.textSecondary)
        }
        .padding(16)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var analysisContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeading("AI Analysis", subtitle: "Local Qwen vision model")
            HStack(spacing: 12) {
                Image(systemName: "cpu").font(.system(size: 18)).foregroundStyle(ACTATheme.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qwen3.5-9B-4bit").font(.system(size: 14, weight: .semibold))
                    Text(languageSettings.localizedMessage(model.vlmStatus)).font(.system(size: 12)).foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Button("Open AI analysis", action: openAIChat).buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
            Text("\(languageSettings.localized(model.vlmPreferences.scheduleEnabled ? "Scheduled checks enabled" : "Scheduled checks off")) · \(languageSettings.localized("%lld active alert conditions", arguments: [model.vlmPreferences.alertRules.filter(\.enabled).count]))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ACTATheme.textSecondary)
            Spacer()
        }
        .padding(20)
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
                    .font(.system(size: 12))
                    .foregroundStyle(ACTATheme.textSecondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ACTATheme.background)
    }

    private func reportMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(ACTATheme.textSecondary)
            Text(value).font(.system(size: 21, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var activityStrip: some View {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let recentAlerts = latestAlerts.filter { $0.createdAt >= cutoff }
        return VStack(spacing: 5) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("AI EVENTS · 24H", systemImage: "waveform.path")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ACTATheme.textSecondary)
                    Text(languageSettings.localized("%lld events", arguments: [recentAlerts.count]))
                        .font(.system(size: 11))
                        .foregroundStyle(ACTATheme.textMuted)
                }
                Spacer(minLength: 8)
                ForEach(latestAlerts.prefix(3)) { alert in
                    Button { selectedAlert = alert } label: {
                        HStack(spacing: 6) {
                            Circle().fill(ACTATheme.primary).frame(width: 7, height: 7)
                            Text(alert.cameraName).lineLimit(1)
                            Text(alert.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(ACTATheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                if !latestAlerts.isEmpty {
                    Button("All events") { section = .events }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(ACTATheme.primary)
                }
            }
            HStack(spacing: 8) {
                Text(cutoff.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ACTATheme.border).frame(height: 6)
                        ForEach(recentAlerts) { alert in
                            let age = min(1, max(0, Date().timeIntervalSince(alert.createdAt) / (24 * 60 * 60)))
                            Button { selectedAlert = alert } label: {
                                Circle().fill(ACTATheme.primary)
                                    .frame(width: 10, height: 10)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(alert.cameraName) · \(alert.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale))")
                            .accessibilityLabel(languageSettings.localized(
                                "AI alert for %@ at %@",
                                arguments: [alert.cameraName, alert.createdAt.formatted(date: .omitted, time: .shortened, locale: languageSettings.locale)]
                            ))
                            .position(x: max(12, min(geometry.size.width - 12, geometry.size.width * (1 - age))),
                                      y: geometry.size.height / 2)
                        }
                    }
                }
                .frame(height: 24)
                Text("Now")
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(ACTATheme.textMuted)
        }
        .padding(.horizontal, 20)
        .frame(height: 78)
        .background(ACTATheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(ACTATheme.border).frame(height: 1) }
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
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ACTATheme.textSecondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(ACTATheme.sidebar)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: 20, weight: .semibold))
            Text(LocalizedStringKey(subtitle)).font(.system(size: 12)).foregroundStyle(ACTATheme.textSecondary)
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
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(alert.cameraName).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(alert.createdAt.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(ACTATheme.textMuted)
                    }
                    Text(alert.condition).font(.system(size: 12, weight: .medium))
                    Text(alert.evidence).font(.system(size: 12)).foregroundStyle(ACTATheme.textSecondary)
                        .lineLimit(2)
                    if let review = model.operationsAlertReviews[alert.id] {
                        Label("\(languageSettings.localized(review.priority.rawValue.capitalized)) · \(languageSettings.localized(review.status.rawValue.capitalized))",
                              systemImage: review.priority == .critical ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(review.priority == .critical ? ACTATheme.warning : ACTATheme.textSecondary)
                    } else if let acknowledgedAt = model.operationsAlertAcknowledgements[alert.id] {
                        Label("Acknowledged · \(acknowledgedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ACTATheme.success)
                    } else if alert.priority == .critical {
                        Label("Critical · Open", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 18, weight: .semibold))
            Text(alert.condition).font(.system(size: 14, weight: .medium))
            Text(alert.evidence).font(.system(size: 14)).foregroundStyle(ACTATheme.textSecondary)
            if let watchID = alert.watchID, let trackID = alert.sourceTrackID {
                Label("Local watch · track \(trackID.uuidString)", systemImage: "eye")
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                    .accessibilityLabel("Local watch alert for per-camera track \(trackID.uuidString), rule \(watchID.uuidString)")
            }
            Text(alert.createdAt.formatted(date: .complete, time: .shortened, locale: languageSettings.locale))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(ACTATheme.textMuted)
            if model.featurePreferences.enabledFeatures.contains(.operationalAlerts) {
                if alert.clipID != nil {
                    DisclosureGroup("Local lookback frames · 8 seconds") {
                        VStack(alignment: .leading, spacing: 10) {
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
                                        .font(.system(size: 11).monospacedDigit())
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
                                Text(languageSettings.localizedMessage(alertClipError)).font(.caption).foregroundStyle(ACTATheme.danger)
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
                    Text(languageSettings.localizedMessage(alertReviewError)).font(.caption).foregroundStyle(ACTATheme.danger)
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
                                .font(.caption)
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
                    .buttonStyle(.borderedProminent)
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
            .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 10, weight: .bold))
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
                Text(camera.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Circle().fill(tile.stale ? ACTATheme.textMuted : ACTATheme.success).frame(width: 8, height: 8)
                    Text(LocalizedStringKey(tile.stale ? "Offline" : "Live"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tile.stale ? ACTATheme.textSecondary : ACTATheme.success)
                    if !tile.stale {
                        Text("· \(tile.frame.width)×\(tile.frame.height)")
                        Text("· \(tile.frame.measuredFPS.formatted(.number.precision(.fractionLength(1)))) FPS")
                    }
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(ACTATheme.textSecondary)
                if !tile.objects.isEmpty {
                    Text(appLanguage.localized("%lld objects detected", arguments: [tile.objects.count]))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ACTATheme.primary)
                }
                HStack(spacing: 14) {
                    Toggle("YOLO", isOn: Binding(get: { camera.yoloEnabled }, set: toggleYOLO))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help(appLanguage.localized("Run YOLO26 on %@", arguments: [camera.name]))
                    Toggle("AI chat", isOn: Binding(get: { camera.aiChatEnabled }, set: toggleAIChat))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help(appLanguage.localized("Include %@ in AI chat", arguments: [camera.name]))
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