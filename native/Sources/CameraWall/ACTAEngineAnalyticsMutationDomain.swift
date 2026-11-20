import CameraCore
import Foundation

@MainActor
final class ACTAEngineAnalyticsMutationDomain: ACTAAnalyticsSettingsMutationDomain {
    private weak var engine: LocalVideoAnalyticsEngine?

    init(engine: LocalVideoAnalyticsEngine) { self.engine = engine }

    func capture() throws -> ACTAAnalyticsSettingsObservation {
        guard let engine, engine.auditLog.lastPersistenceError == nil else {
            throw ConfigurationError.invalid("Analytics engine or audit is unavailable.")
        }
        return try engine.reviewedSettingsSnapshot()
    }

    func commit(expected: ACTAAnalyticsSettingsObservation,
                replacement: VideoAnalyticsSettings) throws -> ACTAAnalyticsSettingsObservation? {
        guard let engine else { throw ConfigurationError.invalid("Analytics engine is unavailable.") }
        guard try capture() == expected else { return nil }
        try engine.updateSettings(replacement, expectedRevision: expected.revision)
        guard engine.auditLog.lastPersistenceError == nil else {
            throw ConfigurationError.invalid("Analytics audit failed; outcome may be unknown.")
        }
        return try capture()
    }
}
