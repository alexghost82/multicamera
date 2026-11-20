import Foundation
import XCTest
@testable import CameraWall

private actor AnalyticsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class AnalyticsWorkTrackerTests: XCTestCase {
    func testDrainWaitsForDetachedWorkAndActorDelivery() async throws {
        let tracker = AnalyticsWorkTracker()
        let parent = tracker.begin()
        let gate = AnalyticsGate()
        let task = Task.detached {
            await gate.wait()
            let delivery = tracker.begin()
            parent.finish()
            await MainActor.run { delivery.finish() }
        }
        while !(await gate.waiting) { await Task.yield() }
        var drained = false
        let waiter = Task { @MainActor in
            await tracker.wait()
            drained = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained)
        await gate.release()
        await task.value
        await waiter.value
        XCTAssertTrue(drained)
    }

    func testMultipleWaitersAndIdempotentCompletion() async {
        let tracker = AnalyticsWorkTracker()
        let ticket = tracker.begin()
        let first = Task { await tracker.wait() }
        let second = Task { await tracker.wait() }
        ticket.finish()
        ticket.finish()
        await first.value
        await second.value
        await tracker.wait()
    }
}
