import CoreGraphics
import ImageIO
import XCTest
@testable import CameraWall

final class ONNXSegmentationTests: XCTestCase {
    func testDownloadedSegmentationModelProducesTransparentCutout() throws {
        guard ONNXSegmentationEncoder.modelURL != nil else {
            throw XCTSkip("Run make -C native seg-models to export the segmentation ONNX model.")
        }
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sampleURL = nativeRoot.appendingPathComponent(".build/models/bus.jpg")
        guard FileManager.default.fileExists(atPath: sampleURL.path) else {
            throw XCTSkip("Run make -C native test to fetch the sample image.")
        }

        let source = try Data(contentsOf: sampleURL)
        let cutout = try XCTUnwrap(ONNXSegmentationEncoder.transparentPNG(fromJPEG: source, label: "bus"))
        XCTAssertEqual(Array(cutout.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertTrue(hasTransparentPixel(cutout))
    }

    private func hasTransparentPixel(_ png: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return rendered && stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }
}