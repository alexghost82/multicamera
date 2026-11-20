import Foundation

// An adapter must create a distinct session for each attempt. A frame's attempt ID
// and timestamp must be recorded at the actual decoder/capture publication point,
// never assigned later while reading a shared tile or cached frame.
struct ReconnectFrameEvidence {
    let attemptID: UUID
    let sequence: UInt64
    let receivedAt: ContinuousClock.Instant
}

// Cancellation handlers run off-actor; serialize cancellation with decoder scheduling.
final class ReconnectCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func runIfActive(_ action: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        action()
        return true
    }
}

@MainActor
protocol ReconnectAttemptSession: AnyObject {
    var attemptID: UUID { get }

    // These methods must be nonblocking. stop() must be idempotent and fence all
    // delayed startup/callback work, including work which ignores cancellation.
    func start() throws
    func latestFrame() -> ReconnectFrameEvidence?
    var failure: Error? { get }
    func stop()
}

extension ReconnectAttemptSession {
    var failure: Error? { nil }
}

@MainActor
private final class ReconnectDrainTracker {
    static let shared = ReconnectDrainTracker()
    private var tasks: [UUID: Task<Void, Error>] = [:]
    private var failed = false

    func track(_ task: Task<Void, Error>) {
        let id = UUID()
        tasks[id] = task
        Task {
            let result = await task.result
            finish(id, result: result)
        }
    }

    func markUncertain() {
        failed = true
    }

    func wait() async throws {
        while !tasks.isEmpty {
            let current = tasks
            for (id, task) in current {
                let result = await task.result
                finish(id, result: result)
            }
        }
        if failed { throw DrainFailure() }
    }

    private func finish(_ id: UUID, result: Result<Void, Error>) {
        guard tasks.removeValue(forKey: id) != nil else { return }
        if case .failure = result { failed = true }
    }

    private struct DrainFailure: Error {}
}

@MainActor
final class NetworkReconnectSession: ReconnectAttemptSession {
    let attemptID: UUID
    let session: CameraSession
    private let register: @MainActor () async throws -> String
    private let startDecoder: @MainActor (CameraSession, String) -> Void
    private let cancellation: ReconnectCancellationFlag
    private var registration: Task<Void, Never>?
    private var stopped = false
    private var drainTracker: ReconnectDrainTracker?
    private(set) var failure: Error?

    init(attemptID: UUID, register: @escaping @MainActor () async throws -> String,
         startDecoder: @escaping @MainActor (CameraSession, String) -> Void,
         cancellation: ReconnectCancellationFlag = ReconnectCancellationFlag()) {
        self.attemptID = attemptID
        self.session = CameraSession(attemptID: attemptID)
        self.register = register
        self.startDecoder = startDecoder
        self.cancellation = cancellation
    }

    fileprivate func attachDrainTracker(_ tracker: ReconnectDrainTracker) -> Bool {
        guard !stopped, registration == nil, drainTracker == nil else { return false }
        drainTracker = tracker
        return true
    }

    func start() throws {
        guard !stopped, registration == nil else { throw CancellationError() }
        registration = Task {
            do {
                guard !stopped, !Task.isCancelled, !cancellation.isCancelled() else { return }
                let url = try await register()
                guard !stopped, !Task.isCancelled else { return }
                cancellation.runIfActive { startDecoder(session, url) }
            } catch {
                if !stopped, !Task.isCancelled { failure = error }
            }
        }
    }

    func latestFrame() -> ReconnectFrameEvidence? {
        let frame = session.snapshot()
        return frame.pixel == nil ? nil : frame.reconnectEvidence
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        registration?.cancel()
        session.stop()
        let pendingRegistration = registration
        let pendingSession = session
        let task = Task { @MainActor in
            await pendingRegistration?.value
            try await pendingSession.stopAndWait()
        }
        drainTracker?.track(task)
        ReconnectDrainTracker.shared.track(task)
    }
}

@MainActor
final class CameraReconnectAttempt {
    enum Failure: Error, Equatable {
        case invalidTimeout
        case invalidSession
        case timedOut
        case superseded
    }

    struct Verified {
        let attemptID: UUID
        let session: any ReconnectAttemptSession
        let frame: ReconnectFrameEvidence
    }

    private struct Active {
        let id: UUID
        let session: any ReconnectAttemptSession
    }

    private var active: Active?
    private let drainTracker = ReconnectDrainTracker()
    private let clock = ContinuousClock()
    private let pollInterval: Duration = .milliseconds(20)
    private let maxFrameAge: Duration = .seconds(2)
    private let maxTimeout: Duration = .seconds(30)

    /// Call after fencing all new reconnects and joining their owning tasks.
    static func waitForStoppedSessions() async throws {
        try await ReconnectDrainTracker.shared.wait()
    }

    /// Call after fencing and joining this instance's reconnect producers.
    func waitForStoppedSessions() async throws {
        try await drainTracker.wait()
    }

    // The factory must be nonblocking, return an unstarted distinct session,
    // and clean up its own resources if it throws. The caller must take
    // ownership of a verified session and stop it on later lifecycle changes.
    // No tile is installed or modified here.
    func run(timeout: Duration, makeSession: (UUID) throws -> any ReconnectAttemptSession) async throws -> Verified {
        guard timeout > .zero, timeout <= maxTimeout else { throw Failure.invalidTimeout }
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: timeout)
        let session = try makeSession(id)
        active = Active(id: id, session: session)
        var transferred = false
        defer {
            if active?.id == id { active = nil }
            if !transferred { session.stop() }
        }
        if let network = session as? NetworkReconnectSession,
           !network.attachDrainTracker(drainTracker) {
            drainTracker.markUncertain()
            throw Failure.invalidSession
        }
        guard session.attemptID == id else { throw Failure.invalidSession }
        try Task.checkCancellation()
        guard clock.now < deadline else { throw Failure.timedOut }
        try session.start()
        while true {
            try Task.checkCancellation()
            guard active?.id == id else { throw Failure.superseded }
            if let failure = session.failure { throw failure }
            let now = clock.now
            guard now < deadline else { throw Failure.timedOut }
            if let frame = session.latestFrame(),
               frame.attemptID == id, frame.sequence > 0,
               frame.receivedAt >= startedAt, frame.receivedAt <= now,
               frame.receivedAt.duration(to: now) <= maxFrameAge {
                try Task.checkCancellation()
                guard active?.id == id else { throw Failure.superseded }
                guard clock.now < deadline else { throw Failure.timedOut }
                transferred = true
                return Verified(attemptID: id, session: session, frame: frame)
            }
            try await clock.sleep(until: min(deadline, now.advanced(by: pollInterval)))
        }
    }

    // Wall stop, camera removal, expansion switches, and replacement attempts
    // must all call this before mutating the corresponding stream.
    func cancel() {
        let previous = active
        active = nil
        previous?.session.stop()
    }
}
