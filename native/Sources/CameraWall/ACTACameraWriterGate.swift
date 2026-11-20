import Foundation

/// A process-local, synchronous gate for coordinating configuration writers.
/// It does not lock files or coordinate another process. A caller must route
/// every relevant read and write through this instance before relying on it.
@MainActor
final class ACTACameraWriterGate {
    final class Revision: Sendable {
        fileprivate init() {}
    }

    enum GateError: LocalizedError {
        case busy
        case stale
        case reconciliationRequired

        var errorDescription: String? {
            switch self {
            case .busy: return "A camera configuration operation is already in progress."
            case .stale: return "Camera configuration changed; reload it and retry."
            case .reconciliationRequired: return "Camera configuration requires reconciliation before further changes."
            }
        }
    }

    private var revision = Revision()
    private var active = false
    private var reconciliationRequired = false

    func requireReconciliation() {
        precondition(active)
        reconciliationRequired = true
    }

    func clearReconciliationRequirement() {
        precondition(active)
        reconciliationRequired = false
    }

    /// Reads are prohibited during a write, including synchronous observers
    /// invoked before @Published has installed its new value.
    func capture<T>(_ read: () throws -> T) throws -> (revision: Revision, value: T) {
        guard !active else { throw GateError.busy }
        guard !reconciliationRequired else { throw GateError.reconciliationRequired }
        let captured = revision
        let value = try read()
        guard !active, captured === revision else { throw GateError.stale }
        return (captured, value)
    }

    /// A failed body still invalidates previous observations: it may have
    /// changed memory, disk, or another effect before throwing.
    func write<T>(_ body: () throws -> T) throws -> T {
        try write(expected: nil, allowReconciliation: false, body)
    }

    func writeIfCurrent<T>(_ expected: Revision, _ body: () throws -> T) throws -> T {
        try write(expected: expected, allowReconciliation: false, body)
    }

    func writeForReconciliation<T>(_ body: () throws -> T) throws -> T {
        try write(expected: nil, allowReconciliation: true, body)
    }

    private func write<T>(expected: Revision?, allowReconciliation: Bool, _ body: () throws -> T) throws -> T {
        guard !active else { throw GateError.busy }
        guard allowReconciliation || !reconciliationRequired else { throw GateError.reconciliationRequired }
        if let expected, expected !== revision { throw GateError.stale }
        active = true
        revision = Revision()
        defer {
            revision = Revision()
            active = false
        }
        return try body()
    }
}
