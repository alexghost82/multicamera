import CameraCore
import Foundation

/// WallModel does not yet use this contract. A conforming domain must
/// serialize every GUI, legacy and cross-process writer of configuration,
/// identity and relevant runtime state. Capture must reject missing, duplicate,
/// unreadable or divergent memory/disk state. The never-reused revision covers
/// all of that state, including ABA and effects eligibility. Commit atomically
/// compares the observation, checks that effects are impossible, and changes
/// only the requested flag; it must not start/stop streams, inference or other
/// services. It returns nil without a write when stale or unsafe. Errors may
/// mean an unknown outcome. Readback does not establish crash durability.
@MainActor
protocol ACTACameraFlagsReviewDomain: Sendable {
    func capture(cameraID: UUID) throws -> ACTACameraFlagsObservation?
    func commit(expected: ACTACameraFlagsObservation, field: ACTACameraFlag,
                value: Bool) throws -> ACTACameraFlagsObservation?
}

enum ACTACameraFlag: String, Sendable {
    case enabled, yolo, aiChat = "ai_chat"
}

struct ACTACameraFlagsObservation: Sendable, Equatable {
    let revision: UUID
    let cameraID: UUID
    let enabled: Bool
    let yolo: Bool
    let aiChat: Bool

    func value(_ field: ACTACameraFlag) -> Bool {
        switch field {
        case .enabled: return enabled
        case .yolo: return yolo
        case .aiChat: return aiChat
        }
    }

    func replacing(_ field: ACTACameraFlag, value: Bool, revision: UUID) -> Self {
        Self(revision: revision, cameraID: cameraID,
             enabled: field == .enabled ? value : enabled,
             yolo: field == .yolo ? value : yolo,
             aiChat: field == .aiChat ? value : aiChat)
    }
}

/// Deliberately unregistered until WallModel writers and runtime participate
/// in the coordinated domain. Normal setters have service and inference effects.
struct ACTAPreparedCameraFlagsAction: ACTAPreparedConfirmationAction {
    enum Kind: Sendable {
        case enabled, processing
    }

    @MainActor
    final class State {
        var receipt: (parameters: [String: String], threadID: String, observation: ACTACameraFlagsObservation)?
    }

    @MainActor
    final class Ticket {
        let owner: State
        var used = false
        init(owner: State) { self.owner = owner }
    }

    struct ConfirmationSnapshot: Sendable {
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let before: ACTACameraFlagsObservation
        fileprivate let ticket: Ticket
    }

    let kind: Kind
    private let domain: any ACTACameraFlagsReviewDomain
    private let state: State

    @MainActor
    init(kind: Kind, domain: any ACTACameraFlagsReviewDomain) {
        self.kind = kind
        self.domain = domain
        self.state = State()
    }

    var id: String { kind == .enabled ? "camera.set_enabled" : "camera.set_processing" }
    var title: String { kind == .enabled ? "Set Camera Enabled" : "Set Camera Processing" }
    let description = "Review a camera flag in an isolated configuration domain without service effects."
    let classification = ACTAActionClassification.serviceAffecting
    var parameters: [ACTAActionParameterSchema] {
        var fields = [
            ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID", isRequired: true),
            ACTAActionParameterSchema(name: "enabled", type: "boolean", description: "Requested flag value", isRequired: true)
        ]
        if kind == .processing {
            fields.append(ACTAActionParameterSchema(name: "feature", type: "string", description: "Processing flag",
                                                    isRequired: true, allowedValues: ["yolo", "ai_chat"]))
        }
        return fields
    }

    private func parse(_ parameters: [String: String]) throws -> (UUID, ACTACameraFlag, Bool) {
        let keys: Set<String> = kind == .enabled ? ["camera_id", "enabled"] : ["camera_id", "enabled", "feature"]
        guard Set(parameters.keys) == keys, let rawID = parameters["camera_id"],
              let cameraID = UUID(uuidString: rawID), rawID.uppercased() == cameraID.uuidString,
              let rawValue = parameters["enabled"], rawValue == "true" || rawValue == "false" else {
            throw FlagError.invalid
        }
        let field: ACTACameraFlag
        if kind == .enabled { field = .enabled }
        else {
            guard let raw = parameters["feature"], let parsed = ACTACameraFlag(rawValue: raw),
                  parsed != .enabled else { throw FlagError.invalid }
            field = parsed
        }
        return (cameraID, field, rawValue == "true")
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (cameraID, field, value) = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            let before: ACTACameraFlagsObservation
            do {
                guard let captured = try domain.capture(cameraID: cameraID), captured.cameraID == cameraID else {
                    throw FlagError.unavailable
                }
                before = captured
            } catch { throw FlagError.unavailable }
            let summary = "Camera UUID: \(cameraID.uuidString). \(field.rawValue): \(before.value(field)) -> \(value). No immediate service effects; a later service start may use this flag. Readback does not establish crash durability."
            return ACTAPreparedConfirmation(snapshot: ConfirmationSnapshot(
                parameters: parameters, threadID: context.threadID, before: before, ticket: Ticket(owner: state)),
                reviewSummary: summary)
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        try await MainActor.run {
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            try Task.checkCancellation()
            guard snapshot.parameters == parameters, snapshot.threadID == context.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
            }
            let (cameraID, field, value) = try parse(parameters)
            guard state.receipt == nil else {
                return .failed(actionID: id, error: "ACTION_BUSY: A previous update awaits verification.")
            }
            let committed: ACTACameraFlagsObservation?
            do { committed = try domain.commit(expected: snapshot.before, field: field, value: value) }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let committed else {
                return .failed(actionID: id, error: "STALE_OR_UNSAFE: Camera state changed or effects cannot be excluded.")
            }
            do {
                guard committed.revision != snapshot.before.revision,
                      committed == snapshot.before.replacing(field, value: value, revision: committed.revision),
                      try domain.capture(cameraID: cameraID) == committed else {
                    return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.")
                }
            } catch { return .failed(actionID: id, error: "READBACK_FAILED: Outcome may be unknown.") }
            state.receipt = (parameters, context.threadID, committed)
            let output = try JSONSerialization.data(withJSONObject: [
                "camera_id": cameraID.uuidString, "field": field.rawValue, "enabled": value
            ] as [String: Any])
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera flag updated and read back; crash durability and service readiness are not verified.",
                outputJSON: String(decoding: output, as: UTF8.self))
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard let receipt, receipt.parameters == parameters, receipt.threadID == context.threadID else { return false }
            return (try? domain.capture(cameraID: receipt.observation.cameraID)) == receipt.observation
        }
    }

    private enum FlagError: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Provide a camera UUID and valid flag."
            case .unavailable: return "UNAVAILABLE: Camera state cannot be safely reviewed."
            }
        }
    }
}
