import CameraCore
import Darwin
import Foundation

@main
struct NarrativeCASProcess {
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let id = UUID(uuidString: CommandLine.arguments[3]) else { fatalError("invalid fixture") }
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        switch CommandLine.arguments[1] {
        case "aba":
            let store = try LocalTrackingStore(url: url)
            try store.setACTANarrativePinned(chapterID: id.uuidString, pinned: true)
            try store.setACTANarrativePinned(chapterID: id.uuidString, pinned: false)
        case "hold":
            let lock = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).narrative-revision")
            let fd = open(lock.path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { fatalError("lock failed") }
            defer { flock(fd, LOCK_UN); close(fd) }
            FileHandle.standardOutput.write(Data([1]))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { fatalError("no release") }
        case "race":
            let tracking = try LocalTrackingStore(url: url)
            let store = try tracking.makeACTANarrativePinStore()
            guard let before = try store.capture(chapterID: id) else { fatalError("missing fixture") }
            FileHandle.standardOutput.write(Data([1]))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { fatalError("no release") }
            let result = try store.commit(expected: before, pinned: true)
            FileHandle.standardOutput.write(Data([result == nil ? 0 : 1]))
        default: fatalError("invalid fixture command")
        }
    }
}
