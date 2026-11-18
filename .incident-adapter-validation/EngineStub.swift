import CameraCore
import Foundation
@MainActor final class LocalVideoAnalyticsEngine {
    let incidentManager = StubIncidentManager()
    let persistenceError: Error? = nil
}
@MainActor final class StubIncidentManager {
    let lastPersistenceError: Error? = nil
    func incident(id: UUID) -> SafetyIncident? { nil }
}
