import Foundation

protocol ScreenCaptureLifecycleStream: AnyObject {
    func start(completion: @escaping (Error?) -> Void)
    func stop(completion: @escaping (Error?) -> Void)
}

final class ScreenCaptureLifecycle: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CameraWall.screenLifecycle")
    private let stateLock = NSLock()
    private var stopped = false
    private var stream: (any ScreenCaptureLifecycleStream)?
    private var pendingStarts = 0
    private var pendingStops = 0
    private var stopFailed = false
    private var stopWaiters: [CheckedContinuation<Void, Error>] = []

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func start(
        makeStream: () async throws -> any ScreenCaptureLifecycleStream,
        onResult: @escaping (Result<Void, Error>) -> Void
    ) async {
        let admitted = queue.sync {
            guard !isStopped() else { return false }
            pendingStarts += 1
            return true
        }
        guard admitted else { return }
        do {
            let candidate = try await makeStream()
            queue.sync {
                guard !isStopped(), stream == nil else {
                    pendingStarts -= 1
                    finishWaitersIfDrained()
                    return
                }
                stream = candidate
                candidate.start { [self, candidate] error in
                    queue.async {
                        self.pendingStarts -= 1
                        if self.isStopped() {
                            // A stop issued during start may have completed before start did.
                            self.requestStop(candidate)
                        } else if let error {
                            onResult(.failure(error))
                        } else {
                            onResult(.success(()))
                        }
                        self.finishWaitersIfDrained()
                    }
                }
            }
        } catch {
            queue.sync {
                pendingStarts -= 1
                if !isStopped() { onResult(.failure(error)) }
                finishWaitersIfDrained()
            }
        }
    }

    func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        queue.async { [self] in
            if let stream { requestStop(stream) }
            stream = nil
            finishWaitersIfDrained()
        }
        stateLock.unlock()
    }

    private func requestStop(_ stream: any ScreenCaptureLifecycleStream) {
        pendingStops += 1
        stream.stop { [self] error in
            queue.async {
                if let error {
                    self.stopFailed = true
                    NSLog("Screen capture stop failed: %@", error.localizedDescription)
                }
                self.pendingStops -= 1
                self.finishWaitersIfDrained()
            }
        }
    }

    func stopAndWait() async throws {
        stop()
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.stopWaiters.append(continuation)
                self.finishWaitersIfDrained()
            }
        }
    }

    private func finishWaitersIfDrained() {
        guard isStopped(), pendingStarts == 0, pendingStops == 0 else { return }
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            if stopFailed { waiter.resume(throwing: StopFailure()) }
            else { waiter.resume() }
        }
    }

    private struct StopFailure: Error {}
}
