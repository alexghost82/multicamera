import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Vision

enum IdentityCutoutEncoder {
    static func pngData(fromJPEG jpeg: Data) -> Data? {
        let handler = VNImageRequestHandler(data: jpeg)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty,
                                    let masked = try? observation.generateMaskedImage(
                                        ofInstances: observation.allInstances,
                                        from: handler,
                                        croppedToInstancesExtent: false
                                    ) else { return nil }
            let image = CIImage(cvPixelBuffer: masked)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        } catch {
            return nil
        }
    }
}