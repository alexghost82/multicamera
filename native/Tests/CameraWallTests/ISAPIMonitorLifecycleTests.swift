import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor SyntheticISAPIProducer {
    private var state: ISAPIMonitorLifecycle.StateCallback?
    private var event: ISAPIMonitorLifecycle.EventCallback?
    private var continuation: CheckedContinuation<Void, Never>?

    func run(state: @escaping ISAPIMonitorLifecycle.StateCallback,
             event: @escaping ISAPIMonitorLifecycle.EventCallback) async {
        self.state = state
        self.event = event
        await withCheckedContinuation { continuation = $0 }
    }

    var started: Bool { continuation != nil }

    func send(_ label: String, record: ISAPIEventRecord) async {
        await state?(label)
        await event?(record)
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ISAPICancelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func cancel() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class ISAPIMonitorLifecycleTests: XCTestCase {
    private func waitUntilStarted(_ producer: SyntheticISAPIProducer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await !producer.started {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCancelledProducerIsJoinedAndOldCallbacksCannotAffectRestart() async throws {
        let lifecycle = ISAPIMonitorLifecycle()
        let old = SyntheticISAPIProducer()
        let replacement = SyntheticISAPIProducer()
        let cancellation = ISAPICancelProbe()
        let cameraID = UUID()
        let record = ISAPIEventRecord(cameraID: cameraID, cameraName: "synthetic",
            payload: ISAPIEventPayload(eventType: "VMD", eventState: nil, channelID: nil,
                                       eventDescription: nil, occurredAt: nil))
        var states: [String] = []
        var events: [ISAPIEventRecord] = []
        XCTAssertTrue(lifecycle.activate())
        XCTAssertTrue(lifecycle.start(cameraID: cameraID, cancel: { cancellation.cancel() },
            run: { state, event in await old.run(state: state, event: event) },
            onState: { states.append($0) }, onEvent: { events.append($0) }))
        try await waitUntilStarted(old)
        await old.send("old live", record: record)
        XCTAssertEqual(states, ["old live"])
        XCTAssertEqual(events.count, 1)
        lifecycle.fence()
        XCTAssertEqual(cancellation.count, 1)
        var drained = false
        let drain = Task { @MainActor in
            try await lifecycle.waitForStop()
            drained = true
        }
        await old.send("old after stop", record: record)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(drained)
        XCTAssertFalse(lifecycle.activate())
        XCTAssertEqual(states, ["old live"])
        XCTAssertEqual(events.count, 1)
        await old.finish()
        try await drain.value
        XCTAssertTrue(drained)

        XCTAssertTrue(lifecycle.activate())
        XCTAssertTrue(lifecycle.start(cameraID: cameraID, cancel: {},
            run: { state, event in await replacement.run(state: state, event: event) },
            onState: { states.append($0) }, onEvent: { events.append($0) }))
        try await waitUntilStarted(replacement)
        await old.send("old after restart", record: record)
        await replacement.send("new live", record: record)
        XCTAssertEqual(states, ["old live", "new live"])
        XCTAssertEqual(events.count, 2)
        lifecycle.fence()
        await replacement.finish()
        try await lifecycle.waitForStop()
    }

    func testRepeatedStopWhileProducerIsRunningCanStillDrain() async throws {
        let lifecycle = ISAPIMonitorLifecycle()
        let producer = SyntheticISAPIProducer()
        XCTAssertTrue(lifecycle.activate())
        XCTAssertTrue(lifecycle.start(cameraID: UUID(), cancel: {},
            run: { state, event in await producer.run(state: state, event: event) },
            onState: { _ in }, onEvent: { _ in }))
        try await waitUntilStarted(producer)
        lifecycle.fence()
        let first = Task { @MainActor in try await lifecycle.waitForStop() }
        await Task.yield()
        lifecycle.fence()
        let second = Task { @MainActor in try await lifecycle.waitForStop() }
        await producer.finish()
        try await first.value
        try await second.value
        XCTAssertTrue(lifecycle.activate())
        lifecycle.fence()
        try await lifecycle.waitForStop()
    }

    func testNetworkRestartWaitsForCancelledMonitorProducer() async throws {
        let lifecycle = ISAPIMonitorLifecycle()
        let network = CameraNetworkLifecycle()
        let producer = SyntheticISAPIProducer()
        XCTAssertTrue(lifecycle.activate())
        XCTAssertTrue(lifecycle.start(cameraID: UUID(), cancel: {},
            run: { state, event in await producer.run(state: state, event: event) },
            onState: { _ in }, onEvent: { _ in }))
        try await waitUntilStarted(producer)
        lifecycle.fence()
        network.fence()
        network.join { try await lifecycle.waitForStop() }
        var restarted = false
        let restart = Task { @MainActor in
            try await network.prepareStart()
            restarted = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(restarted)
        await producer.finish()
        try await restart.value
        XCTAssertTrue(restarted)
        XCTAssertTrue(lifecycle.activate())
        lifecycle.fence()
        try await lifecycle.waitForStop()
    }

    func testOneMonitorFailureStillJoinsOtherProducers() async throws {
        let lifecycle = ISAPIMonitorLifecycle()
        let failing = SyntheticISAPIProducer()
        let pending = SyntheticISAPIProducer()
        XCTAssertTrue(lifecycle.activate())
        XCTAssertTrue(lifecycle.start(cameraID: UUID(), cancel: {},
            run: { state, event in
                await failing.run(state: state, event: event)
                throw CocoaError(.fileReadUnknown)
            }, onState: { _ in }, onEvent: { _ in }))
        XCTAssertTrue(lifecycle.start(cameraID: UUID(), cancel: {},
            run: { state, event in await pending.run(state: state, event: event) },
            onState: { _ in }, onEvent: { _ in }))
        try await waitUntilStarted(failing)
        try await waitUntilStarted(pending)
        lifecycle.fence()
        var finished = false
        let drain = Task { @MainActor in
            defer { finished = true }
            try await lifecycle.waitForStop()
        }
        await failing.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)
        await pending.finish()
        do {
            try await drain.value
            XCTFail("Monitor failure must prevent a successful drain")
        } catch {}
        XCTAssertFalse(lifecycle.activate())
    }
}
