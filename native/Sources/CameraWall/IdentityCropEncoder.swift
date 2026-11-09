import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

struct IdentityPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

enum IdentityCropEncoder {
    static func jpegData(pixel: CVPixelBuffer, box: CGRect, maximumSide: CGFloat = 320) -> Data? {
        let image = CIImage(cvPixelBuffer: pixel)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              box.width > 0, box.height > 0 else { return nil }
        let padding = max(box.width, box.height) * 0.08
        let normalized = CGRect(x: box.minX - padding, y: box.minY - padding,
                                width: box.width + padding * 2, height: box.height + padding * 2)
        let cropRect = CGRect(x: extent.minX + normalized.minX * extent.width,
                              y: extent.minY + normalized.minY * extent.height,
                              width: normalized.width * extent.width,
                              height: normalized.height * extent.height)
            .intersection(extent)
        guard !cropRect.isNull, !cropRect.isEmpty else { return nil }

        let crop = image.cropped(to: cropRect)
        let scale = min(1, maximumSide / max(cropRect.width, cropRect.height))
        let resized = scale < 1 ? crop.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : crop
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(resized, from: resized.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage,
                                   [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}