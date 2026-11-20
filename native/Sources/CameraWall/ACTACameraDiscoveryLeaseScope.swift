import CameraCore
import Foundation

/// One discovery operation owns its relay until all discovery resources exit.
@MainActor
final class ACTACameraDiscoveryLeaseScope {
    private static var retainedAfterUncertainDrain: [CoordinatedCameraConfigurationStore.RuntimeLease] = []
    private let lease: CoordinatedCameraConfigurationStore.RuntimeLease
    private let stop: @MainActor () -> Void
    private let drain: @MainActor () async throws -> Void
    private var started = false
    private var stopped = false

    static func acquire(for url: URL, expected: WallConfiguration,
                        initializeMissing: Bool = false) throws -> CoordinatedCameraConfigurationStore.RuntimeLease {
        let lease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        if snapshot.isMissing, snapshot.revision != nil {
            throw ConfigurationError.invalid("Camera configuration is missing after an earlier write; reconcile it before discovery.")
        }
        if initializeMissing, snapshot.isMissing {
            var initial = WallConfiguration()
            initial.go2rtcPath = expected.go2rtcPath
            guard initial == expected,
                  try CoordinatedCameraConfigurationStore.initializeMissingForDiscovery(
                    initial, expected: snapshot, to: url, using: lease) != nil else {
                throw ConfigurationError.invalid("Camera configuration changed; reload it before discovery.")
            }
        } else if snapshot.configuration != expected {
            throw ConfigurationError.invalid("Camera configuration changed; reload it before discovery.")
        }
        return lease
    }

    init(lease: CoordinatedCameraConfigurationStore.RuntimeLease,
         stop: @escaping @MainActor () -> Void,
         drain: @escaping @MainActor () async throws -> Void) {
        self.lease = lease
        self.stop = stop
        self.drain = drain
    }

    func run<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        guard !started else { throw CancellationError() }
        started = true
        let result: Result<T, Error> = await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        } onCancel: {
            Task { @MainActor in self.requestStop() }
        }
        requestStop()
        do {
            try await drain()
        } catch {
            Self.retainedAfterUncertainDrain.append(lease)
            throw error
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private func requestStop() {
        guard !stopped else { return }
        stopped = true
        stop()
    }
}
