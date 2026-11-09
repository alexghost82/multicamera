import XCTest
@testable import CameraCore

final class FeaturePreferencesTests: XCTestCase {
    func testDefaultsKeepEveryFeatureAndExternalCapabilityDisabled() {
        let preferences = CameraFeaturePreferences()

        XCTAssertTrue(preferences.enabledFeatures.isEmpty)
        XCTAssertFalse(preferences.retainFullFrames)
        XCTAssertFalse(preferences.allowExternalAI)
        XCTAssertFalse(preferences.allowVoiceInput)
        XCTAssertFalse(preferences.allowPlateRegistryLookup)
        XCTAssertFalse(preferences.allowPublicAccess)
        XCTAssertEqual(preferences.retentionDays, 30)
    }

    func testPreferencesRoundTripAndUsePrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("feature-preferences.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferences = CameraFeaturePreferences(
            enabledFeatures: [.crossCameraIdentity, .knowledgeSearch],
            retentionDays: 45
        )

        try CameraFeaturePreferencesStore.save(preferences, to: url)

        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), preferences)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLoadReturnsSafeDefaultsWhenSidecarDoesNotExist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("feature-preferences.json")

        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), CameraFeaturePreferences())
    }

    func testRetentionOutsideSupportedRangeIsRejected() {
        XCTAssertThrowsError(try CameraFeaturePreferences(retentionDays: 0).validate())
        XCTAssertThrowsError(try CameraFeaturePreferences(retentionDays: 366).validate())
    }
}