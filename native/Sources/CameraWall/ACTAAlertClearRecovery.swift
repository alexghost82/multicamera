import Foundation
import Darwin
import CameraCore

/// Complete, non-mutating snapshots are required; missing or unreadable sources must throw
/// rather than be represented as empty. Clip images include metadata and all frame bytes.
struct ACTAAlertClearSnapshot {
    let alerts: [VLMAlert]
    let reviews: [UUID: OperationsAlertReview]
    let acknowledgements: [UUID: Date]
    let audit: [OperationsAlertReview]
    let clips: [UUID: Data]
}

struct ACTAAlertClearPlan {
    let affectedAlerts: [VLMAlert]
    let affectedReviews: [OperationsAlertReview]
    let affectedAcknowledgements: [UUID: Date]
    let affectedAudit: [OperationsAlertReview]
    let referencedClipIDs: Set<UUID>
    let missingClipIDs: Set<UUID>
    let changes: [ACTAAlertClearRecovery.Change]

    private struct Acknowledgement: Codable {
        let id: UUID
        let date: Date
    }

    private struct ReviewImage: Codable {
        let reviews: [OperationsAlertReview]
        let acknowledgements: [Acknowledgement]
        let audit: [OperationsAlertReview]
    }

    private struct Clip: Codable {
        let id: UUID
        let image: Data
    }

    static func make(snapshot: ACTAAlertClearSnapshot) throws -> ACTAAlertClearPlan {
        guard !snapshot.alerts.isEmpty,
              Set(snapshot.alerts.map(\.id)).count == snapshot.alerts.count,
              snapshot.reviews.allSatisfy({ $0.key == $0.value.alertID }) else {
            throw ACTAAlertClearRecoveryError.invalidPlan
        }
        let clipIDs = Set(snapshot.alerts.compactMap(\.clipID))
        let reviews = snapshot.reviews.values.sorted { $0.alertID.uuidString < $1.alertID.uuidString }
        let acknowledgements = snapshot.acknowledgements.map { Acknowledgement(id: $0.key, date: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let clips = snapshot.clips.map { Clip(id: $0.key, image: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeReviews = ReviewImage(reviews: reviews, acknowledgements: acknowledgements, audit: snapshot.audit)
        let afterReviews = ReviewImage(reviews: [], acknowledgements: [], audit: [])
        return try ACTAAlertClearPlan(
            affectedAlerts: snapshot.alerts,
            affectedReviews: reviews,
            affectedAcknowledgements: snapshot.acknowledgements,
            affectedAudit: snapshot.audit,
            referencedClipIDs: clipIDs,
            missingClipIDs: clipIDs.subtracting(snapshot.clips.keys),
            changes: [
                .init(store: "alerts", before: encoder.encode(snapshot.alerts), after: encoder.encode([VLMAlert]())),
                .init(store: "clips", before: encoder.encode(clips),
                      after: encoder.encode(clips.filter { !clipIDs.contains($0.id) })),
                .init(store: "reviews", before: encoder.encode(beforeReviews), after: encoder.encode(afterReviews))
            ])
    }
}

/// A store adapter must hold an exclusive lease covering all participating writers,
/// and each replacement must atomically compare the complete current image and replace it.
/// Images must include every affected record, including orphaned audit rows and clip bytes.
@MainActor
protocol ACTAAlertClearRecoveryStores {
    func withExclusiveLease<T>(_ body: () throws -> T) throws -> T
    func readImage(store: String) throws -> Data
    func replaceImage(store: String, matching: Data, with: Data) throws -> Bool
}

enum ACTAAlertClearRecoveryError: Error {
    case invalidPlan
    case pendingRecovery
    case conflict
    case verificationFailed
}

struct ACTAAlertClearRecoveryFailure: LocalizedError {
    let initialError: any Error
    let recoveryError: any Error

    var errorDescription: String? {
        "Alert clear failed: \(initialError.localizedDescription). "
            + "Recovery failed: \(recoveryError.localizedDescription). The recovery journal requires attention."
    }
}

/// Foundation only: no production store adapter or agent action is registered.
/// The journal contains sensitive store images and must live in a private directory.
/// Power-loss durability is not established by this process-crash recovery mechanism.
@MainActor
final class ACTAAlertClearRecovery {
    struct Change: Codable, Equatable {
        let store: String
        let before: Data
        let after: Data
    }

    private struct Journal: Codable {
        let version: Int
        let changes: [Change]
    }

    private let journalURL: URL
    private let stores: any ACTAAlertClearRecoveryStores

    init(journalURL: URL, stores: any ACTAAlertClearRecoveryStores) {
        self.journalURL = journalURL
        self.stores = stores
    }

    /// The caller must display and confirm the exact before/after images before calling.
    func execute(confirmed changes: [Change]) throws {
        try validate(changes)
        try stores.withExclusiveLease {
            guard !FileManager.default.fileExists(atPath: journalURL.path) else {
                throw ACTAAlertClearRecoveryError.pendingRecovery
            }
            for change in changes {
                guard try stores.readImage(store: change.store) == change.before else {
                    throw ACTAAlertClearRecoveryError.conflict
                }
            }
            try createJournal(Journal(version: 1, changes: changes))
            do {
                for change in changes where change.before != change.after {
                    guard try stores.replaceImage(store: change.store, matching: change.before, with: change.after) else {
                        throw ACTAAlertClearRecoveryError.conflict
                    }
                }
                for change in changes {
                    guard try stores.readImage(store: change.store) == change.after else {
                        throw ACTAAlertClearRecoveryError.verificationFailed
                    }
                }
            } catch let initialError {
                do {
                    try recoverLocked()
                } catch let recoveryError {
                    throw ACTAAlertClearRecoveryFailure(initialError: initialError, recoveryError: recoveryError)
                }
                throw initialError
            }
            try FileManager.default.removeItem(at: journalURL)
        }
    }

    func recover() throws {
        try stores.withExclusiveLease { try recoverLocked() }
    }

    private func recoverLocked() throws {
        let data = try Data(contentsOf: journalURL)
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.version == 1 else { throw ACTAAlertClearRecoveryError.invalidPlan }
        try validate(journal.changes)
        // Check every store before restoring any, so a conflict does not trigger a partial rollback.
        for change in journal.changes {
            let current = try stores.readImage(store: change.store)
            guard current == change.before || current == change.after else {
                throw ACTAAlertClearRecoveryError.conflict
            }
        }
        for change in journal.changes.reversed() where change.before != change.after {
            let current = try stores.readImage(store: change.store)
            if current == change.after {
                guard try stores.replaceImage(store: change.store, matching: change.after, with: change.before) else {
                    throw ACTAAlertClearRecoveryError.conflict
                }
            } else if current != change.before {
                throw ACTAAlertClearRecoveryError.conflict
            }
        }
        for change in journal.changes {
            guard try stores.readImage(store: change.store) == change.before else {
                throw ACTAAlertClearRecoveryError.verificationFailed
            }
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func validate(_ changes: [Change]) throws {
        guard !changes.isEmpty, changes.allSatisfy({ !$0.store.isEmpty }),
              Set(changes.map(\.store)).count == changes.count else {
            throw ACTAAlertClearRecoveryError.invalidPlan
        }
    }

    private func createJournal(_ journal: Journal) throws {
        let data = try JSONEncoder().encode(journal)
        let descriptor = open(journalURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ACTAAlertClearRecoveryError.pendingRecovery }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        // A failed or interrupted journal creation remains as a fail-closed marker.
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
