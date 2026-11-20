import CameraCore
import Foundation

enum ACTAISAPIReadSource: String, Sendable {
    case localStore = "local_store"
    case liveMemory = "live_memory"
}

enum ACTAISAPIHistoryStatus: String, Sendable {
    case available
    /// Only a provider with independent first-launch evidence may return this status.
    case verifiedFirstLaunch = "verified_first_launch"
}

struct ACTAISAPISnapshot: Sendable {
    let records: [ISAPIEventRecord]
    let source: ACTAISAPIReadSource
    let status: ACTAISAPIHistoryStatus
    let capturedAt: Date
}

enum ACTAISAPIProviderError: Error, Sendable {
    case unavailable
    case invalidData
}

/// Implementations must not start a monitor, access credentials, or mutate the source.
/// Missing history is unavailable unless first launch is independently established.
protocol ACTAISAPIReadProvider: Sendable {
    func snapshot(now: Date) async throws -> ACTAISAPISnapshot
}

/// Reads only the existing local file. It cannot establish first-launch status.
struct ACTAISAPIStoreReadProvider: ACTAISAPIReadProvider {
    let url: URL

    func snapshot(now: Date) async throws -> ACTAISAPISnapshot {
        do {
            let records = try ISAPIEventStore.readSnapshot(from: url, now: now)
            return ACTAISAPISnapshot(records: records, source: .localStore, status: .available, capturedAt: now)
        } catch is DecodingError {
            throw ACTAISAPIProviderError.invalidData
        } catch {
            throw ACTAISAPIProviderError.unavailable
        }
    }
}

@MainActor
final class ACTAWallISAPIReadProvider: ACTAISAPIReadProvider {
    private weak var model: WallModel?

    init(model: WallModel) { self.model = model }

    func snapshot(now: Date) async throws -> ACTAISAPISnapshot {
        guard let model, model.actaISAPIEventsLoaded else { throw ACTAISAPIProviderError.unavailable }
        let records = try ISAPIEventStore.readSnapshot(from: model.isapiEventsURL, now: now)
        guard records == ISAPIEventStore.retainedRecords(model.isapiEvents, now: now) else {
            throw ACTAISAPIProviderError.unavailable
        }
        return ACTAISAPISnapshot(records: records, source: .liveMemory, status: .available, capturedAt: now)
    }
}

struct ACTAScopedISAPIReadAction: ACTAActionProtocol {
    let id = "monitor.get_isapi_events"
    let title = "List ISAPI Event Metadata"
    let description = "List up to 50 locally retained ISAPI event IDs and received times; no camera IDs or event text."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "limit", type: "integer",
                                  description: "Maximum results, from 1 through 50")
    ]
    let provider: any ACTAISAPIReadProvider

    func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys).isSubset(of: ["limit"]),
              parameters["limit"].map({ Int($0).map { (1...50).contains($0) } ?? false }) ?? true else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Invalid event list parameters.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do { try validate(parameters: parameters) }
        catch { return .failed(actionID: id, error: "INVALID_ARGUMENT: Invalid event list parameters.") }
        do {
            try Task.checkCancellation()
            let snapshot = try await provider.snapshot(now: context.now)
            try Task.checkCancellation()
            guard snapshot.records.count <= ISAPIEventStore.maximumRecords,
                  snapshot.status != .verifiedFirstLaunch || snapshot.records.isEmpty,
                  Set(snapshot.records.map(\.id)).count == snapshot.records.count,
                  snapshot.records.allSatisfy({ $0.receivedAt.timeIntervalSince1970.isFinite }) else {
                return .failed(actionID: id, error: "INVALID_DATA: ISAPI history is invalid.")
            }
            let events = snapshot.records.sorted {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(parameters["limit"].flatMap(Int.init) ?? 20).map {
                Metadata(id: $0.id, received_at: $0.receivedAt)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return ACTAActionResult(actionID: id, success: true, summary: "ISAPI event metadata retrieved.",
                                    outputJSON: String(decoding: try encoder.encode(Output(events: events)), as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch ACTAISAPIProviderError.invalidData {
            return .failed(actionID: id, error: "INVALID_DATA: ISAPI history is invalid.")
        } catch {
            return .failed(actionID: id, error: "UNAVAILABLE: ISAPI history is unavailable.")
        }
    }

    private struct Output: Encodable { let events: [Metadata] }
    private struct Metadata: Encodable {
        let id: UUID
        let received_at: Date
    }
}

struct ACTAISAPIReadAction: ACTAActionProtocol {
    let provider: any ACTAISAPIReadProvider
    let id = "monitor.get_isapi_events"
    let title = "Read ISAPI events"
    let description = "Read already collected local ISAPI event metadata, newest received first."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Optional camera UUID"),
        ACTAActionParameterSchema(name: "limit", type: "integer", description: "Maximum results, 1...100 (default 50)")
    ]

    func validate(parameters: [String: String]) throws {
        guard Set(parameters.keys).isSubset(of: ["camera_id", "limit"]) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown parameter.")
        }
        if let value = parameters["camera_id"], UUID(uuidString: value) == nil {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: camera_id must be a UUID.")
        }
        if let value = parameters["limit"], !(Int(value).map { (1...100).contains($0) } ?? false) {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: limit must be an integer in 1...100.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let snapshot: ACTAISAPISnapshot
        do {
            snapshot = try await provider.snapshot(now: context.now)
        } catch is CancellationError {
            throw CancellationError()
        } catch ACTAISAPIProviderError.invalidData {
            return .failed(actionID: id, error: "INVALID_DATA: ISAPI history is invalid.")
        } catch {
            return .failed(actionID: id, error: "UNAVAILABLE: ISAPI history is unavailable.")
        }
        try Task.checkCancellation()
        guard snapshot.status != .verifiedFirstLaunch || snapshot.records.isEmpty else {
            return .failed(actionID: id, error: "INVALID_DATA: Inconsistent ISAPI source status.")
        }
        let cameraID = parameters["camera_id"].flatMap(UUID.init(uuidString:))
        let limit = parameters["limit"].flatMap(Int.init) ?? 50
        let records = snapshot.records
            .filter { cameraID == nil || $0.cameraID == cameraID }
            .sorted {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(limit)
            .map(Event.init)
        let output = Output(source: snapshot.source.rawValue, status: snapshot.status.rawValue,
                            capturedAt: snapshot.capturedAt, events: records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return ACTAActionResult(actionID: id, success: true, summary: "Read local ISAPI event metadata.",
                                outputJSON: String(decoding: try encoder.encode(output), as: UTF8.self))
    }

    private struct Event: Encodable {
        let id: UUID
        let cameraID: UUID
        let eventType: String
        let eventState: String?
        let occurredAt: Date?
        let receivedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case cameraID = "camera_id"
            case eventType = "event_type"
            case eventState = "event_state"
            case occurredAt = "occurred_at"
            case receivedAt = "received_at"
        }

        init(_ record: ISAPIEventRecord) {
            id = record.id
            cameraID = record.cameraID
            eventType = record.eventType
            eventState = record.eventState
            occurredAt = record.occurredAt
            receivedAt = record.receivedAt
        }
    }

    private struct Output: Encodable {
        let source: String
        let status: String
        let capturedAt: Date
        let events: [Event]

        enum CodingKeys: String, CodingKey {
            case source, status, events
            case capturedAt = "captured_at"
        }
    }
}
