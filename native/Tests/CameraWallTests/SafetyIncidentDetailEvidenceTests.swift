import Foundation
import XCTest
@testable import CameraCore
@testable import CameraWall

final class SafetyIncidentDetailEvidenceTests: XCTestCase {
    func testSnapshotErrorIsReportedWithoutDiscardingReadableClipFrames() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".snapshot-view-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let bundle = root.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("snapshot.jpg"),
                                                withIntermediateDirectories: false)
        let frame = Data([1, 2, 3])
        try frame.write(to: bundle.appendingPathComponent("pre-01.jpg"))
        let store = SafetyEvidenceStore(baseDirectoryURL: root)

        let result = SafetyIncidentEvidenceFrames.load(store: store, incidentID: id)
        XCTAssertNotNil(result.snapshotError)
        XCTAssertNil(result.clipError)
        XCTAssertEqual(result.frames, [frame])
    }

    func testClipErrorIsReportedWithoutDiscardingReadableSnapshot() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".snapshot-view-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let bundle = root.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let snapshot = Data([4, 5])
        try snapshot.write(to: bundle.appendingPathComponent("snapshot.jpg"))
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("post-01.jpg"),
                                                withIntermediateDirectories: false)
        let result = SafetyIncidentEvidenceFrames.load(store: SafetyEvidenceStore(baseDirectoryURL: root), incidentID: id)
        XCTAssertNil(result.snapshotError)
        XCTAssertNotNil(result.clipError)
        XCTAssertEqual(result.frames, [snapshot])
    }

    func testSnapshotAndClipErrorsAreBothReported() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".snapshot-view-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let bundle = root.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("snapshot.jpg"),
                                                withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("pre-01.jpg"),
                                                withIntermediateDirectories: false)
        let result = SafetyIncidentEvidenceFrames.load(store: SafetyEvidenceStore(baseDirectoryURL: root), incidentID: id)
        XCTAssertNotNil(result.snapshotError)
        XCTAssertNotNil(result.clipError)
        XCTAssertTrue(result.frames.isEmpty)
    }

    func testMissingAndReadableSnapshotDoNotReportError() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".snapshot-view-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = SafetyEvidenceStore(baseDirectoryURL: root)
        let missing = SafetyIncidentEvidenceFrames.load(store: store, incidentID: id)
        XCTAssertNil(missing.snapshotError)
        XCTAssertNil(missing.clipError)
        XCTAssertTrue(missing.frames.isEmpty)
        let bundle = root.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let snapshot = Data([4, 5])
        try snapshot.write(to: bundle.appendingPathComponent("snapshot.jpg"))
        let loaded = SafetyIncidentEvidenceFrames.load(store: store, incidentID: id)
        XCTAssertNil(loaded.snapshotError)
        XCTAssertNil(loaded.clipError)
        XCTAssertEqual(loaded.frames, [snapshot])
    }
}
