import CameraCore
import Foundation

/// A point-in-time window-state snapshot, not proof of what is rendered.
struct ACTAScopedCanvasStateAction: ACTAActionProtocol {
    let id = "canvas.get_state"
    let title = "Inspect camera canvas state"
    let description = "Read a minimal snapshot of the unique attached camera view. Search and location contents and selected camera IDs are not disclosed. State may change after the snapshot; rendering and connectivity are not verified."
    let classification = ACTAActionClassification.inspect
    let parameters: [ACTAActionParameterSchema] = []
    let bridge: ACTACanvasFilterBridge

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: No parameters are accepted.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let snapshot = await MainActor.run { () -> Snapshot? in
            guard let state = bridge.activeState else { return nil }
            let status: String
            switch state.cameraScope {
            case .all: status = "all"
            case .live: status = "live"
            case .offline: status = "offline"
            }
            return Snapshot(presentation: state.presentation.rawValue, arrange_mode: state.arrangeCameras,
                            status: status, favorites_only: state.favoritesOnly, events_only: state.alertsOnly,
                            search_active: !state.searchText.isEmpty, location_active: state.locationFilter != nil,
                            selection_active: state.selectedCameraIDs != nil)
        }
        try Task.checkCancellation()
        guard let snapshot else {
            return .failed(actionID: id, error: "UNAVAILABLE: No unique attached camera view.")
        }
        let data = try JSONEncoder().encode(snapshot)
        return ACTAActionResult(actionID: id, success: true,
            summary: "Window state snapshot retrieved; rendering was not verified.",
            outputJSON: String(decoding: data, as: UTF8.self))
    }

    private struct Snapshot: Encodable, Sendable {
        let presentation: String
        let arrange_mode: Bool
        let status: String
        let favorites_only: Bool
        let events_only: Bool
        let search_active: Bool
        let location_active: Bool
        let selection_active: Bool
    }
}
