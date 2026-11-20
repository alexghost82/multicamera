import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraDomainLeaseRetentionTests: XCTestCase {
    private enum DrainFailure: Error { case uncertain }

    func testFailedDrainRetainsLeaseAfterDomainDeallocation() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Python is unavailable for the separate-process lease test.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        var domain: ACTACoordinatedCameraDomain? = ACTACoordinatedCameraDomain(
            url: url, readMemory: { memory }, installMemory: { memory = $0 })
        weak var weakDomain = domain
        try domain?.beginRuntime()
        do {
            try await domain?.endRuntime { throw DrainFailure.uncertain }
            XCTFail("Uncertain drain must fail")
        } catch DrainFailure.uncertain {}
        domain = nil
        XCTAssertNil(weakDomain)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
            import fcntl, sys
            with open(sys.argv[1], 'rb') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    sys.exit(0)
                sys.exit(1)
            """, root.appendingPathComponent(".cameras.json.runtime-lock").path]
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testSuccessfulDrainReleasesLease() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        var domain: ACTACoordinatedCameraDomain? = ACTACoordinatedCameraDomain(
            url: url, readMemory: { memory }, installMemory: { memory = $0 })
        try domain?.beginRuntime()
        try await domain?.endRuntime(afterDraining: {})
        domain = nil
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
    }

    func testDrainFencesCallbacksAndRestartRejectsStaleConfiguration() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                 installMemory: { memory = $0 })
        try domain.beginRuntime()
        let callbacks = CameraRuntimeWorkGroup()
        let pending = try XCTUnwrap(callbacks.begin())
        var fenced = false
        let stopping = Task { @MainActor in
            try await domain.endRuntime {
                callbacks.fence()
                fenced = true
                await callbacks.wait()
            }
        }
        while !fenced { await Task.yield() }
        XCTAssertNil(callbacks.begin())
        XCTAssertThrowsError(try domain.currentRuntimeLease())
        XCTAssertThrowsError(try domain.beginRuntime())
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
        pending.finish()
        try await stopping.value

        let before = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var external = memory
        external.columns = 5
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(external, expected: before, to: url))
        XCTAssertThrowsError(try domain.beginRuntime())
        memory = external
        try domain.beginRuntime()
        try await domain.endRuntime(afterDraining: {})
    }

    func testRuntimeRejectsUnrecognizedConfigurationFields() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["futureField"] = true
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: url)
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                 installMemory: { memory = $0 })
        XCTAssertThrowsError(try domain.beginRuntime())
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
    }

    func testPoisonedSharedGateStillAllowsRuntimeDrainBeforeReload() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let gate = ACTACameraWriterGate()
        let domain = ACTACoordinatedCameraDomain(url: url, gate: gate, readMemory: { memory },
                                                 installMemory: { memory = $0 })
        try domain.beginRuntime()
        try gate.write { gate.requireReconciliation() }
        XCTAssertThrowsError(try domain.reloadIfStopped())
        XCTAssertThrowsError(try domain.currentRuntimeLease())
        try await domain.endRuntime(afterDraining: {})
        try domain.reloadIfStopped()
        try domain.beginRuntime()
        try await domain.endRuntime(afterDraining: {})
    }

    func testUnjoinedNetworkFenceCannotReleaseDomainLease() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-retention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                 installMemory: { memory = $0 })
        let network = CameraNetworkLifecycle()
        try domain.beginRuntime()
        network.fence()
        let unjoined = network.stoppedRevision()
        do {
            try await domain.endRuntime { try await network.waitForStop(unjoined) }
            XCTFail("Unjoined network work must not release the runtime lease")
        } catch {}
        XCTAssertThrowsError(try domain.currentRuntimeLease())
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
        network.join {}
        let joined = network.stoppedRevision()
        try await domain.endRuntime { try await network.waitForStop(joined) }
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
    }
}
