import CameraCore
import Foundation

/// Opt-in bridge for the scoped settings action; it does not register the action.
struct ACTAWallModelSettingsReadProvider: ACTAExistingSystemSettingsReadProvider {
    private let snapshot: @MainActor @Sendable () throws -> WallConfiguration

    @MainActor
    init(model: WallModel) {
        snapshot = { [weak model] in
            guard let model, model.error == nil else { throw SnapshotError.unavailable }
            var projection = WallConfiguration()
            projection.columns = model.config.columns
            projection.staleAfterMilliseconds = model.config.staleAfterMilliseconds
            projection.detectionThreshold = model.config.detectionThreshold
            projection.detectionFPS = model.config.detectionFPS
            return projection
        }
    }

    func loadExistingConfiguration() async throws -> WallConfiguration {
        try await snapshot()
    }

    private enum SnapshotError: Error { case unavailable }
}
