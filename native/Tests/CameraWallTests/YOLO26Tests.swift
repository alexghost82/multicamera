import XCTest
import CoreML
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
@testable import CameraWall

final class YOLO26Tests: XCTestCase {
    func testNMSFreeOutputDecodingAndConfidenceFilter() throws {
        let tensor = try MLMultiArray(shape: [1, 3, 6], dataType: .float32)
        let rows: [[Double]] = [[64, 128, 320, 512, 0.9, 0], [0, 0, 640, 640, 0.1, 2], [0, 0, 640, 640, 0.8, 79]]
        for row in rows.indices {
            for column in 0..<6 { tensor[[0, NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: rows[row][column]) }
        }
        let result = try YOLO26Detector.decode(tensor, input: CGSize(width: 640, height: 640), threshold: 0.35)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].label, "person")
        XCTAssertEqual(result[1].label, "toothbrush")
        XCTAssertEqual(result[0].box.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result[0].box.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result[0].box.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result[0].box.height, 0.6, accuracy: 0.0001)
    }

    func testRejectsDifferentModelOutput() throws {
        let tensor = try MLMultiArray(shape: [1, 84, 8400], dataType: .float32)
        XCTAssertThrowsError(try YOLO26Detector.decode(tensor, input: CGSize(width: 640, height: 640), threshold: 0.35))
    }

    func testOfficialModelRunsOnPixelBuffer() throws {
        guard ProcessInfo.processInfo.environment["CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION=1 to run installed model inference.")
        }
        guard YOLO26Detector.defaultModelURL != nil else { throw XCTSkip("Run make -C native model for actual YOLO26 inference.") }
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 640, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let result = try YOLO26Detector().detect(pixel: buffer, threshold: 0.35)
        XCTAssertGreaterThan(result.inferenceMilliseconds, 0)
        XCTAssertTrue(result.objects.allSatisfy { $0.confidence >= 0.35 })
    }

    func testOfficialYOLO26DetectsObjectsInReferenceImage() throws {
        guard ProcessInfo.processInfo.environment["CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CAMERAWALL_RUN_INSTALLED_MODEL_INTEGRATION=1 to run installed model inference.")
        }
        let path = ProcessInfo.processInfo.environment["CAMERAWALL_YOLO_FIXTURE"]
            ?? YOLO26Detector.defaultModelURL?.deletingLastPathComponent().appendingPathComponent("bus.jpg").path ?? ""
        guard YOLO26Detector.defaultModelURL != nil, FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Provide the official bus.jpg fixture to validate known detections.")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CIContext().render(CIImage(cgImage: image), to: buffer)
        let result = try YOLO26Detector().detect(pixel: buffer, threshold: 0.35)
        XCTAssertTrue(result.objects.contains { $0.label == "bus" && $0.box.width > 0.2 }, "Reference image must produce a bus with correctly scaled coordinates")
        XCTAssertTrue(result.objects.contains { $0.label == "person" })
        print("YOLO26n reference: \(result.objects.count) objects, \(Int(result.inferenceMilliseconds)) ms")
    }
}