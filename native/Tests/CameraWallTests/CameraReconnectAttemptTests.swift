import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CameraWall
#endif

@MainActor
private final class FakeReconnectSession: ReconnectAttemptSession {
    let attemptID: UUID
    var frame: ReconnectFrameEvidence?
    var startError = false
    var started = false
    var stopped = false
    var stopCount = 0

    init(_ attemptID: UUID) { self.attemptID = attemptID }

    func start() throws {
        started = true
        if startError { throw FakeError.start }
    }

    func latestFrame() -> ReconnectFrameEvidence? { frame }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stopCount += 1
    }

    func publish(id: UUID? = nil, sequence: UInt64 = 1, at time: ContinuousClock.Instant = ContinuousClock().now) {
        guard !stopped else { return }
        frame = ReconnectFrameEvidence(attemptID: id ?? attemptID, sequence: sequence, receivedAt: time)
    }

    enum FakeError: Error { case start }
}

@MainActor
final class CameraReconnectAttemptTests: XCTestCase {
    func testFreshFrameTransfersOnlyNewSession() async throws {
        let helper = CameraReconnectAttempt()
        var session: FakeReconnectSession!
        let task = Task {
            try await helper.run(timeout: .seconds(1)) { id in
                session = FakeReconnectSession(id)
                return session
            }
        }
        await Task.yield()
        session.publish(id: UUID())
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(session.stopped)
        session.publish(sequence: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        session.publish()
        let verified = try await task.value
        XCTAssertEqual(verified.attemptID, session.attemptID)
        XCTAssertEqual(verified.frame.attemptID, verified.attemptID)
        XCTAssertEqual(verified.frame.sequence, 1)
        XCTAssertTrue(verified.session === session)
        XCTAssertFalse(session.stopped)
        session.stop()
    }

    func testStaleAndFutureFramesCannotVerify() async throws {
        let helper = CameraReconnectAttempt()
        let stale = ContinuousClock().now.advanced(by: .seconds(-1))
        var session: FakeReconnectSession!
        let task = Task {
            try await helper.run(timeout: .milliseconds(130)) { id in
                session = FakeReconnectSession(id)
                session.publish(at: stale)
                return session
            }
        }
        await Task.yield()
        try await Task.sleep(nanoseconds: 40_000_000)
        session.publish(at: ContinuousClock().now.advanced(by: .seconds(10)))
        do {
            _ = try await task.value
            XCTFail("Unattributable timestamps must not verify")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .timedOut)
        }
        XCTAssertTrue(session.stopped)
    }

    func testTimeoutAndLateCallbackStopSession() async throws {
        let helper = CameraReconnectAttempt()
        var session: FakeReconnectSession!
        do {
            _ = try await helper.run(timeout: .milliseconds(70)) { id in
                session = FakeReconnectSession(id)
                return session
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .timedOut)
        }
        session.publish()
        XCTAssertNil(session.frame)
        XCTAssertEqual(session.stopCount, 1)
    }

    func testTaskCancellationStopsSession() async throws {
        let helper = CameraReconnectAttempt()
        var session: FakeReconnectSession!
        let task = Task {
            try await helper.run(timeout: .seconds(1)) { id in
                session = FakeReconnectSession(id)
                return session
            }
        }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(session.stopped)
    }

    func testSupersessionCannotStopOrVerifyReplacement() async throws {
        let helper = CameraReconnectAttempt()
        var first: FakeReconnectSession!
        var second: FakeReconnectSession!
        let old = Task {
            try await helper.run(timeout: .seconds(1)) { id in
                first = FakeReconnectSession(id)
                return first
            }
        }
        await Task.yield()
        let new = Task {
            try await helper.run(timeout: .seconds(1)) { id in
                second = FakeReconnectSession(id)
                return second
            }
        }
        await Task.yield()
        XCTAssertTrue(first.stopped)
        XCTAssertNotEqual(first.attemptID, second.attemptID)
        second.publish(id: first.attemptID)
        try await Task.sleep(nanoseconds: 50_000_000)
        second.publish()
        let verified = try await new.value
        do {
            _ = try await old.value
            XCTFail("Old attempt must not succeed")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .superseded)
        }
        XCTAssertEqual(verified.attemptID, second.attemptID)
        XCTAssertFalse(second.stopped)
        second.stop()
    }

    func testExplicitCancelAndStartFailureStopSession() async throws {
        let helper = CameraReconnectAttempt()
        var session: FakeReconnectSession!
        let task = Task {
            try await helper.run(timeout: .seconds(1)) { id in
                session = FakeReconnectSession(id)
                return session
            }
        }
        await Task.yield()
        helper.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected supersession")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .superseded)
        }
        XCTAssertEqual(session.stopCount, 1)

        do {
            _ = try await helper.run(timeout: .seconds(1)) { id in
                session = FakeReconnectSession(id)
                session.startError = true
                return session
            }
            XCTFail("Expected start failure")
        } catch is FakeReconnectSession.FakeError {
        }
        XCTAssertEqual(session.stopCount, 1)
    }

    func testInvalidTimeoutAndSessionAreRejected() async throws {
        let helper = CameraReconnectAttempt()
        var made = false
        do {
            _ = try await helper.run(timeout: .seconds(31)) { id in
                made = true
                return FakeReconnectSession(id)
            }
            XCTFail("Expected invalid timeout")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .invalidTimeout)
        }
        XCTAssertFalse(made)
        var session: FakeReconnectSession!
        do {
            _ = try await helper.run(timeout: .seconds(1)) { _ in
                session = FakeReconnectSession(UUID())
                return session
            }
            XCTFail("Expected invalid session")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .invalidSession)
        }
        XCTAssertTrue(session.stopped)
    }

    func testExpiredFactoryCannotStartSession() async throws {
        let helper = CameraReconnectAttempt()
        var session: FakeReconnectSession!
        do {
            _ = try await helper.run(timeout: .milliseconds(5)) { id in
                session = FakeReconnectSession(id)
                Thread.sleep(forTimeInterval: 0.02)
                return session
            }
            XCTFail("Expired attempt must not start")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .timedOut)
        }
        XCTAssertFalse(session.started)
        XCTAssertTrue(session.stopped)
    }
}
