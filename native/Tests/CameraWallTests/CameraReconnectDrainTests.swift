import Foundation
import XCTest
@testable import CameraWall

private final class ReconnectPermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?

    func request(_ callback: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        completion = callback
        lock.unlock()
    }

    func resolve() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(true)
    }
}

@MainActor
final class CameraReconnectDrainTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            await Task.yield()
        }
    }

    func testStoppedReconnectWaitsForLateRegistrationAndNeverStartsDecoder() async throws {
        var resume: CheckedContinuation<String, Error>?
        var decoderStarts = 0
        let session = NetworkReconnectSession(attemptID: UUID(), register: {
            try await withCheckedThrowingContinuation { resume = $0 }
        }, startDecoder: { _, _ in decoderStarts += 1 })
        try session.start()
        while resume == nil { await Task.yield() }
        session.stop()
        var drained = false
        let task = Task { @MainActor in
            try await CameraReconnectAttempt.waitForStoppedSessions()
            drained = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained)
        resume?.resume(returning: "fixture")
        try await task.value
        XCTAssertTrue(drained)
        XCTAssertEqual(decoderStarts, 0)
    }

    func testRestartWaitsForCancelledReconnectRegistration() async throws {
        var resume: CheckedContinuation<String, Error>?
        var decoderStarts = 0
        let session = NetworkReconnectSession(attemptID: UUID(), register: {
            try await withCheckedThrowingContinuation { resume = $0 }
        }, startDecoder: { _, _ in decoderStarts += 1 })
        let lifecycle = CameraNetworkLifecycle()
        let owner = try XCTUnwrap(lifecycle.begin())
        try session.start()
        while resume == nil { await Task.yield() }
        lifecycle.fence()
        session.stop()
        lifecycle.join { try await CameraReconnectAttempt.waitForStoppedSessions() }
        owner.finish()
        var restarted = false
        let restart = Task { @MainActor in
            try await lifecycle.prepareStart()
            restarted = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(restarted)
        resume?.resume(returning: "fixture")
        try await restart.value
        XCTAssertTrue(restarted)
        XCTAssertEqual(decoderStarts, 0)
    }

    func testInstanceDrainDoesNotWaitForAnotherInstancesStoppedSession() async throws {
        let first = CameraReconnectAttempt()
        let second = CameraReconnectAttempt()
        let permission = ReconnectPermissionProbe()
        defer { permission.resolve() }
        var firstSession: NetworkReconnectSession?
        var secondRegistration: CheckedContinuation<String, Error>?
        let firstRun = Task { @MainActor in
            try await first.run(timeout: .seconds(5)) { id in
                let session = NetworkReconnectSession(attemptID: id, register: { "fixture" },
                                                      startDecoder: { _, _ in })
                session.session.start(deviceID: "synthetic", authorizationStatus: { .notDetermined },
                                      requestAccess: { permission.request($0) })
                firstSession = session
                return session
            }
        }
        try await waitUntil { firstSession != nil }
        first.cancel()
        _ = await firstRun.result

        let secondRun = Task { @MainActor in
            try await second.run(timeout: .seconds(5)) { id in
                NetworkReconnectSession(attemptID: id, register: {
                    try await withCheckedThrowingContinuation { secondRegistration = $0 }
                }, startDecoder: { _, _ in XCTFail("Cancelled registration started a decoder") })
            }
        }
        try await waitUntil { secondRegistration != nil }
        second.cancel()
        _ = await secondRun.result
        var firstDrained = false
        var secondDrained = false
        var globalDrained = false
        var firstWaiting = false
        var globalWaiting = false
        let firstWait = Task { @MainActor in
            firstWaiting = true
            try await first.waitForStoppedSessions()
            firstDrained = true
        }
        let secondWait = Task { @MainActor in
            try await second.waitForStoppedSessions()
            secondDrained = true
        }
        let globalWait = Task { @MainActor in
            globalWaiting = true
            try await CameraReconnectAttempt.waitForStoppedSessions()
            globalDrained = true
        }
        try await waitUntil { firstWaiting && globalWaiting }
        XCTAssertFalse(firstDrained)
        XCTAssertFalse(globalDrained)
        XCTAssertFalse(secondDrained)
        secondRegistration?.resume(returning: "fixture")
        try await waitUntil { secondDrained }
        XCTAssertFalse(firstDrained)
        XCTAssertFalse(globalDrained)
        permission.resolve()
        try await firstWait.value
        try await secondWait.value
        try await globalWait.value
        XCTAssertTrue(firstDrained)
        XCTAssertTrue(globalDrained)
    }

    func testReusedSessionFailsClosedOnlyForItsNewOwner() async throws {
        let session = NetworkReconnectSession(attemptID: UUID(), register: { "fixture" },
                                              startDecoder: { _, _ in XCTFail("Unexpected decoder") })
        session.stop()
        try await CameraReconnectAttempt.waitForStoppedSessions()
        let invalidOwner = CameraReconnectAttempt()
        do {
            _ = try await invalidOwner.run(timeout: .seconds(1)) { _ in session }
            XCTFail("A stopped session cannot be reassigned")
        } catch {
            XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .invalidSession)
        }
        do {
            try await invalidOwner.waitForStoppedSessions()
            XCTFail("Uncertain session ownership must fail closed")
        } catch {}
        try await CameraReconnectAttempt().waitForStoppedSessions()
        try await CameraReconnectAttempt.waitForStoppedSessions()
    }
}
