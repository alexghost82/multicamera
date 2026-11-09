import XCTest
@testable import CameraCore

final class CameraFeatureCoordinatorTests: XCTestCase {
    func testReadingDefaultsDoesNotCreateSidecarFiles() throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let coordinator = makeCoordinator(paths)

        XCTAssertEqual(try coordinator.preferences(), CameraFeaturePreferences())
        XCTAssertTrue(try coordinator.operationsAlertReviews().isEmpty)
        XCTAssertTrue(try coordinator.operationsAlertReviewAudit(alertID: UUID()).isEmpty)
        XCTAssertThrowsError(try coordinator.reviewOperationsAlert(alertID: UUID(), priority: .critical))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    func testDisabledFeatureEnqueueDoesNotCreateDatabase() throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let coordinator = makeCoordinator(paths)

        XCTAssertThrowsError(try coordinator.enqueue(featureID: .publicShowcase)) { error in
            guard case CameraFeatureStoreError.featureDisabled(.publicShowcase) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.database.path))
    }

    func testOptedInJobSurvivesCoordinatorShutdownAndReopen() throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
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

    private func makeCoordinator(_ paths: Paths) -> CameraFeatureCoordinator {
        CameraFeatureCoordinator(
            preferencesURL: paths.preferences,
            databaseURL: paths.database
        )
    }

    private func makePaths() -> Paths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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