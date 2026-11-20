import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VLMFrameEncoder {
    static func jpegData(from pixelBuffer: CVPixelBuffer, maxDimension: CGFloat = 1024,
                         quality: CGFloat = 0.65) async throws -> Data {
        let frame = SendablePixelBuffer(value: pixelBuffer)
        return try await Task.detached(priority: .utility) {
            try encode(frame.value, maxDimension: maxDimension, quality: quality)
        }.value
    }

    private static func encode(_ pixelBuffer: CVPixelBuffer, maxDimension: CGFloat,
                               quality: CGFloat) throws -> Data {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
        let resized = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let context = CIContext(options: [.cacheIntermediates: false])
        let cgImage: CGImage
        if let rendered = context.createCGImage(resized, from: resized.extent) {
            cgImage = rendered
        } else if let softwareRendered = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
            .createCGImage(resized, from: resized.extent) {
            cgImage = softwareRendered
        } else if let cpuRendered = cpuFallbackCGImage(from: pixelBuffer, maxDimension: maxDimension) {
            cgImage = cpuRendered
        } else {
            throw LocalVLMError.invalidImage
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LocalVLMError.invalidImage
        }
        CGImageDestinationAddImage(destination, cgImage,
                                  [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LocalVLMError.invalidImage }
        return data as Data
    }

    private static func cpuFallbackCGImage(from pixelBuffer: CVPixelBuffer, maxDimension: CGFloat) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let sourceContext = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let sourceImage = sourceContext.makeImage() else {
            return nil
        }
        let scale = min(1, maxDimension / max(CGFloat(width), CGFloat(height)))
        guard scale < 1 else { return sourceImage }
        let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let scaledContext = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return sourceImage
        }
        scaledContext.interpolationQuality = .high
        scaledContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return scaledContext.makeImage()
    }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}
