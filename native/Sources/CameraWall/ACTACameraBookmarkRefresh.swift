import CameraCore
import Foundation

/// Coordinates the automatic bookmark writer. Other camera writers and the
/// GUI runtime must also participate before this provides full coordination.
@MainActor
final class ACTACameraBookmarkRefresh {
    private let gate: ACTACameraWriterGate
    private var reconciliationRequired = false

    init(gate: ACTACameraWriterGate? = nil) {
        self.gate = gate ?? ACTACameraWriterGate()
    }

    func persist(camera: Camera, resolvedURL: URL, bookmarkData: Data?, configURL: URL,
                 readMemory: () -> WallConfiguration,
                 installMemory: (WallConfiguration) -> Void) throws {
        try gate.write {
            guard !reconciliationRequired else { throw Failure.reconciliationRequired }
            try CoordinatedCameraConfigurationStore.withWriterLease(for: configURL) { lease in
                let expected = try CoordinatedCameraConfigurationStore.snapshot(from: configURL)
                let current = readMemory()
                guard current == expected.configuration,
                      let index = current.cameras.firstIndex(where: { $0.id == camera.id }),
                      current.cameras[index] == camera else { throw Failure.stale }
                var next = current
                next.cameras[index].fileURL = resolvedURL.standardizedFileURL
                next.cameras[index].fileBookmarkData = bookmarkData
                guard next != current else { return }
                do {
                    guard let saved = try CoordinatedCameraConfigurationStore.compareAndSave(
                        next, expected: expected, to: configURL, using: lease) else { throw Failure.stale }
                    installMemory(saved.configuration)
                    guard readMemory() == saved.configuration,
                          try CoordinatedCameraConfigurationStore.snapshot(from: configURL).matches(saved) else {
                        throw Failure.reconciliationRequired
                    }
                } catch Failure.stale {
                    throw Failure.stale
                } catch {
                    reconciliationRequired = true
                    throw error
                }
            }
        }
    }

    enum Failure: LocalizedError {
        case stale, reconciliationRequired
        var errorDescription: String? {
            switch self {
            case .stale: return "Camera configuration changed; reload it before refreshing the video bookmark."
            case .reconciliationRequired: return "The video bookmark could not be reconciled; restart the application."
            }
        }
    }
}
