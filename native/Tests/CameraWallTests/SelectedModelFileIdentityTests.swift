import Darwin
import Foundation
import XCTest
@testable import CameraWall

final class SelectedModelFileIdentityTests: XCTestCase {
    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".model-identity-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("fixture.onnx")
        try Data("fixture".utf8).write(to: model)
        try body(directory, model)
    }

    func testUnchangedFileIsReadFromVerifiedDescriptor() throws {
        try withFixture { _, model in
            let identity = try SelectedModelFileIdentity.capture(url: model, maximumBytes: 32)
            let content = try identity.withVerifiedFile { descriptor in
                var bytes = [UInt8](repeating: 0, count: 32)
                let count = read(descriptor, &bytes, bytes.count)
                XCTAssertGreaterThanOrEqual(count, 0)
                return Data(bytes.prefix(max(count, 0)))
            }
            XCTAssertEqual(content, Data("fixture".utf8))
        }
    }

    func testReplacementAndDeletionRejectBeforeCallback() throws {
        try withFixture { directory, model in
            let identity = try SelectedModelFileIdentity.capture(url: model, maximumBytes: 32)
            try FileManager.default.moveItem(at: model, to: directory.appendingPathComponent("original"))
            try Data("fixture".utf8).write(to: model)
            var called = false
            XCTAssertThrowsError(try identity.withVerifiedFile { _ in called = true })
            XCTAssertFalse(called)
            try FileManager.default.removeItem(at: model)
            XCTAssertThrowsError(try identity.withVerifiedFile { _ in called = true })
            XCTAssertFalse(called)
        }
    }

    func testInPlaceChangeAndChangeDuringUseAreRejected() throws {
        try withFixture { _, model in
            let identity = try SelectedModelFileIdentity.capture(url: model, maximumBytes: 32)
            try Data("changed".utf8).write(to: model)
            var called = false
            XCTAssertThrowsError(try identity.withVerifiedFile { _ in called = true })
            XCTAssertFalse(called)

            let updated = try SelectedModelFileIdentity.capture(url: model, maximumBytes: 32)
            XCTAssertThrowsError(try updated.withVerifiedFile { _ in
                try Data("mutated".utf8).write(to: model)
            })
        }
    }

    func testPathReplacementDuringUseIsDetected() throws {
        try withFixture { directory, model in
            let identity = try SelectedModelFileIdentity.capture(url: model, maximumBytes: 32)
            XCTAssertThrowsError(try identity.withVerifiedFile { descriptor in
                try FileManager.default.moveItem(at: model, to: directory.appendingPathComponent("original"))
                try Data("fixture".utf8).write(to: model)
                var bytes = [UInt8](repeating: 0, count: 7)
                XCTAssertEqual(read(descriptor, &bytes, bytes.count), 7)
                XCTAssertEqual(Data(bytes), Data("fixture".utf8))
            })
        }
    }

    func testSymlinksDirectoriesAndOversizedFilesAreRejected() throws {
        try withFixture { directory, model in
            let link = directory.appendingPathComponent("link.onnx")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model)
            XCTAssertThrowsError(try SelectedModelFileIdentity.capture(url: link, maximumBytes: 32))
            XCTAssertThrowsError(try SelectedModelFileIdentity.capture(url: directory, maximumBytes: 32))
            XCTAssertThrowsError(try SelectedModelFileIdentity.capture(url: model, maximumBytes: 6))
            XCTAssertThrowsError(try SelectedModelFileIdentity.capture(url: model, maximumBytes: -1))

            let identity = try SelectedModelFileIdentity.capture(url: model, maximumBytes: 32)
            let original = directory.appendingPathComponent("original")
            try FileManager.default.moveItem(at: model, to: original)
            try FileManager.default.createSymbolicLink(at: model, withDestinationURL: original)
            var called = false
            XCTAssertThrowsError(try identity.withVerifiedFile { _ in called = true })
            XCTAssertFalse(called)
        }
    }
}
