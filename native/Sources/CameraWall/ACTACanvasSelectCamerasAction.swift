import CameraCore
import Foundation

struct ACTACanvasSelectCamerasAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let lifecycleRevision: UUID
        let previous: Set<UUID>?
        let inventory: Set<UUID>
        let selected: Set<UUID>
    }
    let id = "canvas.select_cameras"
    let title = "Select cameras in the canvas"
    let description = "Set the camera picker in the unique attached security center. All selects the currently enabled cameras, none clears the selection, and subset requires enabled camera UUIDs. Selection is a snapshot, like the GUI; other filters are unchanged. Verification checks GUI state and the enabled-camera inventory, not rendering or connectivity."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "mode", type: "string", description: "Selection mode", isRequired: true, allowedValues: ["all", "none", "subset"]),
        ACTAActionParameterSchema(name: "camera_ids", type: "string", description: "For subset only: comma-separated enabled camera UUIDs")
    ]
    let bridge: ACTACanvasFilterBridge
    let enabledCameraIDs: @MainActor @Sendable () -> [UUID]?

    private enum Selection {
        case all, none, subset(Set<UUID>)

        func resolve(inventory: Set<UUID>) -> Set<UUID>? {
            switch self {
            case .all: return inventory
            case .none: return []
            case .subset(let ids): return ids.isSubset(of: inventory) ? ids : nil
            }
        }
    }

    private func parse(_ parameters: [String: String]) throws -> Selection {
        guard Set(parameters.keys).isSubset(of: ["mode", "camera_ids"]) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown selection parameter.")
        }
        switch parameters["mode"] {
        case "all" where parameters["camera_ids"] == nil: return .all
        case "none" where parameters["camera_ids"] == nil: return .none
        case "subset":
            guard let raw = parameters["camera_ids"], !raw.isEmpty, raw.utf8.count <= 4096 else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide camera UUIDs for subset.")
            }
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            let ids = parts.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !ids.isEmpty, ids.count == parts.count, Set(ids).count == ids.count else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Camera UUIDs must be valid and unique.")
            }
            return .subset(Set(ids))
        default:
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Use all, none, or subset; camera_ids is only valid for subset.")
        }
    }

    func validate(parameters: [String: String]) throws {
        _ = try parse(parameters)
    }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let selection = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState, let ids = enabledCameraIDs(), Set(ids).count == ids.count else {
                throw ConfigurationError.invalid("UNAVAILABLE: No unique active camera view or valid enabled-camera inventory.")
            }
            let inventory = Set(ids)
            guard let selected = selection.resolve(inventory: inventory) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Camera IDs must be currently enabled.")
            }
            func display(_ ids: Set<UUID>) -> String {
                ids.isEmpty ? "(none)" : ids.map(\.uuidString).sorted().joined(separator: ", ")
            }
            let previous = state.selectedCameraIDs.map(display) ?? "(automatic: all cameras)"
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(lifecycleRevision: bridge.lifecycleRevision,
                    previous: state.selectedCameraIDs, inventory: inventory, selected: selected),
                reviewSummary: "Unique active camera view. Previous selection: \(previous). New selection: \(display(selected)).")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let selection = try parse(parameters)
        guard selection.resolve(inventory: snapshot.inventory) == snapshot.selected else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Camera selection changed.")
        }
        return try await MainActor.run {
            try Task.checkCancellation()
            guard bridge.lifecycleRevision == snapshot.lifecycleRevision, let state = bridge.activeState,
                  state.selectedCameraIDs == snapshot.previous, let ids = enabledCameraIDs(),
                  Set(ids).count == ids.count, Set(ids) == snapshot.inventory else {
                return .failed(actionID: id, error: "STALE_REVIEW: Camera selection, inventory or window changed.")
            }
            state.selectedCameraIDs = snapshot.selected
            bridge.recordSelectionWrite(to: state, inventory: snapshot.inventory, selection: snapshot.selected)
            guard bridge.verifiesSelection(inventory: snapshot.inventory, selection: snapshot.selected) else {
                return .failed(actionID: id, error: "Camera selection state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera picker selection updated; rendering and camera connectivity were not verified.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let selection = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState, let ids = enabledCameraIDs(), Set(ids).count == ids.count else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active camera view or valid enabled-camera inventory.")
            }
            let inventory = Set(ids)
            guard let selected = selection.resolve(inventory: inventory) else {
                return .failed(actionID: id, error: "INVALID_ARGUMENT: Camera IDs must be currently enabled.")
            }
            state.selectedCameraIDs = selected
            bridge.recordSelectionWrite(to: state, inventory: inventory, selection: selected)
            guard bridge.verifiesSelection(inventory: inventory, selection: selected) else {
                return .failed(actionID: id, error: "Camera selection state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera picker selection updated; rendering and camera connectivity were not verified.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let selection = try parse(parameters)
        return await MainActor.run {
            guard let ids = enabledCameraIDs(), Set(ids).count == ids.count else { return false }
            let inventory = Set(ids)
            guard let selected = selection.resolve(inventory: inventory) else { return false }
            return bridge.verifiesSelection(inventory: inventory, selection: selected)
        }
    }
}
