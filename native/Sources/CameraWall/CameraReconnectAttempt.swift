import Foundation

// An adapter must create a distinct session for each attempt. A frame's attempt ID
// and timestamp must be recorded at the actual decoder/capture publication point,
// never assigned later while reading a shared tile or cached frame.
struct ReconnectFrameEvidence {
    let attemptID: UUID
    let sequence: UInt64
    let receivedAt: ContinuousClock.Instant
}

@MainActor
protocol ReconnectAttemptSession: AnyObject {
    var attemptID: UUID { get }

    // These methods must be nonblocking. stop() must be idempotent and fence all
    // delayed startup/callback work, including work which ignores cancellation.
    func start() throws
    func latestFrame() -> ReconnectFrameEvidence?
    func stop()
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
    private let clock = ContinuousClock()
    private let pollInterval: Duration = .milliseconds(20)
    private let maxFrameAge: Duration = .seconds(2)
    private let maxTimeout: Duration = .seconds(30)

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
        guard session.attemptID == id else { throw Failure.invalidSession }
        try Task.checkCancellation()
        guard clock.now < deadline else { throw Failure.timedOut }
        try session.start()
        while true {
            try Task.checkCancellation()
            guard active?.id == id else { throw Failure.superseded }
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
