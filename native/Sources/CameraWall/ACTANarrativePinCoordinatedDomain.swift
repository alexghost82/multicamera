import CameraCore
import Foundation

/// Adapter boundary for a revisioned SQLite implementation. The revision is
/// global to the complete chapter list and changes on every chapter write,
/// including deletion/recreation, no-op writes and writes in other processes.
/// Commit must compare and write in one transaction.
@MainActor
protocol ACTANarrativePinAtomicStore: Sendable {
    func capture(chapterID: UUID) throws -> ACTANarrativePinObservation?
    func commit(chapterID: UUID, expected: ACTANarrativePinObservation,
                pinned: Bool) throws -> ACTANarrativePinObservation?
}

@MainActor
final class ACTANarrativePinProductionStore: ACTANarrativePinAtomicStore {
    private let store: ACTANarrativePinSQLiteStore

    init(trackingStore: LocalTrackingStore) throws {
        store = try trackingStore.makeACTANarrativePinStore()
    }

    init(store: ACTANarrativePinSQLiteStore) {
        self.store = store
    }

    func capture(chapterID: UUID) throws -> ACTANarrativePinObservation? {
        try store.capture(chapterID: chapterID).map(Self.convert)
    }

    func commit(chapterID: UUID, expected: ACTANarrativePinObservation,
                pinned: Bool) throws -> ACTANarrativePinObservation? {
        guard chapterID == expected.chapterID, expected.revision.sequence == 0 else { return nil }
        let snapshot = ACTANarrativePinSQLiteSnapshot(
            chapterID: chapterID, revision: expected.revision.generation,
            pinned: expected.pinned, operatorMarked: expected.operatorMarked,
            preservedFields: expected.preservedFields)
        return try store.commit(expected: snapshot, pinned: pinned).map(Self.convert)
    }

    private static func convert(_ value: ACTANarrativePinSQLiteSnapshot) -> ACTANarrativePinObservation {
        ACTANarrativePinObservation(chapterID: value.chapterID,
            revision: .init(generation: value.revision, sequence: 0), pinned: value.pinned,
            operatorMarked: value.operatorMarked, preservedFields: value.preservedFields)
    }
}

/// The refresh must install a freshly read complete chapter-list snapshot without
/// reentrant will-set overwrites. It must not write to the store. A failed
/// refresh or a concurrent write leaves this domain unavailable until repaired.
@MainActor
final class ACTANarrativePinCoordinatedDomain: ACTANarrativePinReviewDomain {
    private let store: any ACTANarrativePinAtomicStore
    private let refresh: @MainActor () throws -> Void
    private let isReady: @MainActor () -> Bool
    private let onUnavailable: @MainActor () -> Void
    private var needsReconciliation = false
    private(set) var reconciliationChapterID: UUID?
    private var operationInProgress = false
    var canStart: Bool { !needsReconciliation && !operationInProgress && isReady() }

    init(store: any ACTANarrativePinAtomicStore, isReady: @escaping @MainActor () -> Bool = { true },
         onUnavailable: @escaping @MainActor () -> Void = {},
         refresh: @escaping @MainActor () throws -> Void) {
        self.store = store
        self.isReady = isReady
        self.onUnavailable = onUnavailable
        self.refresh = refresh
    }

    func capture(chapterID: UUID) throws -> ACTANarrativePinObservation? {
        guard !needsReconciliation, !operationInProgress, isReady() else { throw CoordinationError.unavailable }
        operationInProgress = true
        defer { operationInProgress = false }
        do { return try store.capture(chapterID: chapterID) }
        catch { onUnavailable(); throw CoordinationError.unavailable }
    }

    func commit(chapterID: UUID, expected: ACTANarrativePinObservation,
                pinned: Bool) throws -> ACTANarrativePinObservation? {
        guard !needsReconciliation, !operationInProgress, isReady(), expected.chapterID == chapterID,
              !pinned || expected.operatorMarked else { throw CoordinationError.unavailable }
        operationInProgress = true
        defer { operationInProgress = false }
        let result: ACTANarrativePinObservation?
        do {
            result = try store.commit(chapterID: chapterID, expected: expected, pinned: pinned)
        } catch {
            needsReconciliation = true
            reconciliationChapterID = chapterID
            onUnavailable()
            throw CoordinationError.unknownOutcome
        }
        guard let result else { return nil }
        needsReconciliation = true
        reconciliationChapterID = chapterID
        do {
            guard result.chapterID == chapterID, result.revision != expected.revision,
                  result.pinned == pinned, result.operatorMarked == expected.operatorMarked,
                  result.preservedFields == expected.preservedFields else {
                throw CoordinationError.unavailable
            }
            try refresh()
            guard try store.capture(chapterID: chapterID) == result else {
                throw CoordinationError.unavailable
            }
        } catch {
            onUnavailable()
            throw CoordinationError.unknownOutcome
        }
        needsReconciliation = false
        reconciliationChapterID = nil
        return result
    }

    /// Call only after the actual store and presentation have been repaired.
    /// A stable global revision across refresh is required; deletion of the
    /// specified chapter fails closed rather than fabricating a baseline.
    func reconcile(chapterID: UUID) throws {
        guard !operationInProgress, needsReconciliation,
              reconciliationChapterID == chapterID else { throw CoordinationError.unavailable }
        operationInProgress = true
        needsReconciliation = true
        defer { operationInProgress = false }
        do {
            guard let before = try store.capture(chapterID: chapterID) else { throw CoordinationError.unavailable }
            try refresh()
            guard try store.capture(chapterID: chapterID) == before else { throw CoordinationError.unavailable }
        } catch { onUnavailable(); throw CoordinationError.unavailable }
        needsReconciliation = false
        reconciliationChapterID = nil
    }

    private enum CoordinationError: Error {
        case unavailable
        case unknownOutcome
    }
}
