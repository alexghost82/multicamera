import AppKit
import SwiftUI
import CameraCore

struct CameraMemoryView: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var selectedFrame: CameraMemoryFrame?
    @State private var selectedImage: NSImage?
    @State private var editingChapter: GhostNarrativeChapterRecord?
    @State private var operatorTextDraft: String = ""
    @State private var showPinnedOnly: Bool = false
    @State private var loadError = ""
    @State private var confirmsClear = false

    private var memoryEnabled: Bool {
        model.featurePreferences.enabledFeatures.contains(.chronologicalMemory)
    }

    private var filteredChapters: [GhostNarrativeChapterRecord] {
        showPinnedOnly ? model.ghostNarrativeChapters.filter(\.pinned) : model.ghostNarrativeChapters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chronological memory")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Sampled local frames · expires after 7 days")
                        .font(.system(size: 12))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Button(role: .destructive) { confirmsClear = true } label: {
                    Label("Clear all frames", systemImage: "trash")
                }
                .disabled(model.cameraMemoryFrames.isEmpty)
            }

            Toggle("Enable chronological memory", isOn: Binding(
                get: { memoryEnabled },
                set: { enabled in
                    do { try model.setFeatureEnabled(.chronologicalMemory, enabled: enabled) }
                    catch { loadError = "Could not save memory setting" }
                }
            ))
            .toggleStyle(.switch)

            Toggle("Retain sampled camera frames", isOn: Binding(
                get: { model.featurePreferences.retainFullFrames },
                set: { enabled in
                    do { try model.setMemoryFrameRetentionEnabled(enabled) }
                    catch { loadError = "Could not save frame-retention setting" }
                }
            ))
            .toggleStyle(.switch)
            .disabled(!memoryEnabled)

            Text("Sampling starts only when both switches are on. One frame per camera is sampled at most every 15 minutes; storage is capped at 256 frames or 128 MB, and all frames expire within 7 days.")
                .font(.system(size: 12))
                .foregroundStyle(ACTATheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !loadError.isEmpty {
                Text(locale.appLanguage.localizedMessage(loadError)).font(.system(size: 12)).foregroundStyle(ACTATheme.danger)
            }

            ghostMemorySection

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
                                .font(.system(size: 13, weight: .semibold))
                            Text(frame.capturedAt.formatted(date: .abbreviated, time: .shortened, locale: locale))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(ACTATheme.textMuted)
                            Text(frame.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(ACTATheme.textSecondary)
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(frame.fileSize), countStyle: .file)) · expires \(frame.capturedAt.addingTimeInterval(Double(CameraMemoryStore.retentionDays) * 86_400).formatted(date: .abbreviated, time: .shortened, locale: locale))")
                                .font(.system(size: 10).monospacedDigit())
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
                            model.deleteCameraMemoryFrame(frame)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete sampled frame")
                        .accessibilityLabel("Delete sampled frame from \(frame.cameraName)")
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.plain)
            }
        }
        .padding(20)
        .onAppear { model.reloadCameraMemoryFrames() }
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
                Text(frame.summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(minWidth: 520, minHeight: 360)
        }
        .sheet(item: $editingChapter) { chapter in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit Ghost Memory Chapter · \(chapter.cameraName)")
                    .font(.headline)
                Text("Original AI summary: \(chapter.aiSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $operatorTextDraft)
                    .font(.body)
                    .frame(minHeight: 100)
                HStack {
                    Button("Restore AI Summary") {
                        model.saveGhostNarrativeOperatorText(chapter, text: nil)
                        editingChapter = nil
                    }
                    Spacer()
                    Button("Cancel") {
                        editingChapter = nil
                    }
                    Button("Save Operator Text") {
                        model.saveGhostNarrativeOperatorText(chapter, text: operatorTextDraft)
                        editingChapter = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 460, minHeight: 240)
        }
        .confirmationDialog("Delete all sampled memory frames?", isPresented: $confirmsClear) {
            Button("Delete all frames", role: .destructive) {
                for frame in model.cameraMemoryFrames { model.deleteCameraMemoryFrame(frame) }
            }
        } message: {
            Text("This removes locally retained sampled images and cannot be undone.")
        }
    }

    @ViewBuilder
    private var ghostMemorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Ghost Memory · Narrative Chapters (\(filteredChapters.count))", systemImage: "book.pages")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Pinned only", isOn: $showPinnedOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                if let firstCam = model.config.cameras.first(where: \.enabled) {
                    Button("Close chapter now") {
                        model.forceCloseGhostNarrativeChapter(cameraID: firstCam.id)
                    }
                    .font(.system(size: 11))
                }
                Button("Rebuild Knowledge") {
                    model.rebuildGhostKnowledgeLayer()
                }
                .font(.system(size: 11))
            }

            if !filteredChapters.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(filteredChapters.prefix(15))) { chapter in
                            ghostChapterRow(chapter)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    @ViewBuilder
    private func ghostChapterRow(_ chapter: GhostNarrativeChapterRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chapter.cameraName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(chapter.narrative.chapterTitle)
                        .font(.system(size: 12, weight: .medium))
                    if chapter.operatorMarked {
                        Text("OPERATOR")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ACTATheme.primary.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                Text("\(chapter.startedAt.formatted(date: .abbreviated, time: .shortened, locale: locale)) – \(chapter.endedAt.formatted(date: .omitted, time: .shortened, locale: locale)) · frames: \(chapter.frameCount) · sightings: \(chapter.sightingCount)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(ACTATheme.textMuted)
                Text(chapter.effectiveSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(ACTATheme.textSecondary)
                if let delta = chapter.narrative.deltaFromPrevious, !delta.isEmpty {
                    Text("Δ \(delta)")
                        .font(.system(size: 11))
                        .foregroundStyle(ACTATheme.textMuted)
                }
            }
            Spacer()
            Button {
                model.toggleGhostNarrativePin(chapter)
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
            let data = try CameraMemoryStore().imageData(for: frame)
            guard let image = NSImage(data: data) else { throw CameraMemoryStoreError.invalidImage }
            selectedImage = image
            selectedFrame = frame
        } catch {
            loadError = "Could not open this sampled frame"
        }
    }
}