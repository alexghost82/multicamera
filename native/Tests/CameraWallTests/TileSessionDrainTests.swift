import AVFoundation
import Foundation
import XCTest
@testable import CameraWall

private final class TilePermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Bool) -> Void)?

    func request(_ callback: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func resolve() {
        lock.lock()
        let callback = callback
        self.callback = nil
        lock.unlock()
        callback?(false)
    }
}

private final class TileScreenProbe: ScreenCaptureLifecycleStream {
    private let lock = NSLock()
    private var startCallback: ((Error?) -> Void)?
    private var stopCount = 0

    func start(completion: @escaping (Error?) -> Void) {
        lock.lock()
        startCallback = completion
        lock.unlock()
    }

    func stop(completion: @escaping (Error?) -> Void) {
        lock.lock()
        stopCount += 1
        lock.unlock()
        completion(nil)
    }

    func finishStart() {
        lock.lock()
        let callback = startCallback
        startCallback = nil
        lock.unlock()
        callback?(nil)
    }

    var stops: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
    }
}

@MainActor
final class TileSessionDrainTests: XCTestCase {
    func testReplacedTileSessionsAreJoinedBeforeRestart() async throws {
        let tracker = CameraSessionDrainTracker()
        let lifecycle = CameraNetworkLifecycle()
        let tile = TileState(id: UUID())
        let first = CameraSession()
        let permission = TilePermissionProbe()
        defer { permission.resolve() }
        first.start(deviceID: "synthetic", authorizationStatus: { .notDetermined },
                    requestAccess: { permission.request($0) })
        tile.session = first
        tile.stop(tracking: tracker)

        let second = CameraSession()
        let stream = TileScreenProbe()
        defer { stream.finishStart() }
        await second.startScreenCapture { stream }
        tile.session = second
        tile.stop(tracking: tracker)
        lifecycle.fence()
        lifecycle.join { try await tracker.wait() }
        var restarted = false
        let restart = Task { @MainActor in
            try await lifecycle.prepareStart()
            restarted = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(restarted)
        permission.resolve()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(restarted)
        stream.finishStart()
        try await restart.value
        XCTAssertTrue(restarted)
        XCTAssertNil(tile.session)
        XCTAssertTrue(tile.stale)
        XCTAssertEqual(first.snapshot().message, "Stopped")
        XCTAssertEqual(second.snapshot().message, "Stopped")
        XCTAssertEqual(stream.stops, 2)
    }

    func testTwoOwnersDrainIndependently() async throws {
        let firstTracker = CameraSessionDrainTracker()
        let secondTracker = CameraSessionDrainTracker()
        let firstTile = TileState(id: UUID())
        let secondTile = TileState(id: UUID())
        let first = CameraSession()
        let second = CameraSession()
        let permission = TilePermissionProbe()
        defer { permission.resolve() }
        first.start(deviceID: "synthetic", authorizationStatus: { .notDetermined },
                    requestAccess: { permission.request($0) })
        firstTile.session = first
        secondTile.session = second
        firstTile.stop(tracking: firstTracker)
        secondTile.stop(tracking: secondTracker)
        var firstFinished = false
        let firstDrain = Task { @MainActor in
            try await firstTracker.wait()
            firstFinished = true
        }
        var secondFinished = false
        let secondDrain = Task { @MainActor in
            try await secondTracker.wait()
            secondFinished = true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !secondFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(secondFinished)
        XCTAssertFalse(firstFinished)
        permission.resolve()
        try await firstDrain.value
        try await secondDrain.value
        XCTAssertTrue(firstFinished)
    }

    func testStopJoinsLateTileRetirementFromFencedProducer() async throws {
        let tracker = CameraSessionDrainTracker()
        let lifecycle = CameraNetworkLifecycle()
        let ticket = try XCTUnwrap(lifecycle.begin())
        let tile = TileState(id: UUID())
        let session = CameraSession()
        let permission = TilePermissionProbe()
        defer { permission.resolve() }
        session.start(deviceID: "synthetic", authorizationStatus: { .notDetermined },
                      requestAccess: { permission.request($0) })
        tile.session = session
        lifecycle.fence()
        lifecycle.join { try await tracker.wait() }
        var finished = false
        let drain = Task { @MainActor in
            try await lifecycle.waitForStop(lifecycle.stoppedRevision())
            finished = true
        }
        tile.stop(tracking: tracker)
        ticket.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)
        permission.resolve()
        try await drain.value
        XCTAssertTrue(finished)
    }
}
