import XCTest
import Darwin
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
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("feature-preferences.json")

        let preferences = CameraFeaturePreferences(
            enabledFeatures: [.crossCameraIdentity, .knowledgeSearch],
            retentionDays: 45
        )

        try CameraFeaturePreferencesStore.save(preferences, to: url)

        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), preferences)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.url.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLoadReturnsSafeDefaultsWhenSidecarDoesNotExist() throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("feature-preferences.json")

        XCTAssertEqual(try CameraFeaturePreferencesStore.load(from: url), CameraFeaturePreferences())
    }

    func testRetentionOutsideSupportedRangeIsRejected() {
        XCTAssertThrowsError(try CameraFeaturePreferences(retentionDays: 0).validate())
        XCTAssertThrowsError(try CameraFeaturePreferences(retentionDays: 366).validate())
    }

    func testUnsafePolicyLockRejectsBeforeSnapshotCallback() throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("features.json")
        let lock = directory.url.appendingPathComponent(".features.json.lock")
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
        var called = false
        XCTAssertThrowsError(try CameraFeaturePreferencesStore.withLockedSnapshot(from: url) { _ in
            called = true
        }) { XCTAssertEqual($0 as? CameraFeaturePreferencesStoreError, .unsafeLock) }
        XCTAssertFalse(called)
    }

    func testHardLinkedPolicyLockIsRejected() throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("features.json")
        let lock = directory.url.appendingPathComponent(".features.json.lock")
        let alias = directory.url.appendingPathComponent("lock-alias")
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        XCTAssertEqual(link(lock.path, alias.path), 0)
        XCTAssertThrowsError(try CameraFeaturePreferencesStore.withLockedSnapshot(from: url) { _ in
            XCTFail("An unsafe lock must not enter the callback")
        }) { XCTAssertEqual($0 as? CameraFeaturePreferencesStoreError, .unsafeLock) }
    }

    func testPolicyLockReplacementDuringCallbackReportsUncertainOutcome() throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("features.json")
        let lock = directory.url.appendingPathComponent(".features.json.lock")
        let oldLock = directory.url.appendingPathComponent("old-lock")
        var called = false
        XCTAssertThrowsError(try CameraFeaturePreferencesStore.withLockedSnapshot(from: url) { _ in
            called = true
            try FileManager.default.moveItem(at: lock, to: oldLock)
            try Data().write(to: lock)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        }) { XCTAssertEqual($0 as? CameraFeaturePreferencesStoreError, .unsafeLock) }
        XCTAssertTrue(called)
    }

    func testPolicySnapshotExcludesWriterAndRevisionDetectsABA() throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("features.json")
        let enabled = CameraFeaturePreferences(enabledFeatures: [.scheduledMissions])
        try CameraFeaturePreferencesStore.save(enabled, to: url)
        let first = try CameraFeaturePreferencesStore.withLockedSnapshot(from: url) { snapshot in
            XCTAssertThrowsError(try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: url)) {
                XCTAssertEqual($0 as? CameraFeaturePreferencesStoreError, .busy)
            }
            return snapshot
        }
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: url)
        try CameraFeaturePreferencesStore.save(enabled, to: url)
        let last = try CameraFeaturePreferencesStore.withLockedSnapshot(from: url) { $0 }
        XCTAssertEqual(first.preferences, last.preferences)
        XCTAssertNotNil(first.revision)
        XCTAssertNotEqual(first.revision, last.revision)
    }
}