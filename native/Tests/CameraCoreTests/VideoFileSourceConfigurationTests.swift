import Foundation
import XCTest
@testable import CameraCore

final class VideoFileSourceConfigurationTests: XCTestCase {
    func testFileSourceRoundTripsWithoutChangingNetworkDefaults() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/camera-wall-sample.mov")
        let camera = Camera(name: "Recorded entrance", substream: "", fileURL: fileURL)
        try camera.validate()

        let decoded = try JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(camera))

        XCTAssertEqual(decoded, camera)
        XCTAssertEqual(decoded.fileURL, fileURL)
        XCTAssertNil(decoded.fileBookmarkData)
        XCTAssertEqual(decoded.source(expanded: false), fileURL.absoluteString)
        XCTAssertNil(Camera(name: "Network", substream: "rtsp://camera.local/live").fileURL)
    }

    func testSecurityScopedBookmarkResolvesSelectedLocalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("sample.mov")
        try Data([0, 1, 2, 3]).write(to: fileURL)

        let bookmark = try VideoFileBookmark.create(for: fileURL)
        let resolution = try VideoFileBookmark.resolve(bookmark, fallbackURL: fileURL)
        let camera = Camera(
            name: "Recorded entrance", substream: "", fileURL: resolution.url,
            fileBookmarkData: resolution.bookmarkData
        )
        let decoded = try JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(camera))

        XCTAssertEqual(resolution.url.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(decoded.fileBookmarkData, resolution.bookmarkData)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolution.url.path))
    }

    func testFileSourceCannotMixWithOtherInputKindsOrISAPI() {
        let fileURL = URL(fileURLWithPath: "/tmp/camera-wall-sample.mov")

        XCTAssertThrowsError(try Camera(
            name: "Mixed network",
            substream: "rtsp://camera.local/live",
            fileURL: fileURL
        ).validate())
        XCTAssertThrowsError(try Camera(
            name: "Mixed local device",
            substream: "",
            localDeviceID: "device-1",
            fileURL: fileURL
        ).validate())
        XCTAssertThrowsError(try Camera(
            name: "File with ISAPI",
            substream: "",
            fileURL: fileURL,
            isapiEventsEnabled: true
        ).validate())
        XCTAssertThrowsError(try Camera(
            name: "Remote file URL",
            substream: "",
            fileURL: URL(string: "https://example.invalid/video.mov")
        ).validate())
    }
}