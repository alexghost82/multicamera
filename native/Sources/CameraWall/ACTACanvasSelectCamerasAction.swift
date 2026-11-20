import CameraCore
import Foundation

struct ACTACanvasSelectCamerasAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let lifecycleRevision: UUID
        let stateRevision: UUID
        let previous: Set<UUID>?
        let inventory: Set<UUID>
        let selected: Set<UUID>
        let inventoryRevision: UUID
        let parameters: [String: String]
        let threadID: String
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
    var inventoryRevision: @MainActor @Sendable () -> UUID? = { nil }

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
            guard let state = bridge.activeState else {
                throw ConfigurationError.invalid("UNAVAILABLE: No unique active camera view or valid enabled-camera inventory.")
            }
            let lifecycle = bridge.lifecycleRevision
            let stateRevision = state.reviewRevision
            guard let revision = inventoryRevision(), let ids = enabledCameraIDs(),
                  Set(ids).count == ids.count, inventoryRevision() == revision,
                  bridge.lifecycleRevision == lifecycle, bridge.activeState === state,
                  state.reviewRevision == stateRevision else {
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
                snapshot: ConfirmationSnapshot(lifecycleRevision: lifecycle,
                    stateRevision: stateRevision, previous: state.selectedCameraIDs,
                    inventory: inventory, selected: selected, inventoryRevision: revision,
                    parameters: parameters, threadID: context.threadID),
                reviewSummary: "Unique active camera view. Previous selection: \(previous). New selection: \(display(selected)).")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let selection = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearSelectionWrite()
            guard context.isConfirmed, parameters == snapshot.parameters, context.threadID == snapshot.threadID,
                  selection.resolve(inventory: snapshot.inventory) == snapshot.selected else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Camera selection changed.")
            }
            guard bridge.lifecycleRevision == snapshot.lifecycleRevision, let state = bridge.activeState,
                  state.reviewRevision == snapshot.stateRevision, state.selectedCameraIDs == snapshot.previous,
                  let revision = state.commitReviewed(expectedRevision: snapshot.stateRevision, isValid: {
                      guard inventoryRevision() == snapshot.inventoryRevision,
                            let ids = enabledCameraIDs(), Set(ids).count == ids.count,
                            Set(ids) == snapshot.inventory, inventoryRevision() == snapshot.inventoryRevision else {
                          return false
                      }
                      return !Task.isCancelled && bridge.lifecycleRevision == snapshot.lifecycleRevision && bridge.activeState === state
                  }, update: { $0.selectedCameraIDs = snapshot.selected }),
                  state.reviewRevision == revision, state.selectedCameraIDs == snapshot.selected,
                  bridge.lifecycleRevision == snapshot.lifecycleRevision, bridge.activeState === state else {
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Camera selection, inventory or window changed.")
            }
            bridge.recordSelectionWrite(to: state, inventory: snapshot.inventory, selection: snapshot.selected,
                                        inventoryRevision: snapshot.inventoryRevision)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera picker selection updated; rendering and camera connectivity were not verified.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let selection = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            bridge.clearSelectionWrite()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active camera view or valid enabled-camera inventory.")
            }
            let lifecycle = bridge.lifecycleRevision
            let stateRevision = state.reviewRevision
            let revision = inventoryRevision()
            guard let ids = enabledCameraIDs(), Set(ids).count == ids.count, inventoryRevision() == revision,
                  bridge.lifecycleRevision == lifecycle, bridge.activeState === state,
                  state.reviewRevision == stateRevision else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active camera view or valid enabled-camera inventory.")
            }
            let inventory = Set(ids)
            guard let selected = selection.resolve(inventory: inventory) else {
                return .failed(actionID: id, error: "INVALID_ARGUMENT: Camera IDs must be currently enabled.")
            }
            guard state.commitReviewed(expectedRevision: stateRevision, isValid: {
                guard inventoryRevision() == revision, let currentIDs = enabledCameraIDs(),
                      Set(currentIDs).count == currentIDs.count, Set(currentIDs) == inventory,
                      inventoryRevision() == revision else { return false }
                return !Task.isCancelled && bridge.lifecycleRevision == lifecycle && bridge.activeState === state
            }, update: { $0.selectedCameraIDs = selected }) != nil else {
                bridge.clearSelectionWrite()
                try Task.checkCancellation()
                return .failed(actionID: id, error: "STALE_REVIEW: Camera selection, inventory or window changed.")
            }
            bridge.recordSelectionWrite(to: state, inventory: inventory, selection: selected, inventoryRevision: revision)
            guard bridge.verifiesSelection(inventory: inventory, selection: selected, inventoryRevision: revision) else {
                return .failed(actionID: id, error: "Camera selection state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera picker selection updated; rendering and camera connectivity were not verified.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let selection = try parse(parameters)
        return await MainActor.run {
            let revision = inventoryRevision()
            guard let ids = enabledCameraIDs(), Set(ids).count == ids.count,
                  inventoryRevision() == revision else { return false }
            let inventory = Set(ids)
            guard let selected = selection.resolve(inventory: inventory) else { return false }
            return bridge.verifiesSelection(inventory: inventory, selection: selected, inventoryRevision: revision)
        }
    }
}
