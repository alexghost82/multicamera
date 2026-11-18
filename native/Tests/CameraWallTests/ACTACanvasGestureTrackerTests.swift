import AppKit
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasGestureTrackerTests: XCTestCase {
    func testGripRemovalCancelsActiveGestureOnce() throws {
        let tracker = ACTACanvasGestureTracker()
        let grip = MouseGripView()
        grip.edges = .right
        var token: UUID?
        var cancellations = 0
        grip.begin = { token = tracker.begin() }
        grip.end = { cancelled in
            XCTAssertTrue(cancelled)
            cancellations += 1
            if let token { tracker.end(token) }
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        grip.mouseDown(with: event)
        XCTAssertTrue(tracker.hasActiveGestures)
        grip.viewWillMove(toWindow: nil)
        grip.cancelOperation(nil)
        XCTAssertFalse(tracker.hasActiveGestures)
        XCTAssertEqual(cancellations, 1)
    }
}
