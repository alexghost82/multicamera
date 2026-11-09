import CoreVideo
import XCTest
@testable import CameraWall

final class ONNXReIDEncoderTests: XCTestCase {
    func testPreprocessingMatchesSourceTensorShapes() throws {
        let jpeg = try makeJPEG()
        let person = try ONNXReIDEncoder.preprocess(jpeg, kind: .person)
        let vehicle = try ONNXReIDEncoder.preprocess(jpeg, kind: .vehicle)

        XCTAssertEqual(person.count, 3 * 128 * 256)
        XCTAssertEqual(vehicle.count, 3 * 208 * 208)
        XCTAssertTrue(person.allSatisfy(\.isFinite))
        XCTAssertTrue(vehicle.allSatisfy(\.isFinite))
    }

    func testDownloadedReIDModelsReturnNormalized512DEmbeddings() throws {
        guard ONNXReIDEncoder.modelURL(for: .person) != nil,
              ONNXReIDEncoder.modelURL(for: .vehicle) != nil else {
            throw XCTSkip("Run make -C native reid-models to fetch the source GHOST encoders.")
        }
        let jpeg = try makeJPEG()
        let encoder = try ONNXReIDEncoder()

        for (label, id) in [("person", UUID()), ("car", UUID())] {
            let vector = try encoder.embedding(jpeg: jpeg, trackID: id, label: label)
            XCTAssertEqual(vector.count, 512)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1, accuracy: 0.0001)
        }
    }

    private func makeJPEG() throws -> Data {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 128, 256, kCVPixelFormatType_32BGRA,
                                           attributes, &pixelBuffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 127, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return try XCTUnwrap(IdentityCropEncoder.jpegData(
            pixel: pixel,
            box: CGRect(x: 0, y: 0, width: 1, height: 1)
        ))
    }
}