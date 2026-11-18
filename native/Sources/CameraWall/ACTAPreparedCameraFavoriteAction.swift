import CameraCore
import Foundation

/// A domain implementing this contract must serialize *all* preference and camera
/// identity writers, including other processes, with capture and commit. Capture
/// returns nil for a missing or ambiguous identity and must reject unreadable or
/// non-string preference values. The revision changes on every relevant write,
/// including ABA changes. Commit atomically compares the whole observation and
/// resolves the request, returning nil without writing on any mismatch; on success
/// it returns the post-write observation. Errors may mean an unknown outcome.
/// UserDefaults does not provide this contract; a MainActor lock is not sufficient.
@MainActor
protocol ACTAFavoriteReviewDomain: Sendable {
    func capture(request: String) throws -> ACTAFavoriteObservation?
    func commit(request: String, expected: ACTAFavoriteObservation,
                replacement: String?) throws -> ACTAFavoriteObservation?
}

struct ACTAFavoriteObservation: Sendable, Equatable {
    let revision: UUID
    let cameraID: UUID
    let preference: String?
}

/// This action is intentionally not registered. It requires a domain that can
/// enforce ACTAFavoriteReviewDomain for every writer, which UserDefaults cannot.
struct ACTAPreparedCameraFavoriteAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let parameters: [String: String]
        let before: ACTAFavoriteObservation
        let replacement: String?
    }

    @MainActor
    final class Receipt {
        var parameters: [String: String]?
        var threadID: String?
        var observation: ACTAFavoriteObservation?
    }

    let id = "camera.set_favorite"
    let title = "Set Camera Favorite"
    let description = "Review and change the complete favorite preference for one uniquely resolved camera. Readback does not establish disk durability."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or unique name", isRequired: true),
        ACTAActionParameterSchema(name: "favorite", type: "boolean", description: "True to add, false to remove", isRequired: true)
    ]
    let domain: any ACTAFavoriteReviewDomain
    private let receipt: Receipt

    @MainActor
    init(domain: any ACTAFavoriteReviewDomain) {
        self.domain = domain
        self.receipt = Receipt()
    }

    private func parse(_ parameters: [String: String]) throws -> (String, Bool) {
        guard Set(parameters.keys) == ["camera_id", "favorite"],
              let request = parameters["camera_id"], !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let favorite = parameters["favorite"], favorite == "true" || favorite == "false" else {
            throw FavoriteError.invalid
        }
        return (request, favorite == "true")
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    private func checkedIDs(_ preference: String?) throws -> Set<UUID> {
        guard let preference else { return [] }
        let ids = ACTACameraFavorites.decode(preference)
        // Reject malformed, duplicate, or noncanonical data rather than silently
        // dropping anything from the stored preference during the update.
        guard ACTACameraFavorites.encode(ids) == preference else { throw FavoriteError.invalidPreference }
        return ids
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (request, favorite) = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let before = try domain.capture(request: request) else { throw FavoriteError.unavailable }
            var ids = try checkedIDs(before.preference)
            let wasFavorite = ids.contains(before.cameraID)
            if favorite { ids.insert(before.cameraID) } else { ids.remove(before.cameraID) }
            let replacement = wasFavorite == favorite ? before.preference : ACTACameraFavorites.encode(ids)
            func display(_ value: String?) -> String { value.map { $0.isEmpty ? "(empty)" : $0 } ?? "(absent)" }
            let summary = "Camera UUID: \(before.cameraID.uuidString). Favorite: \(wasFavorite) -> \(favorite). Complete preference before: \(display(before.preference)). Complete preference after: \(display(replacement)). Readback does not verify disk durability."
            guard summary.utf8.count <= ACTAActionRegistry.maxPreparedReviewSummaryUTF8Bytes else {
                throw FavoriteError.invalidPreference
            }
            return ACTAPreparedConfirmation(snapshot: ConfirmationSnapshot(parameters: parameters, before: before,
                                                                            replacement: replacement),
                                            reviewSummary: summary)
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let (request, _) = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard receipt.observation == nil else {
                return .failed(actionID: id, error: "ACTION_BUSY: A previous favorite update awaits verification.")
            }
            guard parameters == snapshot.parameters else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Favorite request changed.")
            }
            let committed: ACTAFavoriteObservation?
            do {
                committed = try domain.commit(request: request, expected: snapshot.before,
                                              replacement: snapshot.replacement)
            } catch {
                return .failed(actionID: id, error: "Favorite commit failed; outcome may be unknown.")
            }
            guard let committed else {
                return .failed(actionID: id, error: "STALE_REVIEW: Camera or favorite preference changed.")
            }
            guard committed.cameraID == snapshot.before.cameraID,
                  committed.preference == snapshot.replacement else {
                return .failed(actionID: id, error: "Favorite preference readback failed; outcome may be unknown.")
            }
            let readback: ACTAFavoriteObservation?
            do { readback = try domain.capture(request: request) }
            catch { return .failed(actionID: id, error: "Favorite preference readback failed; outcome may be unknown.") }
            guard readback == committed else {
                return .failed(actionID: id, error: "Favorite preference readback failed; outcome may be unknown.")
            }
            receipt.parameters = parameters
            receipt.threadID = context.threadID
            receipt.observation = committed
            let output = try JSONSerialization.data(withJSONObject: [
                "camera_id": committed.cameraID.uuidString, "favorite": parameters["favorite"] == "true"
            ] as [String: Any])
            return ACTAActionResult(actionID: id, success: true,
                summary: "Favorite preference updated and read back; disk durability is not verified.",
                outputJSON: String(decoding: output, as: UTF8.self))
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let (request, _) = try parse(parameters)
        return await MainActor.run {
            let matches = receipt.parameters == parameters && receipt.threadID == context.threadID
            let observation = receipt.observation
            receipt.parameters = nil
            receipt.threadID = nil
            receipt.observation = nil
            guard matches, let observation else { return false }
            return (try? domain.capture(request: request)) == observation
        }
    }

    private enum FavoriteError: LocalizedError {
        case invalid, invalidPreference, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Provide a camera and boolean favorite."
            case .invalidPreference: return "UNAVAILABLE: Favorite preference cannot be safely reviewed."
            case .unavailable: return "UNAVAILABLE: Camera is missing or ambiguous."
            }
        }
    }
}
