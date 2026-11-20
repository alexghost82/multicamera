import Foundation
import XCTest
@testable import CameraWall

private actor DeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class CameraRuntimeWorkGroupTests: XCTestCase {
    func testFenceJoinsLateDeliveryBeforeAllowingRestart() async throws {
        let group = CameraRuntimeWorkGroup()
        let ticket = try XCTUnwrap(group.begin())
        group.fence()
        XCTAssertNil(group.begin())
        XCTAssertFalse(group.resume())

        var delivered = false
        let delivery = Task { @MainActor in
            await Task.yield()
            delivered = true
            ticket.finish()
            ticket.finish()
        }
        await group.wait()
        XCTAssertTrue(delivered)
        await delivery.value
        XCTAssertTrue(group.resume())
        let next = try XCTUnwrap(group.begin())
        group.fence()
        XCTAssertFalse(group.resume())
        next.finish()
        await group.wait()
        XCTAssertTrue(group.resume())
    }

    func testMultipleDrainWaitersResumeOnlyAfterAllTicketsFinish() async throws {
        let group = CameraRuntimeWorkGroup()
        let first = try XCTUnwrap(group.begin())
        let second = try XCTUnwrap(group.begin())
        group.fence()
        var completed = 0
        let a = Task { @MainActor in await group.wait(); completed += 1 }
        let b = Task { @MainActor in await group.wait(); completed += 1 }
        await Task.yield()
        first.finish()
        await Task.yield()
        XCTAssertEqual(completed, 0)
        second.finish()
        await a.value
        await b.value
        XCTAssertEqual(completed, 2)
        XCTAssertTrue(group.resume())
    }

    func testFencedWorkTransfersThroughQueueAndActorWithoutBlockingOtherInstance() async throws {
        let lifecycle = CameraNetworkLifecycle()
        let other = CameraNetworkLifecycle()
        let producer = try XCTUnwrap(lifecycle.begin())
        lifecycle.fence()
        lifecycle.join {}
        var restarted = false
        let restart = Task { @MainActor in
            try await lifecycle.prepareStart()
            restarted = true
        }

        other.fence()
        other.join {}
        try await other.prepareStart()
        XCTAssertFalse(restarted)

        let queueEntered = expectation(description: "tracking queue entered")
        let deliveryEntered = expectation(description: "actor delivery entered")
        let queueGate = DispatchSemaphore(value: 0)
        let deliveryGate = DeliveryGate()
        defer { queueGate.signal(); Task { await deliveryGate.release() } }
        let tracking = producer.makeChild()
        DispatchQueue(label: "SyntheticDetectionTracking").async {
            queueEntered.fulfill()
            queueGate.wait()
            let delivery = tracking.makeChild()
            Task { @MainActor in
                deliveryEntered.fulfill()
                await deliveryGate.wait()
                delivery.finish()
            }
            tracking.finish()
        }
        producer.finish()
        await fulfillment(of: [queueEntered], timeout: 5)
        XCTAssertFalse(restarted)
        XCTAssertNil(lifecycle.begin())
        queueGate.signal()
        await fulfillment(of: [deliveryEntered], timeout: 5)
        XCTAssertFalse(restarted)
        await deliveryGate.release()
        try await restart.value
        XCTAssertTrue(restarted)
    }
}
