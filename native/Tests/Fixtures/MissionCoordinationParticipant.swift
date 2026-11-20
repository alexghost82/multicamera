import CameraCore
import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
let url = URL(fileURLWithPath: arguments[2])

func waitForRelease() {
    print("ready")
    fflush(stdout)
    var byte: UInt8 = 0
    _ = read(STDIN_FILENO, &byte, 1)
}

do {
    switch arguments[1] {
    case "camera":
        let current = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var next = current.configuration
        next.columns = next.columns == 4 ? 5 : 4
        guard try CoordinatedCameraConfigurationStore.compareAndSave(next, expected: current, to: url) != nil else {
            exit(8)
        }
    case "feature":
        var preferences = try CameraFeaturePreferencesStore.load(from: url)
        preferences.enabledFeatures.remove(.scheduledMissions)
        try CameraFeaturePreferencesStore.save(preferences, to: url)
    case "hold-camera":
        try CoordinatedCameraConfigurationStore.withLockedSnapshot(from: url) { _ in waitForRelease() }
    case "hold-feature":
        try CameraFeaturePreferencesStore.withLockedSnapshot(from: url) { _ in waitForRelease() }
    default:
        exit(64)
    }
    exit(0)
} catch CameraFeaturePreferencesStoreError.busy {
    exit(7)
} catch let error as POSIXError where error.code == .EWOULDBLOCK || error.code == .EAGAIN {
    exit(7)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
