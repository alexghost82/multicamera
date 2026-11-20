import XCTest
@testable import CameraCore

final class CameraFeatureCoordinatorTests: XCTestCase {
    func testReadingDefaultsDoesNotCreateSidecarFiles() throws {
        let paths = try makePaths()
        let coordinator = makeCoordinator(paths)

        XCTAssertEqual(try coordinator.preferences(), CameraFeaturePreferences())
        XCTAssertTrue(try coordinator.operationsAlertReviews().isEmpty)
        XCTAssertTrue(try coordinator.operationsAlertReviewAudit(alertID: UUID()).isEmpty)
        XCTAssertThrowsError(try coordinator.reviewOperationsAlert(alertID: UUID(), priority: .critical))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    func testDisabledFeatureEnqueueDoesNotCreateDatabase() throws {
        let paths = try makePaths()
        let coordinator = makeCoordinator(paths)

        XCTAssertThrowsError(try coordinator.enqueue(featureID: .publicShowcase)) { error in
            guard case CameraFeatureStoreError.featureDisabled(.publicShowcase) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.database.path))
    }

    func testOptedInJobSurvivesCoordinatorShutdownAndReopen() throws {
        let paths = try makePaths()
        let preferences = CameraFeaturePreferences(enabledFeatures: [.historyResearch])
        let coordinator = makeCoordinator(paths)
        try coordinator.savePreferences(preferences)
        let job = try coordinator.enqueue(
            featureID: .historyResearch,
            payloadJSON: #"{"query":"local history"}"#
        )

        coordinator.shutdown()
        let reopened = makeCoordinator(paths)
        XCTAssertEqual(try reopened.preferences(), preferences)
        XCTAssertEqual(try reopened.claimNext()?.id, job.id)
    }

    func testDescriptionRetryRejectsChangedFeaturePolicy() throws {
        let paths = try makePaths()
        let coordinator = makeCoordinator(paths)
        try coordinator.savePreferences(CameraFeaturePreferences(enabledFeatures: [.visionDescriptions]))
        let job = try coordinator.enqueue(featureID: .visionDescriptions)
        _ = try coordinator.claimNext(featureID: .visionDescriptions)
        let store = try CameraFeatureStore(url: paths.database)
        try store.fail(jobID: job.id, message: "Synthetic failure")
        let snapshot = try coordinator.descriptionJobSnapshot(id: job.id)
        let operationID = UUID()
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: paths.preferences)
        XCTAssertThrowsError(try coordinator.retryDescriptionJob(snapshot: snapshot, operationID: operationID))
        XCTAssertFalse(try coordinator.hasDescriptionRetryReceipt(.init(jobID: job.id, operationID: operationID)))
        XCTAssertEqual(try store.jobs(featureID: .visionDescriptions).first?.status, .failed)
    }

    private func makeCoordinator(_ paths: Paths) -> CameraFeatureCoordinator {
        CameraFeatureCoordinator(
            preferencesURL: paths.preferences,
            databaseURL: paths.database
        )
    }

    private func makePaths() throws -> Paths {
        let fixture = try IsolatedStoreTestDirectory()
        addTeardownBlock { try fixture.remove() }
        let directory = fixture.url.appendingPathComponent("store", isDirectory: true)
        return Paths(
            directory: directory,
            preferences: directory.appendingPathComponent("feature-preferences.json"),
            database: directory.appendingPathComponent("feature-jobs.sqlite3")
        )
    }

    private struct Paths {
        let directory: URL
        let preferences: URL
        let database: URL
    }
}