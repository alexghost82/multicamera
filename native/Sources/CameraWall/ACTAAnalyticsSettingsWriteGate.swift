import Foundation

/// Serializes synchronous settings writes made through one engine. The revision
/// invalidates reviews even when a write fails after an unknown partial effect.
/// It does not coordinate other engines, processes, or direct file writers.
@MainActor
final class ACTAAnalyticsSettingsWriteGate {
    enum Error: LocalizedError {
        case writeInProgress, staleRevision
        var errorDescription: String? {
            switch self {
            case .writeInProgress: return "An analytics settings update is already in progress."
            case .staleRevision: return "Analytics settings changed after review."
            }
        }
    }

    private(set) var revision = UUID()
    private var writing = false

    func captureRevision() throws -> UUID {
        guard !writing else { throw Error.writeInProgress }
        return revision
    }

    func perform<T>(expectedRevision: UUID? = nil, _ operation: () throws -> T) throws -> T {
        guard !writing else { throw Error.writeInProgress }
        if let expectedRevision, expectedRevision != revision { throw Error.staleRevision }
        writing = true
        revision = UUID()
        defer { writing = false }
        return try operation()
    }
}
