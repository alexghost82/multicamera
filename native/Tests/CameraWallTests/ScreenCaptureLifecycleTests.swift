import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CameraWall
#endif

private final class FakeScreenStream: ScreenCaptureLifecycleStream {
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?
    private var starts = 0
    private var stops = 0
    var stoppedAgain: XCTestExpectation?
    var startEntered: XCTestExpectation?
    var startRelease: DispatchSemaphore?

    func start(completion: @escaping (Error?) -> Void) {
        lock.lock()
        starts += 1
        self.completion = completion
        lock.unlock()
        startEntered?.fulfill()
        _ = startRelease?.wait(timeout: .now() + 2)
    }

    func stop(completion: @escaping (Error?) -> Void) {
        lock.lock()
        stops += 1
        let expectation = stops == 2 ? stoppedAgain : nil
        lock.unlock()
        completion(nil)
        expectation?.fulfill()
    }

    func finishStart(_ error: Error? = nil) {
        lock.lock()
        let callback = completion
        lock.unlock()
        callback?(error)
    }

    var counts: (starts: Int, stops: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, stops)
    }
}

private actor ScreenFactoryGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(entered: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

final class ScreenCaptureLifecycleTests: XCTestCase {
    private func waitForStops(_ count: Int, stream: FakeScreenStream) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while stream.counts.stops < count && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(stream.counts.stops, count)
    }

    func testStopWhileFactoryIsSuspendedNeverStartsLateStream() async {
        let session = CameraSession()
        let stream = FakeScreenStream()
        let gate = ScreenFactoryGate()
        let entered = expectation(description: "factory entered")
        let task = Task {
            await session.startScreenCapture {
                await gate.wait(entered: entered)
                return stream
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        session.stop()
        await gate.open()
        await task.value

        XCTAssertEqual(stream.counts.starts, 0)
        XCTAssertEqual(stream.counts.stops, 0)
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testStopDuringStartStopsAgainAfterLateCompletion() async throws {
        let session = CameraSession()
        let stream = FakeScreenStream()
        let stoppedAgain = expectation(description: "late start stopped")
        stream.stoppedAgain = stoppedAgain
        await session.startScreenCapture { stream }
        XCTAssertEqual(stream.counts.starts, 1)

        session.stop()
        session.stop()
        try await waitForStops(1, stream: stream)
        stream.finishStart()
        await fulfillment(of: [stoppedAgain], timeout: 1)
        XCTAssertEqual(stream.counts.stops, 2)
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testSuccessfulStartReportsLiveAndStopRequestsCleanup() async throws {
        let session = CameraSession()
        let stream = FakeScreenStream()
        await session.startScreenCapture { stream }
        stream.finishStart()

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while session.snapshot().message != "Live · ScreenCaptureKit", ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.snapshot().message, "Live · ScreenCaptureKit")
        session.stop()
        try await waitForStops(1, stream: stream)
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testFailedLateStartDoesNotChangeStoppedStatusAndIsStoppedAgain() async {
        struct FakeError: Error {}
        let session = CameraSession()
        let stream = FakeScreenStream()
        let stoppedAgain = expectation(description: "failed late start cleaned up")
        stream.stoppedAgain = stoppedAgain
        await session.startScreenCapture { stream }
        session.stop()
        stream.finishStart(FakeError())
        await fulfillment(of: [stoppedAgain], timeout: 1)

        XCTAssertEqual(stream.counts.stops, 2)
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testFactoryFailureAfterStopDoesNotOverwriteStoppedStatus() async {
        struct FakeError: Error {}
        let session = CameraSession()
        let gate = ScreenFactoryGate()
        let entered = expectation(description: "factory entered")
        let task = Task {
            await session.startScreenCapture {
                await gate.wait(entered: entered)
                throw FakeError()
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        session.stop()
        await gate.open()
        await task.value

        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testStartFailurePreservesErrorMessage() async throws {
        struct FakeError: Error {}
        let session = CameraSession()
        let stream = FakeScreenStream()
        await session.startScreenCapture { stream }
        stream.finishStart(FakeError())
        let expected = "Screen capture could not start. Check Screen Recording permission."
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while session.snapshot().message != expected, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.snapshot().message, expected)
        session.stop()
        try await waitForStops(1, stream: stream)
    }

    func testBlockingStartDoesNotBlockStopAndLateCompletionIsStopped() async throws {
        let session = CameraSession()
        let stream = FakeScreenStream()
        let entered = expectation(description: "blocking start entered")
        let stoppedAgain = expectation(description: "late start stopped again")
        let release = DispatchSemaphore(value: 0)
        stream.startEntered = entered
        stream.startRelease = release
        stream.stoppedAgain = stoppedAgain
        let task = Task { await session.startScreenCapture { stream } }
        await fulfillment(of: [entered], timeout: 1)
        let beforeStop = ContinuousClock.now
        session.stop()
        XCTAssertLessThan(beforeStop.duration(to: .now), .seconds(1))
        XCTAssertEqual(session.snapshot().message, "Stopped")
        release.signal()
        await task.value
        try await waitForStops(1, stream: stream)
        stream.finishStart()
        await fulfillment(of: [stoppedAgain], timeout: 1)
        XCTAssertEqual(stream.counts.stops, 2)
    }
}
