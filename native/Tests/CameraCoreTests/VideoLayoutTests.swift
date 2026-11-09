import XCTest
@testable import CameraCore

final class VideoLayoutTests: XCTestCase {
    private let frame = VideoTileFrame(x: 100, y: 80, width: 320, height: 200)

    func testConfiguredGridColumnsAreNotCappedAtFourOrFive() {
        for columns in 1...16 {
            XCTAssertEqual(VideoWallLayout.columnCount(configured: columns, cameraCount: 60, expanded: false), columns)
        }
        XCTAssertEqual(VideoWallLayout.columnCount(configured: 10, cameraCount: 3, expanded: false), 3)
        XCTAssertEqual(VideoWallLayout.columnCount(configured: 10, cameraCount: 0, expanded: false), 1)
        XCTAssertEqual(VideoWallLayout.columnCount(configured: 10, cameraCount: 60, expanded: true), 1)
    }

    func testGridTileFramesUseSixteenByNineAspectRatio() {
        let frame = VideoWallLayout.gridTileFrame(index: 5, columns: 4, availableWidth: 1000, gap: 7)
        XCTAssertEqual(frame.width / frame.height, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(frame.x, frame.width + 14, accuracy: 0.0001)
        XCTAssertEqual(frame.y, frame.height + 14, accuracy: 0.0001)
    }

    func testMoveTracksPointerAndClampsTopLeft() {
        XCTAssertEqual(frame.moved(dx: 40, dy: 25), VideoTileFrame(x: 140, y: 105, width: 320, height: 200))
        XCTAssertEqual(frame.moved(dx: -1000, dy: -1000), VideoTileFrame(x: 0, y: 0, width: 320, height: 200))
        XCTAssertEqual(frame.moved(dx: .nan, dy: 0), frame)
    }

    func testAllEdgesAndCornersKeepOppositeEdgeAnchored() {
        for edges: ResizeEdges in [.left, .right, .top, .bottom, [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]] {
            let resized = frame.resized(edges: edges, dx: 25, dy: 30)
            XCTAssertTrue(resized.isValid)
            if edges.contains(.left) { XCTAssertEqual(resized.x + resized.width, frame.x + frame.width) }
            if edges.contains(.right) { XCTAssertEqual(resized.x, frame.x) }
            if edges.contains(.top) { XCTAssertEqual(resized.y + resized.height, frame.y + frame.height) }
            if edges.contains(.bottom) { XCTAssertEqual(resized.y, frame.y) }
        }
        XCTAssertEqual(frame.resized(edges: [.right, .bottom], dx: 100, dy: 50),
                       VideoTileFrame(x: 100, y: 80, width: 420, height: 250))
    }

    func testMinimumSizeAndNonnegativeOrigin() {
        let small = frame.resized(edges: [.left, .top], dx: 10000, dy: 10000)
        XCTAssertEqual(small.width, VideoTileFrame.minimumWidth)
        XCTAssertEqual(small.height, VideoTileFrame.minimumHeight)
        let clipped = frame.resized(edges: [.left, .top], dx: -10000, dy: -10000)
        XCTAssertEqual(clipped.x, 0)
        XCTAssertEqual(clipped.y, 0)
        XCTAssertEqual(clipped.x + clipped.width, frame.x + frame.width)
        XCTAssertEqual(clipped.y + clipped.height, frame.y + frame.height)
    }

    func testLayoutRoundTripAndRejectsInvalidGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout.json")
        var layout = VideoWallLayout()
        let id = UUID().uuidString
        layout.frames[id] = frame
        try layout.save(to: url)
        XCTAssertEqual(try VideoWallLayout.load(from: url), layout)
        layout.frames[id]?.width = -1
        XCTAssertThrowsError(try layout.validate())
        layout.frames[id] = VideoTileFrame(x: .infinity, y: 0, width: 320, height: 200)
        XCTAssertThrowsError(try layout.validate())
    }
}