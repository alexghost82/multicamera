import Foundation

/// Tracks work across detached tasks, dispatch queues and their actor deliveries.
final class AnalyticsWorkTracker: @unchecked Sendable {
    final class Ticket: @unchecked Sendable {
        private let owner: AnalyticsWorkTracker
        private let lock = NSLock()
        private var finished = false

        fileprivate init(owner: AnalyticsWorkTracker) { self.owner = owner }
        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            owner.complete()
        }
        deinit { finish() }
    }

    private let lock = NSLock()
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> Ticket {
        lock.lock()
        count += 1
        lock.unlock()
        return Ticket(owner: self)
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func complete() {
        lock.lock()
        count -= 1
        let ready = count == 0 ? waiters : []
        if count == 0 { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }
}
