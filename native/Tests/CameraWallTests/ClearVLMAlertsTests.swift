import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ClearVLMAlertsTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: WallModel
        let coordinator: CameraFeatureCoordinator
        let clips: CriticalAlertClipStore
        let alert: VLMAlert
        let otherClipID: UUID
        let frames: [Data]
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-vlm-alerts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let preferencesURL = root.appendingPathComponent("features.json")
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.operationalAlerts]), to: preferencesURL
        )
        let coordinator = CameraFeatureCoordinator(
            preferencesURL: preferencesURL, databaseURL: root.appendingPathComponent("features.sqlite")
        )
        let clips = CriticalAlertClipStore(url: root.appendingPathComponent("clips"))
        let now = Date()
        let cameraID = UUID()
        let alertID = UUID()
        let otherClipID = UUID()
        let frames = [Data([1, 2, 3]), Data([4, 5, 6])]
        let lookback = frames.enumerated().map { index, data in
            AlertLookbackFrame(serial: UInt64(index), capturedAt: now.addingTimeInterval(Double(index) - 1), jpegData: data)
        }
        try clips.save(alertID: alertID, cameraID: cameraID, frames: lookback, now: now)
        try clips.save(alertID: otherClipID, cameraID: cameraID, frames: lookback, now: now)
        let alert = VLMAlert(id: alertID, cameraID: cameraID, cameraName: "Synthetic camera",
                             condition: "Synthetic condition", evidence: "Synthetic evidence", clipID: alertID)
        try VLMStore.save([alert], to: root.appendingPathComponent("vlm-alerts.json"))
        try coordinator.reviewOperationsAlert(alertID: alertID, status: .acknowledged, note: "Synthetic review")

        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let model = WallModel(
            configURL: root.appendingPathComponent("cameras.json"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: coordinator,
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ClearAlertsTestCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: clips,
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json")
        )
        defer { model.shutdown() }
        try body(Fixture(root: root, model: model, coordinator: coordinator, clips: clips,
                         alert: alert, otherClipID: otherClipID, frames: frames))
    }

    func testFailedSavePreservesGUIClipsAndReviews() throws {
        try withFixture { fixture in
            let model = fixture.model
            let reviews = model.operationsAlertReviews
            let acknowledgements = model.operationsAlertAcknowledgements
            let audit = try fixture.coordinator.operationsAlertReviewAudit(alertID: fixture.alert.id)
            XCTAssertEqual(model.vlmAlerts, [fixture.alert])
            XCTAssertNotNil(reviews[fixture.alert.id])
            XCTAssertNotNil(acknowledgements[fixture.alert.id])
            XCTAssertFalse(audit.isEmpty)
            XCTAssertTrue(model.actaVLMAlertsLoaded)

            let alertsURL = fixture.root.appendingPathComponent("vlm-alerts.json")
            let savedURL = fixture.root.appendingPathComponent("saved-alerts.json")
            try FileManager.default.moveItem(at: alertsURL, to: savedURL)
            try FileManager.default.createDirectory(at: alertsURL, withIntermediateDirectories: false)
            model.clearVLMAlerts()

            XCTAssertEqual(model.vlmAlerts, [fixture.alert])
            XCTAssertEqual(model.operationsAlertReviews, reviews)
            XCTAssertEqual(model.operationsAlertAcknowledgements, acknowledgements)
            XCTAssertFalse(model.actaVLMAlertsLoaded)
            XCTAssertNotNil(model.error)
            XCTAssertTrue(model.notice.contains("Could not clear local VLM alerts"))
            XCTAssertEqual(try VLMStore.loadAlerts(from: savedURL), [fixture.alert])
            XCTAssertEqual(try fixture.clips.frames(for: fixture.alert.id), fixture.frames)
            XCTAssertEqual(try fixture.clips.frames(for: fixture.otherClipID), fixture.frames)
            let disk = try fixture.coordinator.readOpenAlertState(includeExpired: true)
            XCTAssertEqual(disk.reviews, reviews)
            XCTAssertEqual(disk.acknowledgements, acknowledgements)
            XCTAssertEqual(try fixture.coordinator.operationsAlertReviewAudit(alertID: fixture.alert.id), audit)
        }
    }

    func testSuccessfulGUIClearRemovesLinkedClipAndReviewState() throws {
        try withFixture { fixture in
            let model = fixture.model
            XCTAssertEqual(model.vlmAlerts, [fixture.alert])
            XCTAssertNotNil(model.operationsAlertReviews[fixture.alert.id])
            model.clearVLMAlerts()

            XCTAssertTrue(model.vlmAlerts.isEmpty)
            XCTAssertTrue(model.operationsAlertReviews.isEmpty)
            XCTAssertTrue(model.operationsAlertAcknowledgements.isEmpty)
            XCTAssertNil(model.error)
            XCTAssertEqual(try VLMStore.loadAlerts(from: model.vlmAlertsURL), [])
            XCTAssertThrowsError(try fixture.clips.frames(for: fixture.alert.id))
            XCTAssertNoThrow(try fixture.clips.delete(fixture.alert.id))
            XCTAssertEqual(try fixture.clips.frames(for: fixture.otherClipID), fixture.frames)
            let disk = try fixture.coordinator.readOpenAlertState(includeExpired: true)
            XCTAssertTrue(disk.reviews.isEmpty)
            XCTAssertTrue(disk.acknowledgements.isEmpty)
            XCTAssertTrue(try fixture.coordinator.operationsAlertReviewAudit(alertID: fixture.alert.id).isEmpty)
        }
    }

    func testClipFailureReportsPartialClear() throws {
        try withFixture { fixture in
            try Data("{broken".utf8).write(to: fixture.root.appendingPathComponent("clips/index.json"))
            fixture.model.clearVLMAlerts()
            XCTAssertTrue(fixture.model.vlmAlerts.isEmpty)
            XCTAssertTrue(fixture.model.notice.contains("some clips or review state"))
            XCTAssertNotNil(fixture.model.error)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("clips/\(fixture.alert.id.uuidString.lowercased())").path
            ))
        }
    }

    func testClipDirectoryDeletionFailureIsReported() throws {
        try withFixture { fixture in
            let directory = fixture.root.appendingPathComponent("clips/\(fixture.alert.id.uuidString.lowercased())")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            fixture.model.clearVLMAlerts()
            XCTAssertTrue(fixture.model.vlmAlerts.isEmpty)
            XCTAssertTrue(fixture.model.notice.contains("some clips or review state"))
            XCTAssertNotNil(fixture.model.error)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
    }
}

private struct ClearAlertsTestCredentials: CameraCredentialStore {
    func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential read"); return nil }
    func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential save") }
    func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal") }
}
