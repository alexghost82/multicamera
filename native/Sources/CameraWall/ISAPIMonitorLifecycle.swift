import CameraCore
import Foundation

@MainActor
final class ISAPIMonitorLifecycle {
    typealias StateCallback = @MainActor @Sendable (String) -> Void
    typealias EventCallback = @MainActor @Sendable (ISAPIEventRecord) -> Void

    private struct Entry {
        let cancel: @Sendable () -> Void
        let task: Task<Void, Error>
    }

    private var generation = UUID()
    private var active = false
    private var entries: [UUID: Entry] = [:]

    func activate() -> Bool {
        guard !active, entries.isEmpty else { return false }
        generation = UUID()
        active = true
        return true
    }

    func canStart(cameraID: UUID) -> Bool {
        active && entries[cameraID] == nil
    }

    func start(cameraID: UUID, cancel: @escaping @Sendable () -> Void,
               run: @escaping @Sendable (@escaping StateCallback, @escaping EventCallback) async throws -> Void,
               onState: @escaping StateCallback, onEvent: @escaping EventCallback) -> Bool {
        guard canStart(cameraID: cameraID) else { return false }
        let expected = generation
        let state: StateCallback = { [weak self] value in
            guard let self, self.active, self.generation == expected else { return }
            onState(value)
        }
        let event: EventCallback = { [weak self] value in
            guard let self, self.active, self.generation == expected else { return }
            onEvent(value)
        }
        let task = Task { try await run(state, event) }
        entries[cameraID] = Entry(cancel: cancel, task: task)
        return true
    }

    func fence() {
        active = false
        generation = UUID()
        for entry in entries.values {
            entry.cancel()
            entry.task.cancel()
        }
    }

    func waitForStop() async throws {
        guard !active else { throw Failure.active }
        let expected = generation
        let current = entries
        var firstFailure: Error?
        for entry in current.values {
            if case .failure(let error) = await entry.task.result, firstFailure == nil {
                firstFailure = error
            }
        }
        guard !active, generation == expected else { return }
        if let firstFailure { throw firstFailure }
        entries.removeAll()
    }

    private enum Failure: Error { case active }
}
