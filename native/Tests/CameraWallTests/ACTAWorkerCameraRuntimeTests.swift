import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAWorkerCameraRuntimeTests: XCTestCase {
    func testOtherProcessRemainsLockedWhileStoppedWorkerTaskIsPending() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_COORDINATION_TEST_DRIVER"] else {
            throw XCTSkip("Set CAMERA_COORDINATION_TEST_DRIVER to the synthetic participant.")
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".worker-camera-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var runtime: ACTAWorkerCameraRuntime? = ACTAWorkerCameraRuntime()
        _ = try runtime?.open(url)
        var continuation: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor [runtime] in
            await withCheckedContinuation { continuation = $0 }
            try runtime?.checkActive()
        }
        while continuation == nil { await Task.yield() }
        runtime?.stop()
        runtime = nil
        XCTAssertEqual(try probe(executable, url), 2)
        continuation?.resume()
        do { try await task.value; XCTFail("Stopped worker resumed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try probe(executable, url), 0)
    }

    private func probe(_ executable: String, _ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.path, "discovery"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testStopFencesResumingTaskAndRetainsLeaseUntilOwnerEnds() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".worker-camera-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var runtime: ACTAWorkerCameraRuntime? = ACTAWorkerCameraRuntime()
        XCTAssertEqual(try runtime?.open(url), WallConfiguration())
        var continuation: CheckedContinuation<Void, Never>?
        var didStart = false
        let task = Task { @MainActor [runtime] in
            await withCheckedContinuation { continuation = $0 }
            try runtime?.checkActive()
            didStart = true
        }
        while continuation == nil { await Task.yield() }
        runtime?.stop()
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        continuation?.resume()
        do {
            try await task.value
            XCTFail("Stopped worker resumed startup")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(didStart)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        runtime = nil
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }

    func testFailedOpenStaysFencedUntilOwnerEnds() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".worker-camera-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        try Data("invalid".utf8).write(to: url)
        var runtime: ACTAWorkerCameraRuntime? = ACTAWorkerCameraRuntime()
        XCTAssertThrowsError(try runtime?.open(url))
        runtime?.stop()
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        runtime = nil
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }
}
