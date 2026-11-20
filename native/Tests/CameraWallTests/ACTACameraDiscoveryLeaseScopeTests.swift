import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraDiscoveryLeaseScopeTests: XCTestCase {
    func testOtherProcessCannotAcquireUntilDiscoveryOperationAndDrainFinish() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_COORDINATION_TEST_DRIVER"] else {
            throw XCTSkip("Set CAMERA_COORDINATION_TEST_DRIVER to the synthetic participant.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".discovery-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let configuration = WallConfiguration()
        try ConfigurationStore.save(configuration, to: url)
        var stale = configuration
        stale.columns = 8
        XCTAssertThrowsError(try ACTACameraDiscoveryLeaseScope.acquire(for: url, expected: stale))
        var operation: CheckedContinuation<Void, Never>?
        var drain: CheckedContinuation<Void, Never>?
        var scope: ACTACameraDiscoveryLeaseScope? = ACTACameraDiscoveryLeaseScope(
            lease: try ACTACameraDiscoveryLeaseScope.acquire(for: url, expected: configuration),
            stop: {}, drain: { await withCheckedContinuation { drain = $0 } })
        let task = Task { @MainActor [scope] in
            try await scope!.run { await withCheckedContinuation { operation = $0 } }
        }
        while operation == nil { await Task.yield() }
        task.cancel()
        XCTAssertEqual(try probe(executable, url), 2)
        operation?.resume()
        while drain == nil { await Task.yield() }
        XCTAssertEqual(try probe(executable, url), 2)
        drain?.resume()
        do { try await task.value; XCTFail("Cancelled discovery returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        scope = nil
        XCTAssertEqual(try probe(executable, url), 0)
    }

    private func probe(_ executable: String, _ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.path, "worker"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testGuardedDiscoveryKeepsLeaseForCancelledReadinessTransport() async throws {
        guard let guardianPath = ProcessInfo.processInfo.environment["CAMERA_GUARDIAN_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: guardianPath),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Set CAMERA_GUARDIAN_TEST_EXECUTABLE to the isolated guardian driver.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".discovery-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("relay")
        try Data("#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let url = root.appendingPathComponent("cameras.json")
        var config = WallConfiguration()
        config.go2rtcPath = executable.path
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let relay = Go2RTC(transport: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }, configurationDirectory: root, cameraLease: try XCTUnwrap(lease),
            guardianExecutable: URL(fileURLWithPath: guardianPath))
        var scope: ACTACameraDiscoveryLeaseScope? = ACTACameraDiscoveryLeaseScope(
            lease: try XCTUnwrap(lease), stop: { relay.stop() }, drain: {
                await relay.waitForPendingReadinessRequests()
                await relay.waitForChildrenToExit()
            })
        lease = nil
        defer { relay.stop(); pending?.resume(throwing: CancellationError()) }
        let task = Task { @MainActor [scope] in try await scope!.run { try await relay.start(config: config) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while pending == nil {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        scope = nil
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        pending?.resume(throwing: CancellationError())
        pending = nil
        do { try await task.value; XCTFail("Cancelled discovery returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }

    func testFailedDrainRetainsLeaseAfterScopeIsReleased() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".discovery-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var scope: ACTACameraDiscoveryLeaseScope? = ACTACameraDiscoveryLeaseScope(
            lease: try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url),
            stop: {}, drain: { throw CocoaError(.fileReadUnknown) })
        do {
            _ = try await XCTUnwrap(scope).run { 1 }
            XCTFail("Unverified cleanup must not succeed")
        } catch { }
        scope = nil
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }

    func testCancellationStopsPromptlyAndHoldsLeaseUntilOperationAndDrainFinish() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".discovery-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        var operation: CheckedContinuation<Void, Never>?
        var drain: CheckedContinuation<Void, Never>?
        var stopCount = 0
        var scope: ACTACameraDiscoveryLeaseScope? = ACTACameraDiscoveryLeaseScope(
            lease: try XCTUnwrap(lease),
            stop: { stopCount += 1 },
            drain: { await withCheckedContinuation { drain = $0 } })
        lease = nil
        let task = Task { @MainActor [scope] in
            try await scope!.run {
                await withCheckedContinuation { operation = $0 }
                return 1
            }
        }
        while operation == nil { await Task.yield() }
        task.cancel()
        while stopCount == 0 { await Task.yield() }
        XCTAssertEqual(stopCount, 1)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        operation?.resume()
        while drain == nil { await Task.yield() }
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        drain?.resume()
        do { _ = try await task.value; XCTFail("Cancelled discovery returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        scope = nil
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }
}
