import CameraCore
import Foundation

/// Owns the exact bytes associated with the last verified in-memory snapshot.
/// Callers must serialize all access with their model on the main actor.
@MainActor
final class ACTAISAPIHistoryBaseline {
    private let read: () throws -> Data
    private let save: ([ISAPIEventRecord], Date) throws -> Void
    private(set) var bytes: Data?
    private(set) var events: [ISAPIEventRecord]?

    init(url: URL) {
        read = { try Data(contentsOf: url) }
        save = { try ISAPIEventStore.save($0, to: url, now: $1) }
    }

    init(read: @escaping () throws -> Data,
         save: @escaping ([ISAPIEventRecord], Date) throws -> Void) {
        self.read = read
        self.save = save
    }

    /// Reads without pruning or writing the existing file. Missing history fails closed.
    func load(now: Date) throws -> [ISAPIEventRecord] {
        invalidate()
        let data: Data
        do { data = try read() }
        catch { throw ACTAClearISAPIEventsError.unavailable }
        let decoded: [ISAPIEventRecord]
        do { decoded = try JSONDecoder().decode([ISAPIEventRecord].self, from: data) }
        catch { throw ACTAClearISAPIEventsError.invalidData }
        do {
            guard try read() == data else { throw ACTAClearISAPIEventsError.changed }
        } catch let error as ACTAClearISAPIEventsError {
            throw error
        } catch {
            throw ACTAClearISAPIEventsError.unavailable
        }
        let retained = ISAPIEventStore.retainedRecords(decoded, now: now)
        bytes = data
        events = retained
        return retained
    }

    /// Persist before changing the model; a failed write or readback invalidates the baseline.
    func save(_ newEvents: [ISAPIEventRecord], replacing current: [ISAPIEventRecord],
              now: Date) throws -> [ISAPIEventRecord] {
        guard let baseline = bytes, let expected = events else {
            throw ACTAClearISAPIEventsError.unavailable
        }
        guard current == expected else {
            invalidate()
            throw ACTAClearISAPIEventsError.changed
        }
        do {
            guard try read() == baseline, try read() == baseline else {
                throw ACTAClearISAPIEventsError.changed
            }
        } catch let error as ACTAClearISAPIEventsError {
            invalidate()
            throw error
        } catch {
            invalidate()
            throw ACTAClearISAPIEventsError.unavailable
        }

        let retained = ISAPIEventStore.retainedRecords(newEvents, now: now)
        do {
            try save(newEvents, now)
            let actualBytes = try read()
            let actual = try JSONDecoder().decode([ISAPIEventRecord].self, from: actualBytes)
            guard actual == retained else { throw ACTAClearISAPIEventsError.partialFailure }
            bytes = actualBytes
            events = retained
            return retained
        } catch {
            invalidate()
            throw ACTAClearISAPIEventsError.partialFailure
        }
    }

    /// Called only after the clear service has verified the written file.
    func acceptVerifiedClear(_ data: Data) throws {
        do {
            guard try read() == data,
                  try JSONDecoder().decode([ISAPIEventRecord].self, from: data).isEmpty else {
                throw ACTAClearISAPIEventsError.partialFailure
            }
            bytes = data
            events = []
        } catch {
            invalidate()
            throw ACTAClearISAPIEventsError.partialFailure
        }
    }

    func invalidate() {
        bytes = nil
        events = nil
    }
}
