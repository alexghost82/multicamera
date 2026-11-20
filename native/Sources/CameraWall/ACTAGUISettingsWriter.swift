import CameraCore
import Foundation

/// Serializes configuration writes with participating writers and runtimes.
@MainActor
final class ACTAGUISettingsWriter {
    private let gate: ACTACameraWriterGate

    init(gate: ACTACameraWriterGate) {
        self.gate = gate
    }

    func save(_ draft: WallConfiguration, includingPorts: Bool, to url: URL,
              readMemory: () -> WallConfiguration,
              installMemory: (WallConfiguration) throws -> Void,
              afterCommit: (WallConfiguration, WallConfiguration) throws -> Void) throws {
        try commit(to: url, readMemory: readMemory, installMemory: installMemory,
                   afterCommit: afterCommit) { current in
            var next = try current.applyingSettings(from: draft)
            if includingPorts {
                next.apiPort = draft.apiPort
                next.rtspPort = draft.rtspPort
            }
            return next
        }
    }

    func replaceConfiguration(_ replacement: WallConfiguration, to url: URL,
                              using writerLease: CoordinatedCameraConfigurationStore.WriterLease? = nil,
                              expectedSnapshot: CoordinatedCameraConfigurationStore.Snapshot? = nil,
                              readMemory: () -> WallConfiguration,
                              installMemory: (WallConfiguration) throws -> Void,
                              afterCommit: (WallConfiguration, WallConfiguration) throws -> Void) throws {
        try commit(to: url, using: writerLease, expectedSnapshot: expectedSnapshot,
                   readMemory: readMemory, installMemory: installMemory,
                   afterCommit: afterCommit) { _ in replacement }
    }

    private func commit(to url: URL, using writerLease: CoordinatedCameraConfigurationStore.WriterLease? = nil,
                        expectedSnapshot: CoordinatedCameraConfigurationStore.Snapshot? = nil,
                        readMemory: () -> WallConfiguration,
                        installMemory: (WallConfiguration) throws -> Void,
                        afterCommit: (WallConfiguration, WallConfiguration) throws -> Void,
                        prepare: (WallConfiguration) throws -> WallConfiguration) throws {
        do {
            try gate.write {
                @MainActor func write(_ lease: CoordinatedCameraConfigurationStore.WriterLease) throws {
                    let expected = try CoordinatedCameraConfigurationStore.snapshot(from: url)
                    if let expectedSnapshot, !expected.matches(expectedSnapshot) { throw Failure.stale }
                    let current = readMemory()
                    var initial = WallConfiguration()
                    initial.go2rtcPath = current.go2rtcPath
                    guard current == expected.configuration || (expected.isMissing && current == initial) else {
                        throw Failure.stale
                    }
                    guard try expected.isSemanticallyRoundTrippable() else {
                        throw ConfigurationError.invalid("Camera configuration contains fields this version cannot safely preserve.")
                    }
                    let next = try prepare(current)
                    try next.validate()
                    guard readMemory() == current else { throw Failure.stale }
                    let saved: CoordinatedCameraConfigurationStore.Snapshot
                    do {
                        guard let result = try CoordinatedCameraConfigurationStore.compareAndSave(
                            next, expected: expected, to: url, using: lease) else { throw Failure.stale }
                        saved = result
                    } catch Failure.stale {
                        throw Failure.stale
                    } catch {
                        self.gate.requireReconciliation()
                        throw Failure.reconciliationRequired
                    }
                    do {
                        try installMemory(saved.configuration)
                        guard readMemory() == saved.configuration,
                              try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(saved) else {
                            throw Failure.reconciliationRequired
                        }
                        try afterCommit(current, saved.configuration)
                        guard readMemory() == saved.configuration,
                              try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(saved) else {
                            throw Failure.reconciliationRequired
                        }
                    } catch {
                        self.gate.requireReconciliation()
                        throw Failure.reconciliationRequired
                    }
                }
                if let writerLease {
                    try write(writerLease)
                } else {
                    try CoordinatedCameraConfigurationStore.withWriterLease(for: url, write)
                }
            }
        } catch let error as POSIXError where error.code == .EAGAIN {
            throw ConfigurationError.invalid("Camera configuration is in use by another process; retry after it stops.")
        }
    }

    enum Failure: LocalizedError {
        case stale, reconciliationRequired

        var errorDescription: String? {
            switch self {
            case .stale: return "Camera configuration changed; reload it before saving."
            case .reconciliationRequired: return "Camera configuration could not be reconciled; restart before making further changes."
            }
        }
    }
}
