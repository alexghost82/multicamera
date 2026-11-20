import CameraCore
import CoreVideo
import Foundation
import Testing

@testable import CameraWall

private enum FrameExportFixtureError: Error { case inaccessible }

@MainActor
private final class FrameExportFixture {
    let camera = Camera(name: "Synthetic camera", substream: "")
    let session = CameraSession()
    var preview: Data?
}

@MainActor
private struct SyntheticFrameSelector: ACTAReviewedFileSelector {
    let fixture: FrameExportFixture
    let destination: URL

    func selectAndReview() async throws -> ACTAReviewedFileSelection {
        let provider = ACTAWallSnapshotFrameProvider(
            source: { id in
                guard id == fixture.camera.id else { return nil }
                return .init(camera: fixture.camera, session: fixture.session)
            },
            encode: { try await VLMFrameEncoder.jpegData(from: $0) },
            now: { ProcessInfo.processInfo.systemUptime })
        let frame = try await provider.captureFreshFrame(cameraID: fixture.camera.id)
        let preview = try ACTAFrameExportPreview(jpeg: frame.jpeg)
        fixture.preview = preview.bytes
        return .init(kind: .cameraFrame, bytes: preview.bytes, destination: destination)
    }
}

@MainActor
struct ACTAFrameCaptureEndToEndTests {
    @Test func reviewedSyntheticFrameIsTheOnlyCreatedContent() async throws {
        let fixture = FrameExportFixture()
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixel = try #require(buffer)
        do {
            guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else {
                throw FrameExportFixtureError.inaccessible
            }
            defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw FrameExportFixtureError.inaccessible }
            memset(base, 42, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".frame-e2e-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("frame.jpg")
        let action = ACTAReviewedFileExportAction(kind: .cameraFrame,
            selector: SyntheticFrameSelector(fixture: fixture, destination: destination))
        let made = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await made.broker.openSession(operatorKey: made.operatorKey, input: .chat,
            threadID: "synthetic", actionIDs: [action.id]))
        let injected = await made.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"destination_path":"/model.jpg"}"#)
        #expect(!injected.success)
        let request = Task {
            await made.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !fixture.session.hasPendingOwnedFrameCapture && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(fixture.session.hasPendingOwnedFrameCapture)
        fixture.session.publish(pixel, message: "Synthetic")
        let pending = await request.value
        #expect(pending.requiresOperatorConfirmation)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let preview = try #require(fixture.preview)
        #expect(Data(ACTAReviewedFileExportUI.hex(preview).split(whereSeparator: \.isWhitespace)
            .compactMap { UInt8($0, radix: 16) }) == preview)
        let reviews = await made.broker.reviews(operatorKey: made.operatorKey, session: session)
        let review = try #require(reviews.first)
        let result = await made.broker.resolve(operatorKey: made.operatorKey, session: session,
                                               reviewed: review, approved: true)
        #expect(result.success && result.verified)
        #expect(try Data(contentsOf: destination) == preview)
        #expect(throws: ACTACreateOnlyExport.Failure.self) {
            try ACTACreateOnlyExport.publish(Data([1, 2, 3]), to: destination)
        }
        #expect(try Data(contentsOf: destination) == preview)
    }
}
