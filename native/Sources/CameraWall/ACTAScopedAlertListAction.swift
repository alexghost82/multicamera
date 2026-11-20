import CameraCore
import Foundation

/// Uses the GUI/store comparison from the existing reader, without exposing its
/// camera-scoped registry interface. External writers are not synchronized.
struct ACTAScopedAlertListAction: ACTAActionProtocol {
    let id = "alert.vlm_list"
    let title = "List VLM Alert Metadata"
    let description = "List up to 50 VLM alerts by ID, status, priority, and creation time, without camera identifiers or evidence."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "unacknowledged_only", type: "boolean",
                                  description: "Only open alerts", isRequired: false),
        ACTAActionParameterSchema(name: "limit", type: "integer",
                                  description: "Maximum results, from 1 through 50", isRequired: false)
    ]
    private let provider: any ACTAAlertReadProvider

    init(provider: any ACTAAlertReadProvider) {
        self.provider = provider
    }

    private struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: Invalid alert list parameters." }
    }

    func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys).isSubset(of: ["unacknowledged_only", "limit"]),
              parameters["unacknowledged_only"].map({ $0 == "true" || $0 == "false" }) ?? true,
              parameters["limit"].map({ Int($0).map { (1...50).contains($0) } ?? false }) ?? true else {
            throw InvalidArguments()
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try validate(parameters: parameters)
            try Task.checkCancellation()
            let rows = try await MainActor.run {
                let snapshot = try provider.readAlertSnapshot()
                guard snapshot.alerts.count <= 100,
                      Set(snapshot.alerts.map(\.id)).count == snapshot.alerts.count,
                      snapshot.alerts.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite }) else {
                    throw ReadError.invalid
                }
                let ordered = OperationsAlertQueue.ordered(snapshot.alerts, reviews: snapshot.reviews,
                                                           acknowledgements: snapshot.acknowledgements)
                return Array(ordered.lazy.filter {
                    parameters["unacknowledged_only"] != "true" ||
                        OperationsAlertQueue.status(for: $0.id, reviews: snapshot.reviews,
                                                    acknowledgements: snapshot.acknowledgements) == .open
                }.prefix(parameters["limit"].flatMap(Int.init) ?? 20).map {
                    Metadata(id: $0.id, created_at: $0.createdAt,
                             status: OperationsAlertQueue.status(for: $0.id, reviews: snapshot.reviews,
                                                                  acknowledgements: snapshot.acknowledgements),
                             priority: snapshot.reviews[$0.id]?.priority ?? $0.priority)
                })
            }
            try Task.checkCancellation()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Output(alerts: rows))
            return ACTAActionResult(actionID: id, success: true, summary: "VLM alert metadata retrieved.",
                                    outputJSON: String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch is InvalidArguments {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Invalid alert list parameters.")
        } catch ACTAAlertReadProviderError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Alert snapshot is unavailable.")
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Alert read failed.")
        }
    }

    private enum ReadError: Error { case invalid }
    private struct Output: Encodable { let alerts: [Metadata] }
    private struct Metadata: Encodable, Sendable {
        let id: UUID
        let created_at: Date
        let status: OperationsAlertReview.Status
        let priority: OperationsAlertReview.Priority
    }
}
