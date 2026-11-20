import CameraCore
import Combine
import Foundation

/// One published snapshot binds every visible row to the revision it displayed.
@MainActor
final class ACTANarrativePresentationState: @preconcurrency ObservableObject {
    final class Ticket {
        fileprivate let observation: ACTANarrativePinSQLiteSnapshot
        fileprivate init(_ observation: ACTANarrativePinSQLiteSnapshot) { self.observation = observation }
    }

    struct Row: Identifiable {
        let chapter: ACTANarrativeChapterRecord
        fileprivate let ticket: Ticket
        var id: String { chapter.chapterID }
    }

    enum Failure: LocalizedError {
        case unavailable, stale, unknownOutcome, operatorMarkRequired
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Narrative memory is unavailable. Refresh before making changes."
            case .stale: return "The chapter list changed. Refresh and review it again."
            case .unknownOutcome: return "The pin update may have completed. Refresh and verify before retrying."
            case .operatorMarkRequired: return "Pinning an unmarked chapter is unavailable because it would also mark it."
            }
        }
    }

    let objectWillChange = ObservableObjectPublisher()
    private let trackingStore: LocalTrackingStore
    private let pinStore: ACTANarrativePinSQLiteStore
    private var snapshot: [Row] = []
    private var healthy = false
    private var busy = false
    private lazy var domain = ACTANarrativePinCoordinatedDomain(
        store: ACTANarrativePinProductionStore(store: pinStore),
        isReady: { [weak self] in self?.readyForDomain ?? false },
        onUnavailable: { [weak self] in self?.markUnhealthy() },
        refresh: { [weak self] in
            guard let self else { throw Failure.unavailable }
            try self.refresh()
        })

    var rows: [Row] { snapshot }
    var canToggle: Bool { readyForDomain && domain.canStart }
    var reconciliationChapterID: UUID? { domain.reconciliationChapterID }
    private var readyForDomain: Bool { healthy && !busy }

    init(trackingStore: LocalTrackingStore) throws {
        self.trackingStore = trackingStore
        pinStore = try trackingStore.makeACTANarrativePinStore()
    }

    /// Keep this state object alive across broker sessions.
    func makePinAction() -> ACTAPreparedNarrativePinAction {
        ACTAPreparedNarrativePinAction(domain: domain)
    }

    func refresh() throws {
        guard !busy else { throw Failure.unavailable }
        busy = true
        defer { busy = false }
        do { try refreshLocked() }
        catch {
            markUnhealthy()
            throw error
        }
    }

    /// Explicitly reconcile an uncertain agent commit before using the domain again.
    func reconcile(chapterID: UUID) throws {
        try domain.reconcile(chapterID: chapterID)
    }

    func toggle(_ row: Row) throws {
        guard canToggle else { throw Failure.unavailable }
        guard snapshot.contains(where: { $0.ticket === row.ticket }) else { throw Failure.stale }
        guard row.ticket.observation.pinned || row.ticket.observation.operatorMarked else {
            throw Failure.operatorMarkRequired
        }
        busy = true
        defer { busy = false }
        let result: ACTANarrativePinSQLiteSnapshot?
        do {
            result = try pinStore.commit(expected: row.ticket.observation,
                                         pinned: !row.ticket.observation.pinned)
        } catch {
            markUnhealthy()
            throw Failure.unknownOutcome
        }
        guard result != nil else {
            markUnhealthy()
            throw Failure.stale
        }
        do { try refreshLocked() }
        catch {
            markUnhealthy()
            throw Failure.unknownOutcome
        }
    }

    private func markUnhealthy() {
        guard healthy else { return }
        let wasBusy = busy
        busy = true
        objectWillChange.send()
        healthy = false
        busy = wasBusy
    }

    private func refreshLocked() throws {
        let revision = try pinStore.revision()
        let chapters = try trackingStore.loadACTANarrativeChapterRecords(limit: 50, requireValidRows: true)
        var seen = Set<UUID>()
        var rows: [Row] = []
        for chapter in chapters {
            guard let id = UUID(uuidString: chapter.chapterID), seen.insert(id).inserted,
                  let observation = try pinStore.capture(chapterID: id),
                  observation.revision == revision,
                  observation.pinned == chapter.pinned,
                  observation.operatorMarked == chapter.operatorMarked else { throw Failure.stale }
            rows.append(Row(chapter: chapter, ticket: Ticket(observation)))
        }
        guard try pinStore.revision() == revision else { throw Failure.stale }
        objectWillChange.send()
        guard try pinStore.revision() == revision else { throw Failure.stale }
        snapshot = rows
        healthy = true
    }
}
