import CameraCore
import Foundation

/// The source compares GUI and store snapshots; it does not coordinate external writers.
struct ACTAOperationsWatchReadProvider: ACTAWatchListReadProvider {
    enum RuleState {
        case unavailable
        case failed
        case loaded([OperationsWatchRule])
    }

    struct Snapshot {
        let enabled: Bool
        let gui: RuleState
        let store: RuleState
        let checkedAt: Date
    }

    private let snapshot: (@MainActor @Sendable () throws -> Snapshot)?

    init(snapshot: (@MainActor @Sendable () throws -> Snapshot)? = nil) {
        self.snapshot = snapshot
    }

    @MainActor
    init(model: WallModel) {
        snapshot = { [weak model] in
            guard let model, model.featurePreferences.enabledFeatures.contains(.operationalAlerts),
                  FileManager.default.fileExists(atPath: model.operationsWatchURL.path) else {
                throw ACTAWatchListReadError.unavailable
            }
            let checkedAt = Date()
            let stored = try OperationsWatchStore.load(from: model.operationsWatchURL, at: checkedAt)
            return Snapshot(enabled: true, gui: .loaded(model.operationsWatchRules),
                            store: .loaded(stored), checkedAt: checkedAt)
        }
    }

    func activeWatchMetadata() async throws -> [ACTAWatchMetadata] {
        try Task.checkCancellation()
        guard let snapshot else { throw ACTAWatchListReadError.unavailable }
        let result = try await Self.read(snapshot)
        try Task.checkCancellation()
        return result
    }

    @MainActor
    private static func read(_ source: @MainActor @Sendable () throws -> Snapshot) throws -> [ACTAWatchMetadata] {
        let snapshot = try source()
        guard snapshot.enabled else { throw ACTAWatchListReadError.unavailable }
        let gui = try loaded(snapshot.gui)
        let store = try loaded(snapshot.store)
        guard snapshot.checkedAt.timeIntervalSince1970.isFinite,
              valid(gui), valid(store),
              Dictionary(uniqueKeysWithValues: gui.map { ($0.id, $0) })
                == Dictionary(uniqueKeysWithValues: store.map { ($0.id, $0) }) else {
            throw ReadError.inconsistent
        }
        return store.filter { $0.isActive(at: snapshot.checkedAt) }.map {
            ACTAWatchMetadata(cameraScope: $0.cameraIDs.isEmpty ? .all : .selected,
                              expiration: $0.expiresAt == nil ? .indefinite : .timed)
        }
    }

    private static func loaded(_ state: RuleState) throws -> [OperationsWatchRule] {
        switch state {
        case .unavailable: throw ACTAWatchListReadError.unavailable
        case .failed: throw ReadError.failed
        case .loaded(let rules): return rules
        }
    }

    private static func valid(_ rules: [OperationsWatchRule]) -> Bool {
        rules.count <= OperationsWatchRule.maximumRules
            && Set(rules.map(\.id)).count == rules.count
            && rules.allSatisfy {
                $0.terms == OperationsWatchMatcher.terms($0.text)
                    && $0.firedTrackIDs.count <= 64
                    && Set($0.firedTrackIDs).count == $0.firedTrackIDs.count
                    && $0.createdAt.timeIntervalSince1970.isFinite
                    && ($0.expiresAt.map {
                        $0.timeIntervalSince1970.isFinite
                    } ?? true)
            }
    }

    private enum ReadError: Error { case failed, inconsistent }
}
