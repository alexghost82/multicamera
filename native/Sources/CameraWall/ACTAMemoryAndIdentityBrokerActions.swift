import CameraCore
import Foundation

// MARK: - Memory Clear & Recovery Backends (Snapshot-Bound)

final class ACTAWallCameraMemoryClearBackend: ACTACameraMemoryClearBackend, @unchecked Sendable {
    private let store: CameraMemoryStore
    private let onDidClear: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var lastSnapshot: CameraMemoryDeletionSnapshot?

    @MainActor
    init(model: WallModel) {
        self.store = model.cameraMemoryStore
        self.onDidClear = { [weak model] in model?.reloadCameraMemoryFrames() }
    }

    func snapshot() async throws -> CameraMemoryDeletionSnapshot {
        try store.deletionSnapshot()
    }

    func clear(_ snapshot: CameraMemoryDeletionSnapshot) async throws {
        try store.deleteConfirmedSnapshot(snapshot)
        lock.withLock { lastSnapshot = snapshot }
        await onDidClear()
    }

    func verify(_ snapshot: CameraMemoryDeletionSnapshot) async throws -> Bool {
        try store.verifyConfirmedDeletion(snapshot)
    }

    func verifyCurrentState() async throws -> Bool {
        guard let snap = lock.withLock({ lastSnapshot }) else { return false }
        return try store.verifyConfirmedDeletion(snap)
    }
}

final class ACTAWallCameraMemoryRecoveryBackend: ACTACameraMemoryRecoveryBackend, @unchecked Sendable {
    private let store: CameraMemoryStore
    private let onDidRecover: @MainActor @Sendable () -> Void

    @MainActor
    init(model: WallModel) {
        self.store = model.cameraMemoryStore
        self.onDidRecover = { [weak model] in model?.reloadCameraMemoryFrames() }
    }

    func snapshot() async throws -> CameraMemoryRecoverySnapshot {
        try store.recoverySnapshot()
    }

    func recover(_ snapshot: CameraMemoryRecoverySnapshot) async throws {
        try store.recoverPendingDeletion()
        await onDidRecover()
    }

    func verify(_ snapshot: CameraMemoryRecoverySnapshot) async throws -> Bool {
        try !store.hasPendingDeletion()
    }

    func verifyCurrentState() async throws -> Bool {
        try !store.hasPendingDeletion()
    }
}

// MARK: - Description Jobs Backend (Bridged to CameraFeatureCoordinator)

final class ACTAWallDescriptionJobBackend: ACTADescriptionJobBackend, @unchecked Sendable {
    private let coordinator: CameraFeatureCoordinator
    private let lock = NSLock()
    private var snapshotsByKey: [UUID: DescriptionJobPolicySnapshot] = [:]

    init(coordinator: CameraFeatureCoordinator) {
        self.coordinator = coordinator
    }

    func recent(context: ACTAActionContext) async throws -> [ACTADescriptionJobView] {
        do {
            let jobs = try coordinator.jobs(limit: 50, featureID: .visionDescriptions)
            return jobs.map { ACTADescriptionJobView(id: $0.id, status: $0.status, attempts: $0.attempts, updatedAt: $0.updatedAt) }
        } catch {
            throw ACTADescriptionJobError.unavailable
        }
    }

    func snapshot(id: UUID, context: ACTAActionContext) async throws -> ACTADescriptionJobSnapshot {
        do {
            let policySnap = try coordinator.descriptionJobSnapshot(id: id)
            let token = UUID()
            lock.withLock { snapshotsByKey[token] = policySnap }
            let view = ACTADescriptionJobView(
                id: policySnap.job.id,
                status: policySnap.job.status,
                attempts: policySnap.job.attempts,
                updatedAt: policySnap.job.updatedAt
            )
            return ACTADescriptionJobSnapshot(job: view, revision: token)
        } catch {
            throw ACTADescriptionJobError.unavailable
        }
    }

    func retry(_ snapshot: ACTADescriptionJobSnapshot, context: ACTAActionContext) async throws -> ACTADescriptionRetryReceipt {
        guard let policySnap = lock.withLock({ snapshotsByKey.removeValue(forKey: snapshot.revision) }) else {
            throw ACTADescriptionJobError.stale
        }
        let opID = UUID()
        do {
            let receipt = try coordinator.retryDescriptionJob(snapshot: policySnap, operationID: opID, at: context.now)
            return ACTADescriptionRetryReceipt(jobID: receipt.jobID, operationID: receipt.operationID)
        } catch {
            throw ACTADescriptionJobError.stale
        }
    }

    func verify(_ receipt: ACTADescriptionRetryReceipt, context: ACTAActionContext) async throws -> Bool {
        (try? coordinator.hasDescriptionRetryReceipt(
            DescriptionRetryReceipt(jobID: receipt.jobID, operationID: receipt.operationID)
        )) ?? false
    }
}

// MARK: - memory.close_chapter_now & memory.rebuild_knowledge

struct ACTAMemoryCloseChapterAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let cameraID: UUID
        let cameraName: String
        let threadID: String
    }

    let id = "memory.close_chapter_now"
    let title = "Close Active Narrative Chapter"
    let description = "Force-close and flush the active chronological narrative chapter for one configured camera after operator review. Verifies flush request admission, not model summary completion."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or unique name", isRequired: true)
    ]

    private unowned let model: WallModel

    init(model: WallModel) { self.model = model }

    func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys) == ["camera_id"],
              let value = parameters["camera_id"],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Specify camera_id.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            guard model.featurePreferences.enabledFeatures.contains(.chronologicalMemory) else {
                throw CameraFeatureStoreError.featureDisabled(.chronologicalMemory)
            }
            guard let cam = actaResolveCamera(parameters["camera_id"] ?? "", model: model) else {
                throw ConfigurationError.invalid("Camera does not exist or its name is ambiguous; specify a UUID.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(cameraID: cam.id, cameraName: cam.name, threadID: context.threadID),
                reviewSummary: "Force-close active narrative chapter for camera '\(cam.name)' (\(cam.id.uuidString))."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return await MainActor.run {
            model.forceCloseACTANarrativeChapter(cameraID: snapshot.cameraID)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Narrative chapter close requested; asynchronous flush completion is not certified.",
                outputJSON: "{\"camera_id\":\"\(snapshot.cameraID.uuidString)\",\"accepted\":true,\"completion_verified\":false}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

struct ACTAMemoryRebuildKnowledgeAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let threadID: String
    }

    let id = "memory.rebuild_knowledge"
    let title = "Rebuild Local Knowledge Index"
    let description = "Rebuild the local SQLite ACTA knowledge, route, and dossier index from existing local records after operator review."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters: [ACTAActionParameterSchema] = []

    private unowned let model: WallModel

    init(model: WallModel) { self.model = model }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: memory.rebuild_knowledge takes no parameters.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            guard model.actaTrackingStore != nil else {
                throw ConfigurationError.invalid("UNAVAILABLE: Local tracking store is unavailable.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(threadID: context.threadID),
                reviewSummary: "Rebuild local SQLite knowledge and identity dossier index."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            guard let store = model.actaTrackingStore else {
                return .failed(actionID: id, error: "UNAVAILABLE: Local tracking store is unavailable.")
            }
            try store.rebuildAllACTAKnowledge()
            let dossiers = try store.loadAllACTAIdentityDossiers()
            model.notice = "Knowledge index rebuilt successfully"
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Local knowledge index rebuilt (\(dossiers.count) dossiers).",
                outputJSON: "{\"rebuilt\":true,\"dossier_count\":\(dossiers.count)}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run { model.actaTrackingStore != nil }
    }
}

// MARK: - Identity Broker Actions (rename, merge, split, review_proposal, undo_merge, delete_tracked_object, plates, group/detach)

struct ACTAIdentityGalleryMutationAction: ACTAPreparedConfirmationAction {
    enum Kind: String, CaseIterable, Sendable {
        case rename = "identity.rename"
        case merge = "identity.merge"
        case split = "identity.split"
    }

    struct ConfirmationSnapshot: Sendable {
        let parameters: [String: String]
        let threadID: String
    }

    let kind: Kind
    var id: String { kind.rawValue }
    var title: String {
        switch kind {
        case .rename: return "Rename Identity"
        case .merge: return "Merge Identities"
        case .split: return "Split Identity Track"
        }
    }
    var description: String {
        switch kind {
        case .rename: return "Assign a display name to an existing local identity after operator review."
        case .merge: return "Permanently merge two local identities of the same kind after operator review."
        case .split: return "Split a member track out of a local identity and record a cannot-link constraint after operator review."
        }
    }
    var classification: ACTAActionClassification { kind == .rename ? .reversible : .destructive }
    var parameters: [ACTAActionParameterSchema] {
        switch kind {
        case .rename:
            return [
                ACTAActionParameterSchema(name: "identity_id", type: "string", description: "Identity ID or display code", isRequired: true),
                ACTAActionParameterSchema(name: "new_name", type: "string", description: "New display name (1...256 chars)", isRequired: true)
            ]
        case .merge:
            return [
                ACTAActionParameterSchema(name: "source_id", type: "string", description: "Source identity ID to merge from", isRequired: true),
                ACTAActionParameterSchema(name: "target_id", type: "string", description: "Target identity ID to keep", isRequired: true)
            ]
        case .split:
            return [
                ACTAActionParameterSchema(name: "identity_id", type: "string", description: "Identity ID to split", isRequired: true),
                ACTAActionParameterSchema(name: "track_id", type: "string", description: "Member track key to split out", isRequired: true)
            ]
        }
    }

    private unowned let model: WallModel

    init(kind: Kind, model: WallModel) {
        self.kind = kind
        self.model = model
    }

    func validate(parameters: [String: String]) throws {
        let expected = Set(self.parameters.map(\.name))
        guard Set(parameters.keys) == expected,
              parameters.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 256 }) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Missing or invalid identity mutation arguments.")
        }
        if kind == .merge, parameters["source_id"] == parameters["target_id"] {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: source_id and target_id must differ.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            guard model.actaAnalytics != nil else {
                throw ConfigurationError.invalid("UNAVAILABLE: Identity analytics coordinator is unavailable.")
            }
            let desc = parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: ", ")
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(parameters: parameters, threadID: context.threadID),
                reviewSummary: "\(title) (\(desc))."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID, snapshot.parameters == parameters else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        return try await MainActor.run {
            guard let coordinator = model.actaAnalytics else {
                return .failed(actionID: id, error: "UNAVAILABLE: Identity analytics coordinator is unavailable.")
            }
            let outputJSON = try coordinator.executeReviewedIdentityMutation(kind: id, parameters: parameters, now: context.now)
            return ACTAActionResult(actionID: id, success: true, summary: "\(title) saved and verified.", outputJSON: outputJSON)
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

struct ACTAIdentityReviewProposalAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let prepared: CrossCameraIdentityPolicyPreparedReview
        let proposalID: UUID
        let accept: Bool
        let threadID: String
    }

    let id = "identity.review_proposal"
    let title = "Review Cross-Camera Identity Proposal"
    let description = "Accept or reject a pending cross-camera identity proposal using the policy-locked review service after operator confirmation."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "proposal_id", type: "string", description: "Proposal UUID", isRequired: true),
        ACTAActionParameterSchema(name: "accept", type: "boolean", description: "true to accept, false to reject", isRequired: true)
    ]

    private unowned let model: WallModel

    init(model: WallModel) { self.model = model }

    private static func parse(_ parameters: [String: String]) throws -> (UUID, Bool) {
        guard Set(parameters.keys) == ["proposal_id", "accept"],
              let rawID = parameters["proposal_id"], let id = UUID(uuidString: rawID),
              let rawAccept = parameters["accept"], ["true", "false", "1", "0"].contains(rawAccept) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide proposal_id (UUID) and boolean accept.")
        }
        return (id, rawAccept == "true" || rawAccept == "1")
    }

    func validate(parameters: [String: String]) throws { _ = try Self.parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (proposalID, accept) = try Self.parse(parameters)
        return try await MainActor.run {
            let service = try model.actaCrossCameraIdentityReviewService()
            let prepared = try service.prepareReview(proposalID: proposalID, accept: accept)
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(prepared: prepared, proposalID: proposalID, accept: accept, threadID: context.threadID),
                reviewSummary: "\(accept ? "Accept" : "Reject") cross-camera identity proposal \(proposalID.uuidString)."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            let service = try model.actaCrossCameraIdentityReviewService()
            let updated = try service.review(snapshot.prepared)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Proposal \(updated.id.uuidString) updated to \(updated.status.rawValue).",
                outputJSON: "{\"proposal_id\":\"\(updated.id.uuidString)\",\"status\":\"\(updated.status.rawValue)\"}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

struct ACTAIdentityUndoMergeAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let prepared: CrossCameraIdentityPolicyPreparedUndo
        let proposalID: UUID
        let threadID: String
    }

    let id = "identity.undo_merge"
    let title = "Undo Accepted Cross-Camera Identity Merge"
    let description = "Undo an accepted cross-camera identity proposal using the policy-locked review service after operator confirmation."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "proposal_id", type: "string", description: "Accepted proposal UUID", isRequired: true)
    ]

    private unowned let model: WallModel

    init(model: WallModel) { self.model = model }

    private static func parse(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["proposal_id"],
              let rawID = parameters["proposal_id"], let id = UUID(uuidString: rawID) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide proposal_id (UUID).")
        }
        return id
    }

    func validate(parameters: [String: String]) throws { _ = try Self.parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let proposalID = try Self.parse(parameters)
        return try await MainActor.run {
            let service = try model.actaCrossCameraIdentityReviewService()
            let prepared = try service.prepareUndo(proposalID: proposalID)
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(prepared: prepared, proposalID: proposalID, threadID: context.threadID),
                reviewSummary: "Undo accepted cross-camera identity proposal \(proposalID.uuidString)."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            let service = try model.actaCrossCameraIdentityReviewService()
            try service.undo(snapshot.prepared)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Undid cross-camera identity merge \(snapshot.proposalID.uuidString).",
                outputJSON: "{\"proposal_id\":\"\(snapshot.proposalID.uuidString)\",\"undone\":true}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

struct ACTAIdentityDeleteTrackedObjectAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let trackID: UUID
        let label: String
        let threadID: String
    }

    let id = "identity.delete_tracked_object"
    let title = "Delete Local Tracked Object"
    let description = "Permanently delete a local tracked object record and its crop image from SQLite after operator review."
    let classification = ACTAActionClassification.destructive
    let parameters = [
        ACTAActionParameterSchema(name: "track_id", type: "string", description: "Track UUID", isRequired: true)
    ]

    private unowned let model: WallModel

    init(model: WallModel) { self.model = model }

    private static func parse(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["track_id"],
              let raw = parameters["track_id"], let id = UUID(uuidString: raw) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide track_id (UUID).")
        }
        return id
    }

    func validate(parameters: [String: String]) throws { _ = try Self.parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let trackID = try Self.parse(parameters)
        return try await MainActor.run {
            guard let store = model.actaTrackingStore, let record = try store.track(trackID: trackID) else {
                throw ConfigurationError.invalid("NOT_FOUND: Track \(trackID.uuidString) does not exist.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(trackID: trackID, label: record.label, threadID: context.threadID),
                reviewSummary: "Permanently delete tracked object \(trackID.uuidString) (label=\(record.label))."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            guard let store = model.actaTrackingStore else {
                return .failed(actionID: id, error: "UNAVAILABLE: Tracking store is unavailable.")
            }
            try store.delete(trackID: snapshot.trackID)
            guard try !store.contains(trackID: snapshot.trackID) else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Track still exists after deletion.")
            }
            model.recentTracks = (try? store.recentTracks()) ?? model.recentTracks.filter { $0.trackID != snapshot.trackID }
            model.vehicleTextCandidates.removeValue(forKey: snapshot.trackID)
            model.savedVehicleTextEvidence.removeValue(forKey: snapshot.trackID)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Tracked object \(snapshot.trackID.uuidString) deleted and verified.",
                outputJSON: "{\"track_id\":\"\(snapshot.trackID.uuidString)\",\"deleted\":true}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let trackID = try Self.parse(parameters)
        return await MainActor.run {
            guard let store = model.actaTrackingStore else { return false }
            return (try? !store.contains(trackID: trackID)) ?? false
        }
    }
}

struct ACTAIdentityReadVehiclePlateAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let trackID: UUID
        let persistIfOptedIn: Bool
        let threadID: String
    }

    let id = "identity.read_vehicle_plate"
    let title = "Read Vehicle Plate Candidates (Local OCR)"
    let description = "Run local Vision OCR on a saved vehicle crop image after operator review. Persists plate evidence only if plateRecognition feature is enabled."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "track_id", type: "string", description: "Vehicle track UUID", isRequired: true)
    ]

    private unowned let model: WallModel
    private let ocrReader: @Sendable (Data) throws -> [VehicleTextCandidate]

    init(
        model: WallModel,
        ocrReader: @escaping @Sendable (Data) throws -> [VehicleTextCandidate] = { try VehicleTextReader.readCandidates(from: $0) }
    ) {
        self.model = model
        self.ocrReader = ocrReader
    }

    private static func parse(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["track_id"],
              let raw = parameters["track_id"], let id = UUID(uuidString: raw) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide track_id (UUID).")
        }
        return id
    }

    func validate(parameters: [String: String]) throws { _ = try Self.parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let trackID = try Self.parse(parameters)
        return try await MainActor.run {
            guard let store = model.actaTrackingStore, let record = try store.track(trackID: trackID) else {
                throw ConfigurationError.invalid("NOT_FOUND: Track does not exist.")
            }
            guard ["car", "truck", "bus", "motorcycle", "bicycle", "boat"].contains(record.label) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Track is not a vehicle.")
            }
            let persist = model.featurePreferences.enabledFeatures.contains(.plateRecognition)
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(trackID: trackID, persistIfOptedIn: persist, threadID: context.threadID),
                reviewSummary: "Run local OCR on vehicle track \(trackID.uuidString) (persist_evidence=\(persist))."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            guard let store = model.actaTrackingStore,
                  let record = try store.track(trackID: snapshot.trackID),
                  let imageURL = store.imageURL(for: record) else {
                return .failed(actionID: id, error: "UNAVAILABLE: Vehicle track image is unavailable.")
            }
            let data = try Data(contentsOf: imageURL)
            let candidates = try ocrReader(data)
            var persisted = false
            if snapshot.persistIfOptedIn && model.featurePreferences.enabledFeatures.contains(.plateRecognition) {
                let evidence = try VehicleTextReader.evidence(candidates: candidates, imageData: data, trackID: snapshot.trackID)
                try store.saveVehicleTextEvidence(evidence)
                model.savedVehicleTextEvidence[snapshot.trackID] = evidence
                persisted = true
            }
            model.vehicleTextCandidates[snapshot.trackID] = candidates
            let texts = candidates.map(\.text)
            let payload: [String: Any] = [
                "track_id": snapshot.trackID.uuidString,
                "candidate_count": texts.count,
                "candidates": texts,
                "persisted": persisted
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Local OCR completed (\(texts.count) candidate(s)).", outputJSON: json)
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

struct ACTAIdentityClearVehiclePlateAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let trackID: UUID
        let evidence: VehicleTextEvidence
        let threadID: String
    }

    let id = "identity.clear_vehicle_plate"
    let title = "Clear Saved Vehicle Plate Evidence"
    let description = "Remove saved OCR vehicle plate evidence from one track record after operator review. Derived search copies may require a knowledge rebuild."
    let classification = ACTAActionClassification.destructive
    let parameters = [
        ACTAActionParameterSchema(name: "track_id", type: "string", description: "Vehicle track UUID", isRequired: true)
    ]

    private unowned let model: WallModel

    init(model: WallModel) { self.model = model }

    private static func parse(_ parameters: [String: String]) throws -> UUID {
        guard Set(parameters.keys) == ["track_id"],
              let raw = parameters["track_id"], let id = UUID(uuidString: raw) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide track_id (UUID).")
        }
        return id
    }

    func validate(parameters: [String: String]) throws { _ = try Self.parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let trackID = try Self.parse(parameters)
        return try await MainActor.run {
            guard let store = model.actaTrackingStore,
                  let evidence = try store.vehicleTextEvidence(for: trackID) else {
                throw ConfigurationError.invalid("NOT_FOUND: No saved vehicle text evidence for track \(trackID.uuidString).")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(trackID: trackID, evidence: evidence, threadID: context.threadID),
                reviewSummary: "Clear saved vehicle text evidence for track \(trackID.uuidString). Existing search index copies require memory.rebuild_knowledge."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            guard let store = model.actaTrackingStore else {
                return .failed(actionID: id, error: "UNAVAILABLE: Tracking store is unavailable.")
            }
            let cleared = try store.clearVehicleTextEvidence(matching: snapshot.evidence)
            guard cleared else {
                return .failed(actionID: id, error: "STALE_STATE: Vehicle text evidence changed since review.")
            }
            model.savedVehicleTextEvidence.removeValue(forKey: snapshot.trackID)
            model.vehicleTextCandidates.removeValue(forKey: snapshot.trackID)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Vehicle plate evidence cleared from track \(snapshot.trackID.uuidString).",
                outputJSON: "{\"track_id\":\"\(snapshot.trackID.uuidString)\",\"cleared\":true}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let trackID = try Self.parse(parameters)
        return await MainActor.run {
            guard let store = model.actaTrackingStore else { return false }
            return (try? store.vehicleTextEvidence(for: trackID)) == nil
        }
    }
}

struct ACTAIdentityTrackGroupAction: ACTAPreparedConfirmationAction {
    enum Mode: String, Sendable {
        case group = "identity.group_tracks"
        case detach = "identity.detach_tracks"
    }

    struct ConfirmationSnapshot: Sendable {
        let trackIDs: [UUID]
        let threadID: String
    }

    let mode: Mode
    var id: String { mode.rawValue }
    var title: String { mode == .group ? "Group Selected Tracks" : "Detach Tracks from Operator Group" }
    var description: String {
        mode == .group
            ? "Group two or more tracked object UUIDs (comma-separated) into an operator group after review."
            : "Detach one or more tracked object UUIDs (comma-separated) from their operator groups after review."
    }
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "track_ids", type: "string", description: "Comma-separated track UUIDs", isRequired: true)
    ]

    private unowned let model: WallModel

    init(mode: Mode, model: WallModel) {
        self.mode = mode
        self.model = model
    }

    private func parse(_ parameters: [String: String]) throws -> [UUID] {
        guard Set(parameters.keys) == ["track_ids"], let raw = parameters["track_ids"] else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide comma-separated track_ids.")
        }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let ids = parts.compactMap(UUID.init(uuidString:))
        guard ids.count == parts.count, Set(ids).count == ids.count,
              mode == .group ? ids.count >= 2 : !ids.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide unique valid track UUIDs.")
        }
        return ids
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let ids = try parse(parameters)
        return ACTAPreparedConfirmation(
            snapshot: ConfirmationSnapshot(trackIDs: ids, threadID: context.threadID),
            reviewSummary: "\(title) for \(ids.count) track(s)."
        )
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return await MainActor.run {
            let set = Set(snapshot.trackIDs)
            if mode == .group {
                model.groupTrackedObjects(set)
            } else {
                model.detachTrackedObjects(set)
            }
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "\(title) requested for \(set.count) track(s).",
                outputJSON: "{\"track_count\":\(set.count)}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

// MARK: - Chat Thread & Cancellation Actions

struct ACTAChatThreadAction: ACTAPreparedConfirmationAction {
    enum Mode: String, Sendable {
        case select = "chat.select_thread"
        case create = "chat.new_thread"
        case cancel = "chat.cancel_request"
    }

    struct ConfirmationSnapshot: Sendable {
        let targetThreadID: String?
        let threadID: String
    }

    let mode: Mode
    var id: String { mode.rawValue }
    var title: String {
        switch mode {
        case .select: return "Select Chat Thread"
        case .create: return "Create New Chat Thread"
        case .cancel: return "Cancel Active Chat Request"
        }
    }
    var description: String {
        switch mode {
        case .select: return "Switch the active ACTA chat thread to an existing thread ID after operator review."
        case .create: return "Create and activate a new empty ACTA chat thread after operator review."
        case .cancel: return "Cancel any currently running ACTA agent chat request after operator review."
        }
    }
    let classification = ACTAActionClassification.reversible
    var parameters: [ACTAActionParameterSchema] {
        mode == .select
            ? [ACTAActionParameterSchema(name: "thread_id", type: "string", description: "Target chat thread ID", isRequired: true)]
            : []
    }

    private unowned let model: WallModel

    init(mode: Mode, model: WallModel) {
        self.mode = mode
        self.model = model
    }

    func validate(parameters: [String: String]) throws {
        if mode == .select {
            guard Set(parameters.keys) == ["thread_id"],
                  let target = parameters["thread_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty, target.count <= 128 else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide thread_id (1...128 chars).")
            }
        } else {
            guard parameters.isEmpty else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: \(id) takes no parameters.")
            }
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        let target = mode == .select ? parameters["thread_id"] : (mode == .create ? "thread-\(UUID().uuidString.lowercased())" : nil)
        let summary: String
        switch mode {
        case .select: summary = "Switch active chat thread to '\(target ?? "")'."
        case .create: summary = "Create and switch to new chat thread '\(target ?? "")'."
        case .cancel: summary = "Cancel any currently active ACTA agent request."
        }
        return ACTAPreparedConfirmation(
            snapshot: ConfirmationSnapshot(targetThreadID: target, threadID: context.threadID),
            reviewSummary: summary
        )
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return await MainActor.run {
            switch mode {
            case .select, .create:
                guard let target = snapshot.targetThreadID else {
                    return .failed(actionID: id, error: "INVALID_ARGUMENT: Missing target thread.")
                }
                model.selectACTAChatThread(target)
                guard model.activeACTAThreadID == target else {
                    return .failed(actionID: id, error: "THREAD_SWITCH_FAILED: Could not switch active thread.")
                }
                return ACTAActionResult(
                    actionID: id,
                    success: true,
                    summary: "Active chat thread set to '\(target)'.",
                    outputJSON: "{\"thread_id\":\"\(target)\"}"
                )
            case .cancel:
                model.cancelACTAAgent()
                return ACTAActionResult(
                    actionID: id,
                    success: true,
                    summary: "Active chat request cancelled.",
                    outputJSON: "{\"busy\":\(model.actaAgentBusy)}"
                )
            }
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            switch mode {
            case .select: return model.activeACTAThreadID == parameters["thread_id"]
            case .create: return !model.activeACTAThreadID.isEmpty
            case .cancel: return !model.actaAgentBusy
            }
        }
    }
}

// MARK: - Local Voice Control Actions (Category I)

struct ACTAVoiceControlAction: ACTAPreparedConfirmationAction {
    enum Mode: String, CaseIterable, Sendable {
        case startListening = "voice.start_listening"
        case stopListening = "voice.stop_listening"
        case cancelListening = "voice.cancel_listening"
        case speakText = "voice.speak_text"
        case stopSpeaking = "voice.stop_speaking"
    }

    struct ConfirmationSnapshot: Sendable {
        let locale: String?
        let text: String?
        let threadID: String
    }

    let mode: Mode
    var id: String { mode.rawValue }
    var title: String {
        switch mode {
        case .startListening: return "Start Local Voice Dictation"
        case .stopListening: return "Stop Local Voice Dictation"
        case .cancelListening: return "Cancel Local Voice Dictation"
        case .speakText: return "Speak Text Locally (eSpeak NG)"
        case .stopSpeaking: return "Stop Local Voice Speech"
        }
    }
    var description: String {
        switch mode {
        case .startListening: return "Start on-device push-to-talk speech dictation after operator review (requires allowVoiceInput permission)."
        case .stopListening: return "Stop active on-device speech dictation and finalize transcript after operator review."
        case .cancelListening: return "Cancel active on-device speech dictation without submitting after operator review."
        case .speakText: return "Speak concise local status text using offline eSpeak NG after operator review (max 2000 bytes, no network)."
        case .stopSpeaking: return "Interrupt and stop active offline eSpeak NG voice output after operator review."
        }
    }
    let classification = ACTAActionClassification.reversible
    var parameters: [ACTAActionParameterSchema] {
        switch mode {
        case .startListening:
            return [ACTAActionParameterSchema(name: "locale", type: "string", description: "Optional BCP-47 locale", allowedValues: ["en-US", "ru-RU", "he-IL"])]
        case .speakText:
            return [
                ACTAActionParameterSchema(name: "text", type: "string", description: "Text to speak locally (1...2000 UTF-8 bytes)", isRequired: true),
                ACTAActionParameterSchema(name: "language", type: "string", description: "Optional speech language", allowedValues: ["en-US", "ru-RU", "he-IL"])
            ]
        case .stopListening, .cancelListening, .stopSpeaking:
            return []
        }
    }

    private unowned let model: WallModel
    private let speakHook: (@MainActor @Sendable (String, String) -> Void)?
    private let stopSpeakHook: (@MainActor @Sendable () -> Void)?

    init(
        mode: Mode,
        model: WallModel,
        speakHook: (@MainActor @Sendable (String, String) -> Void)? = nil,
        stopSpeakHook: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.mode = mode
        self.model = model
        self.speakHook = speakHook
        self.stopSpeakHook = stopSpeakHook
    }

    func validate(parameters: [String: String]) throws {
        switch mode {
        case .startListening:
            if let locale = parameters["locale"], !["en-US", "ru-RU", "he-IL"].contains(locale) {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Unsupported voice locale.")
            }
        case .speakText:
            guard let text = parameters["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.utf8.count <= 2000 else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: text must be 1...2000 UTF-8 bytes.")
            }
            if let lang = parameters["language"], !["en-US", "ru-RU", "he-IL"].contains(lang) {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Unsupported speech language.")
            }
        case .stopListening, .cancelListening, .stopSpeaking:
            guard parameters.isEmpty else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: \(id) takes no parameters.")
            }
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            if mode == .startListening, !model.featurePreferences.allowVoiceInput {
                throw ConfigurationError.invalid("PERMISSION_DENIED: Local voice input is disabled in permissions.")
            }
            let locale = parameters["locale"] ?? parameters["language"] ?? (AppLanguage.current == .russian ? "ru-RU" : "en-US")
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(locale: locale, text: parameters["text"], threadID: context.threadID),
                reviewSummary: "\(title) (locale=\(locale))."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return await MainActor.run {
            let locale = snapshot.locale ?? "en-US"
            switch mode {
            case .startListening:
                guard model.featurePreferences.allowVoiceInput else {
                    return .failed(actionID: id, error: "PERMISSION_DENIED: Local voice input is disabled.")
                }
                guard let voice = model.canvasFilterBridge.activeState?.analysisVoiceInput else {
                    return .failed(actionID: id, error: "UNAVAILABLE: No active chat voice input view is attached.")
                }
                _ = voice.start(localeIdentifier: locale)
                return ACTAActionResult(actionID: id, success: true, summary: "Local voice dictation requested.", outputJSON: "{\"locale\":\"\(locale)\"}")
            case .stopListening:
                model.canvasFilterBridge.activeState?.analysisVoiceInput.stop()
                return ACTAActionResult(actionID: id, success: true, summary: "Local voice dictation stopped.", outputJSON: "{\"stopped\":true}")
            case .cancelListening:
                model.canvasFilterBridge.activeState?.analysisVoiceInput.cancel()
                return ACTAActionResult(actionID: id, success: true, summary: "Local voice dictation cancelled.", outputJSON: "{\"cancelled\":true}")
            case .speakText:
                let text = snapshot.text ?? ""
                if let speakHook {
                    speakHook(text, locale)
                } else {
                    LocalVoiceOutput.shared.speak(text, localeIdentifier: locale, owner: UUID())
                }
                return ACTAActionResult(actionID: id, success: true, summary: "Local speech synthesis initiated.", outputJSON: "{\"spoken\":true,\"locale\":\"\(locale)\"}")
            case .stopSpeaking:
                if let stopSpeakHook {
                    stopSpeakHook()
                } else {
                    LocalVoiceOutput.shared.stopAll()
                }
                return ACTAActionResult(actionID: id, success: true, summary: "Local speech synthesis stopped.", outputJSON: "{\"stopped\":true}")
            }
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}
