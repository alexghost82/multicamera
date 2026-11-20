import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class CameraNetworkLifecycleTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
    }

    func testRestartWaitsForFencedWorkAndRelayCleanup() async throws {
        let lifecycle = CameraNetworkLifecycle()
        let oldWork = try XCTUnwrap(lifecycle.begin())
        lifecycle.fence()
        XCTAssertNil(lifecycle.begin())
        var cleanup: CheckedContinuation<Void, Never>?
        lifecycle.join {
            await withCheckedContinuation { cleanup = $0 }
        }
        var restarted = false
        let start = Task { @MainActor in
            try await lifecycle.prepareStart()
            restarted = true
        }
        await Task.yield()
        XCTAssertFalse(restarted)
        XCTAssertNil(cleanup)
        oldWork.finish()
        try await waitUntil { cleanup != nil }
        XCTAssertFalse(restarted)
        XCTAssertNil(lifecycle.begin())
        cleanup?.resume()
        try await start.value
        XCTAssertTrue(restarted)
        let newWork = try XCTUnwrap(lifecycle.begin())
        newWork.finish()
    }

    func testRepeatedStopInvalidatesWaitingRestart() async throws {
        let lifecycle = CameraNetworkLifecycle()
        let oldWork = try XCTUnwrap(lifecycle.begin())
        lifecycle.fence()
        lifecycle.join {}
        var entered = false
        let first = Task { @MainActor in
            entered = true
            try await lifecycle.prepareStart()
        }
        try await waitUntil { entered }
        lifecycle.fence()
        lifecycle.join {}
        let second = Task { @MainActor in try await lifecycle.prepareStart() }
        oldWork.finish()
        do {
            try await first.value
            XCTFail("Superseded restart must fail")
        } catch is CancellationError {}
        try await second.value
        let ticket = try XCTUnwrap(lifecycle.begin())
        ticket.finish()
    }

    func testStoppedRevisionIsInvalidAfterRestart() async throws {
        let lifecycle = CameraNetworkLifecycle()
        lifecycle.fence()
        lifecycle.join {}
        let stopped = lifecycle.stoppedRevision()
        try await lifecycle.waitForStop(stopped)
        try await lifecycle.prepareStart()
        XCTAssertThrowsError(try lifecycle.checkStopped(stopped))
    }

    func testFailedCleanupPreventsRestart() async throws {
        struct Failure: Error {}
        let lifecycle = CameraNetworkLifecycle()
        lifecycle.fence()
        lifecycle.join { throw Failure() }
        do {
            try await lifecycle.prepareStart()
            XCTFail("A failed drain must not restart network producers")
        } catch is Failure {}
        XCTAssertNil(lifecycle.begin())
    }

    func testAfterStopDoesNotRunForFailedOrSupersededDrain() async throws {
        struct Failure: Error {}
        let failed = CameraNetworkLifecycle()
        failed.fence()
        failed.join { throw Failure() }
        var reopened = false
        var reportedFailure = false
        let failedCallback = failed.afterStop(failed.stoppedRevision(), onFailure: { _ in reportedFailure = true }) { reopened = true }
        await failedCallback.value
        XCTAssertFalse(reopened)
        XCTAssertTrue(reportedFailure)

        let lifecycle = CameraNetworkLifecycle()
        let work = try XCTUnwrap(lifecycle.begin())
        lifecycle.fence()
        lifecycle.join {}
        var supersededFailure = false
        let oldCallback = lifecycle.afterStop(lifecycle.stoppedRevision(), onFailure: { _ in supersededFailure = true }) { reopened = true }
        lifecycle.fence()
        lifecycle.join {}
        work.finish()
        await oldCallback.value
        XCTAssertFalse(reopened)
        XCTAssertFalse(supersededFailure)
        let callback = lifecycle.afterStop(lifecycle.stoppedRevision(), onFailure: { _ in XCTFail("Unexpected drain failure") }) { reopened = true }
        await callback.value
        XCTAssertTrue(reopened)
    }

    func testFenceWithoutJoinCannotReportStopOrRestart() async throws {
        let lifecycle = CameraNetworkLifecycle()
        let ticket = try XCTUnwrap(lifecycle.begin())
        lifecycle.fence()
        let revision = lifecycle.stoppedRevision()
        do {
            try await lifecycle.waitForStop(revision)
            XCTFail("An unjoined fence is not a drain")
        } catch {}
        do {
            try await lifecycle.prepareStart()
            XCTFail("An unjoined fence cannot restart")
        } catch {}
        XCTAssertThrowsError(try lifecycle.checkStopped(revision))
        XCTAssertNil(lifecycle.begin())
        lifecycle.join {}
        let stopping = Task { @MainActor in
            try await lifecycle.waitForStop(lifecycle.stoppedRevision())
        }
        ticket.finish()
        try await stopping.value
        try await lifecycle.prepareStart()
    }

    func testReplacingJoinInvalidatesOlderWaiter() async throws {
        let lifecycle = CameraNetworkLifecycle()
        lifecycle.fence()
        var first: CheckedContinuation<Void, Never>?
        lifecycle.join { await withCheckedContinuation { first = $0 } }
        let oldRevision = lifecycle.stoppedRevision()
        let oldWaiter = Task { @MainActor in try await lifecycle.waitForStop(oldRevision) }
        try await waitUntil { first != nil }
        var second: CheckedContinuation<Void, Never>?
        lifecycle.join { await withCheckedContinuation { second = $0 } }
        let newRevision = lifecycle.stoppedRevision()
        first?.resume()
        do {
            try await oldWaiter.value
            XCTFail("An older join cannot certify the replacement")
        } catch is CancellationError {}
        try await waitUntil { second != nil }
        XCTAssertThrowsError(try lifecycle.checkStopped(oldRevision))
        second?.resume()
        try await lifecycle.waitForStop(newRevision)
    }

    func testStopCheckRejectsPendingCleanup() async throws {
        let lifecycle = CameraNetworkLifecycle()
        lifecycle.fence()
        var cleanup: CheckedContinuation<Void, Never>?
        lifecycle.join { await withCheckedContinuation { cleanup = $0 } }
        let revision = lifecycle.stoppedRevision()
        try await waitUntil { cleanup != nil }
        XCTAssertThrowsError(try lifecycle.checkStopped(revision))
        cleanup?.resume()
        try await lifecycle.waitForStop(revision)
        XCTAssertNoThrow(try lifecycle.checkStopped(revision))
    }
}
