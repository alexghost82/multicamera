import CameraCore
import Darwin
import Foundation
import XCTest
@testable import CameraWall

final class ACTACanvasLayoutStoreTests: XCTestCase {
    private func testURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build")
            .appendingPathComponent("canvas-layout-test-\(UUID().uuidString).json")
    }

    private func removeTestFiles(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
    }

    func testCooperatingStoresRejectStaleSnapshotsAndDetectABA() throws {
        let url = testURL()
        defer { removeTestFiles(url) }
        let first = ACTACanvasLayoutStore(url: url)
        let second = ACTACanvasLayoutStore(url: url)
        let initial = try first.read()
        let camera = UUID().uuidString
        var changed = initial.layout
        changed.frames[camera] = VideoTileFrame(x: 0, y: 0, width: 200, height: 100)
        let saved = try second.commit(changed, expected: initial)
        XCTAssertEqual(try first.read(), saved)
        XCTAssertThrowsError(try first.commit(initial.layout, expected: initial)) {
            guard case ACTACanvasLayoutStore.Failure.conflict = $0 else { return XCTFail("\($0)") }
        }
        let restored = try second.commit(initial.layout, expected: saved)
        XCTAssertNotEqual(restored, initial)
        XCTAssertThrowsError(try first.commit(changed, expected: initial))
        XCTAssertEqual(try VideoWallLayout.load(from: url), initial.layout)
    }

    func testBusyLockAndInvalidFileFailWithoutOverwriting() throws {
        let url = testURL()
        defer { removeTestFiles(url) }
        let store = ACTACanvasLayoutStore(url: url)
        let snapshot = try store.read()
        let lock = open(url.appendingPathExtension("lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.commit(snapshot.layout, expected: snapshot)) {
            guard case ACTACanvasLayoutStore.Failure.busy = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        let invalid = Data("not json".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try store.commit(snapshot.layout, expected: snapshot))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testLegacyLayoutLoadsAndInvalidFrameDoesNotWrite() throws {
        let url = testURL()
        defer { removeTestFiles(url) }
        let legacy = VideoWallLayout()
        try legacy.save(to: url)
        let store = ACTACanvasLayoutStore(url: url)
        let snapshot = try store.read()
        XCTAssertEqual(snapshot.layout, legacy)
        let original = try Data(contentsOf: url)
        var invalid = legacy
        invalid.frames[UUID().uuidString] = VideoTileFrame(x: -1, y: 0, width: 120, height: 90)
        XCTAssertThrowsError(try store.commit(invalid, expected: snapshot))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOtherProcessHoldingLockMakesWritesFailClosed() throws {
        let url = testURL()
        defer { removeTestFiles(url) }
        let store = ACTACanvasLayoutStore(url: url)
        let snapshot = try store.read()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-B", "-c",
            "import fcntl,sys; f=open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); print('ready', flush=True); sys.stdin.read(1)",
            url.appendingPathExtension("lock").path]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readData(ofLength: 6), as: UTF8.self), "ready\n")
        XCTAssertThrowsError(try store.commit(snapshot.layout, expected: snapshot)) {
            guard case ACTACanvasLayoutStore.Failure.busy = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try? Data(contentsOf: url), nil)
    }
}
