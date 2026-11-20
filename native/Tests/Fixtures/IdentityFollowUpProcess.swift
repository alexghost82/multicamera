import CameraCore
import Foundation

@main
struct IdentityFollowUpProcess {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 || (args.count == 4 && args[3] == "leave-pending") else { throw Failure.invalid }
        let path = URL(fileURLWithPath: args[1]).standardizedFileURL
        let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".identity-follow-up-fixtures", isDirectory: true).standardizedFileURL
        guard path.path.hasPrefix(fixtureRoot.path + "/"), path.lastPathComponent == "tracking.sqlite" else {
            throw Failure.invalid
        }
        let store = try LocalTrackingStore(url: path)
        let flags = try store.makeACTAIdentityFollowUpStore()
        guard let before = try flags.capture(identityID: args[2]),
              let changed = try flags.commit(expected: before, flagged: !before.flagged) else { throw Failure.invalid }
        if args.count == 4 { return }
        guard try flags.finish(changed),
              let restored = try flags.commit(expected: changed, flagged: before.flagged),
              try flags.finish(restored) else { throw Failure.invalid }
    }

    enum Failure: Error { case invalid }
}
