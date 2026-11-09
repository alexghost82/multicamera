import AppKit
import SwiftUI
import CameraCore

struct CameraMemoryView: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var selectedFrame: CameraMemoryFrame?
    @State private var selectedImage: NSImage?
    @State private var loadError = ""
    @State private var confirmsClear = false

    private var memoryEnabled: Bool {
        model.featurePreferences.enabledFeatures.contains(.chronologicalMemory)
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
        .confirmationDialog("Delete all sampled memory frames?", isPresented: $confirmsClear) {
            Button("Delete all frames", role: .destructive) {
                for frame in model.cameraMemoryFrames { model.deleteCameraMemoryFrame(frame) }
            }
        } message: {
            Text("This removes locally retained sampled images and cannot be undone.")
        }
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