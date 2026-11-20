import Foundation
import XCTest
@testable import CameraCore

final class ACTACoordinatedSystemSettingsProviderTests: XCTestCase {
    private final class Fault: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = true
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if pending { pending = false; return true }
            return false
        }
    }

    private func fixture() throws -> (URL, WallConfiguration) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".system-provider-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("cameras.json")
        var config = WallConfiguration()
        config.cameras = [Camera(name: "Fixture", substream: "", enabled: false, localDeviceID: "synthetic")]
        try ConfigurationStore.save(config, to: url)
        return (url, config)
    }

    func testSnapshotSaveRejectsABAAndWrongPath() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = DefaultACTASystemSettingsProvider(url: url)
        let observed = try provider.captureConfiguration()
        var other = original
        other.columns = 6
        try provider.saveConfiguration(other, expected: observed)
        try provider.saveConfiguration(original, expected: provider.captureConfiguration())
        var draft = original
        draft.detectionFPS = 4
        XCTAssertThrowsError(try provider.saveConfiguration(draft, expected: observed))
        XCTAssertEqual(try provider.loadConfiguration(), original)
        let otherURL = url.deletingLastPathComponent().appendingPathComponent("other.json")
        let wrongPath = try CoordinatedCameraConfigurationStore.snapshot(from: otherURL)
        XCTAssertThrowsError(try provider.saveConfiguration(draft, expected: wrongPath))
        XCTAssertEqual(try provider.loadConfiguration(), original)
    }

    func testMissingConfigurationAndUnknownFields() throws {
        let (url, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        let provider = DefaultACTASystemSettingsProvider(url: url)
        let snapshot = try provider.captureConfiguration()
        XCTAssertTrue(snapshot.isMissing)
        var draft = snapshot.configuration
        draft.columns = 6
        try provider.saveConfiguration(draft, expected: snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["futureField"] = true
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: url)
        XCTAssertThrowsError(try provider.saveConfiguration(draft))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLateUncoordinatedWriteIsRejectedByCAS() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = DefaultACTASystemSettingsProvider(url: url, saveSnapshot: { configuration, expected, url, lease in
            var external = expected.configuration
            external.columns = 8
            try ConfigurationStore.save(external, to: url)
            return try CoordinatedCameraConfigurationStore.compareAndSave(configuration, expected: expected,
                                                                           to: url, using: lease)
        })
        var draft = original
        draft.columns = 7
        XCTAssertThrowsError(try provider.saveConfiguration(draft, expected: provider.captureConfiguration()))
        XCTAssertEqual(try provider.loadConfiguration().columns, 8)
    }

    func testUnknownOutcomeRequiresLockedReloadAcrossProviderCopies() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fault = Fault()
        let provider = DefaultACTASystemSettingsProvider(url: url, saveSnapshot: { configuration, expected, url, lease in
            let saved = try CoordinatedCameraConfigurationStore.compareAndSave(configuration, expected: expected,
                                                                                to: url, using: lease)
            if fault.take() { throw CocoaError(.fileWriteUnknown) }
            return saved
        })
        let copy = provider
        var draft = original
        draft.columns = 7
        XCTAssertThrowsError(try provider.saveConfiguration(draft))
        XCTAssertEqual(try ConfigurationStore.load(from: url), draft)
        XCTAssertThrowsError(try copy.saveConfiguration(original))
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try copy.loadConfiguration())
        lease = nil
        let reloaded = try copy.captureConfiguration()
        XCTAssertEqual(reloaded.configuration, draft)
        try provider.saveConfiguration(original, expected: reloaded)
        XCTAssertEqual(try provider.loadConfiguration(), original)
    }

    func testOtherProcessRuntimeBlocksSave() throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_BOOKMARK_LEASE_DRIVER"] else {
            throw XCTSkip("Set CAMERA_BOOKMARK_LEASE_DRIVER to the synthetic lease driver.")
        }
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = DefaultACTASystemSettingsProvider(url: url)
        let observed = try provider.captureConfiguration()
        let process = Process()
        let input = Pipe()
        let ready = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.path]
        process.standardInput = input
        process.standardOutput = ready
        try process.run()
        defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.waitUntilExit() } }
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 1), Data([1]))
        var next = original
        next.columns = 7
        XCTAssertThrowsError(try provider.saveConfiguration(next, expected: observed))
        XCTAssertEqual(try provider.loadConfiguration(), original)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try provider.saveConfiguration(next, expected: observed)
        XCTAssertEqual(try provider.loadConfiguration(), next)
    }
}
