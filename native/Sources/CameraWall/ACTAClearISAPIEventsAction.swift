import CameraCore
import Foundation

enum ACTAClearISAPIEventsError: Error {
    case confirmationRequired
    case unavailable
    case invalidData
    case changed
    case partialFailure
}

@MainActor
protocol ACTAISAPIEventMemory: Sendable {
    var isAvailable: Bool { get }
    var events: [ISAPIEventRecord] { get }
    func clearEvents() -> Bool
}

@MainActor
final class ACTAWallISAPIEventMemory: ACTAISAPIEventMemory {
    private weak var model: WallModel?

    init(model: WallModel) { self.model = model }
    var isAvailable: Bool { model?.actaISAPIEventsLoaded == true }
    var events: [ISAPIEventRecord] { model?.isapiEvents ?? [] }
    func clearEvents() -> Bool {
        guard let model else { return false }
        model.isapiEvents = []
        return true
    }
}

/// Shared synchronous main-actor operation for the GUI and the agent.
/// The byte comparison is an optimistic check, not an interprocess lock or CAS.
@MainActor
final class ACTAClearISAPIEventsService {
    private let memory: any ACTAISAPIEventMemory
    private let read: () throws -> Data
    private let writeEmpty: () throws -> Void

    init(memory: any ACTAISAPIEventMemory, url: URL) {
        self.memory = memory
        self.read = { try Data(contentsOf: url) }
        self.writeEmpty = { try ISAPIEventStore.save([], to: url) }
    }

    init(memory: any ACTAISAPIEventMemory, read: @escaping () throws -> Data,
         writeEmpty: @escaping () throws -> Void) {
        self.memory = memory
        self.read = read
        self.writeEmpty = writeEmpty
    }

    func clear(confirmed: Bool) throws {
        guard confirmed else { throw ACTAClearISAPIEventsError.confirmationRequired }
        guard memory.isAvailable else { throw ACTAClearISAPIEventsError.unavailable }
        let before: Data
        do { before = try read() }
        catch { throw ACTAClearISAPIEventsError.unavailable }

        let disk: [ISAPIEventRecord]
        do { disk = try JSONDecoder().decode([ISAPIEventRecord].self, from: before) }
        catch { throw ACTAClearISAPIEventsError.invalidData }
        let live = memory.events
        let diskByID = Dictionary(disk.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard diskByID.count == disk.count, live.count == disk.count,
              Set(live.map(\.id)).count == live.count,
              live.allSatisfy({ diskByID[$0.id] == $0 }) else {
            throw ACTAClearISAPIEventsError.changed
        }
        do {
            guard try read() == before else { throw ACTAClearISAPIEventsError.changed }
        } catch let error as ACTAClearISAPIEventsError {
            throw error
        } catch {
            throw ACTAClearISAPIEventsError.unavailable
        }

        // Even a throwing save may have replaced the file (for example chmod failure).
        do {
            try writeEmpty()
            let persisted = try JSONDecoder().decode([ISAPIEventRecord].self, from: read())
            guard persisted.isEmpty else { throw ACTAClearISAPIEventsError.partialFailure }
        } catch {
            throw ACTAClearISAPIEventsError.partialFailure
        }
        guard memory.clearEvents() else { throw ACTAClearISAPIEventsError.partialFailure }
    }

    func isCleared() throws -> Bool {
        guard memory.isAvailable else { throw ACTAClearISAPIEventsError.unavailable }
        let persisted = try JSONDecoder().decode([ISAPIEventRecord].self, from: read())
        return persisted.isEmpty && memory.events.isEmpty
    }
}

struct ACTAClearISAPIEventsAction: ACTAActionProtocol {
    let service: ACTAClearISAPIEventsService
    let id = "monitor.clear_isapi_events"
    let title = "Clear ISAPI event history"
    let description = "Permanently clear local ISAPI event history after operator confirmation."
    let classification = ACTAActionClassification.destructive
    let parameters: [ACTAActionParameterSchema] = []

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown parameter.") }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        return await MainActor.run {
            do {
                try service.clear(confirmed: context.isConfirmed)
                return ACTAActionResult(actionID: id, success: true,
                                        summary: "ISAPI event history cleared and verified on disk.")
            } catch ACTAClearISAPIEventsError.confirmationRequired {
                return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
            } catch ACTAClearISAPIEventsError.invalidData {
                return .failed(actionID: id, error: "INVALID_DATA: ISAPI history is invalid; nothing was cleared.")
            } catch ACTAClearISAPIEventsError.changed {
                return .failed(actionID: id, error: "CONFLICT: ISAPI history changed; nothing was cleared.")
            } catch ACTAClearISAPIEventsError.partialFailure {
                return .failed(actionID: id, error: "PARTIAL_FAILURE: The disk may have changed; memory was not cleared.")
            } catch {
                return .failed(actionID: id, error: "UNAVAILABLE: ISAPI history is unavailable; nothing was cleared.")
            }
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try validate(parameters: parameters)
        return try await MainActor.run { try service.isCleared() }
    }
}
