import Foundation

/// Coordinates registered WallModel producers; it is not a full camera-runtime drain.
@MainActor
final class CameraNetworkLifecycle {
    private var work = CameraRuntimeWorkGroup()
    private var revision = UUID()
    private var drain: Task<Void, Error>?
    private var fenced = false
    private var joined = false
    private var drainedRevision: UUID?

    func begin() -> CameraRuntimeWorkGroup.Ticket? {
        work.begin()
    }

    func fence() {
        revision = UUID()
        fenced = true
        joined = false
        drainedRevision = nil
        work.fence()
    }

    func join(_ cleanup: @escaping @MainActor () async throws -> Void) {
        precondition(fenced)
        revision = UUID()
        joined = true
        drainedRevision = nil
        let expected = revision
        let previous = drain
        let fencedWork = work
        drain = Task { [weak self] in
            try await previous?.value
            await fencedWork.wait()
            try await cleanup()
            if let self, self.fenced, self.joined, self.revision == expected {
                self.drainedRevision = expected
            }
        }
    }

    func prepareStart() async throws {
        let expected = revision
        guard fenced, joined, let drain else { throw Failure.unjoined }
        try await drain.value
        try Task.checkCancellation()
        guard fenced, joined, revision == expected, drainedRevision == expected else { throw CancellationError() }
        revision = UUID()
        fenced = false
        joined = false
        drainedRevision = nil
        work = CameraRuntimeWorkGroup()
        self.drain = nil
    }

    func stoppedRevision() -> UUID { revision }

    @discardableResult
    func afterStop(_ expected: UUID, onFailure: @escaping @MainActor (Error) -> Void,
                   perform action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.waitForStop(expected)
                action()
            } catch {
                if self.fenced, self.joined, self.revision == expected {
                    onFailure(error)
                }
            }
        }
    }

    func waitForStop(_ expected: UUID) async throws {
        guard fenced, joined, revision == expected, let drain else { throw Failure.unjoined }
        try await drain.value
        try Task.checkCancellation()
        guard fenced, joined, revision == expected, drainedRevision == expected else { throw CancellationError() }
    }

    func checkStopped(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard fenced, joined, revision == expected, drainedRevision == expected else { throw CancellationError() }
    }

    private enum Failure: Error { case unjoined }
}
