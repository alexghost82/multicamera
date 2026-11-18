import AppKit
import SwiftUI
import CameraCore

struct CameraMemoryView: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var selectedFrame: CameraMemoryFrame?
    @State private var selectedImage: NSImage?
    @State private var editingChapter: ACTANarrativeChapterRecord?
    @State private var operatorTextDraft: String = ""
    @State private var showPinnedOnly: Bool = false
    @State private var loadError = ""
    @State private var confirmsClear = false
    @State private var clearSnapshot: CameraMemoryDeletionSnapshot?
    @State private var deletionPending = false

    private var memoryEnabled: Bool {
        model.featurePreferences.enabledFeatures.contains(.chronologicalMemory)
    }

    private var filteredChapters: [ACTANarrativeChapterRecord] {
        showPinnedOnly ? model.actaNarrativeChapters.filter(\.pinned) : model.actaNarrativeChapters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chronological memory")
                        .font(.system(size: ACTAType.title, weight: .semibold))
                    Text("Sampled local frames · expires after 7 days")
                        .font(.system(size: ACTAType.caption))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Button(role: .destructive) { prepareClear() } label: {
                    Label("Clear all frames", systemImage: "trash")
                }
                .disabled(model.cameraMemoryFrames.isEmpty || deletionPending)
            }

            OpenSettingsButton(section: .memory)

            Text("Sampling starts only when both switches are on. One frame per camera is sampled at most every 15 minutes; storage is capped at 256 frames or 128 MB, and all frames expire within 7 days.")
                .font(.system(size: ACTAType.caption))
                .foregroundStyle(ACTATheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !loadError.isEmpty {
                Text(locale.appLanguage.localizedMessage(loadError)).font(.system(size: ACTAType.caption)).foregroundStyle(ACTATheme.danger)
            }
            if deletionPending {
                Button("Resume incomplete frame deletion") { recoverDeletion() }
            }

            actaMemorySection

            if model.cameraMemoryFrames.isEmpty {
                ContentUnavailableView(
                    "No sampled frames",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Frames are sampled from fresh camera video only while both memory switches are enabled.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.cameraMemoryFrames) { frame in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(frame.cameraName)
                                .font(.system(size: ACTAType.body, weight: .semibold))
                            Text(frame.capturedAt.formatted(date: .abbreviated, time: .shortened, locale: locale))
                                .font(.system(size: ACTAType.metadata).monospacedDigit())
                                .foregroundStyle(ACTATheme.textMuted)
                            Text(frame.summary)
                                .font(.system(size: ACTAType.body))
                                .lineSpacing(4)
                                .foregroundStyle(ACTATheme.textSecondary)
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(frame.fileSize), countStyle: .file)) · expires \(frame.capturedAt.addingTimeInterval(Double(CameraMemoryStore.retentionDays) * 86_400).formatted(date: .abbreviated, time: .shortened, locale: locale))")
                                .font(.system(size: ACTAType.metadata).monospacedDigit())
                                .foregroundStyle(ACTATheme.textMuted)
                        }
                        Spacer(minLength: 8)
                        Button {
                            show(frame)
                        } label: {
                            Image(systemName: "eye")
                        }
                        .help("View sampled frame")
                        .accessibilityLabel("View sampled frame from \(frame.cameraName)")
                        Button(role: .destructive) {
                            do {
                                try model.deleteCameraMemoryFrameChecked(frame.id)
                                loadError = ""
                            } catch {
                                reportDeletionError(error)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete sampled frame")
                        .accessibilityLabel("Delete sampled frame from \(frame.cameraName)")
                        .disabled(deletionPending)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(ACTATheme.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ACTATheme.background)
            }
        }
        .padding(ACTASpacing.section)
        .onAppear {
            do {
                deletionPending = try model.cameraMemoryStore.hasPendingDeletion()
                if deletionPending {
                    loadError = "Memory deletion is incomplete. Resume it before changing memory."
                } else {
                    refreshFrames()
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
        .sheet(item: $selectedFrame) { frame in
            VStack(alignment: .leading, spacing: 12) {
                Text("\(frame.cameraName) · \(frame.capturedAt.formatted(date: .abbreviated, time: .shortened, locale: locale))")
                    .font(.headline)
                if let selectedImage {
                    Image(nsImage: selectedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Sampled camera frame")
                }
                Text(frame.summary).font(.system(size: ACTAType.body)).lineSpacing(4).foregroundStyle(.secondary)
            }
            .padding(ACTASpacing.section)
            .frame(minWidth: 520, minHeight: 360)
        }
        .sheet(item: $editingChapter) { chapter in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit ACTA Memory Chapter · \(chapter.cameraName)")
                    .font(.headline)
                Text("Original AI summary: \(chapter.aiSummary)")
                    .font(.system(size: ACTAType.caption))
                    .foregroundStyle(.secondary)
                TextEditor(text: $operatorTextDraft)
                    .font(.system(size: ACTAType.body))
                    .frame(minHeight: 100)
                HStack {
                    Button("Restore AI Summary") {
                        model.saveACTANarrativeOperatorText(chapter, text: nil)
                        editingChapter = nil
                    }
                    Spacer()
                    Button("Cancel") {
                        editingChapter = nil
                    }
                    Button("Save Operator Text") {
                        model.saveACTANarrativeOperatorText(chapter, text: operatorTextDraft)
                        editingChapter = nil
                    }
                    .buttonStyle(.borderedProminent).tint(ACTATheme.actionFill)
                }
            }
            .padding(ACTASpacing.section)
            .frame(minWidth: 460, minHeight: 240)
        }
        .confirmationDialog("Delete all sampled memory frames?", isPresented: $confirmsClear) {
            Button("Delete all frames", role: .destructive) {
                guard let snapshot = clearSnapshot else { return }
                clearSnapshot = nil
                do {
                    try model.cameraMemoryStore.deleteConfirmedSnapshot(snapshot)
                    selectedImage = nil
                    selectedFrame = nil
                    loadError = ""
                    refreshFrames()
                } catch {
                    reportDeletionError(error)
                }
            }
        } message: {
            Text("Delete the \(clearSnapshot?.count ?? 0) indexed frames shown in the list. This cannot be undone. If the set changes, review it again.")
        }
    }

    @ViewBuilder
    private var actaMemorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("ACTA Memory · Narrative Chapters (\(filteredChapters.count))", systemImage: "book.pages")
                    .font(.system(size: ACTAType.body, weight: .semibold))
                Spacer()
                Toggle("Pinned only", isOn: $showPinnedOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: ACTAType.metadata))
                if let firstCam = model.config.cameras.first(where: \.enabled) {
                    Button("Close chapter now") {
                        model.forceCloseACTANarrativeChapter(cameraID: firstCam.id)
                    }
                    .font(.system(size: ACTAType.metadata))
                }
                Button("Rebuild Knowledge") {
                    model.rebuildACTAKnowledgeLayer()
                }
                .font(.system(size: ACTAType.metadata))
            }

            if !filteredChapters.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(filteredChapters.prefix(15))) { chapter in
                            actaChapterRow(chapter)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    @ViewBuilder
    private func actaChapterRow(_ chapter: ACTANarrativeChapterRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(chapter.cameraName)
                        .font(.system(size: ACTAType.caption, weight: .semibold))
                    Text(chapter.narrative.chapterTitle)
                        .font(.system(size: ACTAType.caption, weight: .medium))
                    if chapter.operatorMarked {
                        Text("OPERATOR")
                            .font(.system(size: ACTAType.metadata, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ACTATheme.primary.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                Text("\(chapter.startedAt.formatted(date: .abbreviated, time: .shortened, locale: locale)) – \(chapter.endedAt.formatted(date: .omitted, time: .shortened, locale: locale)) · frames: \(chapter.frameCount) · sightings: \(chapter.sightingCount)")
                    .font(.system(size: ACTAType.metadata).monospacedDigit())
                    .foregroundStyle(ACTATheme.textMuted)
                Text(chapter.effectiveSummary)
                    .font(.system(size: ACTAType.body))
                    .lineSpacing(4)
                    .foregroundStyle(ACTATheme.textSecondary)
                if let delta = chapter.narrative.deltaFromPrevious, !delta.isEmpty {
                    Text("Δ \(delta)")
                        .font(.system(size: ACTAType.metadata))
                        .foregroundStyle(ACTATheme.textMuted)
                }
            }
            Spacer()
            Button {
                model.toggleACTANarrativePin(chapter)
            } label: {
                Image(systemName: chapter.pinned ? "pin.fill" : "pin")
            }
            .help(chapter.pinned ? "Unpin chapter" : "Pin chapter")

            Button {
                operatorTextDraft = chapter.operatorText ?? chapter.effectiveSummary
                editingChapter = chapter
            } label: {
                Image(systemName: "pencil")
            }
            .help("Edit operator summary")
        }
        .padding(8)
        .background(ACTATheme.surfaceElevated.opacity(0.5))
        .cornerRadius(6)
    }

    private func show(_ frame: CameraMemoryFrame) {
        do {
            let data = try model.cameraMemoryStore.imageData(for: frame)
            guard let image = NSImage(data: data) else { throw CameraMemoryStoreError.invalidImage }
            selectedImage = image
            selectedFrame = frame
        } catch {
            loadError = "Could not open this sampled frame"
        }
    }

    private func prepareClear() {
        do {
            let snapshot = try model.cameraMemoryStore.deletionSnapshot()
            guard snapshot.count > 0 else {
                refreshFrames()
                return
            }
            guard snapshot.count == model.cameraMemoryFrames.count,
                  snapshot.frames.allSatisfy({ model.cameraMemoryFrames.contains($0) }) else {
                model.cameraMemoryFrames = snapshot.frames
                loadError = "The frame list changed. Review it and try again."
                return
            }
            clearSnapshot = snapshot
            confirmsClear = true
        } catch {
            reportDeletionError(error)
        }
    }

    private func recoverDeletion() {
        do {
            try model.cameraMemoryStore.recoverPendingDeletion()
            deletionPending = false
            selectedImage = nil
            selectedFrame = nil
            loadError = ""
            refreshFrames()
        } catch {
            reportDeletionError(error)
        }
    }

    private func reportDeletionError(_ error: Error) {
        loadError = error.localizedDescription
        do {
            deletionPending = try model.cameraMemoryStore.hasPendingDeletion()
        } catch {
            deletionPending = true
            loadError = error.localizedDescription
        }
        if deletionPending {
            selectedImage = nil
            selectedFrame = nil
        }
        if !deletionPending { refreshFrames() }
    }

    private func refreshFrames() {
        do {
            model.cameraMemoryFrames = try model.cameraMemoryStore.deletionSnapshot().frames
        } catch {
            loadError = error.localizedDescription
        }
    }
}