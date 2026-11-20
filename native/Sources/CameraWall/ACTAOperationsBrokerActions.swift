import CameraCore
import Foundation

// MARK: - alert.clear_all (Snapshot-Bound Destructive Broker Action)

struct ACTAReviewedClearVLMAlertsAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let confirmation: VLMAlertClearConfirmation
        let alertCount: Int
        let threadID: String
    }

    let id = "alert.clear_all"
    let title = "Clear All Local VLM Alerts"
    let description = "Permanently clear all local VLM alerts, clips, and alert reviews after operator review of the exact current alert snapshot. Cross-store crash atomicity is not guaranteed."
    let classification = ACTAActionClassification.destructive
    let parameters: [ACTAActionParameterSchema] = []

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: alert.clear_all takes no parameters.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            guard let confirmation = try model.prepareVLMAlertsClear() else {
                throw ConfigurationError.invalid("UNAVAILABLE: Local VLM alerts state is unavailable.")
            }
            let count = model.vlmAlerts.count
            let summary = "Permanently clear \(count) local VLM alert(s), associated clips, and alert reviews. A partial failure across stores cannot be automatically rolled back."
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(confirmation: confirmation, alertCount: count, threadID: context.threadID),
                reviewSummary: summary
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            guard try snapshot.confirmation.isCurrent(visible: model.vlmAlerts, from: model.vlmAlertsURL) else {
                return .failed(actionID: id, error: "STALE_STATE: VLM alerts changed since review; nothing was cleared.")
            }
            model.clearVLMAlerts(confirmed: snapshot.confirmation)
            guard model.vlmAlerts.isEmpty else {
                return .failed(actionID: id, error: "CLEAR_FAILED: VLM alerts were not cleared.")
            }
            let disk = try VLMStore.loadAlerts(from: model.vlmAlertsURL)
            guard disk.isEmpty else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Persisted VLM alerts are not empty after clear.")
            }
            let json = "{\"cleared_count\":\(snapshot.alertCount),\"remaining\":0}"
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Cleared \(snapshot.alertCount) local VLM alert(s) and verified empty alert store.",
                outputJSON: json
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try await MainActor.run {
            guard model.vlmAlerts.isEmpty else { return false }
            let disk = try VLMStore.loadAlerts(from: model.vlmAlertsURL)
            return disk.isEmpty
        }
    }
}

// MARK: - monitor.clear_isapi_events (Snapshot-Bound Destructive Broker Action)

struct ACTAReviewedClearISAPIEventsAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let diskBytes: Data?
        let eventCount: Int
        let threadID: String
    }

    let id = "monitor.clear_isapi_events"
    let title = "Clear Local ISAPI Event History"
    let description = "Permanently clear local ISAPI camera event history after operator review of the current event count and disk snapshot."
    let classification = ACTAActionClassification.destructive
    let parameters: [ACTAActionParameterSchema] = []

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: monitor.clear_isapi_events takes no parameters.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            let url = model.isapiEventsURL
            let exists = FileManager.default.fileExists(atPath: url.path)
            let bytes: Data? = exists ? try Data(contentsOf: url) : nil
            let disk: [ISAPIEventRecord] = exists ? try ISAPIEventStore.load(from: url) : []
            guard disk == model.isapiEvents else {
                throw ConfigurationError.invalid("ISAPI event history changed on disk; reload before clearing.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(diskBytes: bytes, eventCount: disk.count, threadID: context.threadID),
                reviewSummary: "Permanently clear \(disk.count) local ISAPI event record(s)."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            let url = model.isapiEventsURL
            let currentBytes: Data? = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard currentBytes == snapshot.diskBytes else {
                return .failed(actionID: id, error: "STALE_STATE: ISAPI event history changed since review; nothing was cleared.")
            }
            model.clearISAPIEvents()
            let after = try ISAPIEventStore.load(from: url)
            guard model.isapiEvents.isEmpty, after.isEmpty else {
                return .failed(actionID: id, error: "STORAGE_ERROR: ISAPI event history could not be verified empty.")
            }
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Cleared \(snapshot.eventCount) local ISAPI event record(s) and verified on disk.",
                outputJSON: "{\"cleared_count\":\(snapshot.eventCount),\"remaining\":0}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try await MainActor.run {
            guard model.isapiEvents.isEmpty else { return false }
            let after = try ISAPIEventStore.load(from: model.isapiEventsURL)
            return after.isEmpty
        }
    }
}
