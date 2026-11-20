import CoreVideo
import Foundation

struct ACTAOwnedCameraFrame: @unchecked Sendable {
    let pixel: CVPixelBuffer
    let serial: UInt64
    let receivedAt: TimeInterval
}

/// A producer calls offer synchronously while its source buffer is stable.
/// Only the independently allocated copy is delivered to the consumer.
final class ACTAFrameCaptureGate: @unchecked Sendable {
    enum Failure: Error { case busy, stopped, timeout }

    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<ACTAOwnedCameraFrame, Error>
    }

    private let lock = NSLock()
    private let copy: @Sendable (CVPixelBuffer) throws -> CVPixelBuffer
    private var stopped = false
    private var pending: Pending?
    private var copying = false

    init(copy: @escaping @Sendable (CVPixelBuffer) throws -> CVPixelBuffer = { try ACTASnapshotPixelCopy.copy($0) }) {
        self.copy = copy
    }

    var isAwaitingFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil
    }

    func capture(timeout: Duration = .seconds(3)) async throws -> ACTAOwnedCameraFrame {
        try await withThrowingTaskGroup(of: ACTAOwnedCameraFrame.self) { group in
            group.addTask { try await self.waitForFrame() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else { throw Failure.stopped }
            return frame
        }
    }

    private func waitForFrame() async throws -> ACTAOwnedCameraFrame {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                let error: Error?
                if Task.isCancelled { error = CancellationError() }
                else if stopped { error = Failure.stopped }
                else if pending != nil || copying { error = Failure.busy }
                else {
                    pending = Pending(id: id, continuation: continuation)
                    error = nil
                }
                lock.unlock()
                if let error { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.cancel(id: id, error: CancellationError())
        }
    }

    func offer(_ pixel: CVPixelBuffer, serial: UInt64, receivedAt: TimeInterval) {
        lock.lock()
        guard !stopped, !copying, let request = pending else { lock.unlock(); return }
        copying = true
        lock.unlock()

        let result = Result {
            ACTAOwnedCameraFrame(pixel: try copy(pixel),
                                 serial: serial, receivedAt: receivedAt)
        }
        lock.lock()
        copying = false
        let recipient = pending?.id == request.id ? pending : nil
        if recipient != nil { pending = nil }
        lock.unlock()
        recipient?.continuation.resume(with: result)
    }

    func stop() {
        lock.lock()
        stopped = true
        let recipient = pending
        pending = nil
        lock.unlock()
        recipient?.continuation.resume(throwing: Failure.stopped)
    }

    private func cancel(id: UUID, error: Error) {
        lock.lock()
        let recipient = pending?.id == id ? pending : nil
        if recipient != nil { pending = nil }
        lock.unlock()
        recipient?.continuation.resume(throwing: error)
    }
}
