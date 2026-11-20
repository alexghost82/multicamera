import Foundation

/// Register work before dispatching it and retain the ticket through any
/// subsequent actor delivery. Fence producers before draining the group.
final class CameraRuntimeWorkGroup: @unchecked Sendable {
    final class Ticket: @unchecked Sendable {
        private let owner: CameraRuntimeWorkGroup
        private let lock = NSLock()
        private var finished = false

        fileprivate init(owner: CameraRuntimeWorkGroup) { self.owner = owner }

        /// A producer may transfer work after fencing while its own ticket is active.
        func makeChild() -> Ticket {
            lock.lock()
            defer { lock.unlock() }
            precondition(!finished)
            return owner.beginChild()
        }

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
    private var fenced = false
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard !fenced else { return nil }
        count += 1
        return Ticket(owner: self)
    }

    private func beginChild() -> Ticket {
        lock.lock()
        count += 1
        lock.unlock()
        return Ticket(owner: self)
    }

    func fence() {
        lock.lock()
        fenced = true
        lock.unlock()
    }

    /// Only call after every old producer has been fenced and all registered
    /// work has ended. A pending ticket prevents accidental early restart.
    func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fenced, count == 0 else { return false }
        fenced = false
        return true
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            fenced = true
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
