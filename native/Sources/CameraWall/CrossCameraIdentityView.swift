import AppKit
import SwiftUI
import CameraCore

struct CrossCameraIdentityView: View {
    @Environment(\.locale) private var locale
    @State private var preferences = CameraFeaturePreferences()
    @State private var featureStore: CameraFeatureStore?
    @State private var trackingStore: LocalTrackingStore?
    @State private var records: [TrackedObjectRecord] = []
    @State private var candidates: [ReIDValidationCandidate] = []
    @State private var proposals: [CrossCameraIdentityProposal] = []
    @State private var acceptedProposals: [CrossCameraIdentityProposal] = []
    @State private var reviewSnapshot: CrossCameraIdentityReviewSnapshot?
    @State private var pendingReview: CrossCameraIdentityPolicyPreparedReview?
    @State private var visitGroups: [CrossCameraVisitGroup] = []
    @State private var presenceCameraID: UUID?
    @State private var routeDestinationID: UUID?
    @State private var presenceClass = ""
    @State private var usePresenceInterval = false
    @State private var presenceStart = Date().addingTimeInterval(-86_400)
    @State private var presenceEnd = Date()
    @State private var attributeName = ""
    @State private var attributeValue = ""
    @State private var message = "Identity review is disabled"
    @State private var isLoading = false
    @State private var refreshGeneration = UUID()

    private var isEnabled: Bool { preferences.enabledFeatures.contains(.crossCameraIdentity) }
    private var recordsByID: [UUID: TrackedObjectRecord] { Dictionary(uniqueKeysWithValues: records.map { ($0.trackID, $0) }) }
    private var visibleCandidates: [ReIDValidationCandidate] { candidates }
    private var historyCameras: [(id: UUID, name: String)] {
        Dictionary(grouping: visitGroups.flatMap(\.visits), by: \.cameraID)
            .map { (id: $0.key, name: $0.value.first?.cameraName ?? $0.key.uuidString) }
            .sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
    }
    private var historyAttributeNames: [String] {
        Set(visitGroups.flatMap { $0.attributeFacets().map(\.name) }).sorted()
    }
    private var filteredVisitGroups: [CrossCameraVisitGroup] {
        guard !usePresenceInterval || presenceStart <= presenceEnd else { return [] }
        let query = CrossCameraPresenceQuery(
            cameraIDs: presenceCameraID.map { [$0] } ?? [],
            interval: usePresenceInterval ? DateInterval(start: presenceStart, end: presenceEnd) : nil,
            objectClass: presenceClass.isEmpty ? nil : presenceClass,
            attributes: attributeName.isEmpty ? [:] : [attributeName: attributeValue]
        )
        return visitGroups.filter { group in
            guard query.matches(group) else { return false }
            if let presenceCameraID, let routeDestinationID {
                var routeQuery = query
                routeQuery.cameraIDs = []
                routeQuery.cameraSequence = [presenceCameraID, routeDestinationID]
                return routeQuery.matches(group)
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cross-camera identity")
                        .font(.system(size: ACTAType.title, weight: .semibold))
                    Text("Local appearance matches · operator decisions required")
                        .font(.system(size: ACTAType.caption))
                        .foregroundStyle(ACTATheme.textSecondary)
                }
                Spacer()
                OpenSettingsButton(section: .features)
            }
            .padding(ACTASpacing.section)

            if !isEnabled {
                ContentUnavailableView {
                    Label("Identity review is off", systemImage: "person.2.crop.square.stack")
                } description: {
                    Text("Enable it to rank local cross-camera appearance matches. Suggestions never identify a person and are not applied without review.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    Label("Lower cosine distance is closer", systemImage: "arrow.down.right")
                    Text("Appearance similarity is not identity proof")
                    Spacer()
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
                .font(.system(size: ACTAType.metadata, weight: .medium))
                .foregroundStyle(ACTATheme.textSecondary)
                .padding(.horizontal, ACTASpacing.section)
                .padding(.bottom, 10)
                Text("Automatic suggestions require at least 20 operator-confirmed Same and 100 Different pairs. Calibration uses those same labels, not a held-out set; every suggestion still requires operator review.")
                    .font(.system(size: ACTAType.metadata))
                    .foregroundStyle(ACTATheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ACTASpacing.section)
                    .padding(.bottom, 8)

                if isLoading {
                    ProgressView(message)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            sectionHeader("PENDING OPERATOR REVIEW", count: proposals.count)
                            if proposals.isEmpty {
                                Text("No identity proposals awaiting review.")
                                    .font(.system(size: ACTAType.caption))
                                    .foregroundStyle(ACTATheme.textMuted)
                                    .padding(.horizontal, ACTASpacing.section)
                                    .padding(.vertical, 12)
                            }
                            ForEach(proposals) { proposal in
                                proposalRow(proposal)
                                Divider().padding(.leading, 20)
                            }

                            sectionHeader("ACCEPTED SIDECAR LINKS", count: acceptedProposals.count)
                            if acceptedProposals.isEmpty {
                                Text("No accepted cross-camera links.")
                                    .font(.system(size: ACTAType.caption))
                                    .foregroundStyle(ACTATheme.textMuted)
                                    .padding(.horizontal, ACTASpacing.section)
                                    .padding(.vertical, 12)
                            }
                            ForEach(acceptedProposals) { proposal in
                                acceptedRow(proposal)
                                Divider().padding(.leading, 20)
                            }

                            sectionHeader("REVIEW-APPROVED CAMERA HISTORY", count: filteredVisitGroups.count)
                            presenceFilters
                            if visitGroups.isEmpty {
                                Text("No cross-camera history from accepted links.")
                                    .font(.system(size: ACTAType.caption))
                                    .foregroundStyle(ACTATheme.textMuted)
                                    .padding(.horizontal, ACTASpacing.section)
                                    .padding(.vertical, 12)
                            } else if filteredVisitGroups.isEmpty {
                                Text("No history matches the selected filters.")
                                    .font(.system(size: ACTAType.caption))
                                    .foregroundStyle(ACTATheme.textSecondary)
                                    .padding(.horizontal, ACTASpacing.section)
                                    .padding(.vertical, 12)
                            }
                            ForEach(filteredVisitGroups) { group in
                                visitGroupRow(group)
                                Divider().padding(.leading, 20)
                            }

                            sectionHeader("UNREVIEWED APPEARANCE MATCHES", count: visibleCandidates.count)
                            if visibleCandidates.isEmpty {
                                Text("No unreviewed candidates. New candidates require saved ReID embeddings from different cameras.")
                                    .font(.system(size: ACTAType.caption))
                                    .foregroundStyle(ACTATheme.textMuted)
                                    .padding(.horizontal, ACTASpacing.section)
                                    .padding(.vertical, 12)
                            }
                            ForEach(visibleCandidates) { candidate in
                                candidateRow(candidate)
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            Text(locale.appLanguage.localizedMessage(message))
                .font(.system(size: ACTAType.metadata))
                .foregroundStyle(ACTATheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ACTASpacing.section)
                .padding(.vertical, 10)
        }
        .background(ACTATheme.background)
        .onAppear(perform: load)
        .sheet(item: $pendingReview) { prepared in
            reviewConfirmation(prepared)
        }
    }

    private func reviewConfirmation(_ policyReview: CrossCameraIdentityPolicyPreparedReview) -> some View {
        let prepared = policyReview.review
        return VStack(alignment: .leading, spacing: 12) {
            Text(prepared.accept ? "Confirm appearance link" : "Confirm cannot-link decision")
                .font(.headline)
            Text("Appearance similarity is not identity proof. The evidence and graph will be checked again when confirmed.")
            Text("Proposal: \(prepared.proposal.id.uuidString)")
            Text("Category: \(prepared.proposal.category) · Distance: \(prepared.proposal.cosineDistance.formatted(.number.precision(.fractionLength(3))))")
            ForEach([prepared.trackA, prepared.trackB]) { record in
                VStack(alignment: .leading) {
                    Text("\(record.trackID.uuidString) · \(record.cameraName) · \(record.label)")
                    Text("\(record.firstSeen.formatted()) – \(record.lastSeen.formatted()) · \(record.observationCount) observations")
                }
            }
            Text("Related tracks in the reviewed graph:")
            ScrollView {
                Text(prepared.affectedTrackIDs.map(\.uuidString).joined(separator: "\n"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
            Text("Image files are not included in this confirmation snapshot.")
            HStack {
                Spacer()
                Button("Cancel") { pendingReview = nil }
                Button("Confirm") {
                    pendingReview = nil
                    commitReview(policyReview)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.system(size: ACTAType.metadata, weight: .semibold))
                .foregroundStyle(ACTATheme.textMuted)
            Spacer()
            Text("\(count)")
                .font(.system(size: ACTAType.metadata, weight: .semibold).monospacedDigit())
                .foregroundStyle(ACTATheme.textSecondary)
        }
        .padding(.horizontal, ACTASpacing.section)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func candidateRow(_ candidate: ReIDValidationCandidate) -> some View {
        HStack(spacing: 12) {
            evidence(candidate.trackA)
            evidence(candidate.trackB)
            VStack(alignment: .leading, spacing: 4) {
                Text("Appearance distance")
                    .font(.system(size: ACTAType.metadata, weight: .medium))
                    .foregroundStyle(ACTATheme.textMuted)
                Text(candidate.distance.formatted(.number.precision(.fractionLength(3))))
                    .font(.system(size: ACTAType.body, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ACTATheme.textPrimary)
                temporalEvidence(candidate)
                if candidate.trackA.operatorGroupID != nil,
                   candidate.trackB.operatorGroupID != nil,
                   candidate.trackA.operatorGroupID != candidate.trackB.operatorGroupID {
                    Label("Different operator groups", systemImage: "exclamationmark.triangle")
                        .font(.system(size: ACTAType.metadata, weight: .medium))
                        .foregroundStyle(ACTATheme.warning)
                }
            }
            Spacer(minLength: 4)
            Button {
                createProposal(candidate)
            } label: {
                Label("Propose", systemImage: "plus.circle")
            }
            .disabled(isLoading)
            .help("Add this appearance match to operator review")
        }
        .padding(.horizontal, ACTASpacing.section)
        .padding(.vertical, 10)
    }

    private func proposalRow(_ proposal: CrossCameraIdentityProposal) -> some View {
        HStack(spacing: 12) {
            if let record = recordsByID[proposal.trackA] { evidence(record) }
            if let record = recordsByID[proposal.trackB] { evidence(record) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Proposed appearance match")
                    .font(.system(size: ACTAType.caption, weight: .semibold))
                    .foregroundStyle(ACTATheme.textPrimary)
                    Text("Cosine distance \(proposal.cosineDistance.formatted(.number.precision(.fractionLength(3)))) · \(locale.appLanguage.localized(proposal.category))")
                    .font(.system(size: ACTAType.metadata).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
                if let recordA = recordsByID[proposal.trackA], let recordB = recordsByID[proposal.trackB] {
                    temporalEvidence(ReIDValidationCandidate(trackA: recordA, trackB: recordB, distance: proposal.cosineDistance))
                }
                if let recordA = recordsByID[proposal.trackA],
                   let recordB = recordsByID[proposal.trackB],
                   recordA.operatorGroupID != nil,
                   recordB.operatorGroupID != nil,
                   recordA.operatorGroupID != recordB.operatorGroupID {
                    Label("Conflicts with separate operator groups", systemImage: "exclamationmark.triangle")
                        .font(.system(size: ACTAType.metadata, weight: .medium))
                        .foregroundStyle(ACTATheme.warning)
                }
            }
            Spacer(minLength: 4)
            Button("Accept") { review(proposal, accept: true) }
                .disabled(isLoading || recordsByID[proposal.trackA] == nil || recordsByID[proposal.trackB] == nil)
                .help("Link these tracks in the separate cross-camera identity graph")
            Button("Reject", role: .destructive) { review(proposal, accept: false) }
                .disabled(isLoading || recordsByID[proposal.trackA] == nil || recordsByID[proposal.trackB] == nil)
                .help("Reject and prevent this pair from being proposed again")
        }
        .padding(.horizontal, ACTASpacing.section)
        .padding(.vertical, 10)
    }

    private func acceptedRow(_ proposal: CrossCameraIdentityProposal) -> some View {
        HStack(spacing: 12) {
            if let record = recordsByID[proposal.trackA] { evidence(record) }
            if let record = recordsByID[proposal.trackB] { evidence(record) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Operator accepted appearance link")
                    .font(.system(size: ACTAType.caption, weight: .semibold))
                    .foregroundStyle(ACTATheme.textPrimary)
                Text("\(locale.appLanguage.localized(proposal.category)) · distance \(proposal.cosineDistance.formatted(.number.precision(.fractionLength(3))))")
                    .font(.system(size: ACTAType.metadata).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
            }
            Spacer(minLength: 4)
            Button("Undo", role: .destructive) { undo(proposal) }
                .disabled(isLoading)
                .help("Undo this sidecar identity link and recompute its related groups")
        }
        .padding(.horizontal, ACTASpacing.section)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func temporalEvidence(_ candidate: ReIDValidationCandidate) -> some View {
        if let evidence = CrossCameraIdentityCandidateSelector.evidence(for: candidate) {
            if let gap = evidence.gapSeconds {
                Label("Observation gap: \(gap.formatted(.number.precision(.fractionLength(1)))) s", systemImage: "clock")
                    .font(.system(size: ACTAType.metadata).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
            } else {
                Label("Overlapping observations: \(evidence.overlapSeconds.formatted(.number.precision(.fractionLength(1)))) s", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: ACTAType.metadata).monospacedDigit())
                    .foregroundStyle(ACTATheme.warning)
            }
        } else {
            Label("Observation evidence unavailable", systemImage: "exclamationmark.triangle")
                .font(.system(size: ACTAType.metadata))
                .foregroundStyle(ACTATheme.warning)
        }
    }

    private func visitGroupRow(_ group: CrossCameraVisitGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Operator-reviewed appearance history", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: ACTAType.metadata, weight: .semibold))
                    .foregroundStyle(ACTATheme.textPrimary)
                Spacer()
                Text("\(group.cameraCount) cameras")
                    .font(.system(size: ACTAType.metadata, weight: .medium).monospacedDigit())
                    .foregroundStyle(ACTATheme.textSecondary)
            }
            DisclosureGroup("Dossier · \(group.identityID.uuidString)") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(group.route.enumerated()), id: \.offset) { _, presence in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presence.cameraName).fontWeight(.medium)
                            Text("\(presence.firstSeen.formatted(date: .abbreviated, time: .shortened, locale: locale)) – \(presence.lastSeen.formatted(date: .abbreviated, time: .shortened, locale: locale))")
                            Text(presence.trackIDs.map(\.uuidString).joined(separator: ", "))
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(Array(group.attributeFacets().enumerated()), id: \.offset) { _, facet in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(facet.name): \(facet.value)")
                            Text(facet.trackIDs.map(\.uuidString).joined(separator: ", "))
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: ACTAType.caption))
                .foregroundStyle(ACTATheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            ForEach(group.visits) { record in
                HStack(spacing: 8) {
                    Text(record.firstSeen.formatted(date: .abbreviated, time: .shortened, locale: locale))
                        .font(.system(size: ACTAType.metadata).monospacedDigit())
                        .foregroundStyle(ACTATheme.textMuted)
                    Text(record.cameraName)
                        .font(.system(size: ACTAType.metadata, weight: .medium))
                        .foregroundStyle(ACTATheme.textSecondary)
                    Text(record.label)
                        .font(.system(size: ACTAType.metadata))
                        .foregroundStyle(ACTATheme.textMuted)
                    if let description = record.description {
                        Text(description.summary)
                            .font(.system(size: ACTAType.metadata))
                            .foregroundStyle(ACTATheme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, ACTASpacing.section)
        .padding(.vertical, 10)
    }

    private var presenceFilters: some View {
        DisclosureGroup("Presence and route filters") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Camera / route start", selection: $presenceCameraID) {
                    Text("Any camera").tag(UUID?.none)
                    ForEach(historyCameras, id: \.id) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                Picker("Route destination", selection: $routeDestinationID) {
                    Text("Any destination").tag(UUID?.none)
                    ForEach(historyCameras, id: \.id) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                }
                .disabled(presenceCameraID == nil)
                Picker("Object class", selection: $presenceClass) {
                    Text("Any class").tag("")
                    ForEach(Set(visitGroups.flatMap(\.visits).map(\.label)).sorted(), id: \.self) { label in
                        Text(locale.appLanguage.localized(label)).tag(label)
                    }
                }
                Toggle("Time interval", isOn: $usePresenceInterval)
                if usePresenceInterval {
                    DatePicker("From", selection: $presenceStart)
                    DatePicker("Until", selection: $presenceEnd)
                    if presenceStart > presenceEnd {
                        Label("End must not precede start", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(ACTATheme.warning)
                    }
                }
                Picker("Attribute", selection: $attributeName) {
                    Text("Any attribute").tag("")
                    ForEach(historyAttributeNames, id: \.self) { name in Text(name).tag(name) }
                }
                if !attributeName.isEmpty {
                    LabeledContent("Attribute value") {
                        TextField("Value", text: $attributeValue).accessibilityLabel("Attribute value")
                    }
                }
                Button {
                    presenceCameraID = nil
                    routeDestinationID = nil
                    presenceClass = ""
                    usePresenceInterval = false
                    attributeName = ""
                    attributeValue = ""
                } label: {
                    Label("Clear filters", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            .controlSize(.small)
            .padding(.vertical, 12)
        }
        .padding(.horizontal, ACTASpacing.section)
        .padding(.vertical, 8)
    }

    private func evidence(_ record: TrackedObjectRecord) -> some View {
        HStack(spacing: 8) {
            if let url = LocalTrackingStore.defaultImageURL(for: record),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 54)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Saved track crop")
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(ACTATheme.surfaceElevated)
                    .frame(width: 64, height: 54)
                    .overlay { Image(systemName: "photo").foregroundStyle(ACTATheme.textMuted) }
                    .accessibilityLabel("No crop image saved")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.cameraName)
                    .font(.system(size: ACTAType.metadata, weight: .medium))
                    .foregroundStyle(ACTATheme.textPrimary)
                    .lineLimit(1)
                Text("\(locale.appLanguage.localized(record.label)) · \(record.firstSeen.formatted(date: .abbreviated, time: .shortened, locale: locale))")
                    .font(.system(size: ACTAType.metadata))
                    .foregroundStyle(ACTATheme.textMuted)
                    .lineLimit(1)
                if record.operatorGroupID != nil {
                    Text("Operator grouped")
                        .font(.system(size: ACTAType.metadata, weight: .medium))
                        .foregroundStyle(ACTATheme.primary)
                }
            }
            .frame(width: 130, alignment: .leading)
        }
    }

    private func load() {
        do {
            preferences = try CameraFeaturePreferencesStore.load()
            trackingStore = try LocalTrackingStore()
            if isEnabled {
                featureStore = try CameraFeatureStore()
                refresh()
            }
        } catch {
            message = "Could not open local identity review: \(error.localizedDescription)"
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            refreshGeneration = UUID()
            isLoading = false
            reviewSnapshot = nil
            preferences = try CameraFeaturePreferencesStore.update {
                if enabled { $0.enabledFeatures.insert(.crossCameraIdentity) }
                else { $0.enabledFeatures.remove(.crossCameraIdentity) }
            }
            if enabled {
                featureStore = try CameraFeatureStore()
                refresh()
            }
            else {
                candidates = []
                proposals = []
                acceptedProposals = []
                visitGroups = []
                featureStore = nil
                message = "Identity review is disabled; saved decisions remain local"
            }
        } catch {
            message = "Could not save identity review setting: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        guard !isLoading, isEnabled, let featureStore, let trackingStore else { return }
        isLoading = true
        let generation = UUID()
        refreshGeneration = generation
        let service = CrossCameraIdentityReviewService(tracking: trackingStore, features: featureStore)
        let policyService = CrossCameraIdentityPolicyReviewService(
            tracking: trackingStore, features: featureStore, preferencesURL: CameraFeaturePreferencesStore.defaultURL
        )
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .utility) {
                    _ = try policyService.reconcile()
                    var records = try trackingStore.recentTracks(limit: 1000)
                    let samples = try trackingStore.reidValidationSamples(limit: 50_000)
                    let calibration = ReIDThresholdCalibrator.calibrate(
                        samples.map(\.pair),
                        targetPrecision: ReIDThresholdCalibrator.defaultTargetPrecision
                    )
                    let allCandidates = CrossCameraIdentityCandidateSelector.rankedReviewEvidence(
                        try trackingStore.reidValidationCandidates(limit: 40)
                    ).map(\.candidate)
                    let autoProposals = CrossCameraIdentityCandidateSelector.calibratedReviewCandidates(
                        allCandidates,
                        recommendedDistance: calibration.recommendedDistance
                    )
                    for candidate in autoProposals {
                        do {
                            _ = try policyService.propose(candidate: candidate)
                        } catch CameraFeaturePreferencesStoreError.busy {
                            throw CameraFeaturePreferencesStoreError.busy
                        } catch {
                            continue
                        }
                    }
                    let snapshot = try service.snapshot()
                    let proposals = snapshot.proposals
                    let assignments = snapshot.assignments
                    var history: [TrackedObjectRecord] = []
                    if !assignments.isEmpty {
                        try trackingStore.forEachRecentTrackPage { page in
                            history.append(contentsOf: page.filter { assignments[$0.trackID] != nil })
                        }
                    }
                    let loadedTrackIDs = Set(records.map(\.trackID))
                    records.append(contentsOf: history.filter { !loadedTrackIDs.contains($0.trackID) })
                    let visitGroups = CrossCameraVisitIndex.groups(records: history, identityByTrackID: assignments)
                    let recordIDs = Set(records.map(\.trackID))
                    let proposalTrackIDs = Set(proposals.flatMap { [$0.trackA, $0.trackB] })
                    for trackID in proposalTrackIDs.subtracting(recordIDs) {
                        if let record = try trackingStore.track(trackID: trackID) { records.append(record) }
                    }
                    let candidates = try allCandidates.filter {
                        try !featureStore.hasIdentityDecision(trackA: $0.trackA.trackID, trackB: $0.trackB.trackID)
                    }
                    return (records, proposals, snapshot.accepted, visitGroups, candidates, snapshot)
                }.value
                guard refreshGeneration == generation else { return }
                self.records = result.0
                self.proposals = result.1
                self.acceptedProposals = result.2
                self.visitGroups = result.3
                self.candidates = result.4
                self.reviewSnapshot = result.5
                self.message = "Calibrated suggestions require operator review; appearance similarity is not identity proof. Manual groups are unchanged."
            } catch {
                guard refreshGeneration == generation else { return }
                self.message = "Could not refresh identity candidates: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    private func createProposal(_ candidate: ReIDValidationCandidate) {
        guard let featureStore, let trackingStore else { return }
        do {
            _ = try CrossCameraIdentityPolicyReviewService(
                tracking: trackingStore, features: featureStore, preferencesURL: CameraFeaturePreferencesStore.defaultURL
            ).propose(candidate: candidate)
            refresh()
        } catch {
            message = "Could not create identity proposal: \(error.localizedDescription)"
        }
    }

    private func review(_ proposal: CrossCameraIdentityProposal, accept: Bool) {
        guard let featureStore, let trackingStore, let reviewSnapshot else { return }
        do {
            pendingReview = try CrossCameraIdentityPolicyReviewService(
                tracking: trackingStore, features: featureStore, preferencesURL: CameraFeaturePreferencesStore.defaultURL
            )
                .prepareReview(proposal: proposal, records: records, snapshot: reviewSnapshot,
                               accept: accept)
        } catch {
            message = "Could not prepare identity decision: \(error.localizedDescription)"
        }
    }

    private func commitReview(_ prepared: CrossCameraIdentityPolicyPreparedReview) {
        guard let featureStore, let trackingStore else { return }
        do {
            _ = try CrossCameraIdentityPolicyReviewService(
                tracking: trackingStore, features: featureStore, preferencesURL: CameraFeaturePreferencesStore.defaultURL
            ).review(prepared)
            refresh()
        } catch {
            message = "Could not save identity decision: \(error.localizedDescription)"
        }
    }

    private func undo(_ proposal: CrossCameraIdentityProposal) {
        guard let featureStore, let trackingStore, let reviewSnapshot else { return }
        do {
            try CrossCameraIdentityPolicyReviewService(
                tracking: trackingStore, features: featureStore, preferencesURL: CameraFeaturePreferencesStore.defaultURL
            ).undo(proposal: proposal, snapshot: reviewSnapshot)
            refresh()
        } catch {
            message = "Could not undo identity decision: \(error.localizedDescription)"
        }
    }

    private func pairKey(_ trackA: UUID, _ trackB: UUID) -> String {
        [trackA.uuidString, trackB.uuidString].sorted().joined(separator: ":")
    }
}