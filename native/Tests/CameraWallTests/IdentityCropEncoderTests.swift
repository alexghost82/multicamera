import CoreVideo
import ImageIO
import XCTest
@testable import CameraWall

final class IdentityCropEncoderTests: XCTestCase {
    func testEncodesPixelBufferCropAsJPEGAndRejectsEmptyBounds() throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
                                attributes, &pixelBuffer),
            kCVReturnSuccess
        )
        let pixel = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])

        let jpeg = try XCTUnwrap(IdentityCropEncoder.jpegData(
            pixel: pixel,
            box: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        ))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertNil(IdentityCropEncoder.jpegData(pixel: pixel, box: .zero))

        if let cutout = IdentityCutoutEncoder.pngData(fromJPEG: jpeg) {
            XCTAssertEqual(Array(cutout.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }

    func testForegroundCutoutHasTransparentBackgroundOnSampleImage() throws {
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sampleURL = nativeRoot.appendingPathComponent(".build/models/bus.jpg")
        guard FileManager.default.fileExists(atPath: sampleURL.path) else {
            throw XCTSkip("make -C native test downloads the sample image")
        }
        let source = try Data(contentsOf: sampleURL)
        let cutout = try XCTUnwrap(IdentityCutoutEncoder.pngData(fromJPEG: source))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(cutout as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drewImage = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drewImage)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 })
    }
}