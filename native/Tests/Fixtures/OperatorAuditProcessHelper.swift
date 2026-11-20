import Foundation
import CameraCore
import Darwin

@main
struct OperatorAuditProcessHelper {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let count = Int(arguments[3]) else { exit(2) }
        if arguments[2] == "hold-lock" {
            let url = URL(fileURLWithPath: arguments[1])
            let path = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock").path
            let fd = open(path, O_CREAT | O_RDWR, mode_t(0o600))
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { exit(5) }
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { exit(3) }
            close(fd)
            return
        }
        let audit = OperatorAuditLog(url: URL(fileURLWithPath: arguments[1]))
        try FileHandle.standardOutput.write(contentsOf: Data([1]))
        guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { exit(3) }
        for index in 0..<count {
            audit.record(action: .settingsUpdated, summary: "\(arguments[2])-\(index)")
            var attempts = 0
            while audit.lastPersistenceError != nil && attempts < 1000 {
                Thread.sleep(forTimeInterval: 0.01)
                audit.record(action: .settingsUpdated, summary: "\(arguments[2])-retry-\(index)-\(attempts)")
                attempts += 1
            }
            guard audit.lastPersistenceError == nil else { exit(4) }
        }
    }
}
