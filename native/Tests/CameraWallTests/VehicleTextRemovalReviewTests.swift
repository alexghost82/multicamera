import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class VehicleTextRemovalReviewTests: XCTestCase {
    func testOnlyReviewedEvidenceCanBeRemoved() {
        let trackID = UUID()
        let evidence = VehicleTextEvidence(
            trackID: trackID,
            candidates: [VehicleTextCandidate(text: "FAKE123", confidence: 0.9)],
            readAt: Date(timeIntervalSince1970: 123),
            cropSHA256: String(repeating: "a", count: 64)
        )
        let review = VehicleTextRemovalReview(evidence: evidence)
        let replacement = VehicleTextEvidence(
            trackID: trackID,
            candidates: [VehicleTextCandidate(text: "FAKE456", confidence: 0.9)],
            readAt: evidence.readAt,
            cropSHA256: evidence.cropSHA256
        )
        var removed: [VehicleTextEvidence] = []
        XCTAssertFalse(review.apply(current: nil) { removed.append($0) })
        XCTAssertFalse(review.apply(current: replacement) { removed.append($0) })
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(review.apply(current: evidence) { removed.append($0) })
        XCTAssertEqual(removed, [evidence])
    }

    @MainActor
    func testModelDoesNotRemoveEvidenceChangedOutsideItsCache() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let root = IsolatedWallFixtureSupport.root()
        try IsolatedWallFixtureSupport.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let trackingURL = root.appendingPathComponent("tracks.sqlite")
        let store = try LocalTrackingStore(url: trackingURL)
        let trackID = UUID()
        try store.record(DetectedObject(id: 1, label: "car", confidence: 0.9, box: .zero, trackID: trackID),
                         cameraID: UUID(), cameraName: "Fixture", at: Date())
        let reviewed = VehicleTextEvidence(trackID: trackID,
            candidates: [VehicleTextCandidate(text: "FAKE123", confidence: 0.9)],
            cropSHA256: String(repeating: "a", count: 64))
        let replacement = VehicleTextEvidence(trackID: trackID,
            candidates: [VehicleTextCandidate(text: "FAKE456", confidence: 0.9)],
            cropSHA256: String(repeating: "b", count: 64))
        try store.saveVehicleTextEvidence(replacement)
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            workerMode: false, poseModelURL: root.appendingPathComponent("unused.mlmodel"),
            trackingStoreURL: trackingURL,
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { model.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(model)
        model.savedVehicleTextEvidence[trackID] = reviewed
        let review = VehicleTextRemovalReview(evidence: reviewed)
        XCTAssertTrue(review.apply(current: model.savedVehicleTextEvidence[trackID],
                                   remove: model.clearVehicleTextEvidence(matching:)))
        XCTAssertEqual(try store.vehicleTextEvidence(for: trackID), replacement)
        XCTAssertEqual(model.notice, "Saved vehicle text changed; review it again before removing.")
    }
}
