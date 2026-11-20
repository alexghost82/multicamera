import CameraCore
import Foundation

private final class CameraUncertainRuntimeLeaseRetainer: @unchecked Sendable {
    static let shared = CameraUncertainRuntimeLeaseRetainer()
    private let lock = NSLock()
    private var leases: [CoordinatedCameraConfigurationStore.RuntimeLease] = []

    func retain(_ lease: CoordinatedCameraConfigurationStore.RuntimeLease) {
        lock.lock()
        leases.append(lease)
        lock.unlock()
    }
}

/// The host must route every configuration and runtime transition through this
/// object. Older processes and non-cooperating writers are not coordinated.
@MainActor
final class ACTACoordinatedCameraDomain: ACTACameraFlagsReviewDomain {
    fileprivate final class ConfigurationRevision {}

    struct Draft {
        fileprivate let revision: ACTACameraWriterGate.Revision
        fileprivate let configurationRevision: ConfigurationRevision
        fileprivate let snapshot: CoordinatedCameraConfigurationStore.Snapshot
        let configuration: WallConfiguration
    }

    private struct Capture {
        let observation: ACTACameraFlagsObservation
        let draft: Draft
    }

    private let url: URL
    private let gate: ACTACameraWriterGate
    private var configurationRevision = ConfigurationRevision()
    private let readMemory: () throws -> WallConfiguration
    private let installMemory: (WallConfiguration) throws -> Void
    private var runtimeLease: CoordinatedCameraConfigurationStore.RuntimeLease?
    private var draining = false
    private var drainAttemptInProgress = false
    private var capture: Capture?
    private var poisoned = false

    init(url: URL, gate: ACTACameraWriterGate? = nil,
         readMemory: @escaping () throws -> WallConfiguration,
         installMemory: @escaping (WallConfiguration) throws -> Void) {
        self.url = url
        self.gate = gate ?? ACTACameraWriterGate()
        self.readMemory = readMemory
        self.installMemory = installMemory
    }

    deinit {
        if let runtimeLease {
            CameraUncertainRuntimeLeaseRetainer.shared.retain(runtimeLease)
        }
    }

    func draft() throws -> Draft {
        let captured = try gate.capture {
            guard !poisoned else { throw Failure.reconciliationRequired }
            let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let memory = try readMemory()
            guard memory == snapshot.configuration else { throw Failure.stale }
            return (snapshot, memory, configurationRevision)
        }
        return Draft(revision: captured.revision, configurationRevision: captured.value.2,
                     snapshot: captured.value.0,
                     configuration: captured.value.1)
    }

    /// Renew a draft invalidated only by runtime transitions, never by a
    /// configuration write or a changed on-disk snapshot (including ABA).
    func refreshAfterRuntime(_ expected: Draft) throws -> Draft {
        let captured = try gate.capture {
            guard !poisoned, configurationRevision === expected.configurationRevision else { throw Failure.stale }
            let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            guard snapshot.matches(expected.snapshot),
                  try readMemory() == expected.configuration else { throw Failure.stale }
            return snapshot
        }
        return Draft(revision: captured.revision, configurationRevision: expected.configurationRevision,
                     snapshot: captured.value, configuration: expected.configuration)
    }

    /// GUI drafts must retain their original Draft, not recapture before saving.
    func save(_ configuration: WallConfiguration, expected: Draft) throws {
        try gate.writeIfCurrent(expected.revision) {
            configurationRevision = ConfigurationRevision()
            try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { lease in
                guard !poisoned, runtimeLease == nil,
                      try readMemory() == expected.configuration else { throw Failure.stale }
                do {
                    guard let saved = try CoordinatedCameraConfigurationStore.compareAndSave(
                        configuration, expected: expected.snapshot, to: url, using: lease) else { throw Failure.stale }
                    try installMemory(saved.configuration)
                    guard try readMemory() == saved.configuration,
                          try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(saved) else {
                        throw Failure.reconciliationRequired
                    }
                } catch Failure.stale {
                    throw Failure.stale
                } catch {
                    poisoned = true
                    gate.requireReconciliation()
                    throw error
                }
            }
        }
    }

    /// Reconcile an external write or a failed publication only while all
    /// cooperating runtimes are stopped. Invalidates every earlier draft.
    func reloadIfStopped() throws {
        try gate.writeForReconciliation {
            configurationRevision = ConfigurationRevision()
            try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {
                let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
                poisoned = true
                gate.requireReconciliation()
                try installMemory(snapshot.configuration)
                guard try readMemory() == snapshot.configuration,
                      try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(snapshot) else {
                    throw Failure.reconciliationRequired
                }
                poisoned = false
                gate.clearReconciliationRequirement()
            }
        }
    }

    /// Acquire before starting any source or configuration-dependent service.
    /// Keep the lease until every such service has fully stopped.
    func beginRuntime() throws {
        try gate.write {
            guard !poisoned, runtimeLease == nil else { throw Failure.stale }
            let lease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            guard try snapshot.isSemanticallyRoundTrippable(),
                  try readMemory() == snapshot.configuration else { throw Failure.stale }
            runtimeLease = lease
        }
    }

    func currentRuntimeLease() throws -> CoordinatedCameraConfigurationStore.RuntimeLease {
        try gate.capture {
            guard !poisoned, !draining, let runtimeLease else { throw Failure.stale }
            return runtimeLease
        }.value
    }

    /// The closure must cancel and join all configuration-dependent work,
    /// including capture callbacks and relay child exit. Failure retains the lease
    /// and keeps runtime access fenced; a later call may retry the drain.
    func endRuntime(afterDraining stopAndDrain: () async throws -> Void) async throws {
        try gate.writeForReconciliation {
            guard runtimeLease != nil, !drainAttemptInProgress else { throw Failure.stale }
            draining = true
            drainAttemptInProgress = true
        }
        do {
            try await stopAndDrain()
            try Task.checkCancellation()
        } catch {
            try gate.writeForReconciliation { drainAttemptInProgress = false }
            throw error
        }
        try gate.writeForReconciliation {
            runtimeLease = nil
            draining = false
            drainAttemptInProgress = false
        }
    }

    func capture(cameraID: UUID) throws -> ACTACameraFlagsObservation? {
        let current = try draft()
        guard let camera = current.configuration.cameras.first(where: { $0.id == cameraID }) else { return nil }
        if let prior = capture, prior.observation.cameraID == cameraID,
           prior.draft.revision === current.revision, prior.draft.snapshot.matches(current.snapshot) {
            return prior.observation
        }
        let observation = ACTACameraFlagsObservation(revision: UUID(), cameraID: cameraID,
            enabled: camera.enabled, yolo: camera.yoloEnabled, aiChat: camera.aiChatEnabled)
        capture = Capture(observation: observation, draft: current)
        return observation
    }

    func commit(expected: ACTACameraFlagsObservation, field: ACTACameraFlag,
                value: Bool) throws -> ACTACameraFlagsObservation? {
        guard let previous = capture, previous.observation == expected,
              let index = previous.draft.configuration.cameras.firstIndex(where: { $0.id == expected.cameraID }) else {
            return nil
        }
        var next = previous.draft.configuration
        switch field {
        case .enabled: next.cameras[index].enabled = value
        case .yolo: next.cameras[index].yoloEnabled = value
        case .aiChat: next.cameras[index].aiChatEnabled = value
        }
        do {
            try save(next, expected: previous.draft)
        } catch ACTACameraWriterGate.GateError.stale {
            return nil
        } catch Failure.stale {
            return nil
        }
        capture = nil
        return try capture(cameraID: expected.cameraID)
    }

    private enum Failure: Error {
        case stale, reconciliationRequired
    }
}
