import Foundation

protocol ScreenCaptureLifecycleStream: AnyObject {
    func start(completion: @escaping (Error?) -> Void)
    func stop(completion: @escaping (Error?) -> Void)
}

final class ScreenCaptureLifecycle {
    private let queue = DispatchQueue(label: "CameraWall.screenLifecycle")
    private let stateLock = NSLock()
    private var stopped = false
    private var stream: (any ScreenCaptureLifecycleStream)?

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func start(
        makeStream: () async throws -> any ScreenCaptureLifecycleStream,
        onResult: @escaping (Result<Void, Error>) -> Void
    ) async {
        guard !isStopped() else { return }
        do {
            let candidate = try await makeStream()
            queue.sync {
                guard !isStopped(), stream == nil else { return }
                stream = candidate
                candidate.start { [self, candidate] error in
                    queue.async {
                        if self.isStopped() {
                            // A stop issued during start may have completed before start did.
                            self.requestStop(candidate)
                        } else if let error {
                            onResult(.failure(error))
                        } else {
                            onResult(.success(()))
                        }
                    }
                }
            }
        } catch {
            queue.sync {
                if !isStopped() { onResult(.failure(error)) }
            }
        }
    }

    func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        queue.async { [self] in
            if let stream { requestStop(stream) }
            stream = nil
        }
    }

    private func requestStop(_ stream: any ScreenCaptureLifecycleStream) {
        stream.stop { error in
            if let error { NSLog("Screen capture stop failed: %@", error.localizedDescription) }
        }
    }
}
