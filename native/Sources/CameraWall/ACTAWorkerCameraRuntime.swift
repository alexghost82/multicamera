import CameraCore
import Foundation

/// Retain through process exit; shutdown requests do not prove that async
/// startup, decoder work, or relay children have terminated.
@MainActor
final class ACTAWorkerCameraRuntime {
    private var lease: CoordinatedCameraConfigurationStore.RuntimeLease?
    private var stopped = false

    func open(_ url: URL) throws -> WallConfiguration {
        try checkActive()
        guard lease == nil else { throw Failure.alreadyOpened }
        let acquired = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        lease = acquired
        return try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration
    }

    func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
    }

    func activeLease() throws -> CoordinatedCameraConfigurationStore.RuntimeLease {
        try checkActive()
        guard let lease else { throw Failure.alreadyOpened }
        return lease
    }

    func stop() { stopped = true }

    private enum Failure: Error { case alreadyOpened }
}
