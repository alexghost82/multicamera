import XCTest
import CoreML
import CoreVideo
import CoreImage
import ImageIO
@testable import CameraWall

final class YOLO26PoseDetectorTests: XCTestCase {
    func testDecoderMapsBoxesAndKeypointsThroughLetterboxTransform() throws {
        let tensor = try MLMultiArray(shape: [1, 4, 57], dataType: .float32)
        let rows: [[Double]] = [
            [160, 140, 480, 500, 0.9, 0],
            [32, 32, 100, 100, 0.24, 0],
            [20, 20, 120, 120, 0.8, 1],
            [10, 10, 80, 80, 0.7, 0]
        ]
        for row in rows.indices {
            for column in 0..<6 {
                tensor[[0, NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: rows[row][column])
            }
            for keypoint in 0..<17 {
                let offset = 6 + keypoint * 3
                tensor[[0, NSNumber(value: row), NSNumber(value: offset)]] = 320
                tensor[[0, NSNumber(value: row), NSNumber(value: offset + 1)]] = 320
                tensor[[0, NSNumber(value: row), NSNumber(value: offset + 2)]] = 0.88
            }
        }
        tensor[[0, 3, 10]] = NSNumber(value: Double.nan)
        let transform = PoseLetterboxTransform(sourceWidth: 1280, sourceHeight: 720,
                                               scale: 0.5, paddingX: 0, paddingY: 140,
                                               inputSize: 640)

        let people = try YOLO26PoseDetector.decode(tensor, transform: transform, threshold: 0.25)

        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(people[0].box.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(people[0].box.y, 0, accuracy: 0.0001)
        XCTAssertEqual(people[0].box.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(people[0].box.height, 1, accuracy: 0.0001)
        XCTAssertEqual(people[0].keypoints.count, 17)
        XCTAssertEqual(people[0].keypoints[0].x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(people[0].keypoints[0].y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(people[0].keypoints[0].confidence, 0.88, accuracy: 0.0001)
    }

    func testSwiftCoreMLRuntimeMatchesKnownPersonCountOnBusFixture() throws {
        let modelURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/models/yolo26s-pose.mlpackage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Provide native/.build/models/yolo26s-pose.mlpackage for runtime inference.")
        }
        let imageURL = modelURL.deletingLastPathComponent().appendingPathComponent("bus.jpg")
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw XCTSkip("Provide the existing bus.jpg fixture beside the model package.")
        }
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                           &pixelBuffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(pixelBuffer)
        CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: image), to: pixel)

        let detector = YOLO26PoseDetector(modelURL: modelURL)
        let result = try detector.detect(pixel: pixel, threshold: 0.25)
        XCTAssertEqual(result.people.count, 4)
        XCTAssertTrue(result.people.allSatisfy { $0.keypoints.count == 17 })
        XCTAssertTrue(result.people.allSatisfy { $0.confidence >= 0.25 })
        XCTAssertGreaterThan(result.inferenceMilliseconds, 0)
    }
}