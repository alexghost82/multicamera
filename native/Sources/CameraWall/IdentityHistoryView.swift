import AppKit
import SwiftUI
import CameraCore

struct IdentityHistoryView: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var confirmGroup = false
    @State private var showReIDValidation = false
    @State private var searchText = ""

    private var appLanguage: AppLanguage { locale.appLanguage }
    private var filteredTracks: [TrackedObjectRecord] {
        TrackDescriptionSearch.filter(model.recentTracks, query: searchText)
    }
    private var displayedTracks: [TrackedObjectRecord] {
        guard model.trackHistorySearchQuery == searchText,
              let searchResults = model.trackHistorySearchResults else { return filteredTracks }
        return searchResults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracked objects")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Local per-camera tracks · evidence retained for 30 days")
                        .font(.system(size: 12))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                Button {
                    showReIDValidation = true
                } label: {
                    Label("Validate ReID", systemImage: "checkmark.seal")
                }
                .help("Review real cross-camera pairs and tune the local ReID distance threshold")
                Button {
                    confirmGroup = true
                } label: {
                    Label("Group selected", systemImage: "person.2")
                }
                .disabled(selectedTrackIDs.count < 2)
                .help("Create an operator-confirmed group for the selected tracks")
                .accessibilityLabel("Group selected tracks")
                Button {
                    model.detachTrackedObjects(selectedTrackIDs)
                    selectedTrackIDs = []
                } label: {
                    Image(systemName: "person.crop.rectangle.stack")
                        .frame(width: 30, height: 30)
                }
                .disabled(!model.recentTracks.contains(where: {
                    selectedTrackIDs.contains($0.trackID) && $0.operatorGroupID != nil
                }))
                .help("Detach selected tracks from their operator-confirmed groups")
                .accessibilityLabel("Detach selected tracks")
                Text(appLanguage.localized("%lld recent", arguments: [model.recentTracks.count]))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
            }
            .padding(20)

            HStack {
                Toggle("Motion-aware tracking", isOn: Binding(
                    get: { model.featurePreferences.enabledFeatures.contains(.enhancedDetection) },
                    set: { enabled in
                        do { try model.setFeatureEnabled(.enhancedDetection, enabled: enabled) }
                        catch { model.notice = error.localizedDescription }
                    }
                ))
                Toggle("Save vehicle text locally", isOn: Binding(
                    get: { model.featurePreferences.enabledFeatures.contains(.plateRecognition) },
                    set: { enabled in
                        do { try model.setFeatureEnabled(.plateRecognition, enabled: enabled) }
                        catch { model.notice = error.localizedDescription }
                    }
                ))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                TextField("Search labels, descriptions, attributes or evidence", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search recent tracked-object descriptions and evidence")
                Button {
                    model.searchAllTrackHistory(query: searchText)
                } label: {
                    if model.trackHistorySearchInProgress {
                        ProgressView().controlSize(.small).frame(width: 32, height: 32)
                    } else {
                        Label("Search retained history", systemImage: "magnifyingglass")
                    }
                }
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.trackHistorySearchInProgress)
                .help("Search all retained tracks; show up to 250 results")
                .accessibilityLabel("Search all retained track history")
                if model.trackHistorySearchQuery == searchText,
                   !model.trackHistorySearchInProgress,
                   model.trackHistorySearchResults != nil {
                    Text("Showing \(displayedTracks.count) of \(model.trackHistorySearchMatchCount)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(ACTATheme.textMuted)
                }
            }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .onChange(of: searchText) { _, value in
                    if model.trackHistorySearchQuery != value { model.clearTrackHistorySearch() }
                }

            if model.recentTracks.isEmpty {
                ContentUnavailableView {
                    Label("No tracked objects yet", systemImage: "viewfinder")
                } description: {
                    Text("Enable YOLO26 on a camera. New detections will appear here with a local crop and track history.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if displayedTracks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                List(displayedTracks, selection: $selectedTrackIDs) { record in
                    HStack(spacing: 14) {
                        cropImage(for: record)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appLanguage.localized(record.label).capitalized(with: locale))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ACTATheme.textPrimary)
                            Text(record.cameraName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ACTATheme.textSecondary)
                            if let groupID = record.operatorGroupID {
                                Label(appLanguage.localized("Operator group · %@", arguments: [String(groupID.uuidString.prefix(6))]), systemImage: "person.2.fill")
                                    .font(.system(size: 10, weight: .medium).monospaced())
                                    .foregroundStyle(ACTATheme.primary)
                            }
                            Text("\(record.firstSeen.formatted(date: .abbreviated, time: .shortened, locale: locale)) – \(record.lastSeen.formatted(date: .omitted, time: .shortened, locale: locale))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(ACTATheme.textMuted)
                            if let description = record.description {
                                DisclosureGroup(appLanguage.localized("AI description · %lld%%", arguments: [Int(description.overallConfidence * 100)])) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(description.summary)
                                            .foregroundStyle(ACTATheme.textPrimary)
                                        ForEach(description.attributes.keys.sorted(), id: \.self) { key in
                                            if let attribute = description.attributes[key] {
                                                Text("\(key): \(attribute.value) · \(Int(attribute.confidence * 100))%")
                                                    .foregroundStyle(ACTATheme.textSecondary)
                                                if !attribute.evidence.isEmpty {
                                                    Text("Evidence: \(attribute.evidence)")
                                                        .foregroundStyle(ACTATheme.textMuted)
                                                }
                                            }
                                        }
                                    }
                                    .font(.system(size: 11))
                                    .padding(.top, 4)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .tint(ACTATheme.primary)
                            }
                            if let textCandidates = model.vehicleTextCandidates[record.trackID] {
                                DisclosureGroup("Unverified text candidates · \(textCandidates.count)") {
                                    if let saved = model.savedVehicleTextEvidence[record.trackID] {
                                        Text("Saved OCR: \(saved.readAt.formatted(date: .abbreviated, time: .shortened, locale: locale))")
                                            .font(.system(size: 11))
                                        Text("Crop SHA-256: \(saved.cropSHA256)")
                                            .font(.system(size: 11).monospaced())
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Button(role: .destructive) {
                                            model.clearVehicleTextEvidence(for: record.trackID)
                                        } label: {
                                            Label("Remove saved text", systemImage: "trash")
                                        }
                                    }
                                    if textCandidates.isEmpty {
                                        Text("No readable text was found in this vehicle crop.")
                                            .font(.system(size: 11))
                                            .foregroundStyle(ACTATheme.textSecondary)
                                    }
                                    ForEach(textCandidates) { candidate in
                                        Text("\(candidate.text) · \(Int(candidate.confidence * 100))%")
                                            .font(.system(size: 11).monospaced())
                                            .foregroundStyle(ACTATheme.textSecondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .font(.system(size: 11, weight: .medium))
                                .tint(ACTATheme.primary)
                            }
                            if let matches = model.similarTracksByTrack[record.trackID] {
                                DisclosureGroup("Closest crops · visual distance only") {
                                    if matches.isEmpty {
                                        Text("No comparable crops from other cameras were found.")
                                            .font(.system(size: 11))
                                            .foregroundStyle(ACTATheme.textSecondary)
                                    }
                                    ForEach(matches) { match in
                                        HStack(spacing: 8) {
                                            if let candidate = model.recentTracks.first(where: { $0.trackID == match.trackID }) {
                                                cropImage(for: candidate)
                                            }
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("\(match.cameraName) · \(match.label)")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(ACTATheme.textPrimary)
                                                Text(appLanguage.localized(
                                                    "%@ %@ · lower is closer · review only",
                                                    arguments: [match.metric, match.distance.formatted(.number.precision(.fractionLength(2)))]
                                                ))
                                                    .font(.system(size: 10).monospacedDigit())
                                                    .foregroundStyle(ACTATheme.textMuted)
                                            }
                                            Spacer(minLength: 4)
                                            Button("Select") {
                                                selectedTrackIDs.formUnion([record.trackID, match.trackID])
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(appLanguage.localized("Select similar crop from %@ for manual review", arguments: [match.cameraName]))
                                        }
                                    }
                                }
                                .font(.system(size: 11, weight: .medium))
                                .tint(ACTATheme.primary)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(appLanguage.localized("%lld samples", arguments: [record.observationCount]))
                            Text(appLanguage.localized("Best %lld%%", arguments: [Int(record.bestConfidence * 100)]))
                        }
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(ACTATheme.textSecondary)
                        Button {
                            model.describeTrackedObject(record)
                        } label: {
                            Image(systemName: "sparkles")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.describingTrackIDs.contains(record.trackID))
                        .help("Describe this saved crop using the local VLM")
                        .accessibilityLabel(appLanguage.localized("Describe %@ crop locally", arguments: [record.label]))
                        Button {
                            model.findSimilarTracks(to: record)
                        } label: {
                            if model.searchingTrackIDs.contains(record.trackID) {
                                ProgressView().controlSize(.small).frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "viewfinder")
                                    .frame(width: 30, height: 30)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.searchingTrackIDs.contains(record.trackID))
                        .help("Find visually similar crops from other cameras")
                        .accessibilityLabel(appLanguage.localized("Find similar crops for %@ from other cameras", arguments: [record.label]))
                        if ["car", "truck", "bus", "motorcycle", "bicycle", "boat"].contains(record.label) {
                            Button {
                                model.readVehicleTextCandidates(for: record)
                            } label: {
                                if model.readingVehicleTextTrackIDs.contains(record.trackID) {
                                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                                } else {
                                    Image(systemName: "text.viewfinder")
                                        .frame(width: 30, height: 30)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.readingVehicleTextTrackIDs.contains(record.trackID))
                            .help("Read unverified text candidates from this local vehicle crop")
                            .accessibilityLabel("Read text candidates from \(record.cameraName) vehicle crop")
                        }
                        Button(role: .destructive) {
                            model.deleteTrackedObject(record)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete track and saved crop")
                        .accessibilityLabel(appLanguage.localized("Delete %@ track from %@", arguments: [record.label, record.cameraName]))
                    }
                    .padding(.vertical, 5)
                    .listRowBackground(ACTATheme.surface)
                }
                .listStyle(.plain)
                }
            }
        }
        .background(ACTATheme.background)
        .onAppear { model.reloadVehicleTextEvidence() }
        .onChange(of: displayedTracks.map(\.trackID)) { _, _ in model.reloadVehicleTextEvidence() }
        .sheet(isPresented: $showReIDValidation) {
            ReIDCalibrationView(model: model)
                .frame(minWidth: 760, minHeight: 620)
        }
        .confirmationDialog("Group selected tracks?", isPresented: $confirmGroup) {
            Button("Confirm group") {
                model.groupTrackedObjects(selectedTrackIDs)
                selectedTrackIDs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This records your manual decision only. It does not infer a cross-camera identity.")
        }
    }

    @ViewBuilder
    private func cropImage(for record: TrackedObjectRecord) -> some View {
        if let url = LocalTrackingStore.defaultImageURL(for: record),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 88, height: 64)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Saved crop evidence")
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(ACTATheme.surfaceElevated)
                .frame(width: 88, height: 64)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(ACTATheme.textMuted)
                }
                .accessibilityLabel("No crop image saved")
        }
    }
}

private struct ReIDCalibrationView: View {
    @ObservedObject var model: WallModel
    @Environment(\.locale) private var locale
    @State private var targetPrecision = ReIDThresholdCalibrator.defaultTargetPrecision
    @State private var lastDifferentCandidate: ReIDValidationCandidate?

    private var appLanguage: AppLanguage { locale.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ReID validation")
                        .font(.system(size: 21, weight: .semibold))
                    Text("Human-labeled cross-camera pairs · local only")
                        .font(.system(size: 12))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                if model.reidValidationLoading { ProgressView().controlSize(.small) }
                Button {
                    model.refreshReIDValidation(targetPrecision: targetPrecision, includeCandidates: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 30, height: 30)
                }
                .help("Refresh validation pairs and metrics")
                .accessibilityLabel("Refresh ReID validation")
            }

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("TARGET PRECISION")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ACTATheme.textMuted)
                    Slider(value: $targetPrecision, in: 0.90...1.0, step: 0.005)
                        .accessibilityLabel("Target precision")
                    Text(targetPrecision.formatted(.percent.precision(.fractionLength(1))))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ACTATheme.textPrimary)
                }
                .frame(width: 210)

                if let result = model.reidCalibrationResult {
                    metric("Same pairs", value: "\(result.positivePairs) / \(ReIDThresholdCalibrator.minimumPositivePairs)")
                    metric("Different pairs", value: "\(result.negativePairs) / \(ReIDThresholdCalibrator.minimumNegativePairs)")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("THRESHOLD")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ACTATheme.textMuted)
                        Group {
                            if let distance = result.recommendedDistance {
                                Text("≤ \(distance.formatted(.number.precision(.fractionLength(3))))")
                            } else {
                                Text("Not ready")
                            }
                        }
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ACTATheme.textPrimary)
                    }
                }
            }

            if let result = model.reidCalibrationResult {
                if result.isReady {
                    HStack(spacing: 20) {
                        metric("Empirical precision", value: result.precision?.formatted(.percent.precision(.fractionLength(2))) ?? "—")
                        metric("Recall", value: result.recall?.formatted(.percent.precision(.fractionLength(1))) ?? "—")
                        metric("False-match rate", value: result.falsePositives.map {
                            "\((Double($0) / Double(result.negativePairs)).formatted(.percent.precision(.fractionLength(2)))) (\($0)/\(result.negativePairs))"
                        } ?? "—")
                    }
                } else {
                    Text("Need at least 20 operator-confirmed Same pairs and 100 explicit Different pairs before recommending a threshold.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ACTATheme.warning)
                }
                Text("Pair-level rates are measured on the same labels used to choose the threshold, not on a held-out test set. Repeated tracks can be correlated. Do not treat this recommendation as an identity decision or guarantee.")
                    .font(.system(size: 11))
                    .foregroundStyle(ACTATheme.textSecondary)

                if let candidate = lastDifferentCandidate {
                    HStack(spacing: 8) {
                        Text(appLanguage.localized("Last pair labeled Different: %@ / %@", arguments: [candidate.trackA.cameraName, candidate.trackB.cameraName]))
                            .font(.system(size: 11))
                            .foregroundStyle(ACTATheme.textSecondary)
                        Button("Undo") {
                            model.removeReIDDifferentLabel(candidate, targetPrecision: targetPrecision)
                            lastDifferentCandidate = nil
                        }
                        .disabled(model.reidValidationLoading)
                    }
                }

                if !result.sweep.isEmpty {
                    DisclosureGroup("Observed threshold sweep · \(result.sweep.count) values") {
                        VStack(spacing: 4) {
                            HStack {
                                Text("Distance")
                                Spacer()
                                Text("Precision")
                                Text("Recall")
                                Text("False-match")
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ACTATheme.textMuted)
                            ForEach(result.sweep.suffix(8)) { point in
                                HStack {
                                    Text(point.threshold.formatted(.number.precision(.fractionLength(3))))
                                    Spacer()
                                    Text(point.precision.formatted(.percent.precision(.fractionLength(1))))
                                    Text(point.recall.formatted(.percent.precision(.fractionLength(1))))
                                    Text(point.falseMatchRate?.formatted(.percent.precision(.fractionLength(2))) ?? "—")
                                }
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(ACTATheme.textSecondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .tint(ACTATheme.primary)
                }
            }

            Divider()

            HStack {
                Text("UNLABELED CANDIDATES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ACTATheme.textMuted)
                Spacer()
                Text("Lower cosine distance is closer · review only")
                    .font(.system(size: 10))
                    .foregroundStyle(ACTATheme.textMuted)
            }

            if model.reidValidationCandidates.isEmpty {
                ContentUnavailableView {
                    Label("No review candidates", systemImage: "checkmark.seal")
                } description: {
                    Text("Candidates need cross-camera tracks of the same category with saved ReID embeddings.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.reidValidationCandidates) { candidate in
                            candidateRow(candidate)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(ACTATheme.background)
        .onAppear {
            model.refreshReIDValidation(targetPrecision: targetPrecision, includeCandidates: true)
        }
        .onChange(of: targetPrecision) { _, value in
            model.refreshReIDValidation(targetPrecision: value)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLanguage.localized(title).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ACTATheme.textMuted)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(ACTATheme.textPrimary)
        }
    }

    private func candidateRow(_ candidate: ReIDValidationCandidate) -> some View {
        HStack(spacing: 12) {
            evidence(candidate.trackA)
            evidence(candidate.trackB)
            VStack(alignment: .leading, spacing: 4) {
                Text("Distance")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ACTATheme.textMuted)
                Text(candidate.distance.formatted(.number.precision(.fractionLength(3))))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ACTATheme.textPrimary)
            }
            Spacer(minLength: 4)
            Button {
                lastDifferentCandidate = nil
                model.labelReIDValidation(candidate, sameObject: true, targetPrecision: targetPrecision)
            } label: {
                Label("Same", systemImage: "person.2")
            }
            .disabled(model.reidValidationLoading)
            .help("Confirm these two tracks are the same object and group them")
            Button {
                lastDifferentCandidate = candidate
                model.labelReIDValidation(candidate, sameObject: false, targetPrecision: targetPrecision)
            } label: {
                Label("Different", systemImage: "person.2.slash")
            }
            .disabled(model.reidValidationLoading)
            .help("Record an explicit negative validation pair")
        }
        .padding(.vertical, 9)
    }

    private func evidence(_ record: TrackedObjectRecord) -> some View {
        HStack(spacing: 8) {
            if let url = LocalTrackingStore.defaultImageURL(for: record),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 74, height: 60)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Saved crop evidence")
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(ACTATheme.surfaceElevated)
                    .frame(width: 74, height: 60)
                    .overlay { Image(systemName: "photo").foregroundStyle(ACTATheme.textMuted) }
                    .accessibilityLabel("No crop image saved")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.cameraName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(record.label) · \(record.lastSeen.formatted(date: .abbreviated, time: .shortened, locale: locale))")
                    .font(.system(size: 10))
                    .foregroundStyle(ACTATheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)
        }
    }
}