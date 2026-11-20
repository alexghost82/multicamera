import CoreVideo
import Foundation
import Testing

@testable import CameraWall

private struct GatePixel: @unchecked Sendable {
    let value: CVPixelBuffer
}

private func gatePixel() throws -> GatePixel {
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
          let pixel else { throw GateTestFailure() }
    return GatePixel(value: pixel)
}

private struct GateTestFailure: Error {}

private func awaitPending(_ gate: ACTAFrameCaptureGate) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !gate.isAwaitingFrame && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    guard gate.isAwaitingFrame else { throw GateTestFailure() }
}

private func awaitSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 1) == .success)
        }
    }
}

struct ACTAFrameCaptureGateTests {
    @Test func busyTimeoutCancellationAndLateDelivery() async throws {
        let gate = ACTAFrameCaptureGate()
        let waiting = Task { try await gate.capture(timeout: .seconds(2)) }
        try await awaitPending(gate)
        do {
            _ = try await gate.capture()
            Issue.record("Concurrent capture unexpectedly succeeded")
        } catch ACTAFrameCaptureGate.Failure.busy {
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!gate.isAwaitingFrame)
        gate.offer(try gatePixel().value, serial: 1, receivedAt: 1)
        await #expect(throws: ACTAFrameCaptureGate.Failure.self) {
            try await gate.capture(timeout: .milliseconds(10))
        }
        #expect(!gate.isAwaitingFrame)
        gate.stop()
        await #expect(throws: ACTAFrameCaptureGate.Failure.self) { try await gate.capture() }
    }

    @Test func stopDoesNotWaitForCopyAndLateCopyCannotResumeCapture() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let gate = ACTAFrameCaptureGate { source in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return try ACTASnapshotPixelCopy.copy(source)
        }
        let pixel = try gatePixel()
        let waiting = Task { try await gate.capture(timeout: .seconds(3)) }
        try await awaitPending(gate)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.offer(pixel.value, serial: 1, receivedAt: 1)
            finished.signal()
        }
        #expect(await awaitSignal(entered))
        gate.stop()
        let start = ContinuousClock.now
        await #expect(throws: ACTAFrameCaptureGate.Failure.self) { try await waiting.value }
        #expect(start.duration(to: .now) < .seconds(1))
        release.signal()
        #expect(await awaitSignal(finished))
        #expect(!gate.isAwaitingFrame)
    }

    @Test func cancellationDuringCopyDiscardsResultAndPreventsOverlappingCopy() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let gate = ACTAFrameCaptureGate { source in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            return try ACTASnapshotPixelCopy.copy(source)
        }
        let pixel = try gatePixel()
        let waiting = Task { try await gate.capture(timeout: .seconds(3)) }
        try await awaitPending(gate)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.offer(pixel.value, serial: 1, receivedAt: 1)
            finished.signal()
        }
        #expect(await awaitSignal(entered))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        do {
            _ = try await gate.capture()
            Issue.record("Capture overlapped an abandoned copy")
        } catch ACTAFrameCaptureGate.Failure.busy {
        }
        release.signal()
        #expect(await awaitSignal(finished))
        gate.stop()
        #expect(!gate.isAwaitingFrame)
    }

    @Test func copyErrorsReachOnlyTheWaitingCapture() async throws {
        let gate = ACTAFrameCaptureGate { _ in throw GateTestFailure() }
        let waiting = Task { try await gate.capture() }
        try await awaitPending(gate)
        gate.offer(try gatePixel().value, serial: 1, receivedAt: 1)
        await #expect(throws: GateTestFailure.self) { try await waiting.value }
        #expect(!gate.isAwaitingFrame)
    }
}
