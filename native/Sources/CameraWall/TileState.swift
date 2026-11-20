import CameraCore
import Combine
import CoreGraphics
import Foundation

@MainActor
final class TileState: ObservableObject, Identifiable {
    let id: UUID
    @Published var frame = SessionFrame()
    @Published var stale = true
    @Published var objects: [DetectedObject] = []
    @Published var poseTracks: [TrackedPersonPose] = []
    @Published var restrictedZones: [RestrictedZoneRegion] = []
    @Published var hasCriticalSafetyIncident = false
    var detectionAt: TimeInterval = 0
    var detectionImageSize = CGSize.zero
    var detectionSerial: UInt64 = 0
    var inferenceMilliseconds: Double = 0
    var inferenceCount = 0
    var session: CameraSession?
    init(id: UUID) { self.id = id }
    func stop(tracking tracker: CameraSessionDrainTracker) {
        if let session { tracker.stop(session) }
        session = nil
        frame = SessionFrame()
        stale = true
        objects = []
        poseTracks = []
        restrictedZones = []
        hasCriticalSafetyIncident = false
        detectionAt = 0
        detectionSerial = 0
        inferenceMilliseconds = 0
        inferenceCount = 0
    }
}
