import Darwin
import Foundation

/// An exclusively created workspace-local directory owned by one test.
final class IsolatedStoreTestDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".core-store-test-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(url.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}
