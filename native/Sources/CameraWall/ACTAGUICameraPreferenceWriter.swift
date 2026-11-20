import CameraCore
import Foundation

/// Coordinates these preference writes only. Other GUI writers and runtimes
/// must join the same protocol before the whole camera domain is coordinated.
@MainActor
final class ACTAGUICameraPreferenceWriter {
    private let gate: ACTACameraWriterGate
    private var reconciliationRequired = false

    init(gate: ACTACameraWriterGate? = nil) {
        self.gate = gate ?? ACTACameraWriterGate()
    }

    @discardableResult
    func update(url: URL, readMemory: () -> WallConfiguration,
                installMemory: (WallConfiguration) throws -> Void,
                runtimeLease: CoordinatedCameraConfigurationStore.RuntimeLease? = nil,
                change: (inout WallConfiguration) throws -> Void) throws -> Bool {
        try gate.write {
            @MainActor func perform(_ save: (WallConfiguration, CoordinatedCameraConfigurationStore.Snapshot) throws
                         -> CoordinatedCameraConfigurationStore.Snapshot?) throws -> Bool {
                let expected = try CoordinatedCameraConfigurationStore.snapshot(from: url)
                let current = readMemory()
                guard current == expected.configuration else {
                    throw reconciliationRequired ? Failure.reconciliationRequired : Failure.stale
                }
                reconciliationRequired = false
                var next = current
                try change(&next)
                guard readMemory() == current else { throw Failure.stale }
                guard next != current else { return false }
                try next.validate()
                let saved: CoordinatedCameraConfigurationStore.Snapshot
                do {
                    guard let result = try save(next, expected) else { throw Failure.stale }
                    saved = result
                } catch Failure.stale {
                    throw Failure.stale
                } catch {
                    reconciliationRequired = true
                    throw error
                }
                do {
                    try installMemory(saved.configuration)
                    guard readMemory() == saved.configuration,
                          try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(saved) else {
                        throw Failure.reconciliationRequired
                    }
                    return true
                } catch {
                    reconciliationRequired = true
                    throw error
                }
            }
            if let runtimeLease {
                return try perform { next, expected in
                    try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                        next, expected: expected, to: url, using: runtimeLease)
                }
            }
            return try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { lease in
                try perform { next, expected in
                    try CoordinatedCameraConfigurationStore.compareAndSave(
                        next, expected: expected, to: url, using: lease)
                }
            }
        }
    }

    enum Failure: LocalizedError {
        case stale, reconciliationRequired

        var errorDescription: String? {
            switch self {
            case .stale:
                return "Camera configuration changed; restart the application to reload it before changing preferences."
            case .reconciliationRequired:
                return "Camera preferences could not be reconciled; reconcile the configuration or restart before retrying."
            }
        }
    }
}
