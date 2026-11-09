import CoreVideo
import XCTest
@testable import CameraWall

final class VisionFeatureMatcherTests: XCTestCase {
    func testRanksSameCropAndOnlyReturnsOtherCameraSameCategory() throws {
        let image = try makeJPEG()
        let sourceID = UUID()
        let sourceCameraID = UUID()
        let remoteCameraID = UUID()
        let expectedID = UUID()
        let candidates = [
            VisionFeatureInput(trackID: sourceID, cameraID: remoteCameraID,
                               cameraName: "Remote", label: "person", lastSeen: .now, imageData: image),
            VisionFeatureInput(trackID: UUID(), cameraID: sourceCameraID,
                               cameraName: "Local", label: "person", lastSeen: .now, imageData: image),
            VisionFeatureInput(trackID: UUID(), cameraID: remoteCameraID,
                               cameraName: "Remote", label: "car", lastSeen: .now, imageData: image),
            VisionFeatureInput(trackID: expectedID, cameraID: remoteCameraID,
                               cameraName: "Remote", label: "person", lastSeen: .now, imageData: image)
        ]

        let matches = try VisionFeatureMatcher.nearest(
            sourceTrackID: sourceID,
            sourceCameraID: sourceCameraID,
            sourceLabel: "person",
            sourceImage: image,
            candidates: candidates
        )

        XCTAssertEqual(matches.map(\.trackID), [expectedID])
        XCTAssertEqual(matches[0].distance, 0, accuracy: 0.001)
    }

    func testRanksPersistedReIDVectorsWithoutDecodingImages() throws {
        let sourceID = UUID()
        let candidateID = UUID()
        let sourceCameraID = UUID()
        let candidateCameraID = UUID()
        var sourceVector = [Float](repeating: 0, count: 512)
        sourceVector[0] = 1
        var candidateVector = [Float](repeating: 0, count: 512)
        candidateVector[0] = 0.8
        candidateVector[1] = 0.6
        let candidate = VisionFeatureInput(
            trackID: candidateID, cameraID: candidateCameraID, cameraName: "Side gate",
            label: "person", lastSeen: .now, imageData: Data()
        )

        let matches = try VisionFeatureMatcher.nearest(
            sourceTrackID: sourceID,
            sourceCameraID: sourceCameraID,
            sourceLabel: "person",
            sourceImage: Data(),
            candidates: [candidate],
            sourceEmbedding: sourceVector,
            candidateEmbeddings: [candidateID: candidateVector]
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].distance, 0.2, accuracy: 0.0001)
        XCTAssertEqual(matches[0].metric, "ReID cosine distance")
    }

    private func makeJPEG() throws -> Data {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_32BGRA,
                                           attributes, &pixelBuffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return try XCTUnwrap(IdentityCropEncoder.jpegData(
            pixel: pixel,
            box: CGRect(x: 0, y: 0, width: 1, height: 1)
        ))
    }
}