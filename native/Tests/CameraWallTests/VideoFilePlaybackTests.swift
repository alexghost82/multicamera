import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import CameraWall

final class VideoFilePlaybackTests: XCTestCase {
    func testFileSessionPacesFramesAndStopsAtEndOfVideo() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeMovie(at: url, frameCount: 8, framesPerSecond: 12)

        let session = CameraSession()
        defer { session.stop() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        session.start(fileURL: url)

        let deadline = startedAt + 5
        var ended = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let frame = session.snapshot()
            if frame.message == "End of video" {
                ended = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let finalFrame = session.snapshot()
        XCTAssertTrue(ended, "Local video should terminate instead of reconnecting at EOF.")
        XCTAssertGreaterThanOrEqual(finalFrame.frames, 6)
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.3,
                             "File decode should follow presentation timestamps rather than run at disk speed.")
    }

    private func makeMovie(at url: URL, frameCount: Int, framesPerSecond: Int) async throws {
        let width = 160
        let height = 90
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)

        for index in 0..<frameCount {
            let readinessDeadline = ProcessInfo.processInfo.systemUptime + 2
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < readinessDeadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, Int32(index * 19), CVPixelBufferGetBytesPerRow(pixel) * height)
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(
                pixel,
                withPresentationTime: CMTime(value: Int64(index), timescale: Int32(framesPerSecond))
            ))
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "Movie encoding failed.")
    }
}