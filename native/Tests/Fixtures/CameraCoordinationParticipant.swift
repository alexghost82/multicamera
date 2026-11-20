import CameraCore
import Darwin
import Foundation
@testable import CameraWall

@main
struct CameraCoordinationParticipant {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            switch CommandLine.arguments[2] {
            case "worker":
                let worker = ACTAWorkerCameraRuntime()
                _ = try worker.open(url)
                withExtendedLifetime(worker) {}
            case "discovery":
                let configuration = try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration
                let lease = try ACTACameraDiscoveryLeaseScope.acquire(for: url, expected: configuration)
                withExtendedLifetime(lease) {}
            default:
                exit(64)
            }
        } catch {
            exit(2)
        }
    }
}
