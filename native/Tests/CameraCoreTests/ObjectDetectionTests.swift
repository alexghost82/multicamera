import XCTest
import CoreGraphics
@testable import CameraCore

final class ObjectDetectionTests: XCTestCase {
    func testLetterboxedVideoBounds() {
        XCTAssertEqual(DetectionGeometry.videoRect(image: CGSize(width: 1920, height: 1080),
            viewport: CGSize(width: 400, height: 400)), CGRect(x: 0, y: 87.5, width: 400, height: 225))
    }

    func testVisionBottomLeftCoordinatesBecomeDisplayTopLeft() {
        let rect = DetectionGeometry.displayRect(box: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
            image: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 400, height: 400))
        XCTAssertEqual(rect, CGRect(x: 100, y: 143.75, width: 200, height: 56.25))
    }

    func testBoxesAreClippedAndEmptyVideoIsSafe() {
        XCTAssertEqual(DetectionGeometry.displayRect(box: CGRect(x: -0.5, y: -0.5, width: 2, height: 2),
            image: CGSize(width: 100, height: 100), viewport: CGSize(width: 100, height: 100)),
            CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(DetectionGeometry.videoRect(image: .zero, viewport: CGSize(width: 100, height: 100)), .zero)
    }
}