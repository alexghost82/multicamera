import CameraCore
import Darwin
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let lease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
    if CommandLine.arguments.dropFirst(2).first != "probe" {
        FileHandle.standardOutput.write(Data([1]))
        _ = FileHandle.standardInput.readDataToEndOfFile()
    }
    withExtendedLifetime(lease) {}
} catch {
    exit(2)
}
