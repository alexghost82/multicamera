import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraBookmarkRefreshTests: XCTestCase {
    func testBookmarkRefreshSavesAndRejectsChangedCameraOrDisk() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", enabled: false,
                            fileURL: root.appendingPathComponent("old.mov"), fileBookmarkData: Data([1]))
        var memory = WallConfiguration()
        memory.cameras = [camera]
        try ConfigurationStore.save(memory, to: url)
        let writer = ACTACameraBookmarkRefresh()
        let newURL = root.appendingPathComponent("new.mov")
        try writer.persist(camera: camera, resolvedURL: newURL, bookmarkData: Data([2]),
                           configURL: url, readMemory: { memory }, installMemory: { memory = $0 })
        XCTAssertEqual(memory.cameras[0].fileURL, newURL)
        XCTAssertEqual(memory.cameras[0].fileBookmarkData, Data([2]))
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertThrowsError(try writer.persist(camera: camera, resolvedURL: newURL,
            bookmarkData: Data([3]), configURL: url, readMemory: { memory }, installMemory: { memory = $0 }))
        var external = memory
        external.columns = 8
        try ConfigurationStore.save(external, to: url)
        XCTAssertThrowsError(try writer.persist(camera: memory.cameras[0], resolvedURL: newURL,
            bookmarkData: Data([4]), configURL: url, readMemory: { memory }, installMemory: { memory = $0 }))
        XCTAssertEqual(try ConfigurationStore.load(from: url), external)
    }

    func testActiveRuntimeBlocksBookmarkWriteAndRetryWorksAfterRelease() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", enabled: false,
                            fileURL: root.appendingPathComponent("old.mov"))
        var memory = WallConfiguration()
        memory.cameras = [camera]
        try ConfigurationStore.save(memory, to: url)
        let writer = ACTACameraBookmarkRefresh()
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try writer.persist(camera: camera, resolvedURL: root.appendingPathComponent("new.mov"),
            bookmarkData: Data([1]), configURL: url, readMemory: { memory }, installMemory: { memory = $0 }))
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        lease = nil
        try writer.persist(camera: camera, resolvedURL: root.appendingPathComponent("new.mov"),
            bookmarkData: Data([1]), configURL: url, readMemory: { memory }, installMemory: { memory = $0 })
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testUnknownFieldsRemainUntouched() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", enabled: false,
                            fileURL: root.appendingPathComponent("old.mov"))
        var memory = WallConfiguration()
        memory.cameras = [camera]
        try ConfigurationStore.save(memory, to: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["futureField"] = "keep"
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        try bytes.write(to: url)
        let writer = ACTACameraBookmarkRefresh()
        XCTAssertThrowsError(try writer.persist(camera: camera, resolvedURL: root.appendingPathComponent("new.mov"),
            bookmarkData: Data([1]), configURL: url, readMemory: { memory }, installMemory: { memory = $0 }))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(memory.cameras[0], camera)
    }

    func testOtherProcessRuntimeBlocksRefresh() throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_BOOKMARK_LEASE_DRIVER"] else {
            throw XCTSkip("Set CAMERA_BOOKMARK_LEASE_DRIVER to the synthetic lease driver.")
        }
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", enabled: false,
                            fileURL: root.appendingPathComponent("old.mov"))
        var memory = WallConfiguration()
        memory.cameras = [camera]
        try ConfigurationStore.save(memory, to: url)
        let process = Process()
        let input = Pipe()
        let ready = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.path]
        process.standardInput = input
        process.standardOutput = ready
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 1), Data([1]))
        let writer = ACTACameraBookmarkRefresh()
        XCTAssertThrowsError(try writer.persist(camera: camera, resolvedURL: root.appendingPathComponent("new.mov"),
            bookmarkData: Data([1]), configURL: url, readMemory: { memory }, installMemory: { memory = $0 }))
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testReentrantRefreshIsRejectedDuringMemoryPublication() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", enabled: false,
                            fileURL: root.appendingPathComponent("old.mov"))
        var memory = WallConfiguration()
        memory.cameras = [camera]
        try ConfigurationStore.save(memory, to: url)
        let writer = ACTACameraBookmarkRefresh()
        let newURL = root.appendingPathComponent("new.mov")
        try writer.persist(camera: camera, resolvedURL: newURL, bookmarkData: Data([2]),
                           configURL: url, readMemory: { memory }, installMemory: { value in
            do {
                try writer.persist(camera: camera, resolvedURL: newURL, bookmarkData: Data([3]),
                    configURL: url, readMemory: { memory }, installMemory: { memory = $0 })
                XCTFail("Reentrant write must be rejected")
            } catch {}
            memory = value
        })
        XCTAssertEqual(memory.cameras[0].fileBookmarkData, Data([2]))
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testSharedGateRejectsPreferenceWriterDuringBookmarkPublication() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", enabled: false,
                            fileURL: root.appendingPathComponent("old.mov"))
        var memory = WallConfiguration()
        memory.cameras = [camera]
        try ConfigurationStore.save(memory, to: url)
        let gate = ACTACameraWriterGate()
        let bookmarks = ACTACameraBookmarkRefresh(gate: gate)
        let preferences = ACTAGUICameraPreferenceWriter(gate: gate)
        try bookmarks.persist(camera: camera, resolvedURL: root.appendingPathComponent("new.mov"),
                              bookmarkData: Data([2]), configURL: url, readMemory: { memory },
                              installMemory: { value in
            do {
                try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
                    $0.cameras[0].yoloEnabled = true
                }
                XCTFail("Reentrant preference write must be rejected")
            } catch ACTACameraWriterGate.GateError.busy {
            } catch {
                XCTFail("Expected shared gate to reject reentry, got \(error)")
            }
            memory = value
        })
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    private func fixtureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".bookmark-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
