import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACanvasTileDraftTests: XCTestCase {
    func testConflictKeepsDraftUntilExplicitRetry() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build")
            .appendingPathComponent("canvas-draft-test-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
        }
        let store = ACTACanvasLayoutStore(url: url)
        let initial = try store.read()
        let camera = UUID().uuidString
        let other = UUID().uuidString
        let initialFrame = VideoTileFrame(x: 0, y: 0, width: 200, height: 100)
        let otherFrame = VideoTileFrame(x: 10, y: 10, width: 200, height: 100)
        let tracker = ACTACanvasGestureTracker()
        var draft = ACTACanvasTileDraft()
        XCTAssertTrue(draft.begin(frame: initialFrame, base: initial, tracker: tracker))
        draft.change(edges: [], dx: 40, dy: 20)
        var concurrent = initial.layout
        concurrent.frames[other] = otherFrame
        _ = try store.commit(concurrent, expected: initial)
        let save: (VideoTileFrame, ACTACanvasLayoutStore.Snapshot?) -> Bool = { frame, base in
            guard let base else { return false }
            var next = base.layout
            next.frames[camera] = frame
            return (try? store.commit(next, expected: base)) != nil
        }
        draft.end(cancelled: false, tracker: tracker, commit: save)
        XCTAssertTrue(draft.pending)
        XCTAssertEqual(draft.frame, initialFrame.moved(dx: 40, dy: 20))
        XCTAssertTrue(tracker.hasActiveGestures)
        XCTAssertNil(try store.read().layout.frames[camera])
        draft.change(edges: [], dx: 100, dy: 100)
        draft.retry(tracker: tracker, refresh: { nil }, commit: save)
        XCTAssertTrue(draft.pending)
        XCTAssertEqual(draft.frame, initialFrame.moved(dx: 40, dy: 20))
        draft.retry(tracker: tracker, refresh: { try? store.read() }, commit: save)
        let saved = try store.read().layout
        XCTAssertEqual(saved.frames[other], otherFrame)
        XCTAssertEqual(saved.frames[camera], initialFrame.moved(dx: 40, dy: 20))
        XCTAssertFalse(draft.pending)
        XCTAssertFalse(tracker.hasActiveGestures)
    }

    func testCancelDiscardsDraftAndReleasesGesture() {
        let tracker = ACTACanvasGestureTracker()
        var draft = ACTACanvasTileDraft()
        XCTAssertTrue(draft.begin(frame: VideoTileFrame(x: 0, y: 0, width: 200, height: 100),
                                  base: nil, tracker: tracker))
        draft.change(edges: [], dx: 5, dy: 5)
        draft.end(cancelled: true, tracker: tracker) { _, _ in
            XCTFail("Cancelled draft must not be written")
            return false
        }
        XCTAssertNil(draft.frame)
        XCTAssertFalse(tracker.hasActiveGestures)
    }
}
