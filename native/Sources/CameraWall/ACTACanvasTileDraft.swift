import CameraCore
import Foundation

@MainActor
struct ACTACanvasTileDraft {
    private(set) var origin: VideoTileFrame?
    private(set) var frame: VideoTileFrame?
    private(set) var base: ACTACanvasLayoutStore.Snapshot?
    private(set) var token: UUID?
    private(set) var pending = false

    mutating func begin(frame: VideoTileFrame, base: ACTACanvasLayoutStore.Snapshot?,
                        tracker: ACTACanvasGestureTracker) -> Bool {
        guard token == nil else { return false }
        token = tracker.begin()
        origin = frame
        self.base = base
        return true
    }

    mutating func change(edges: ResizeEdges, dx: Double, dy: Double) {
        guard !pending, token != nil, let origin else { return }
        frame = edges.isEmpty ? origin.moved(dx: dx, dy: dy) : origin.resized(edges: edges, dx: dx, dy: dy)
    }

    mutating func end(cancelled: Bool, tracker: ACTACanvasGestureTracker,
                      commit: (VideoTileFrame, ACTACanvasLayoutStore.Snapshot?) -> Bool) {
        guard token != nil, !pending else { return }
        if !cancelled, let frame {
            if commit(frame, base) { discard(tracker: tracker) }
            else { pending = true }
        } else {
            discard(tracker: tracker)
        }
    }

    mutating func retry(tracker: ACTACanvasGestureTracker,
                        refresh: () -> ACTACanvasLayoutStore.Snapshot?,
                        commit: (VideoTileFrame, ACTACanvasLayoutStore.Snapshot?) -> Bool) {
        guard pending, let frame, let latest = refresh() else { return }
        base = latest
        if commit(frame, latest) { discard(tracker: tracker) }
    }

    mutating func discard(tracker: ACTACanvasGestureTracker) {
        if let token { tracker.end(token) }
        token = nil
        origin = nil
        frame = nil
        base = nil
        pending = false
    }
}
