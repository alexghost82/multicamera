import Foundation
import XCTest
#if !ACTA_STANDALONE
@testable import CameraWall
#endif

final class ACTACreateOnlyExportTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".acta-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testCreateOnlyForAllFormatsAndPrivatePermissions() throws {
        try withDirectory { directory in
            for name in ["report.html", "diagnostics.json", "mission.pdf", "frame.jpg"] {
                let url = directory.appendingPathComponent(name)
                let bytes = Data("synthetic-\(name)".utf8)
                try ACTACreateOnlyExport.publish(bytes, to: url)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
        }
    }

    func testExistingFileAndSymlinkNeverReplaced() throws {
        try withDirectory { directory in
            let existing = directory.appendingPathComponent("existing")
            try Data("original".utf8).write(to: existing)
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
            for url in [existing, link] {
                XCTAssertThrowsError(try ACTACreateOnlyExport.publish(Data("new".utf8), to: url)) {
                    guard case ACTACreateOnlyExport.Failure.collision = $0 else {
                        return XCTFail("Expected collision: \($0)")
                    }
                }
            }
            XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        }
    }

    func testInvalidContentAndSymlinkDirectory() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let alias = directory.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            XCTAssertThrowsError(try ACTACreateOnlyExport.publish(Data(), to: target.appendingPathComponent("empty")))
            XCTAssertThrowsError(try ACTACreateOnlyExport.publish(
                Data(repeating: 0, count: ACTACreateOnlyExport.maximumBytes + 1),
                to: target.appendingPathComponent("large")))
            XCTAssertThrowsError(try ACTACreateOnlyExport.publish(Data("x".utf8), to: alias.appendingPathComponent("x")))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testConcurrentPublishHasExactlyOneWinner() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("race")
            let lock = NSLock()
            var successes = 0
            var collisions = 0
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                do {
                    try ACTACreateOnlyExport.publish(Data("fixture-\(i)".utf8), to: url)
                    lock.lock(); successes += 1; lock.unlock()
                } catch ACTACreateOnlyExport.Failure.collision {
                    lock.lock(); collisions += 1; lock.unlock()
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(successes, 1)
            XCTAssertEqual(collisions, 7)
            XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).hasPrefix("fixture-"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["race"])
        }
    }
}
