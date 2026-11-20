import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraLifecycleIntegrationTests: XCTestCase {
    private enum Failure: Error { case timeout }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDomainDrainWaitsForAnalyticsAndGuardedRelayBeforeDraftCanSave() async throws {
        guard let guardianPath = ProcessInfo.processInfo.environment["CAMERA_GUARDIAN_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: guardianPath),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Set CAMERA_GUARDIAN_TEST_EXECUTABLE to the isolated guardian driver.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("relay")
        let ready = root.appendingPathComponent("ready")
        let signalled = root.appendingPathComponent("signalled")
        let release = root.appendingPathComponent("release")
        let source = """
            #!/usr/bin/python3
            import os, signal, time
            root = os.path.dirname(__file__)
            signal.signal(signal.SIGTERM, lambda *_: open(os.path.join(root, 'signalled'), 'w').close())
            open(os.path.join(root, 'ready'), 'w').close()
            while not os.path.exists(os.path.join(root, 'release')): time.sleep(0.01)
            """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        memory.go2rtcPath = executable.path
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(memory, expected: empty, to: url))
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        var otherMemory = memory
        let other = ACTACoordinatedCameraDomain(url: url, readMemory: { otherMemory },
                                                installMemory: { otherMemory = $0 })
        let originalDraft = try domain.draft()
        try domain.beginRuntime()
        let otherDraft = try other.draft()
        let relay = Go2RTC(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, configurationDirectory: root, cameraLease: try domain.currentRuntimeLease(),
            guardianExecutable: URL(fileURLWithPath: guardianPath))
        defer { relay.stop(); try? Data().write(to: release) }
        try await relay.start(config: memory)
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        let tracker = CameraRuntimeWorkGroup()
        let ticket = try XCTUnwrap(tracker.begin())
        var finished = false
        let stopping = Task { @MainActor in
            try await domain.endRuntime {
                tracker.fence()
                relay.stop()
                await tracker.wait()
                await Go2RTC.waitForAllChildrenToExit()
            }
            finished = true
        }
        try await waitUntil { FileManager.default.fileExists(atPath: signalled.path) }
        var next = memory
        next.columns = 5
        XCTAssertThrowsError(try other.save(next, expected: otherDraft))
        XCTAssertNil(tracker.begin())
        XCTAssertFalse(tracker.resume())
        XCTAssertThrowsError(try ACTAWorkerCameraRuntime().open(url))
        ticket.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        try Data().write(to: release)
        try await stopping.value
        XCTAssertTrue(finished)
        XCTAssertThrowsError(try domain.save(next, expected: originalDraft))
        try domain.save(next, expected: domain.draft())
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, next)
        try FileManager.default.removeItem(at: root)
    }

    func testWorkerLeaseOutlivesOwnerWhileGuardedRelayIsStopping() async throws {
        guard let guardianPath = ProcessInfo.processInfo.environment["CAMERA_GUARDIAN_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: guardianPath),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Set CAMERA_GUARDIAN_TEST_EXECUTABLE to the isolated guardian driver.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("relay")
        let ready = root.appendingPathComponent("ready")
        let signalled = root.appendingPathComponent("signalled")
        let release = root.appendingPathComponent("release")
        let source = """
            #!/usr/bin/python3
            import os, signal, time
            root = os.path.dirname(__file__)
            signal.signal(signal.SIGTERM, lambda *_: open(os.path.join(root, 'signalled'), 'w').close())
            open(os.path.join(root, 'ready'), 'w').close()
            while not os.path.exists(os.path.join(root, 'release')): time.sleep(0.01)
            """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        memory.go2rtcPath = executable.path
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(memory, expected: empty, to: url))
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        let draft = try domain.draft()
        var worker: ACTAWorkerCameraRuntime? = ACTAWorkerCameraRuntime()
        XCTAssertEqual(try worker?.open(url), memory)
        let relay = Go2RTC(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, configurationDirectory: root, cameraLease: try XCTUnwrap(worker).activeLease(),
            guardianExecutable: URL(fileURLWithPath: guardianPath))
        defer { relay.stop(); try? Data().write(to: release) }
        try await relay.start(config: memory)
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        worker?.stop()
        relay.stop()
        worker = nil
        try await waitUntil { FileManager.default.fileExists(atPath: signalled.path) }
        var next = memory
        next.columns = 6
        XCTAssertThrowsError(try domain.save(next, expected: draft))
        XCTAssertThrowsError(try domain.beginRuntime())
        try Data().write(to: release)
        await Go2RTC.waitForAllChildrenToExit()
        XCTAssertThrowsError(try domain.save(next, expected: draft))
        try domain.save(next, expected: domain.draft())
        try domain.beginRuntime()
        try await domain.endRuntime(afterDraining: {})
        try FileManager.default.removeItem(at: root)
    }
}
