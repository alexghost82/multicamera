import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class AnalyticsEngineDrainTests: XCTestCase {
    private func makeEngine(root: URL, name: String) throws -> (LocalVideoAnalyticsEngine, URL) {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent("settings.json")
        try VideoAnalyticsSettingsStore.save(.safeDefaults, to: settingsURL)
        let modelURL = directory.appendingPathComponent("synthetic-pose")
        let engine = LocalVideoAnalyticsEngine(
            settingsURL: settingsURL,
            incidentsURL: directory.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: directory.appendingPathComponent("evidence"),
            auditLogURL: directory.appendingPathComponent("audit.json"),
            poseModelURL: modelURL,
            modelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { _ in ("", 0) })
        )
        return (engine, modelURL)
    }

    private func waitForLoad(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await SyntheticPoseLoads.shared.isWaiting(for: url)) {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum Failure: Error { case timeout }

    func testConcurrentDrainsFenceStartsAndDoNotWaitForAnotherEngine() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".analytics-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ModelSelectionRegistry.poseEnabled = true
        defer { ModelSelectionRegistry.poseEnabled = false }
        let (engine, modelURL) = try makeEngine(root: root, name: "first")
        let (other, _) = try makeEngine(root: root, name: "second")

        engine.startIfEnabled(activeCameraCount: 1)
        try await waitForLoad(modelURL)
        engine.fenceForDrain()
        XCTAssertEqual(engine.engineState, .disabled)
        engine.startIfEnabled(activeCameraCount: 1)
        XCTAssertEqual(engine.engineState, .disabled)
        XCTAssertThrowsError(try engine.resumeAfterDrain())

        var entered = 0
        var finished = 0
        let first = Task { @MainActor in
            entered += 1
            try await engine.stopAndDrain()
            finished += 1
        }
        let second = Task { @MainActor in
            entered += 1
            try await engine.stopAndDrain()
            finished += 1
        }
        while entered < 2 { await Task.yield() }
        XCTAssertEqual(finished, 0)
        XCTAssertThrowsError(try engine.resumeAfterDrain())
        engine.startIfEnabled(activeCameraCount: 1)
        XCTAssertEqual(engine.engineState, .disabled)

        try await other.stopAndDrain()
        try other.resumeAfterDrain()
        XCTAssertEqual(finished, 0)

        await SyntheticPoseLoads.shared.release(modelURL)
        try await first.value
        try await second.value
        XCTAssertEqual(finished, 2)
        try await engine.stopAndDrain()
        engine.startIfEnabled(activeCameraCount: 1)
        XCTAssertEqual(engine.engineState, .disabled)
        try engine.resumeAfterDrain()
        engine.startIfEnabled(activeCameraCount: 1)
        XCTAssertEqual(engine.engineState, .initializing)
        try await waitForLoad(modelURL)
        await SyntheticPoseLoads.shared.release(modelURL)
        try await engine.stopAndDrain()
    }

    func testCancelledWaiterDoesNotCancelSharedDrain() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".analytics-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ModelSelectionRegistry.poseEnabled = true
        defer { ModelSelectionRegistry.poseEnabled = false }
        let (engine, modelURL) = try makeEngine(root: root, name: "engine")
        engine.startIfEnabled(activeCameraCount: 1)
        try await waitForLoad(modelURL)

        var entered = 0
        let cancelled = Task { @MainActor in
            entered += 1
            try await engine.stopAndDrain()
        }
        let other = Task { @MainActor in
            entered += 1
            try await engine.stopAndDrain()
        }
        while entered < 2 { await Task.yield() }
        cancelled.cancel()
        XCTAssertThrowsError(try engine.resumeAfterDrain())
        await SyntheticPoseLoads.shared.release(modelURL)
        do {
            try await cancelled.value
            XCTFail("Cancelled waiter must report cancellation")
        } catch is CancellationError {
        }
        try await other.value
        try engine.resumeAfterDrain()
    }

    func testRestartBarrierSharesDelayedAnalyticsDrainWithWorker() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".analytics-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ModelSelectionRegistry.poseEnabled = true
        defer { ModelSelectionRegistry.poseEnabled = false }
        let (engine, modelURL) = try makeEngine(root: root, name: "engine")
        engine.startIfEnabled(activeCameraCount: 1)
        try await waitForLoad(modelURL)

        let lifecycle = CameraNetworkLifecycle()
        lifecycle.fence()
        engine.fenceForDrain()
        lifecycle.join { try await engine.stopAndDrain() }
        var workerEntered = false
        var workerFinished = false
        var restarted = false
        let worker = Task { @MainActor in
            workerEntered = true
            try await engine.stopAndDrain()
            workerFinished = true
        }
        let restart = Task { @MainActor in
            try await lifecycle.prepareStart()
            restarted = true
        }
        while !workerEntered { await Task.yield() }
        engine.startIfEnabled(activeCameraCount: 1)
        XCTAssertEqual(engine.engineState, .disabled)
        XCTAssertFalse(workerFinished)
        XCTAssertFalse(restarted)

        await SyntheticPoseLoads.shared.release(modelURL)
        try await worker.value
        try await restart.value
        XCTAssertTrue(workerFinished)
        XCTAssertTrue(restarted)
        try engine.resumeAfterDrain()
        try await waitForLoad(modelURL)
        await SyntheticPoseLoads.shared.release(modelURL)
        try await engine.stopAndDrain()
    }

    func testSettingsCanStartAfterStopAndRepeatedStopDefersUntilRestart() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".analytics-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ModelSelectionRegistry.poseEnabled = true
        defer { ModelSelectionRegistry.poseEnabled = false }
        let (engine, modelURL) = try makeEngine(root: root, name: "engine")
        let lifecycle = CameraNetworkLifecycle()
        engine.startIfEnabled(activeCameraCount: 1)
        try await waitForLoad(modelURL)

        lifecycle.fence()
        engine.fenceForDrain()
        lifecycle.join { try await engine.stopAndDrain() }
        let resumed = expectation(description: "analytics reopened after stop")
        lifecycle.afterStop(lifecycle.stoppedRevision(), onFailure: { error in XCTFail("Unexpected drain failure: \(error)") }) {
            do { try engine.resumeAfterDrain() }
            catch { XCTFail("Unexpected resume failure: \(error)") }
            resumed.fulfill()
        }
        XCTAssertThrowsError(try engine.resumeAfterDrain())
        await SyntheticPoseLoads.shared.release(modelURL)
        await fulfillment(of: [resumed], timeout: 5)

        var settings = engine.settings
        settings.globalEnabled = false
        try engine.updateSettings(settings)
        settings.globalEnabled = true
        try engine.updateSettings(settings)
        try await waitForLoad(modelURL)
        let startsAfterSettings = await SyntheticPoseLoads.shared.starts(for: modelURL)
        XCTAssertEqual(startsAfterSettings, 2)

        lifecycle.fence()
        engine.fenceForDrain()
        lifecycle.join { try await engine.stopAndDrain() }
        var staleResumed = false
        lifecycle.afterStop(lifecycle.stoppedRevision(), onFailure: { _ in XCTFail("Superseded drain reported failure") }) { staleResumed = true }
        lifecycle.fence()
        engine.fenceForDrain()
        lifecycle.join { try await engine.stopAndDrain() }
        var running = true
        var resumedWithoutRestart = false
        lifecycle.afterStop(lifecycle.stoppedRevision(), onFailure: { error in XCTFail("Unexpected drain failure: \(error)") }) {
            guard !running else { return }
            resumedWithoutRestart = true
            try? engine.resumeAfterDrain()
        }
        let restart = Task { try await lifecycle.prepareStart() }
        settings.globalEnabled = false
        try engine.updateSettings(settings)
        settings.globalEnabled = true
        try engine.updateSettings(settings)
        XCTAssertEqual(engine.engineState, .disabled)
        let startsDuringDrain = await SyntheticPoseLoads.shared.starts(for: modelURL)
        XCTAssertEqual(startsDuringDrain, 2)
        XCTAssertThrowsError(try engine.resumeAfterDrain())

        await SyntheticPoseLoads.shared.release(modelURL)
        try await restart.value
        XCTAssertFalse(staleResumed)
        XCTAssertFalse(resumedWithoutRestart)
        try engine.resumeAfterDrain()
        try await waitForLoad(modelURL)
        let startsAfterRestart = await SyntheticPoseLoads.shared.starts(for: modelURL)
        XCTAssertEqual(startsAfterRestart, 3)
        running = false
        await SyntheticPoseLoads.shared.release(modelURL)
        try await engine.stopAndDrain()
    }

    func testExplicitStoppedBarrierDoesNotReopenBeforeLeaseRelease() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".analytics-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ModelSelectionRegistry.poseEnabled = true
        defer { ModelSelectionRegistry.poseEnabled = false }
        let (engine, modelURL) = try makeEngine(root: root, name: "engine")
        let configURL = root.appendingPathComponent("cameras.json")
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: configURL)
        XCTAssertNotNil(lease)
        let lifecycle = CameraNetworkLifecycle()
        engine.startIfEnabled(activeCameraCount: 1)
        try await waitForLoad(modelURL)

        lifecycle.fence()
        engine.fenceForDrain()
        lifecycle.join { try await engine.stopAndDrain() }
        var staleReopen = false
        lifecycle.afterStop(lifecycle.stoppedRevision(), onFailure: { _ in XCTFail("Superseded drain reported failure") }) {
            staleReopen = true
            try? engine.resumeAfterDrain()
        }
        lifecycle.fence()
        engine.fenceForDrain()
        lifecycle.join { try await engine.stopAndDrain() }
        let revision = lifecycle.stoppedRevision()
        let barrier = Task { try await lifecycle.waitForStop(revision) }
        engine.startIfEnabled(activeCameraCount: 1)
        XCTAssertEqual(engine.engineState, .disabled)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: configURL) {})
        await SyntheticPoseLoads.shared.release(modelURL)
        try await barrier.value
        XCTAssertFalse(staleReopen)
        XCTAssertEqual(engine.engineState, .disabled)
        let starts = await SyntheticPoseLoads.shared.starts(for: modelURL)
        XCTAssertEqual(starts, 1)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: configURL) {})

        lease = nil
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: configURL) {})
        try engine.resumeAfterDrain()
        try await waitForLoad(modelURL)
        await SyntheticPoseLoads.shared.release(modelURL)
        try await engine.stopAndDrain()
    }
}
