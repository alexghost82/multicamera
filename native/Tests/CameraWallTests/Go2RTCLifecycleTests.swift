import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class FakeRelayChild: RelayChild {
    private(set) var isRunning = true
    private(set) var terminationRequests = 0
    private let onExit: @Sendable () -> Void

    init(onExit: @escaping @Sendable () -> Void) { self.onExit = onExit }
    func terminate() { terminationRequests += 1 }
    func exit() {
        guard isRunning else { return }
        isRunning = false
        onExit()
    }
}

@MainActor
private final class RelayFixture {
    let root: URL
    var config = WallConfiguration()
    var children: [FakeRelayChild] = []
    var pending: [CheckedContinuation<(Data, URLResponse), Error>] = []
    var holdRequests = false
    var requestCount = 0

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/relay-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-relay")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        config.go2rtcPath = executable.path
        config.apiPort = 21984
        config.rtspPort = 28554
    }

    func relay(reservationTimeout: Duration = .seconds(5)) -> Go2RTC {
        Go2RTC(transport: { [self] request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if holdRequests {
                return try await withCheckedThrowingContinuation { pending.append($0) }
            }
            return (Data(), response)
        }, configurationDirectory: root, reservationTimeout: reservationTimeout, childFactory: { [self] executable, configuration, onExit in
            XCTAssertEqual(executable.path, config.go2rtcPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.path))
            let child = FakeRelayChild(onExit: onExit)
            children.append(child)
            return child
        })
    }

    func completeRequest() {
        let continuation = pending.removeFirst()
        let response = HTTPURLResponse(url: URL(string: "http://fixture.invalid")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        continuation.resume(returning: (Data(), response))
    }

    func cleanup() {
        for child in children { child.exit() }
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class Go2RTCLifecycleTests: XCTestCase {
    private enum Failure: Error { case timeout }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testInstanceStopJoinsLateRegistrationButNotOtherRelay() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), second = fixture.relay()
        try await first.start(config: fixture.config)
        var otherConfiguration = fixture.config
        otherConfiguration.apiPort += 1
        otherConfiguration.rtspPort += 1
        try await second.start(config: otherConfiguration)
        fixture.holdRequests = true
        let firstRegistration = Task {
            try await first.register(source: "rtsp://fixture.invalid/one", name: "one", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 1 }
        let secondRegistration = Task {
            try await second.register(source: "rtsp://fixture.invalid/two", name: "two", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 2 }
        first.stop()
        var firstFinished = false
        let firstDrain = Task { @MainActor in
            try await first.waitForStopped()
            firstFinished = true
        }
        await Task.yield()
        XCTAssertFalse(firstFinished)
        let count = fixture.requestCount
        do {
            _ = try await first.register(source: "rtsp://fixture.invalid/late", name: "late", credentials: nil)
            XCTFail("Stopped relay accepted a new registration")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.requestCount, count)
        first.stop()
        fixture.completeRequest()
        do { _ = try await firstRegistration.value; XCTFail("Late registration succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await Task.yield()
        XCTAssertFalse(firstFinished)
        fixture.children[0].exit()
        try await firstDrain.value
        XCTAssertTrue(firstFinished)
        XCTAssertEqual(fixture.pending.count, 1)
        XCTAssertTrue(second.running)
        fixture.completeRequest()
        _ = try await secondRegistration.value
        second.stop()
        fixture.children[1].exit()
        try await second.waitForStopped()
    }

    func testLateRegistrationCannotSucceedAfterSameInstanceRestart() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let relay = fixture.relay()
        try await relay.start(config: fixture.config)
        fixture.holdRequests = true
        let oldRegistration = Task {
            try await relay.register(source: "rtsp://fixture.invalid/old", name: "old", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 1 }
        relay.stop()
        fixture.children[0].exit()
        fixture.holdRequests = false
        try await relay.start(config: fixture.config)
        fixture.completeRequest()
        do { _ = try await oldRegistration.value; XCTFail("Old registration survived restart") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(relay.running)
        XCTAssertEqual(fixture.children[1].terminationRequests, 0)
        relay.stop()
        fixture.children[1].exit()
        try await relay.waitForStopped()
    }

    func testStopFencesProfileFallbackAfterLateResponse() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let relay = fixture.relay()
        try await relay.start(config: fixture.config)
        fixture.holdRequests = true
        let profiles = Task {
            try await relay.profiles(address: CameraAddress("fixture.invalid"),
                                     credentials: Credentials(username: "", password: ""))
        }
        try await waitUntil { fixture.pending.count == 1 }
        let count = fixture.requestCount
        relay.stop()
        fixture.children[0].exit()
        fixture.completeRequest()
        do { _ = try await profiles.value; XCTFail("Stopped lookup succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await relay.waitForStopped()
        XCTAssertEqual(fixture.requestCount, count)
        XCTAssertTrue(fixture.pending.isEmpty)
    }

    func testStopJoinsWaitingStarterWithoutWaitingForOtherChild() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let owner = fixture.relay(), waiting = fixture.relay()
        try await owner.start(config: fixture.config)
        var startupFinished = false
        let startup = Task {
            defer { startupFinished = true }
            try await waiting.start(config: fixture.config)
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.stop()
        try await waiting.waitForStopped()
        XCTAssertTrue(startupFinished)
        do { try await startup.value; XCTFail("Stopped starter succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(owner.running)
        XCTAssertEqual(fixture.children.count, 1)
        owner.stop()
        fixture.children[0].exit()
        try await owner.waitForStopped()
    }

    func testInstanceDrainDoesNotWaitForUnrelatedRelay() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), second = fixture.relay()
        try await first.start(config: fixture.config)
        var otherConfiguration = fixture.config
        otherConfiguration.apiPort += 1
        otherConfiguration.rtspPort += 1
        try await second.start(config: otherConfiguration)
        first.stop()
        var finished = false
        let waiting = Task { @MainActor in
            await first.waitForChildrenToExit()
            finished = true
        }
        await Task.yield()
        XCTAssertFalse(finished)
        fixture.children[0].exit()
        try await waitUntil { finished }
        await waiting.value
        XCTAssertTrue(second.running)
        second.stop()
        fixture.children[1].exit()
        await second.waitForChildrenToExit()
    }

    func testReadinessDrainJoinsTransportThatIgnoresCancellation() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        fixture.holdRequests = true
        let relay = fixture.relay()
        let startup = Task { try await relay.start(config: fixture.config) }
        try await waitUntil { fixture.pending.count == 1 }
        relay.stop()
        do { try await startup.value; XCTFail("Stopped relay started") }
        catch { }
        var finished = false
        let waiting = Task { @MainActor in
            await relay.waitForPendingReadinessRequests()
            finished = true
        }
        var allFinished = false
        let allWaiting = Task { @MainActor in
            await Go2RTC.waitForAllPendingRequests()
            allFinished = true
        }
        await Task.yield()
        XCTAssertFalse(finished)
        XCTAssertFalse(allFinished)
        fixture.completeRequest()
        try await waitUntil { finished && allFinished }
        await waiting.value
        await allWaiting.value
        fixture.children[0].exit()
        await relay.waitForChildrenToExit()
    }

    func testGlobalDrainJoinsCancelledRegistrationRequest() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let relay = fixture.relay()
        try await relay.start(config: fixture.config)
        fixture.holdRequests = true
        let registration = Task {
            try await relay.register(source: "rtsp://fixture.invalid/live", name: "fixture", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 1 }
        registration.cancel()
        relay.stop()
        var finished = false
        let waiting = Task { @MainActor in
            await Go2RTC.waitForAllPendingRequests()
            finished = true
        }
        await Task.yield()
        XCTAssertFalse(finished)
        fixture.completeRequest()
        _ = try? await registration.value
        try await waitUntil { finished }
        await waiting.value
        fixture.children[0].exit()
        await relay.waitForChildrenToExit()
    }

    func testInstanceRequestDrainIgnoresUnrelatedRelay() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), second = fixture.relay()
        try await first.start(config: fixture.config)
        var otherConfiguration = fixture.config
        otherConfiguration.apiPort += 1
        otherConfiguration.rtspPort += 1
        try await second.start(config: otherConfiguration)
        fixture.holdRequests = true
        let registration = Task {
            try await second.register(source: "rtsp://fixture.invalid/live", name: "fixture", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 1 }
        var firstFinished = false
        var secondFinished = false
        let firstDrain = Task { @MainActor in
            await first.waitForPendingRequests()
            firstFinished = true
        }
        let secondDrain = Task { @MainActor in
            await second.waitForPendingRequests()
            secondFinished = true
        }
        try await waitUntil { firstFinished }
        XCTAssertFalse(secondFinished)
        fixture.completeRequest()
        _ = try await registration.value
        await firstDrain.value
        await secondDrain.value
        XCTAssertTrue(secondFinished)
        first.stop()
        second.stop()
        fixture.children.forEach { $0.exit() }
        await first.waitForChildrenToExit()
        await second.waitForChildrenToExit()
    }

    func testNetworkFenceJoinsLateRequestAndChildExit() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let relay = fixture.relay()
        try await relay.start(config: fixture.config)
        let lifecycle = CameraNetworkLifecycle()
        let ticket = try XCTUnwrap(lifecycle.begin())
        fixture.holdRequests = true
        let registration = Task {
            defer { ticket.finish() }
            return try await relay.register(source: "rtsp://fixture.invalid/live", name: "fixture", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 1 }
        lifecycle.fence()
        registration.cancel()
        relay.stop()
        lifecycle.join {
            await relay.waitForPendingReadinessRequests()
            await relay.waitForPendingRequests()
            await relay.waitForChildrenToExit()
        }
        let revision = lifecycle.stoppedRevision()
        var finished = false
        let drain = Task { @MainActor in
            try await lifecycle.waitForStop(revision)
            await Go2RTC.waitForAllPendingRequests()
            await Go2RTC.waitForAllChildrenToExit()
            await Go2RTC.waitForAllPendingRequests()
            try lifecycle.checkStopped(revision)
            finished = true
        }
        await Task.yield()
        XCTAssertNil(lifecycle.begin())
        XCTAssertFalse(finished)
        fixture.completeRequest()
        _ = try? await registration.value
        await Task.yield()
        XCTAssertFalse(finished)
        fixture.children[0].exit()
        try await drain.value
        XCTAssertTrue(finished)
    }

    func testDomainLeaseRemainsHeldUntilFakeNetworkDrainFinishes() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("cameras.json")
        var memory = fixture.config
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(memory, expected: empty, to: url))
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                installMemory: { memory = $0 })
        try domain.beginRuntime()
        let relay = fixture.relay()
        try await relay.start(config: memory)
        let lifecycle = CameraNetworkLifecycle()
        let ticket = try XCTUnwrap(lifecycle.begin())
        fixture.holdRequests = true
        let registration = Task {
            defer { ticket.finish() }
            return try await relay.register(source: "rtsp://fixture.invalid/live", name: "fixture", credentials: nil)
        }
        try await waitUntil { fixture.pending.count == 1 }
        lifecycle.fence()
        registration.cancel()
        relay.stop()
        lifecycle.join {
            await relay.waitForPendingReadinessRequests()
            await relay.waitForPendingRequests()
            await relay.waitForChildrenToExit()
        }
        let revision = lifecycle.stoppedRevision()
        var entered = false
        var drained = false
        let stopping = Task { @MainActor in
            try await domain.endRuntime {
                entered = true
                try await lifecycle.waitForStop(revision)
            }
            drained = true
        }
        try await waitUntil { entered }
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
        fixture.completeRequest()
        _ = try? await registration.value
        await Task.yield()
        XCTAssertFalse(drained)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
        fixture.children[0].exit()
        try await stopping.value
        XCTAssertTrue(drained)
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { _ in })
    }

    func testRealChildExitFencesLeaseAfterStop() async throws {
        let fixture = try RelayFixture()
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("Python is unavailable for the synthetic child process.")
        }
        let executable = fixture.root.appendingPathComponent("synthetic-relay")
        let ready = fixture.root.appendingPathComponent("child-ready")
        let signalled = fixture.root.appendingPathComponent("child-signalled")
        let release = fixture.root.appendingPathComponent("child-release")
        let source = """
            #!/usr/bin/python3
            import os, signal, time
            root = os.path.dirname(__file__)
            def stop(signum, frame):
                open(os.path.join(root, 'child-signalled'), 'w').close()
            signal.signal(signal.SIGTERM, stop)
            open(os.path.join(root, 'child-ready'), 'w').close()
            while not os.path.exists(os.path.join(root, 'child-release')):
                time.sleep(0.01)
            """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        fixture.config.go2rtcPath = executable.path
        let configURL = fixture.root.appendingPathComponent("cameras.json")
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: configURL)
        let relay = Go2RTC(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, configurationDirectory: fixture.root)
        defer {
            relay.stop()
            try? Data().write(to: release)
        }
        try await relay.start(config: fixture.config)
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        relay.stop()
        try await waitUntil { FileManager.default.fileExists(atPath: signalled.path) }
        var drained = false
        let drain = Task { @MainActor in
            await Go2RTC.waitForAllChildrenToExit()
            lease = nil
            drained = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(drained)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: configURL) {})
        try Data().write(to: release)
        try await waitUntil { drained }
        await drain.value
        XCTAssertNil(lease)
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: configURL) {})
        fixture.cleanup()
    }

    func testGuardedRelayStopsOnlyAfterOwnedChildExits() async throws {
        guard let guardianPath = ProcessInfo.processInfo.environment["CAMERA_GUARDIAN_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: guardianPath) else {
            throw XCTSkip("Set CAMERA_GUARDIAN_TEST_EXECUTABLE to the isolated guardian driver.")
        }
        let fixture = try RelayFixture()
        let executable = fixture.root.appendingPathComponent("guarded-relay")
        let ready = fixture.root.appendingPathComponent("guarded-ready")
        let signalled = fixture.root.appendingPathComponent("guarded-signalled")
        let release = fixture.root.appendingPathComponent("guarded-release")
        let source = """
            #!/usr/bin/python3
            import os, signal, time
            root = os.path.dirname(__file__)
            signal.signal(signal.SIGTERM, lambda *_: open(os.path.join(root, 'guarded-signalled'), 'w').close())
            open(os.path.join(root, 'guarded-ready'), 'w').close()
            while not os.path.exists(os.path.join(root, 'guarded-release')): time.sleep(0.01)
            """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        fixture.config.go2rtcPath = executable.path
        let lease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(
            for: fixture.root.appendingPathComponent("cameras.json"))
        let relay = Go2RTC(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, configurationDirectory: fixture.root, cameraLease: lease,
            guardianExecutable: URL(fileURLWithPath: guardianPath))
        defer { relay.stop(); try? Data().write(to: release) }
        try await relay.start(config: fixture.config)
        try await waitUntil { FileManager.default.fileExists(atPath: ready.path) }
        relay.stop()
        try await waitUntil { FileManager.default.fileExists(atPath: signalled.path) }
        var drained = false
        let waiting = Task { @MainActor in
            await Go2RTC.waitForAllChildrenToExit()
            drained = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(drained)
        try Data().write(to: release)
        try await waitUntil { drained }
        await waiting.value
        fixture.cleanup()
    }

    func testEarlyGuardedStopWaitsForGuardianReadiness() async throws {
        guard let guardianPath = ProcessInfo.processInfo.environment["CAMERA_GUARDIAN_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: guardianPath) else {
            throw XCTSkip("Set CAMERA_GUARDIAN_TEST_EXECUTABLE to the isolated guardian driver.")
        }
        let fixture = try RelayFixture()
        let executable = fixture.root.appendingPathComponent("early-relay")
        try Data("#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        fixture.config.go2rtcPath = executable.path
        let lease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(
            for: fixture.root.appendingPathComponent("cameras.json"))
        var request: CheckedContinuation<(Data, URLResponse), Error>?
        let relay = Go2RTC(transport: { _ in
            try await withCheckedThrowingContinuation { request = $0 }
        }, configurationDirectory: fixture.root, cameraLease: lease,
            guardianExecutable: URL(fileURLWithPath: guardianPath))
        defer { relay.stop(); request?.resume(throwing: CancellationError()) }
        let startup = Task { try await relay.start(config: fixture.config) }
        try await waitUntil { request != nil }
        relay.stop()
        request?.resume(throwing: CancellationError())
        request = nil
        do { try await startup.value; XCTFail("Stopped relay started") }
        catch { }
        var drained = false
        let waiting = Task { @MainActor in
            await Go2RTC.waitForAllChildrenToExit()
            drained = true
        }
        try await waitUntil { drained }
        await waiting.value
        fixture.cleanup()
    }

    func testStopIsNonblockingAndRestartWaitsForExitAcrossInstances() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), second = fixture.relay()
        try await first.start(config: fixture.config)
        first.stop()
        XCTAssertEqual(fixture.children[0].terminationRequests, 1)
        XCTAssertFalse(first.running)

        let restart = Task { try await second.start(config: fixture.config) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(fixture.children.count, 1)
        XCTAssertFalse(restart.isCancelled)
        fixture.children[0].exit()
        try await restart.value
        XCTAssertEqual(fixture.children.count, 2)
        second.stop()
        fixture.children[1].exit()
    }

    func testStopOrCancellationWhileWaitingCannotLaunchLate() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), stopped = fixture.relay(), cancelled = fixture.relay()
        try await first.start(config: fixture.config)
        first.stop()
        let waiting = Task { try await stopped.start(config: fixture.config) }
        let cancelledTask = Task { try await cancelled.start(config: fixture.config) }
        try await Task.sleep(for: .milliseconds(50))
        stopped.stop()
        cancelledTask.cancel()
        for task in [waiting, cancelledTask] {
            do { try await task.value; XCTFail("Waiting start succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(fixture.children.count, 1)
        XCTAssertTrue(fixture.children[0].isRunning)
        fixture.children[0].exit()
    }

    func testReservationTimeoutPreservesPortsUntilChildExitsAndAllowsRetry() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), retry = fixture.relay(reservationTimeout: .milliseconds(80))
        try await first.start(config: fixture.config)
        first.stop()
        let child = fixture.children[0]
        XCTAssertTrue(child.isRunning)
        XCTAssertEqual(child.terminationRequests, 1)

        for _ in 0..<2 {
            let started = ContinuousClock.now
            var finished = false
            let start = Task {
                defer { finished = true }
                try await retry.start(config: fixture.config)
            }
            try await waitUntil { finished }
            do { try await start.value; XCTFail("Expected reservation timeout") }
            catch {
                XCTAssertTrue(error is ConfigurationError)
                XCTAssertTrue(error.localizedDescription.contains("ports are still reserved"))
            }
            XCTAssertGreaterThanOrEqual(started.duration(to: ContinuousClock.now), .milliseconds(50))
            XCTAssertEqual(fixture.children.count, 1)
            XCTAssertTrue(child.isRunning)
            XCTAssertEqual(child.terminationRequests, 1)
        }

        child.exit()
        try await retry.start(config: fixture.config)
        XCTAssertEqual(fixture.children.count, 2)
        XCTAssertTrue(retry.running)
        retry.stop()
        fixture.children[1].exit()
    }

    func testAlreadyCancelledStartCannotStopCurrentChild() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let relay = fixture.relay()
        try await relay.start(config: fixture.config)
        let stale = Task { try await relay.start(config: fixture.config) }
        stale.cancel()
        do { try await stale.value; XCTFail("Cancelled start succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(relay.running)
        XCTAssertEqual(fixture.children[0].terminationRequests, 0)
        relay.stop()
        fixture.children[0].exit()
    }

    func testLateReadinessCannotReviveStoppedRelayOrReleaseReplacement() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        fixture.holdRequests = true
        let first = fixture.relay(), second = fixture.relay(), third = fixture.relay()
        var oldFinished = false
        let oldStart = Task {
            defer { oldFinished = true }
            try await first.start(config: fixture.config)
        }
        try await waitUntil { fixture.pending.count == 1 }
        first.stop()
        try await waitUntil { oldFinished }
        fixture.children[0].exit()
        fixture.holdRequests = false
        try await second.start(config: fixture.config)
        fixture.completeRequest()
        do { try await oldStart.value; XCTFail("Stopped start succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(second.running)
        let next = Task { try await third.start(config: fixture.config) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.children.count, 2)
        second.stop()
        fixture.children[1].exit()
        try await next.value
        XCTAssertEqual(fixture.children.count, 3)
        third.stop()
        fixture.children[2].exit()
    }

    func testLateReadinessCannotStopNewStartOnSameInstance() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        fixture.holdRequests = true
        let relay = fixture.relay()
        let old = Task { try await relay.start(config: fixture.config) }
        try await waitUntil { fixture.pending.count == 1 }
        relay.stop()
        fixture.children[0].exit()
        fixture.holdRequests = false
        try await relay.start(config: fixture.config)
        fixture.completeRequest()
        do { try await old.value; XCTFail("Old start succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(relay.running)
        XCTAssertEqual(fixture.children[1].terminationRequests, 0)
        relay.stop()
        fixture.children[1].exit()
    }

    func testUnexpectedExitAndLaunchFailureReleaseReservation() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), second = fixture.relay()
        try await first.start(config: fixture.config)
        fixture.children[0].exit()
        try await second.start(config: fixture.config)
        second.stop()
        fixture.children[1].exit()

        let failed = Go2RTC(transport: { _ in XCTFail("Unexpected request"); throw Failure.timeout },
                            configurationDirectory: fixture.root,
                            childFactory: { _, _, _ in throw Failure.timeout })
        do { try await failed.start(config: fixture.config); XCTFail("Launch must fail") }
        catch {}
        let replacement = fixture.relay()
        try await replacement.start(config: fixture.config)
        replacement.stop()
        fixture.children[2].exit()
    }

    func testExitDuringUnresponsiveReadinessFailsWithoutWaitingForTransport() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        fixture.holdRequests = true
        let relay = fixture.relay()
        var finished = false
        let start = Task {
            defer { finished = true }
            try await relay.start(config: fixture.config)
        }
        try await waitUntil { fixture.pending.count == 1 }
        fixture.children[0].exit()
        try await waitUntil { finished }
        do { try await start.value; XCTFail("Exited relay cannot start") }
        catch {}
        fixture.completeRequest()
        XCTAssertFalse(relay.running)
    }

    func testCrossPortOverlapIsReservedUntilExit() async throws {
        let fixture = try RelayFixture()
        defer { fixture.cleanup() }
        let first = fixture.relay(), second = fixture.relay()
        try await first.start(config: fixture.config)
        var overlapping = fixture.config
        overlapping.apiPort = fixture.config.rtspPort
        overlapping.rtspPort = 28555
        first.stop()
        let waiting = Task { try await second.start(config: overlapping) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.children.count, 1)
        fixture.children[0].exit()
        try await waiting.value
        second.stop()
        fixture.children[1].exit()
    }
}
