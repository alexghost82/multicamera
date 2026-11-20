import CameraCore
import Foundation

/// A confirmation applies only to the exact draft the operator reviewed.
enum ACTAAnalyticsDraftDeletion {
    struct Override {
        let cameraID: UUID
        let reviewed: CameraAnalyticsOverride

        init?(cameraID: UUID, settings: VideoAnalyticsSettings) {
            guard let value = settings.cameraOverrides[cameraID], value.cameraID == cameraID else { return nil }
            self.cameraID = cameraID
            self.reviewed = value
        }

        func apply(to settings: inout VideoAnalyticsSettings) -> Bool {
            guard settings.cameraOverrides[cameraID] == reviewed else { return false }
            settings.cameraOverrides.removeValue(forKey: cameraID)
            return true
        }
    }

    struct Zone {
        let zone: RestrictedZoneRegion
        private let reviewed: [RestrictedZoneRegion]

        init?(id: UUID, zones: [RestrictedZoneRegion]) {
            let matches = zones.filter { $0.id == id }
            guard matches.count == 1, let zone = matches.first else { return nil }
            self.zone = zone
            self.reviewed = zones
        }

        func apply(to zones: inout [RestrictedZoneRegion]) -> Bool {
            guard zones == reviewed, let index = zones.firstIndex(where: { $0.id == zone.id }) else { return false }
            zones.remove(at: index)
            return true
        }
    }
}
