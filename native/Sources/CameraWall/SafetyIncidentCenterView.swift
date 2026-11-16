import SwiftUI
import CameraCore

struct SafetyIncidentCenterView: View {
    @ObservedObject var engine: LocalVideoAnalyticsEngine
    @ObservedObject var languageSettings: LanguageSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var cameraID: UUID?
    @State private var openOnly = true
    @State private var query = ""

    private var filtered: [SafetyIncident] {
        engine.incidents.filter {
            (!openOnly || $0.status.isOpen) && (cameraID == nil || cameraID == $0.cameraID)
                && (query.isEmpty || [$0.cameraName, languageSettings.localizedMessage($0.title), $0.explanation, $0.operatorNotes]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(languageSettings.localized("Safety incidents")).font(.title2.weight(.semibold))
                Spacer()
                Button(languageSettings.localized("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 12) {
                TextField(languageSettings.localized("Search incidents"), text: $query).textFieldStyle(.roundedBorder)
                Picker(languageSettings.localized("Camera"), selection: $cameraID) {
                    Text(languageSettings.localized("All cameras")).tag(Optional<UUID>.none)
                    ForEach(Array(Dictionary(grouping: engine.incidents, by: \.cameraID).keys).sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        Text(engine.incidents.first { $0.cameraID == id }?.cameraName ?? id.uuidString).tag(Optional(id))
                    }
                }
                .frame(width: 240)
                Toggle(languageSettings.localized("Open incidents only"), isOn: $openOnly).toggleStyle(.checkbox)
            }
            if let error = engine.persistenceError {
                Label(languageSettings.localizedMessage(error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HSplitView {
                List(selection: $selectedID) {
                    ForEach(filtered) { incident in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(languageSettings.localizedMessage(incident.title)).font(.system(size: 13, weight: .semibold))
                            Text(incident.cameraName).font(.system(size: 12))
                            Text(languageSettings.localized(incident.status.rawValue))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .tag(incident.id)
                    }
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
                if let incident = engine.incidents.first(where: { $0.id == selectedID }) {
                    SafetyIncidentDetailView(engine: engine, languageSettings: languageSettings, incident: incident)
                        .id(incident.id)
                        .frame(minWidth: 450, maxWidth: .infinity)
                } else {
                    ContentUnavailableView(languageSettings.localized("No incident selected"), systemImage: "checkmark.shield",
                        description: Text(languageSettings.localized("Select an incident or change the filters.")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 620)
        .font(.system(size: 13))
        .environment(\.locale, languageSettings.locale)
        .onAppear { selectedID = filtered.first?.id }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = ids.first }
            else if selectedID == nil { selectedID = ids.first }
        }
    }
}
