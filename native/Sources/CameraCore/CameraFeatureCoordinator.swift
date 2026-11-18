import Foundation

public enum OpenAlertStateError: Error {
    case unavailable
    case featureDisabled
}

public struct DescriptionJobPolicySnapshot: Sendable {
    public let job: DescriptionJobRevision
    fileprivate let preferences: CameraFeaturePreferences
    fileprivate let policyRevision: String
}

public final class CameraFeatureCoordinator: @unchecked Sendable {
    private let preferencesURL: URL
    private let databaseURL: URL
    private let pendingLimit: Int
    private let lock = NSRecursiveLock()
    private var cachedPreferences: CameraFeaturePreferences?
    private var store: CameraFeatureStore?

    public init(
        preferencesURL: URL = CameraFeaturePreferencesStore.defaultURL,
        databaseURL: URL = CameraFeatureStore.defaultURL,
        pendingLimit: Int = CameraFeatureStore.defaultPendingLimit
    ) {
        self.preferencesURL = preferencesURL
        self.databaseURL = databaseURL
        self.pendingLimit = pendingLimit
    }

    public func preferences() throws -> CameraFeaturePreferences {
        try locked { try loadPreferences() }
    }

    /// Read disk independently of the runtime cache for mutation verification.
    public func persistedPreferences() throws -> CameraFeaturePreferences {
        try locked { try CameraFeaturePreferencesStore.load(from: preferencesURL) }
    }

    public func savePreferences(_ preferences: CameraFeaturePreferences) throws {
        try locked {
            try CameraFeaturePreferencesStore.save(preferences, to: preferencesURL)
            cachedPreferences = preferences
        }
    }

    @discardableResult
    public func enqueue(
        featureID: CameraFeatureID,
        cameraID: UUID? = nil,
        payloadJSON: String? = nil,
        at time: Date = Date()
    ) throws -> CameraFeatureJob {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(featureID) else {
                throw CameraFeatureStoreError.featureDisabled(featureID)
            }
            let featureStore = try openStore()
            return try featureStore.enqueue(
                featureID: featureID,
                cameraID: cameraID,
                payloadJSON: payloadJSON,
                preferences: preferences,
                at: time
            )
        }
    }

    public func claimNext(featureID: CameraFeatureID? = nil, at time: Date = Date()) throws -> CameraFeatureJob? {
        try locked { try openStore().claimNext(featureID: featureID, at: time) }
    }

    public func claimNextBatch(featureID: CameraFeatureID,
                               limit: Int = 4,
                               at time: Date = Date()) throws -> [CameraFeatureJob] {
        try locked { try openStore().claimNextBatch(featureID: featureID, limit: limit, at: time) }
    }

    @discardableResult
    public func recoverInterruptedJobs(
        featureID: CameraFeatureID,
        staleBefore: Date,
        maximumAttempts: Int = 3,
        at time: Date = Date()
    ) throws -> Int {
        try locked {
            try openStore().recoverInterruptedJobs(
                featureID: featureID,
                staleBefore: staleBefore,
                maximumAttempts: maximumAttempts,
                at: time
            )
        }
    }

    public func operationsAlertAcknowledgements() throws -> [UUID: Date] {
        try locked { try openStore().operationsAlertAcknowledgements() }
    }

    /// Never opens a store or loads preferences; unavailable is not an empty result.
    public func readOpenAlertState(at time: Date = Date(), includeExpired: Bool = false) throws -> OperationsAlertReadState {
        try locked {
            guard let preferences = cachedPreferences else { throw OpenAlertStateError.unavailable }
            guard preferences.enabledFeatures.contains(.operationalAlerts) else {
                throw OpenAlertStateError.featureDisabled
            }
            guard let store else { throw OpenAlertStateError.unavailable }
            return try store.readAlertState(retentionDays: preferences.retentionDays, at: time, includeExpired: includeExpired)
        }
    }

    public func operationsAlertReviews() throws -> [OperationsAlertReview] {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(.operationalAlerts) else { return [] }
            let store = try openStore()
            _ = try store.purgeExpired(retentionDays: preferences.retentionDays)
            return try store.operationsAlertReviews()
        }
    }

    public func operationsAlertReviewAudit(alertID: UUID) throws -> [OperationsAlertReview] {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(.operationalAlerts) else { return [] }
            return try openStore().operationsAlertReviews(alertID: alertID, audit: true)
        }
    }

    public func reviewOperationsAlert(
        alertID: UUID, priority: OperationsAlertReview.Priority? = nil, status: OperationsAlertReview.Status? = nil,
        note: String? = nil, at time: Date = Date()
    ) throws {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(.operationalAlerts) else {
                throw CameraFeatureStoreError.featureDisabled(.operationalAlerts)
            }
            _ = try openStore().reviewOperationsAlert(
                alertID: alertID, priority: priority, status: status, note: note, preferences: preferences, at: time
            )
        }
    }

    public func acknowledgeOperationsAlert(alertID: UUID, at time: Date = Date()) throws {
        try locked {
            let preferences = try loadPreferences()
            try openStore().acknowledgeOperationsAlert(
                alertID: alertID,
                preferences: preferences,
                at: time
            )
        }
    }

    public func unacknowledgeOperationsAlert(alertID: UUID) throws {
        try locked {
            let preferences = try loadPreferences()
            try openStore().unacknowledgeOperationsAlert(alertID: alertID, preferences: preferences)
        }
    }

    public func clearOperationsAlertAcknowledgements() throws {
        try locked {
            let preferences = try loadPreferences()
            try openStore().clearOperationsAlertAcknowledgements(preferences: preferences)
        }
    }

    public func complete(jobID: UUID, resultJSON: String? = nil, at time: Date = Date()) throws {
        try locked { try openStore().complete(jobID: jobID, resultJSON: resultJSON, at: time) }
    }

    @discardableResult
    public func fail(jobID: UUID, message: String, retryAt: Date? = nil,
                     maximumAttempts: Int = 3, at time: Date = Date()) throws -> CameraFeatureJobStatus {
        try locked {
            try openStore().fail(
                jobID: jobID,
                message: message,
                retryAt: retryAt,
                maximumAttempts: maximumAttempts,
                at: time
            )
        }
    }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        store = nil
        cachedPreferences = nil
    }

    public func jobs(limit: Int = 100, featureID: CameraFeatureID? = nil) throws -> [CameraFeatureJob] {
        try locked { try openStore().jobs(limit: limit, featureID: featureID) }
    }

    public func operatorActions() throws -> [CameraOperatorAction] {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(.operatorActions) else { return [] }
            let store = try openStore()
            _ = try store.purgeExpired(retentionDays: preferences.retentionDays)
            return try store.operatorActions(limit: 1000)
        }
    }

    public func proposeDescriptionAction(trackIDs: [UUID], allowedTrackIDs: Set<UUID>) throws {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(.operatorActions) else {
                throw CameraFeatureStoreError.featureDisabled(.operatorActions)
            }
            _ = try openStore().proposeDescriptionAction(
                trackIDs: trackIDs, allowedTrackIDs: allowedTrackIDs, preferences: preferences
            )
        }
    }

    public func reviewOperatorAction(id: UUID, accept: Bool, existingTrackIDs: Set<UUID>) throws {
        try locked {
            let preferences = try loadPreferences()
            guard preferences.enabledFeatures.contains(.operatorActions) else {
                throw CameraFeatureStoreError.featureDisabled(.operatorActions)
            }
            _ = try openStore().reviewOperatorAction(
                id: id, accept: accept, existingTrackIDs: existingTrackIDs, preferences: preferences
            )
        }
    }

    public func retryFailedJob(id: UUID, at time: Date = Date()) throws {
        try locked {
            let preferences = try loadPreferences()
            try openStore().retryFailedJob(id: id, preferences: preferences, at: time)
        }
    }

    /// Storage primitive only; the caller must authorize before reading or retrying.
    public func descriptionJobSnapshot(id: UUID) throws -> DescriptionJobPolicySnapshot {
        try locked {
            try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
                guard let revision = policy.revision, policy.preferences == (try loadPreferences()) else {
                    throw CameraFeatureStoreError.descriptionJobStale
                }
                guard policy.preferences.enabledFeatures.contains(.visionDescriptions) else {
                    throw CameraFeatureStoreError.featureDisabled(.visionDescriptions)
                }
                let job = try openStore().descriptionJobRevision(id: id)
                guard job.status == .failed else { throw CameraFeatureStoreError.jobNotFailed(id) }
                return DescriptionJobPolicySnapshot(job: job, preferences: policy.preferences, policyRevision: revision)
            }
        }
    }

    /// An operation ID supplied before calling allows reconciliation after an uncertain commit.
    public func retryDescriptionJob(
        snapshot: DescriptionJobPolicySnapshot, operationID: UUID, at time: Date = Date()
    ) throws -> DescriptionRetryReceipt {
        try locked {
            try CameraFeaturePreferencesStore.withLockedSnapshot(from: preferencesURL) { policy in
                guard policy.revision == snapshot.policyRevision,
                      policy.preferences == snapshot.preferences,
                      policy.preferences == (try loadPreferences()) else {
                    throw CameraFeatureStoreError.descriptionJobStale
                }
                return try openStore().retryDescriptionJob(
                    expected: snapshot.job, preferences: policy.preferences,
                    operationID: operationID, at: time, beforeCommit: { try Task.checkCancellation() }
                )
            }
        }
    }

    /// Authorization must also be checked by the caller before receipt readback.
    public func hasDescriptionRetryReceipt(_ receipt: DescriptionRetryReceipt) throws -> Bool {
        try locked { try openStore().hasDescriptionRetryReceipt(receipt) }
    }

    private func loadPreferences() throws -> CameraFeaturePreferences {
        if let cachedPreferences { return cachedPreferences }
        let loaded = try CameraFeaturePreferencesStore.load(from: preferencesURL)
        cachedPreferences = loaded
        return loaded
    }

    private func openStore() throws -> CameraFeatureStore {
        if let store { return store }
        let opened = try CameraFeatureStore(url: databaseURL, pendingLimit: pendingLimit)
        store = opened
        return opened
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}