import XCTest
import AppKit
import AVFoundation
import SwiftUI
import CameraCore
@testable import CameraWall

@MainActor
final class VideoInteractionTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, x: Double, y: Double, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }

    func testNativeMouseDragTracksDeltaAndCommitsOnce() throws {
        let view = MouseGripView()
        var starts = 0
        var delta = NSPoint.zero
        var endings: [Bool] = []
        view.begin = { starts += 1 }
        view.change = { dx, dy in delta = NSPoint(x: dx, y: dy) }
        view.end = { endings.append($0) }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 100, y: 100))
        view.mouseDragged(with: try mouse(.leftMouseDragged, x: 145, y: 70))
        XCTAssertEqual(delta, NSPoint(x: 45, y: 30))
        view.mouseUp(with: try mouse(.leftMouseUp, x: 145, y: 70))
        view.mouseUp(with: try mouse(.leftMouseUp, x: 145, y: 70))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(endings, [false])
    }

    func testEscapeCancelsDragAndIgnoresSubsequentMouseUp() throws {
        let view = MouseGripView()
        var endings: [Bool] = []
        view.end = { endings.append($0) }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 100, y: 100))
        view.cancelOperation(nil)
        view.mouseUp(with: try mouse(.leftMouseUp, x: 100, y: 100))
        XCTAssertEqual(endings, [true])
    }

    func testDoubleClickExpandsWithoutBeginningDrag() throws {
        let view = MouseGripView()
        var expanded = false
        var began = false
        view.begin = { began = true }
        view.doubleClick = { expanded = true }
        view.mouseDown(with: try mouse(.leftMouseDown, x: 100, y: 100, clicks: 2))
        XCTAssertTrue(expanded)
        XCTAssertFalse(began)
    }

    func testKeyboardMoveAndShiftResize() throws {
        let view = MouseGripView()
        var result: (Double, Double, Bool)?
        view.nudge = { result = ($0, $1, $2) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124))
        view.keyDown(with: event)
        XCTAssertEqual(result?.0, 10)
        XCTAssertEqual(result?.1, 0)
        XCTAssertEqual(result?.2, true)
    }

    func testVideoLayerFollowsResizingAndPreservesAspectRatio() {
        let view = VideoSurface(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        view.setFrameSize(NSSize(width: 640, height: 400))
        view.layout()
        XCTAssertEqual(view.display.frame, view.bounds)
        XCTAssertEqual(view.display.videoGravity, .resizeAspect)
    }

    func testHostedVideoTileHasWorkingMoveAndResizeHitTargets() async throws {
        _ = NSApplication.shared
        let camera = Camera(name: "Test video", substream: "rtsp://192.0.2.1/live")
        let initial = VideoTileFrame(x: 40, y: 30, width: 320, height: 200)
        var committed: VideoTileFrame?
        let tile = MovableVideoTile(camera: camera, tile: TileState(id: camera.id), savedFrame: initial,
            layoutSnapshot: nil, expanded: false, rearrangeEnabled: true, selected: true, activate: {},
            commit: { frame, _ in committed = frame; return true }, refreshLayout: { nil }, expand: {},
            edit: {}, reconnect: {}, snapshot: {}, remove: {})
        let host = NSHostingView(rootView: tile.frame(width: 800, height: 600, alignment: .topLeading))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let grips = findGrips(in: host)
        XCTAssertEqual(grips.count, 9)
        let move = try XCTUnwrap(grips.first { $0.edges.isEmpty })
        let point = move.convert(NSPoint(x: move.bounds.midX, y: move.bounds.midY), to: host.superview)
        XCTAssertTrue(host.hitTest(point) === move, "Title target: \(String(describing: host.hitTest(point))); point \(point); grip \(move.frame), bounds \(move.bounds); host \(host.bounds)")
        move.mouseDown(with: try mouse(.leftMouseDown, x: 100, y: 100))
        move.mouseDragged(with: try mouse(.leftMouseDragged, x: 145, y: 70))
        move.mouseUp(with: try mouse(.leftMouseUp, x: 145, y: 70))
        XCTAssertEqual(committed, initial.moved(dx: 45, dy: 30))
        let corner = try XCTUnwrap(grips.first { $0.edges == [.right, .bottom] })
        let cornerPoint = corner.convert(NSPoint(x: corner.bounds.midX, y: corner.bounds.midY), to: host.superview)
        XCTAssertTrue(host.hitTest(cornerPoint) === corner, "Resize target: \(String(describing: host.hitTest(cornerPoint))); point \(cornerPoint); grip \(corner.frame), bounds \(corner.bounds)")
        corner.mouseDown(with: try mouse(.leftMouseDown, x: 100, y: 100))
        corner.mouseDragged(with: try mouse(.leftMouseDragged, x: 180, y: 55))
        corner.mouseUp(with: try mouse(.leftMouseUp, x: 180, y: 55))
        XCTAssertEqual(committed, initial.resized(edges: [.right, .bottom], dx: 80, dy: 45))
    }

    private func findGrips(in view: NSView) -> [MouseGripView] {
        if let grip = view as? MouseGripView { return [grip] }
        return view.subviews.flatMap { findGrips(in: $0) }
    }
}