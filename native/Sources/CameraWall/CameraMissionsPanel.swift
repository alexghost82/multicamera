import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CameraCore

struct CameraMissionsPanel: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @Environment(\.openUnifiedChat) private var openUnifiedChat
    @State private var selectedCameraID: UUID?
    @State private var name = ""
    @State private var brief = ""
    @State private var intervalSeconds = 3600
    @State private var scheduleKind = CameraMissionScheduleKind.interval
    @State private var clockTime = "09:00"
    @State private var selectedWeekdays: Set<Int> = []
    @State private var timeZoneIdentifier = TimeZone.current.identifier
    @State private var editingMissionID: UUID?
    @State private var errorMessage = ""
    @State private var consultDrafts: [UUID: String] = [:]
    @State private var consultErrors: [UUID: String] = [:]

    private var enabled: Bool { model.featurePreferences.enabledFeatures.contains(.scheduledMissions) }
    private var availableCameras: [Camera] { model.config.cameras.filter(\.enabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scheduled local missions")
                        .font(.system(size: ACTAType.body, weight: .semibold))
                    Text("Up to four fresh frames per run · local VLM · no retained frames")
                        .font(.system(size: ACTAType.metadata))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Toggle("Enable missions", isOn: Binding(
                    get: { enabled },
                    set: { value in
                        do { try model.setFeatureEnabled(.scheduledMissions, enabled: value) }
                        catch { errorMessage = error.localizedDescription }
                    }
                ))
                .toggleStyle(.switch)
                .accessibilityLabel("Enable scheduled local missions")
            }

            if enabled {
                if availableCameras.isEmpty {
                    Text("Enable a camera to create a mission.")
                        .font(.system(size: ACTAType.caption))
                        .foregroundStyle(ACTATheme.textMuted)
                                    .font(.system(size: ACTAType.metadata))
                                    .foregroundStyle(ACTATheme.textSecondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Camera")
                            Picker("Camera", selection: $selectedCameraID) {
                                ForEach(availableCameras) { camera in
                                    Text(camera.name).tag(Optional(camera.id))
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Camera for new mission")
                        }
                        GridRow {
                            Text("Mission name")
                            TextField("Name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Mission name")
                        }
                        GridRow {
                            Text("Inspection brief")
                            TextField("Describe what to inspect", text: $brief, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Inspection brief")
                        }
                        GridRow {
                            Text("Schedule")
                            Picker("Schedule", selection: $scheduleKind) {
                                Text("Interval").tag(CameraMissionScheduleKind.interval)
                                Text("Clock time").tag(CameraMissionScheduleKind.clock)
                            }
                            .labelsHidden()
                            .accessibilityLabel("Mission schedule type")
                        }
                        if scheduleKind == .interval {
                            GridRow {
                                Text("Interval")
                                Stepper(
                                    "\(intervalSeconds / 60) minutes",
                                    value: $intervalSeconds,
                                    in: CameraMission.minimumIntervalSeconds...CameraMission.maximumIntervalSeconds,
                                    step: 60
                                )
                                .accessibilityLabel("Mission interval in minutes")
                            }
                        } else {
                            GridRow {
                                Text("Time")
                                TextField("HH:mm", text: $clockTime)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Mission clock time, 24-hour HH:mm")
                            }
                            GridRow {
                                Text("Time zone")
                                TextField("Area/Location", text: $timeZoneIdentifier)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Mission time zone identifier")
                            }
                            GridRow {
                                Text("Weekdays")
                                HStack(spacing: 4) {
                                    ForEach(0..<7, id: \.self) { weekday in
                                        Toggle(weekdayShortName(weekday), isOn: Binding(
                                            get: { selectedWeekdays.contains(weekday) },
                                            set: { selected in
                                                if selected { selectedWeekdays.insert(weekday) }
                                                else { selectedWeekdays.remove(weekday) }
                                            }
                                        ))
                                        .toggleStyle(.button)
                                        .accessibilityLabel(weekdayFullName(weekday))
                                    }
                                }
                            }
                        }
                    }
                    .font(.system(size: ACTAType.caption))
                    .foregroundStyle(ACTATheme.textSecondary)

                    HStack {
                        if !errorMessage.isEmpty {
                            Text(locale.appLanguage.localizedMessage(errorMessage))
                                .font(.system(size: ACTAType.metadata))
                                .foregroundStyle(ACTATheme.danger)
                                .accessibilityLabel("Mission error: \(errorMessage)")
                        }
                        Spacer()
                        Button(action: saveMission) {
                            Label(editingMissionID == nil ? "Add mission" : "Save changes",
                                  systemImage: editingMissionID == nil ? "plus" : "checkmark")
                        }
                        .disabled(selectedCameraID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help(editingMissionID == nil
                              ? "Save a disabled mission; enable its schedule separately"
                              : "Save changes to this mission")
                        if editingMissionID != nil {
                            Button("Cancel edit", action: cancelEdit)
                                .buttonStyle(.borderless)
                        }
                    }
                }

                ForEach(model.cameraMissions) { mission in
                    missionRow(mission)
                    if mission.id != model.cameraMissions.last?.id {
                        Rectangle().fill(ACTATheme.border).frame(height: 1)
                    }
                }

                if !model.cameraMissionRuns.isEmpty {
                    HStack {
                        Text("RECENT RUNS")
                            .font(.system(size: ACTAType.metadata, weight: .semibold))
                            .foregroundStyle(ACTATheme.textMuted)
                        Spacer()
                        Button("Export HTML report", action: exportReport)
                            .font(.system(size: ACTAType.metadata, weight: .medium))
                            .help("Save a local report with mission summaries only; no images are included")
                        Button("Export PDF", action: exportPDFReport)
                            .font(.system(size: ACTAType.metadata, weight: .medium))
                            .help("Save a private PDF with mission summaries only; no images are included")
                    }
                    .padding(.top, 8)
                    ForEach(Array(model.cameraMissionRuns.reversed().prefix(10))) { run in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: run.status == .completed ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(run.status == .completed ? ACTATheme.success : ACTATheme.warning)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(run.missionName) · \(cameraName(for: run.cameraID))")
                                    .font(.system(size: ACTAType.metadata, weight: .medium))
                                    .foregroundStyle(ACTATheme.textPrimary)
                                Text(run.summary)
                                    .font(.system(size: ACTAType.metadata))
                                    .foregroundStyle(ACTATheme.textSecondary)
                                    .textSelection(.enabled)
                                if let score = run.sceneChangeScore {
                                    Text("Pixel change: \(score.formatted(.percent.precision(.fractionLength(1))))")
                                        .font(.system(size: ACTAType.metadata).monospacedDigit())
                                        .foregroundStyle(ACTATheme.textSecondary)
                                }
                                Text(run.occurredAt.formatted(date: .abbreviated, time: .shortened, locale: locale))
                                    .font(.system(size: ACTAType.metadata).monospacedDigit())
                                    .foregroundStyle(ACTATheme.textMuted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(14)
        .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ACTATheme.border, lineWidth: 1))
        .onAppear {
            if selectedCameraID == nil { selectedCameraID = availableCameras.first?.id }
        }
    }

    private func missionRow(_ mission: CameraMission) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: ACTASpacing.regular) {
            Toggle(mission.name, isOn: Binding(
                get: { model.cameraMissions.first(where: { $0.id == mission.id })?.enabled ?? false },
                set: { updateMission(mission, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .accessibilityLabel("Enable mission \(mission.name)")
            VStack(alignment: .leading, spacing: 4) {
                Text("\(cameraName(for: mission.cameraID)) · every \(mission.intervalSeconds / 60) min")
                    .font(.system(size: ACTAType.metadata, weight: .medium))
                    .foregroundStyle(ACTATheme.textSecondary)
                Text(mission.brief)
                    .font(.system(size: ACTAType.metadata))
                    .foregroundStyle(ACTATheme.textMuted)
                    .lineLimit(2)
                if let lastRunAt = mission.lastRunAt {
                    Text("Last run \(lastRunAt.formatted(date: .abbreviated, time: .shortened, locale: locale)) · next \(mission.nextRunAt.formatted(date: .omitted, time: .shortened, locale: locale))")
                        .font(.system(size: ACTAType.metadata).monospacedDigit())
                        .foregroundStyle(ACTATheme.textMuted)
                } else {
                    Text("First run \(mission.nextRunAt.formatted(date: .abbreviated, time: .shortened, locale: locale))")
                        .font(.system(size: ACTAType.metadata).monospacedDigit())
                        .foregroundStyle(ACTATheme.textMuted)
                }
                if let lastResult = mission.lastResult {
                    Text(lastResult)
                        .font(.system(size: ACTAType.metadata))
                        .foregroundStyle(ACTATheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.runCameraMissionNow(mission.id)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!mission.enabled || !model.running || model.connecting || model.vlmBusy
                      || model.tiles[mission.cameraID]?.stale != false)
            .help("Run mission once now using up to four fresh frames from a connected camera")
            .accessibilityLabel("Run mission \(mission.name) now")
            Button {
                beginEditing(mission)
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Edit mission \(mission.name)")
            .accessibilityLabel("Edit mission \(mission.name)")
            Button(role: .destructive) { model.deleteCameraMission(mission.id) } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Delete mission \(mission.name)")
            .accessibilityLabel("Delete mission \(mission.name)")
        }
        .padding(.top, 8)
            DisclosureGroup("Consult saved run history · \(missionConsults(for: mission.id).count)") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Previous mission conversation. Ask new questions in the unified chat.")
                        .font(.system(size: ACTAType.metadata))
                        .foregroundStyle(ACTATheme.textSecondary)
                    if missionConsults(for: mission.id).isEmpty {
                        Text("No consult messages yet.")
                            .font(.system(size: ACTAType.metadata))
                            .foregroundStyle(ACTATheme.textMuted)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(missionConsults(for: mission.id)) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(LocalizedStringKey(message.role == .operatorMessage ? "Operator" : "Local assistant"))
                                            .font(.system(size: ACTAType.metadata, weight: .semibold))
                                            .foregroundStyle(ACTATheme.textMuted)
                                        Text(message.text)
                                            .font(.system(size: ACTAType.caption))
                                            .foregroundStyle(ACTATheme.textPrimary)
                                            .textSelection(.enabled)
                                        Text(message.createdAt.formatted(date: .abbreviated, time: .shortened, locale: locale))
                                            .font(.system(size: ACTAType.metadata).monospacedDigit())
                                            .foregroundStyle(ACTATheme.textMuted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(ACTATheme.surface, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                    Button("Discuss in unified chat", systemImage: "bubble.left.and.bubble.right") {
                        openUnifiedChat(locale.appLanguage.localized("Review the saved findings of mission %@", arguments: [mission.name]))
                    }
                }
                .padding(.vertical, 8)
            }
            .font(.system(size: ACTAType.metadata, weight: .medium))
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func missionConsults(for missionID: UUID) -> [CameraMissionConsultMessage] {
        model.cameraMissionConsultMessages.filter { $0.missionID == missionID }
    }

    private func binding(for missionID: UUID) -> Binding<String> {
        Binding(
            get: { consultDrafts[missionID, default: ""] },
            set: { consultDrafts[missionID] = String($0.prefix(2000)) }
        )
    }

    private func askMissionConsult(_ missionID: UUID) {
        do {
            try model.askMissionConsult(missionID: missionID, question: consultDrafts[missionID, default: ""])
            consultDrafts[missionID] = ""
            consultErrors[missionID] = ""
        } catch { consultErrors[missionID] = error.localizedDescription }
    }

    private func clearMissionConsult(_ missionID: UUID) {
        do {
            try model.clearMissionConsult(missionID: missionID)
            consultErrors[missionID] = ""
        } catch { consultErrors[missionID] = "Mission consult history could not be cleared" }
    }

    private func saveMission() {
        guard let selectedCameraID else { return }
        do {
            let existing = editingMissionID.flatMap { id in model.cameraMissions.first(where: { $0.id == id }) }
            let clockTimes = scheduleKind == .clock ? [clockTime] : []
            let weekdays = selectedWeekdays.sorted()
            let scheduleChanged = existing.map {
                $0.scheduleKind != scheduleKind
                    || $0.clockTimes != clockTimes
                    || $0.weekdays != weekdays
                    || $0.timeZoneIdentifier != timeZoneIdentifier
                    || (scheduleKind == .interval && $0.intervalSeconds != intervalSeconds)
            } ?? false
            var nextRunAt = existing?.nextRunAt
            if scheduleChanged { nextRunAt = nil }
            let mission = try CameraMission(
                id: existing?.id ?? UUID(),
                cameraID: selectedCameraID,
                name: name,
                brief: brief,
                intervalSeconds: intervalSeconds,
                scheduleKind: scheduleKind,
                clockTimes: clockTimes,
                weekdays: weekdays,
                timeZoneIdentifier: timeZoneIdentifier,
                enabled: existing?.enabled ?? false,
                createdAt: existing?.createdAt ?? Date(),
                scheduleReferenceDate: scheduleChanged ? Date() : (existing?.createdAt ?? Date()),
                nextRunAt: nextRunAt,
                lastRunAt: existing?.lastRunAt,
                lastResult: existing?.lastResult
            )
            try model.saveCameraMission(mission)
            name = ""
            brief = ""
            scheduleKind = .interval
            selectedWeekdays = []
            editingMissionID = nil
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginEditing(_ mission: CameraMission) {
        editingMissionID = mission.id
        selectedCameraID = mission.cameraID
        name = mission.name
        brief = mission.brief
        intervalSeconds = mission.intervalSeconds
        scheduleKind = mission.scheduleKind
        clockTime = mission.clockTimes.first ?? "09:00"
        selectedWeekdays = Set(mission.weekdays)
        timeZoneIdentifier = mission.timeZoneIdentifier
        errorMessage = ""
    }

    private func cancelEdit() {
        editingMissionID = nil
        name = ""
        brief = ""
        intervalSeconds = 3600
        scheduleKind = .interval
        clockTime = "09:00"
        selectedWeekdays = []
        timeZoneIdentifier = TimeZone.current.identifier
        errorMessage = ""
    }

    private func updateMission(_ mission: CameraMission, enabled: Bool) {
        do {
            let updated = try CameraMission(
                id: mission.id,
                cameraID: mission.cameraID,
                name: mission.name,
                brief: mission.brief,
                intervalSeconds: mission.intervalSeconds,
                scheduleKind: mission.scheduleKind,
                clockTimes: mission.clockTimes,
                weekdays: mission.weekdays,
                timeZoneIdentifier: mission.timeZoneIdentifier,
                enabled: enabled,
                createdAt: mission.createdAt,
                nextRunAt: mission.nextRunAt,
                lastRunAt: mission.lastRunAt,
                lastResult: mission.lastResult
            )
            try model.saveCameraMission(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cameraName(for cameraID: UUID) -> String {
        model.config.cameras.first(where: { $0.id == cameraID })?.name ?? "Unavailable camera"
    }

    private func exportReport() {
        let panel = NSSavePanel()
        InterfaceLocalization.configure(panel, title: "Export HTML report", language: locale.appLanguage)
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "camerawall-mission-report.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let html = CameraMissionRun.CameraMissionReport.renderHTML(runs: model.cameraMissionRuns)
            try Data(html.utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            errorMessage = ""
        } catch {
            errorMessage = "Mission report could not be saved"
        }
    }

    private func exportPDFReport() {
        let panel = NSSavePanel()
        InterfaceLocalization.configure(panel, title: "Export PDF", language: locale.appLanguage)
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "camerawall-mission-report.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CameraMissionRun.CameraMissionReport.renderPDF(runs: model.cameraMissionRuns, to: url)
            errorMessage = ""
        } catch {
            errorMessage = "Mission report could not be saved"
        }
    }

    private func weekdayShortName(_ weekday: Int) -> String {
        locale.appLanguage.localized(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][weekday])
    }

    private func weekdayFullName(_ weekday: Int) -> String {
        locale.appLanguage.localized(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][weekday])
    }
}