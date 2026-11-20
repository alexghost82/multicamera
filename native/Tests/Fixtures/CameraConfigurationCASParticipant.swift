import CameraCore
import Foundation
import Darwin

let url = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let expected = try CoordinatedCameraConfigurationStore.snapshot(from: url)
    var changed = expected.configuration
    changed.columns = 7
    guard let saved = try CoordinatedCameraConfigurationStore.compareAndSave(changed, expected: expected, to: url) else {
        exit(3)
    }
    if CommandLine.arguments.dropFirst(2).first == "aba" {
        guard try CoordinatedCameraConfigurationStore.compareAndSave(
            expected.configuration, expected: saved, to: url) != nil else { exit(3) }
    }
    exit(0)
} catch {
    exit(2)
}
