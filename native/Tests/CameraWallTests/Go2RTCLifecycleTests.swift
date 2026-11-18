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
