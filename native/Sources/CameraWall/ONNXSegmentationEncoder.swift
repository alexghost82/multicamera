import CoreGraphics
import Foundation
import ImageIO
import OnnxRuntimeBindings
import UniformTypeIdentifiers

private struct SegmentationModelSession {
    let session: ORTSession
    let inputName: String
    let detectionOutputName: String
    let prototypeOutputName: String
}

enum ONNXSegmentationError: LocalizedError {
    case modelMissing
    case coreMLUnavailable
    case invalidModelOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Missing YOLO26n-seg.onnx. Run make -C native seg-models."
        case .coreMLUnavailable: return "ONNX Runtime CoreML provider is not available on this Mac."
        case .invalidModelOutput: return "YOLO26-seg returned incompatible output tensors."
        }
    }
}

enum ONNXSegmentationEncoder {
    static let inputSize = 640
    static let prototypeSize = 160
    static let prototypeChannels = 32
    static let detectionCount = 300
    static let detectionStride = 6 + prototypeChannels

    private static let environment: ORTEnv? = try? ORTEnv(loggingLevel: .error)
    private static let lock = NSLock()
    private static var loadedSession: SegmentationModelSession?

    static func resetModel() { lock.lock(); defer { lock.unlock() }; loadedSession = nil }

    static func prepare() throws {
        try ModelSelectionRegistry.require(.segmentation)
        _ = try session()
    }

    static var modelURL: URL? {
        guard ModelSelectionRegistry.isEnabled(.segmentation) else { return nil }
        if let selected = ModelSelectionRegistry.path(.segmentation) { return selected }
        if let override = ProcessInfo.processInfo.environment["CAMERAWALL_SEG_MODEL"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("yolo26n-seg.onnx"))
        }
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(nativeRoot.appendingPathComponent(".build/models/yolo26n-seg.onnx"))
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(working.appendingPathComponent("native/.build/models/yolo26n-seg.onnx"))
        candidates.append(working.appendingPathComponent(".build/models/yolo26n-seg.onnx"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func bestEffortCutout(fromJPEG jpeg: Data, label: String) -> Data? {
        if modelURL != nil, let cutout = try? transparentPNG(fromJPEG: jpeg, label: label) {
            return cutout
        }
        return IdentityCutoutEncoder.pngData(fromJPEG: jpeg)
    }

    static func transparentPNG(fromJPEG jpeg: Data, label: String) throws -> Data? {
        guard let classID = classID(for: label) else { return nil }
        let source = try makeSourceImage(jpeg)
        let letterboxed = try makeLetterbox(source.cgImage)
        let model = try session()
        let inputData = NSMutableData(bytes: letterboxed.tensor, length: letterboxed.tensor.count * MemoryLayout<Float>.size)
        let input = try ORTValue(tensorData: inputData, elementType: .float,
                                 shape: [1, 3, inputSize, inputSize].map(NSNumber.init(value:)))
        let outputs = try model.session.run(
            withInputs: [model.inputName: input],
            outputNames: [model.detectionOutputName, model.prototypeOutputName],
            runOptions: nil
        )
        guard let detections = outputs[model.detectionOutputName],
              let prototypes = outputs[model.prototypeOutputName] else { return nil }
        let detectionFloats = try floats(detections)
        let prototypeFloats = try floats(prototypes)
        guard detectionFloats.count == detectionCount * detectionStride,
              prototypeFloats.count == prototypeChannels * prototypeSize * prototypeSize else { return nil }

        guard let selected = bestDetection(detectionFloats, classID: classID) else { return nil }
        let logits = maskLogits(detectionFloats, row: selected.row, prototypes: prototypeFloats)
        return makeMaskedPNG(source.rgba, width: source.cgImage.width, height: source.cgImage.height,
                             letterbox: letterboxed, detection: selected, logits: logits)
    }

    private static func classID(for label: String) -> Int? {
        [
            "person": 0, "bicycle": 1, "car": 2, "motorcycle": 3,
            "bus": 5, "train": 6, "truck": 7, "boat": 8
        ][label]
    }

    private static func makeSourceImage(_ data: Data) throws -> (cgImage: CGImage, rgba: [UInt8]) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rgba = renderRGBA(cgImage, width: cgImage.width, height: cgImage.height) else {
            throw ONNXReIDError.invalidImage
        }
        return (cgImage, rgba)
    }

    private static func makeLetterbox(_ image: CGImage) throws -> (tensor: [Float], scale: CGFloat,
                                                                    left: Int, top: Int) {
        let scale = min(CGFloat(inputSize) / CGFloat(image.width), CGFloat(inputSize) / CGFloat(image.height))
        let resizedWidth = Int((CGFloat(image.width) * scale).rounded())
        let resizedHeight = Int((CGFloat(image.height) * scale).rounded())
        let left = Int((CGFloat(inputSize - resizedWidth) / 2 - 0.1).rounded())
        let top = Int((CGFloat(inputSize - resizedHeight) / 2 - 0.1).rounded())
        let byteCount = inputSize * inputSize * 4
        var pixels = [UInt8](repeating: 114, count: byteCount)
        for index in stride(from: 3, to: byteCount, by: 4) { pixels[index] = 255 }
        let rect = CGRect(x: left, y: top, width: resizedWidth, height: resizedHeight)
        let drew = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = makeBitmapContext(storage, width: inputSize, height: inputSize) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return true
        }
        guard drew else { throw ONNXReIDError.invalidImage }

        let planeSize = inputSize * inputSize
        var tensor = [Float](repeating: 0, count: planeSize * 3)
        for pixel in 0..<planeSize {
            let source = pixel * 4
            tensor[pixel] = Float(pixels[source]) / 255
            tensor[planeSize + pixel] = Float(pixels[source + 1]) / 255
            tensor[2 * planeSize + pixel] = Float(pixels[source + 2]) / 255
        }
        return (tensor, scale, left, top)
    }

    private struct SelectedDetection {
        let row: Int
        let box: (left: Float, top: Float, right: Float, bottom: Float)
    }

    private static func bestDetection(_ values: [Float], classID: Int) -> SelectedDetection? {
        var best: SelectedDetection?
        var bestConfidence: Float = 0.2
        for row in 0..<detectionCount {
            let offset = row * detectionStride
            guard values[offset + 5].isFinite,
                  Int(values[offset + 5]) == classID,
                  values[offset + 4].isFinite,
                  values[offset + 4] > bestConfidence else { continue }
            let box = (values[offset], values[offset + 1], values[offset + 2], values[offset + 3])
            guard box.0.isFinite, box.1.isFinite, box.2 > box.0, box.3 > box.1 else { continue }
            bestConfidence = values[offset + 4]
            best = SelectedDetection(row: row, box: box)
        }
        return best
    }

    private static func maskLogits(_ detections: [Float], row: Int, prototypes: [Float]) -> [Float] {
        let offset = row * detectionStride + 6
        let maskSize = prototypeSize * prototypeSize
        var logits = [Float](repeating: 0, count: maskSize)
        for channel in 0..<prototypeChannels {
            let coefficient = detections[offset + channel]
            let protoOffset = channel * maskSize
            for index in 0..<maskSize {
                logits[index] += coefficient * prototypes[protoOffset + index]
            }
        }
        return logits
    }

    private static func makeMaskedPNG(_ source: [UInt8], width: Int, height: Int,
                                      letterbox: (tensor: [Float], scale: CGFloat, left: Int, top: Int),
                                      detection: SelectedDetection, logits: [Float]) -> Data? {
        let box = detection.box
        let boxArea = max(1, (box.right - box.left) * (box.bottom - box.top))
        let frameArea = Float(inputSize * inputSize)
        guard boxArea / frameArea > 0.002 else { return nil }

        var pixels = source
        var visible = 0
        for y in 0..<height {
            for x in 0..<width {
                let modelX = Float(CGFloat(x) * letterbox.scale + CGFloat(letterbox.left))
                let modelY = Float(CGFloat(y) * letterbox.scale + CGFloat(letterbox.top))
                let pixel = y * width + x
                let sourceOffset = pixel * 4
                guard modelX >= box.left, modelX <= box.right,
                      modelY >= box.top, modelY <= box.bottom else {
                    pixels[sourceOffset] = 0; pixels[sourceOffset + 1] = 0; pixels[sourceOffset + 2] = 0
                    pixels[sourceOffset + 3] = 0
                    continue
                }
                let protoX = (modelX + 0.5) * Float(prototypeSize) / Float(inputSize) - 0.5
                let protoY = (modelY + 0.5) * Float(prototypeSize) / Float(inputSize) - 0.5
                let x0 = max(0, min(prototypeSize - 1, Int(floor(protoX))))
                let y0 = max(0, min(prototypeSize - 1, Int(floor(protoY))))
                let x1 = min(prototypeSize - 1, x0 + 1)
                let y1 = min(prototypeSize - 1, y0 + 1)
                let fx = max(0, min(1, protoX - Float(x0)))
                let fy = max(0, min(1, protoY - Float(y0)))
                let top = logits[y0 * prototypeSize + x0] * (1 - fx) + logits[y0 * prototypeSize + x1] * fx
                let bottom = logits[y1 * prototypeSize + x0] * (1 - fx) + logits[y1 * prototypeSize + x1] * fx
                let logit = top * (1 - fy) + bottom * fy
                if logit > 0 {
                    visible += 1
                } else {
                    pixels[sourceOffset] = 0; pixels[sourceOffset + 1] = 0; pixels[sourceOffset + 2] = 0
                    pixels[sourceOffset + 3] = 0
                }
            }
        }
        guard visible >= max(20, width * height / 200) else { return nil }
        return encodePNG(pixels, width: width, height: height)
    }

    private static func renderRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = makeBitmapContext(storage, width: width, height: height) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? pixels : nil
    }

    private static func makeBitmapContext(_ storage: UnsafeMutableRawBufferPointer,
                                          width: Int, height: Int) -> CGContext? {
        guard let base = storage.baseAddress else { return nil }
        return CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                            | CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func encodePNG(_ pixels: [UInt8], width: Int, height: Int) -> Data? {
        var mutablePixels = pixels
        return mutablePixels.withUnsafeMutableBytes { storage in
            guard let context = makeBitmapContext(storage, width: width, height: height),
                  let cgImage = context.makeImage() else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData()
        let count = data.length / MemoryLayout<Float>.size
        let values = data.bytes.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }

    private static func session() throws -> SegmentationModelSession {
        try ModelSelectionRegistry.require(.segmentation)
        lock.lock()
        defer { lock.unlock() }
        if let loadedSession { return loadedSession }
        guard ORTIsCoreMLExecutionProviderAvailable() else { throw ONNXSegmentationError.coreMLUnavailable }
        guard let modelURL else { throw ONNXSegmentationError.modelMissing }
        guard let ortEnvironment = environment else { throw ONNXSegmentationError.coreMLUnavailable }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        let coreMLOptions = ORTCoreMLExecutionProviderOptions()
        coreMLOptions.onlyAllowStaticInputShapes = true
        coreMLOptions.createMLProgram = true
        try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        let session = try ORTSession(env: ortEnvironment, modelPath: modelURL.path, sessionOptions: options)
          let inputs = try session.inputNames()
          let outputs = try session.outputNames()
          guard let inputName = inputs.first, outputs.count >= 2 else {
            throw ONNXSegmentationError.invalidModelOutput
        }
        _ = environment
        let result = SegmentationModelSession(session: session, inputName: inputName,
                                              detectionOutputName: outputs[0],
                                              prototypeOutputName: outputs[1])
        loadedSession = result
        return result
    }
}