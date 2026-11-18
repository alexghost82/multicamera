import CameraCore
import CoreVideo
import Foundation

/// This source is not registered as an action: publication is not atomic and
/// the source's external producers are not synchronized against pixel copying.
@MainActor
final class ACTAWallSnapshotFrameProvider: ACTASnapshotFrameProvider {
    struct Source {
        let camera: Camera
        let session: CameraSession
    }

    private struct Captured {
        let source: Source
        let frame: ACTASnapshotFrame
    }

    private let source: @MainActor (UUID) throws -> Source?
    private let encode: @MainActor (CVPixelBuffer) async throws -> Data
    private let now: @Sendable () -> TimeInterval
    private var captures: [UUID: Captured] = [:]
    private var capturesInFlight = 0

    init(model: WallModel) {
        source = { [weak model] id in
            guard let model, model.running, !model.connecting else { return nil }
            let config = try model.cameraConfigurationChecked()
            guard let camera = config.cameras.first(where: { $0.id == id && $0.enabled }),
                  let tile = model.tiles[id], !tile.stale, let session = tile.session else { return nil }
            return Source(camera: camera, session: session)
        }
        encode = {
            let dimension = max(CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0))
            return try await VLMFrameEncoder.jpegData(from: $0, maxDimension: CGFloat(dimension))
        }
        now = { ProcessInfo.processInfo.systemUptime }
    }

    init(source: @escaping @MainActor (UUID) throws -> Source?,
         encode: @escaping @MainActor (CVPixelBuffer) async throws -> Data,
         now: @escaping @Sendable () -> TimeInterval) {
        self.source = source
        self.encode = encode
        self.now = now
    }

    func captureFreshFrame(cameraID: UUID) async throws -> ACTASnapshotFrame {
        let instant = now()
        captures = captures.filter { instant.isFinite && instant >= $0.value.frame.selectedUptime
            && instant - $0.value.frame.selectedUptime < 300 }
        guard captures.count + capturesInFlight < 4, let current = try source(cameraID),
              current.camera.id == cameraID, current.camera.enabled else {
            throw ACTASnapshotActionError.staleFrame
        }
        capturesInFlight += 1
        defer { capturesInFlight -= 1 }
        let sample = current.session.snapshot()
        let selectedAt = now()
        guard let pixel = sample.pixel, sample.serial > 0, sample.receivedAt.isFinite,
              selectedAt.isFinite, selectedAt >= sample.receivedAt, selectedAt - sample.receivedAt <= 2 else {
            throw ACTASnapshotActionError.staleFrame
        }
        let ownedPixel = try ACTASnapshotPixelCopy.copy(pixel)
        try Task.checkCancellation()
        let jpeg = Data([UInt8](try await encode(ownedPixel)))
        try Task.checkCancellation()
        guard jpeg.count >= 4, jpeg.count <= 8 * 1024 * 1024,
              jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2).elementsEqual([0xff, 0xd9]) else {
            throw ACTASnapshotActionError.invalidPreparation
        }
        var frameID = UUID()
        while captures[frameID] != nil { frameID = UUID() }
        let frame = ACTASnapshotFrame(cameraID: cameraID, frameID: frameID,
                                      capturedUptime: sample.receivedAt, selectedUptime: selectedAt, jpeg: jpeg)
        let captured = Captured(source: current, frame: frame)
        guard captures.count < 4, try matches(captured) else { throw ACTASnapshotActionError.staleFrame }
        captures[frame.frameID] = captured
        return frame
    }

    func isCaptureValid(_ frame: ACTASnapshotFrame) async throws -> Bool {
        guard let captured = captures[frame.frameID],
              captured.frame.cameraID == frame.cameraID,
              captured.frame.capturedUptime == frame.capturedUptime,
              captured.frame.selectedUptime == frame.selectedUptime,
              captured.frame.jpeg == frame.jpeg else { return false }
        return try matches(captured)
    }

    private func matches(_ captured: Captured) throws -> Bool {
        let instant = now()
        guard instant.isFinite, instant >= captured.frame.selectedUptime,
              instant - captured.frame.selectedUptime < 300,
              let current = try source(captured.frame.cameraID),
              current.camera.id == captured.frame.cameraID, current.camera.enabled,
              current.camera == captured.source.camera,
              current.session === captured.source.session else { return false }
        return true
    }
}
