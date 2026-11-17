import CameraCore
import Foundation

@MainActor
private final class ACTAHealthCheckModelReference {
    weak var model: WallModel?
    var receiptID: UUID?
    init(_ model: WallModel) { self.model = model }
}

struct ACTARunHealthCheckAction: ACTAActionProtocol {
    let id = "settings.run_health_check"
    let title = "Run local health check"
    let description = "Run the in-app monitor now. Changes monitor counters and may write local history; no independent watcher or external checks are provided."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters: [ACTAActionParameterSchema] = []
    private let modelReference: ACTAHealthCheckModelReference

    @MainActor
    init(model: WallModel) { modelReference = ACTAHealthCheckModelReference(model) }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw ConfigurationError.invalid("This action takes no parameters.") }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let model = modelReference.model else {
                return .failed(actionID: id, error: "UNAVAILABLE: The in-app monitor is unavailable.")
            }
            modelReference.receiptID = nil
            let previousNotice = model.notice
            model.notice = "Local health check requested; counters and history may change. No independent watcher is running."
            do {
                let receipt = try model.runLocalOperationsMonitorCheckChecked()
                guard model.currentLocalMonitorCheckReceipt() == receipt,
                      let checkedAt = receipt.snapshot.checkedAt else {
                    return .failed(actionID: id, error: LocalMonitorCheckError.observationFailed.localizedDescription)
                }
                let output: [String: Any] = [
                    "check_id": receipt.id.uuidString,
                    "checked_at": checkedAt.ISO8601Format(),
                    "verdict": receipt.snapshot.verdict.rawValue,
                    "probes": receipt.snapshot.probes.map {
                        ["id": $0.id, "label": $0.label, "status": $0.status.rawValue, "detail": $0.detail]
                    },
                    "history_written": receipt.historyWritten,
                    "independent_watcher": false
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else {
                    return .failed(actionID: id, error: "OUTPUT_FAILED: The check completed but its result could not be encoded; monitor state may have changed.")
                }
                modelReference.receiptID = receipt.id
                return ACTAActionResult(actionID: id, success: true,
                    summary: "Fresh in-app monitor snapshot verified. No independent watcher or external checks.",
                    outputJSON: String(decoding: data, as: UTF8.self))
            } catch let error as LocalMonitorCheckError {
                switch error {
                case .historyWriteFailed:
                    model.notice = "Local monitor history could not be saved. Counters and history may have changed; no independent watcher is running."
                case .historyUnavailable:
                    model.notice = "\(previousNotice.isEmpty ? "Local monitor history is unavailable" : previousNotice). Check not run; no independent watcher is running."
                case .disabled:
                    model.notice = "Local health check not run: in-app monitor is disabled. No independent watcher is running."
                case .busy:
                    model.notice = "Local health check not run: another check is in progress. No independent watcher is running."
                case .observationFailed:
                    model.notice = "Local health check could not be verified; state may have changed. No independent watcher is running."
                }
                return .failed(actionID: id, error: error.localizedDescription)
            }
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            guard let receiptID = modelReference.receiptID else { return false }
            return modelReference.model?.currentLocalMonitorCheckReceipt()?.id == receiptID
        }
    }
}
