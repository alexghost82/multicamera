import AppKit
import SwiftUI
import CameraCore

struct SafetyIncidentEvidenceFrames {
    let frames: [Data]
    let snapshotError: String?
    let clipError: String?

    static func load(store: SafetyEvidenceStore, incidentID: UUID) -> Self {
        var frames: [Data] = []
        var snapshotError: String?
        do {
            if let snapshot = try store.loadSnapshotChecked(for: incidentID) { frames.append(snapshot) }
        } catch {
            snapshotError = error.localizedDescription
        }
        var clipError: String?
        do {
            frames.append(contentsOf: try store.loadClipFramesChecked(for: incidentID))
        } catch {
            clipError = error.localizedDescription
        }
        return Self(frames: frames, snapshotError: snapshotError, clipError: clipError)
    }
}

struct SafetyIncidentDetailView: View {
    @ObservedObject var engine: LocalVideoAnalyticsEngine
    @ObservedObject var languageSettings: LanguageSettings
    let incident: SafetyIncident
    @State private var note = ""
    @State private var images: [Data] = []
    @State private var frameIndex = 0
    @State private var evidenceReadError: String?
    @State private var clipReadError: String?
    @State private var evidenceLoadID = UUID()
    @State private var confirmingFalseAlarm = false
    @State private var confirmingDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(languageSettings.localizedMessage(incident.title)).font(.title3.weight(.semibold))
                Text(incident.cameraName).font(.headline)
                Text(incident.createdAt.formatted(date: .abbreviated, time: .standard, locale: languageSettings.locale))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(languageSettings.localized(incident.severity.rawValue))
                    Text(languageSettings.localized("·"))
                    Text(languageSettings.localized(incident.status.rawValue))
                }
                if let until = incident.suppressedUntil {
                    LabeledContent(languageSettings.localized("Suppressed until"), value: until.formatted(date: .abbreviated, time: .shortened, locale: languageSettings.locale))
                }
                Text(languageSettings.localized("Detector confidence: %lld%%", arguments: [Int(incident.confidence * 100)]))
                    .font(.system(size: ACTAType.caption))
                Text(languageSettings.localizedMessage(incident.explanation)).textSelection(.enabled)
                LabeledContent(languageSettings.localized("Secondary verification"), value: languageSettings.localized(incident.secondaryVLMStatus.rawValue))
                if let summary = incident.secondaryVLMSummary {
                    Text(languageSettings.localizedMessage(summary)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text(languageSettings.localized("Evidence")).font(.headline)
                    Spacer()
                    Button(languageSettings.localized("Refresh evidence")) { Task { await loadEvidence() } }
                }
                if let error = engine.evidenceDeletionError, error.incidentID == incident.id {
                    Label(languageSettings.localizedMessage(error.message), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = evidenceReadError {
                    Label(languageSettings.localized("Cannot read evidence snapshot: %@",
                        arguments: [languageSettings.localizedMessage(error)]), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = clipReadError {
                    Label(languageSettings.localized("Cannot read evidence clip frames: %@",
                        arguments: [languageSettings.localizedMessage(error)]), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if images.indices.contains(frameIndex), let image = NSImage(data: images[frameIndex]) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                        .accessibilityLabel("Incident evidence frame")
                    HStack {
                        Button(languageSettings.localized("Previous frame")) { frameIndex = max(0, frameIndex - 1) }.disabled(frameIndex == 0)
                        Text(languageSettings.localized("Frame %lld of %lld", arguments: [frameIndex + 1, images.count]))
                            .monospacedDigit()
                        Button(languageSettings.localized("Next frame")) { frameIndex = min(images.count - 1, frameIndex + 1) }.disabled(frameIndex + 1 >= images.count)
                    }
                } else if evidenceReadError == nil && clipReadError == nil {
                    Text(languageSettings.localized("No readable evidence frames are available.")).foregroundStyle(.secondary)
                }
                Divider()
                Text(languageSettings.localized("Operator note")).font(.headline)
                TextField(languageSettings.localized("Add an operator note"), text: $note, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder)
                Button(languageSettings.localized("Save note")) { engine.updateIncidentNote(incident.id, note: note) }
                    .disabled(note == incident.operatorNotes || note.count > 4000)
                if incident.status.isOpen {
                    HStack {
                        Button(languageSettings.localized("Acknowledge")) { transition(.acknowledged) }.disabled(incident.status == .acknowledged)
                        Button(languageSettings.localized("Confirm")) { transition(.confirmed) }.disabled(incident.status == .confirmed)
                        Button(languageSettings.localized("Resolve")) { transition(.resolved) }
                    }
                    HStack {
                        Button(languageSettings.localized("Mark as false alarm"), role: .destructive) { confirmingFalseAlarm = true }
                        Button(languageSettings.localized("Suppress for 5 minutes")) {
                            engine.transitionIncident(incident.id, to: .suppressed, note: note, suppressDurationSeconds: 300)
                        }
                    }
                } else {
                    Button(languageSettings.localized("Reopen incident")) { transition(.active) }
                }
                if incident.clipID != nil {
                    Button(languageSettings.localized("Delete evidence"), role: .destructive) { confirmingDeletion = true }
                }
                Text(incident.id.uuidString).font(.system(size: ACTAType.metadata, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(ACTATheme.surface)
        .task(id: incident.clipID ?? incident.id) { await loadEvidence() }
        .onAppear { note = incident.operatorNotes }
        .confirmationDialog(languageSettings.localized("Mark this incident as a false alarm?"), isPresented: $confirmingFalseAlarm) {
            Button(languageSettings.localized("Mark as false alarm"), role: .destructive) { transition(.falsePositive) }
            Button(languageSettings.localized("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(languageSettings.localized("Delete saved evidence?"), isPresented: $confirmingDeletion) {
            Button(languageSettings.localized("Delete evidence"), role: .destructive) { engine.deleteIncidentEvidence(incident.id) }
            Button(languageSettings.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(languageSettings.localized("Saved frames will be permanently deleted. The incident record will remain."))
        }
    }

    private func transition(_ status: SafetyIncidentStatus) {
        engine.transitionIncident(incident.id, to: status, note: note)
    }

    private func loadEvidence() async {
        let loadID = UUID()
        evidenceLoadID = loadID
        let store = engine.evidenceStore
        let id = incident.clipID ?? incident.id
        let result = await Task.detached(priority: .utility) {
            SafetyIncidentEvidenceFrames.load(store: store, incidentID: id)
        }.value
        guard !Task.isCancelled, evidenceLoadID == loadID else { return }
        images = result.frames
        evidenceReadError = result.snapshotError
        clipReadError = result.clipError
        frameIndex = 0
    }
}
