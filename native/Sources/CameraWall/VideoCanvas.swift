import AppKit
import SwiftUI
import CameraCore

struct VideoCanvas: View {
    @ObservedObject var model: WallModel
    var cameras: [Camera]? = nil
    var arrangeCameras = false
    var preferredColumns: Int? = nil
    var edit: (Camera) -> Void
    var remove: (Camera) -> Void
    @State private var order: [UUID] = []

    var body: some View {
        GeometryReader { geometry in
            let candidates = cameras ?? model.visible
            let visibleCameras = model.expanded.flatMap { expandedID in
                candidates.first { $0.id == expandedID }
            }.map { [$0] } ?? candidates
            let columns = model.expanded != nil ? 1 : preferredColumns ?? VideoWallLayout.columnCount(configured: model.config.columns,
                cameraCount: visibleCameras.count, expanded: model.expanded != nil)
            let gridGap = 12.0
            let frames = Dictionary(uniqueKeysWithValues: visibleCameras.enumerated().map { index, camera in
                let initial = VideoWallLayout.gridTileFrame(index: index, columns: columns,
                    availableWidth: geometry.size.width, gap: gridGap)
                let frame = arrangeCameras && model.expanded == nil
                    ? (model.layout.frames[camera.id.uuidString] ?? initial)
                    : initial
                return (camera.id, frame)
            })
            let canvasWidth = max(geometry.size.width, frames.values.map { $0.x + $0.width + gridGap }.max() ?? 0)
            let canvasHeight = max(geometry.size.height, frames.values.map { $0.y + $0.height + gridGap }.max() ?? 0)
            ScrollViewReader { scroll in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: 1, height: 1).id("canvasOrigin")
                        ForEach(visibleCameras) { camera in
                            if let tile = model.tiles[camera.id], let frame = frames[camera.id] {
                                MovableVideoTile(camera: camera, tile: tile, savedFrame: frame,
                                    layoutSnapshot: model.canvasLayoutSnapshot,
                                    expanded: model.expanded == camera.id,
                                    rearrangeEnabled: arrangeCameras,
                                    selected: order.last == camera.id,
                                    activate: { order.removeAll { $0 == camera.id }; order.append(camera.id) },
                                    commit: { model.setTileFrame($0, for: camera.id, expected: $1) },
                                    refreshLayout: {
                                        guard model.refreshCanvasLayout() else { return nil }
                                        return model.canvasLayoutSnapshot
                                    },
                                    expand: { model.toggleExpanded(camera) }, edit: { edit(camera) },
                                    reconnect: { model.reconnect(camera) },
                                    snapshot: {
                                        ACTAOperationalExportUI.start(ACTAReviewedFrameExport.make(
                                            cameraID: camera.id, frames: ACTAWallSnapshotFrameProvider(model: model)))
                                    },
                                    remove: { remove(camera) },
                                    toggleYOLO: { model.setYOLOEnabled(for: camera.id, enabled: $0) },
                                    toggleAIChat: { model.setAIChatEnabled(for: camera.id, enabled: $0) })
                                    .zIndex(Double((order.firstIndex(of: camera.id) ?? -1) + 1))
                            }
                        }
                    }.frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                }
                .onChange(of: model.expanded) { _, _ in scroll.scrollTo("canvasOrigin", anchor: .topLeading) }
            }
        }
    }
}

struct MovableVideoTile: View {
    let camera: Camera
    @ObservedObject var tile: TileState
    let savedFrame: VideoTileFrame
    let layoutSnapshot: ACTACanvasLayoutStore.Snapshot?
    let expanded: Bool
    let rearrangeEnabled: Bool
    let selected: Bool
    var activate: () -> Void
    var commit: (VideoTileFrame, ACTACanvasLayoutStore.Snapshot?) -> Bool
    var refreshLayout: () -> ACTACanvasLayoutStore.Snapshot?
    var expand: () -> Void
    var edit: () -> Void
    var reconnect: () -> Void
    var snapshot: () -> Void
    var remove: () -> Void
    var toggleYOLO: (Bool) -> Void = { _ in }
    var toggleAIChat: (Bool) -> Void = { _ in }
    @State private var draft = ACTACanvasTileDraft()

    private var frame: VideoTileFrame { draft.frame ?? savedFrame }

    var body: some View {
        CameraTile(camera: camera, tile: tile, expanded: expanded, expand: expand,
                   edit: edit, reconnect: reconnect, snapshot: snapshot, remove: remove, activate: activate,
                   toggleYOLO: toggleYOLO, toggleAIChat: toggleAIChat)
            .frame(width: frame.width, height: frame.height)
            .overlay(alignment: .topLeading) {
                if !expanded && rearrangeEnabled {
                    grip(edges: [], label: "Move \(camera.name)")
                        .frame(width: max(24, frame.width - 38), height: 22).offset(x: 5, y: 3)
                }
            }
            .overlay { Rectangle().strokeBorder(rearrangeEnabled && selected ? ACTATheme.borderActive : Color.clear, lineWidth: 2).allowsHitTesting(false) }
            .overlay(alignment: .leading) { if !expanded && rearrangeEnabled { grip(edges: .left, label: "Resize left").frame(width: 8, height: max(12, frame.height - 24)) } }
            .overlay(alignment: .trailing) { if !expanded && rearrangeEnabled { grip(edges: .right, label: "Resize right").frame(width: 8, height: max(12, frame.height - 24)) } }
            .overlay(alignment: .top) { if !expanded && rearrangeEnabled { grip(edges: .top, label: "Resize top").frame(width: max(12, frame.width - 24), height: 8) } }
            .overlay(alignment: .bottom) { if !expanded && rearrangeEnabled { grip(edges: .bottom, label: "Resize bottom").frame(width: max(12, frame.width - 24), height: 8) } }
            .overlay(alignment: .topLeading) { if !expanded && rearrangeEnabled { grip(edges: [.top, .left], label: "Resize top left").frame(width: 12, height: 12) } }
            .overlay(alignment: .topTrailing) { if !expanded && rearrangeEnabled { grip(edges: [.top, .right], label: "Resize top right").frame(width: 12, height: 12) } }
            .overlay(alignment: .bottomLeading) { if !expanded && rearrangeEnabled { grip(edges: [.bottom, .left], label: "Resize bottom left").frame(width: 12, height: 12) } }
            .overlay(alignment: .bottomTrailing) {
                if !expanded && rearrangeEnabled {
                    grip(edges: [.bottom, .right], label: "Resize bottom right")
                        .frame(width: 14, height: 14)
                        .overlay { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: ACTAType.metadata)).foregroundStyle(.white).allowsHitTesting(false) }
                }
            }
            .overlay(alignment: .bottom) {
                if draft.pending {
                    HStack {
                        Button("Discard draft") { cancelGesture() }
                        Button("Apply draft over newer layout") { retryDraft() }
                    }
                    .padding(6)
                    .background(.regularMaterial)
                }
            }
            .focusable()
            .onMoveCommand { direction in
                guard rearrangeEnabled, !expanded else { return }
                let dx: Double = direction == .left ? -10 : (direction == .right ? 10 : 0)
                let dy: Double = direction == .up ? -10 : (direction == .down ? 10 : 0)
                nudge(dx: dx, dy: dy, resize: NSEvent.modifierFlags.contains(.shift))
            }
            .accessibilityAction(named: Text("Move left")) { nudge(dx: -10, dy: 0) }
            .accessibilityAction(named: Text("Move right")) { nudge(dx: 10, dy: 0) }
            .accessibilityAction(named: Text("Move up")) { nudge(dx: 0, dy: -10) }
            .accessibilityAction(named: Text("Move down")) { nudge(dx: 0, dy: 10) }
            .accessibilityAction(named: Text("Increase size")) { nudge(dx: 20, dy: 12, resize: true) }
            .accessibilityAction(named: Text("Decrease size")) { nudge(dx: -20, dy: -12, resize: true) }
            .onChange(of: rearrangeEnabled) { _, enabled in if !enabled && !draft.pending { cancelGesture() } }
            .onChange(of: expanded) { _, isExpanded in if isExpanded && !draft.pending { cancelGesture() } }
            .onDisappear { cancelGesture() }
            .offset(x: frame.x, y: frame.y)
    }

    private func grip(edges: ResizeEdges, label: String) -> MouseGrip {
        MouseGrip(edges: edges, label: label, begin: {
                      let initial = frame
                      guard draft.begin(frame: initial, base: layoutSnapshot,
                                        tracker: .shared) else { return }
                      activate()
                  },
                  change: { dx, dy in
                      draft.change(edges: edges, dx: dx, dy: dy)
                  }, end: { cancelled in
                      draft.end(cancelled: cancelled, tracker: .shared, commit: commit)
                  }, doubleClick: expand, nudge: { dx, dy, resize in nudge(dx: dx, dy: dy, resize: resize) })
    }

    private func cancelGesture() {
        draft.discard(tracker: .shared)
    }

    private func retryDraft() {
        draft.retry(tracker: .shared, refresh: refreshLayout, commit: commit)
    }

    private func nudge(dx: Double, dy: Double, resize: Bool = false) {
        guard rearrangeEnabled, !expanded, draft.token == nil else { return }
        activate()
        _ = commit(resize ? savedFrame.resized(edges: [.bottom, .right], dx: dx, dy: dy) : savedFrame.moved(dx: dx, dy: dy), layoutSnapshot)
    }
}

struct MouseGrip: NSViewRepresentable {
    var edges: ResizeEdges
    var label: String
    var begin: () -> Void
    var change: (Double, Double) -> Void
    var end: (Bool) -> Void
    var doubleClick: () -> Void
    var nudge: (Double, Double, Bool) -> Void

    func makeNSView(context: Context) -> MouseGripView { MouseGripView() }
    func updateNSView(_ view: MouseGripView, context: Context) {
        view.edges = edges
        view.toolTip = label
        view.begin = begin
        view.change = change
        view.end = end
        view.doubleClick = doubleClick
        view.nudge = nudge
        view.window?.invalidateCursorRects(for: view)
    }
}

final class MouseGripView: NSView {
    var edges: ResizeEdges = []
    var begin: () -> Void = {}
    var change: (Double, Double) -> Void = { _, _ in }
    var end: (Bool) -> Void = { _ in }
    var doubleClick: () -> Void = {}
    var nudge: (Double, Double, Bool) -> Void = { _, _, _ in }
    private var anchor: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let horizontal = !edges.intersection([.left, .right]).isEmpty
        let vertical = !edges.intersection([.top, .bottom]).isEmpty
        let cursor: NSCursor = edges.isEmpty ? .openHand : (horizontal && vertical ? .crosshair : (horizontal ? .resizeLeftRight : .resizeUpDown))
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { doubleClick(); return }
        window?.makeFirstResponder(self)
        anchor = event.locationInWindow
        begin()
        if edges.isEmpty { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        change(event.locationInWindow.x - anchor.x, anchor.y - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        anchor = nil
        end(false)
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
    }

    override func cancelOperation(_ sender: Any?) {
        guard anchor != nil else { return }
        anchor = nil
        end(true)
        NSCursor.arrow.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelOperation(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        let deltas: [UInt16: (Double, Double)] = [123: (-10, 0), 124: (10, 0), 125: (0, 10), 126: (0, -10)]
        if let (dx, dy) = deltas[event.keyCode] {
            nudge(dx, dy, event.modifierFlags.contains(.shift))
        } else { super.keyDown(with: event) }
    }
}