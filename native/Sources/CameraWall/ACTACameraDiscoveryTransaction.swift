import CameraCore
import Foundation

/// Commits discovery only after its runtime lease is released and a writer
/// lease has been acquired against the same snapshot.
@MainActor
enum ACTACameraDiscoveryTransaction {
    static func run<T>(url: URL, configuration: WallConfiguration, revision: UUID,
                       readConfiguration: () -> WallConfiguration, readRevision: () -> UUID,
                       discover: (CoordinatedCameraConfigurationStore.RuntimeLease) async throws -> T,
                       commit: (T, CoordinatedCameraConfigurationStore.WriterLease,
                                CoordinatedCameraConfigurationStore.Snapshot) throws -> Void) async throws {
        try Task.checkCancellation()
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try ACTACameraDiscoveryLeaseScope.acquire(for: url, expected: configuration,
                                                       initializeMissing: true)
        let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        guard try snapshot.isSemanticallyRoundTrippable() else {
            throw ConfigurationError.invalid("Camera configuration is not safely round-trippable; discovery was not started.")
        }
        let result = try await discover(lease!)
        try Task.checkCancellation()
        guard readRevision() == revision, readConfiguration() == configuration,
              try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(snapshot) else {
            throw ConfigurationError.invalid("Camera configuration changed during discovery; review it and retry.")
        }
        lease = nil
        do {
            try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { writer in
                try Task.checkCancellation()
                guard readRevision() == revision, readConfiguration() == configuration,
                      try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(snapshot) else {
                    throw ConfigurationError.invalid("Camera configuration changed during discovery; review it and retry.")
                }
                try commit(result, writer, snapshot)
            }
        } catch let error as POSIXError where error.code == .EAGAIN {
            throw ConfigurationError.invalid("Camera configuration is in use by another process; retry after it stops.")
        }
    }
}
