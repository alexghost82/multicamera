import CoreML
import CoreVideo
import CoreImage
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision
import CameraCore

struct PoseKeypoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
}

struct PoseBoundingBox: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct PosePerson: Equatable, Sendable {
    let confidence: Double
    let box: PoseBoundingBox
    let keypoints: [PoseKeypoint]
}

struct PoseInferenceResult: Sendable {
    let people: [PosePerson]
    let inferenceMilliseconds: Double
}

struct PoseLetterboxTransform: Equatable, Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let scale: Double
    let paddingX: Double
    let paddingY: Double
    let inputSize: Int

    func normalizedPoint(x: Double, y: Double) -> (Double, Double) {
        let sourceX = (x - paddingX) / scale
        let sourceY = (y - paddingY) / scale
        return (min(1, max(0, sourceX / Double(sourceWidth))),
                min(1, max(0, sourceY / Double(sourceHeight))))
    }

    func normalizedBox(left: Double, top: Double, right: Double, bottom: Double) -> PoseBoundingBox? {
        let first = normalizedPoint(x: left, y: top)
        let second = normalizedPoint(x: right, y: bottom)
        guard second.0 > first.0, second.1 > first.1 else { return nil }
        return PoseBoundingBox(x: first.0, y: first.1, width: second.0 - first.0, height: second.1 - first.1)
    }
}

enum YOLO26PoseDetectorError: Error, LocalizedError {
    case modelUnavailable
    case unsupportedModel
    case unsupportedOutput
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "The configured YOLO26s Pose Core ML model is unavailable."
        case .unsupportedModel: return "Expected a compiled Core ML model or an official .mlpackage."
        case .unsupportedOutput: return "YOLO26s Pose returned an unsupported output shape."
        case .invalidFrame: return "The worker received an invalid video frame."
        }
    }
}

final class YOLO26PoseDetector: @unchecked Sendable {
    static let modelIdentifier = "yolo26s-pose-fp16-640"
    static let inputSize = 640
    static let keypointCount = 17

    private let modelURL: URL
    private let queue = DispatchQueue(label: "CameraWall.YOLO26Pose", qos: .utility)
    private let lock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var busy = false
    private var model: VNCoreMLModel?

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    _ = try loadedModel()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func submit(pixel: CVPixelBuffer, threshold: Double,
                completion: @escaping @Sendable (Result<PoseInferenceResult, Error>) -> Void) -> Bool {
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true
        lock.unlock()
        queue.async { [self] in
            let result = Result { try detect(pixel: pixel, threshold: threshold) }
            lock.lock()
            busy = false
            lock.unlock()
            completion(result)
        }
        return true
    }

    func detect(pixel: CVPixelBuffer, threshold: Double) throws -> PoseInferenceResult {
        guard threshold.isFinite, (0...1).contains(threshold) else { throw ConfigurationError.invalid("Invalid pose confidence threshold.") }
        let started = ProcessInfo.processInfo.systemUptime
        let prepared = try letterbox(pixel)
        let request = VNCoreMLRequest(model: try loadedModel())
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cvPixelBuffer: prepared.pixel, orientation: .up).perform([request])
        guard let tensor = (request.results as? [VNCoreMLFeatureValueObservation])?
            .compactMap({ $0.featureValue.multiArrayValue }).first else {
            throw YOLO26PoseDetectorError.unsupportedOutput
        }
        let people = try Self.decode(tensor, transform: prepared.transform, threshold: threshold)
        return PoseInferenceResult(people: people,
                                  inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    static func decode(_ tensor: MLMultiArray, transform: PoseLetterboxTransform,
                       threshold: Double) throws -> [PosePerson] {
        let shape = tensor.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[2] == 6 + keypointCount * 3,
              transform.sourceWidth > 0, transform.sourceHeight > 0,
              threshold.isFinite, (0...1).contains(threshold) else {
            throw YOLO26PoseDetectorError.unsupportedOutput
        }

        var people: [PosePerson] = []
        for row in 0..<shape[1] {
            let values = (0..<shape[2]).map { tensor[[0, NSNumber(value: row), NSNumber(value: $0)]].doubleValue }
            guard values.allSatisfy(\.isFinite), values[4] >= threshold, values[4] <= 1,
                  abs(values[5]) < 0.5,
                  let box = transform.normalizedBox(left: values[0], top: values[1],
                                                    right: values[2], bottom: values[3]) else { continue }
            var keypoints: [PoseKeypoint] = []
            keypoints.reserveCapacity(keypointCount)
            for index in 0..<keypointCount {
                let offset = 6 + index * 3
                let point = transform.normalizedPoint(x: values[offset], y: values[offset + 1])
                keypoints.append(PoseKeypoint(x: point.0, y: point.1,
                                              confidence: min(1, max(0, values[offset + 2]))))
            }
            people.append(PosePerson(confidence: values[4], box: box, keypoints: keypoints))
        }
        return people
    }

    private func loadedModel() throws -> VNCoreMLModel {
        if let model { return model }
        let compiledURL = try Self.compiledModelURL(for: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let coreModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        guard coreModel.modelDescription.inputDescriptionsByName.values.contains(where: { $0.imageConstraint != nil }),
              coreModel.modelDescription.outputDescriptionsByName.values.contains(where: { $0.multiArrayConstraint != nil }) else {
            throw YOLO26PoseDetectorError.unsupportedModel
        }
        let visionModel = try VNCoreMLModel(for: coreModel)
        model = visionModel
        return visionModel
    }

    private func letterbox(_ pixel: CVPixelBuffer) throws -> (pixel: CVPixelBuffer, transform: PoseLetterboxTransform) {
        let sourceWidth = CVPixelBufferGetWidth(pixel)
        let sourceHeight = CVPixelBufferGetHeight(pixel)
        guard sourceWidth > 0, sourceHeight > 0 else { throw YOLO26PoseDetectorError.invalidFrame }
        let scale = min(Double(Self.inputSize) / Double(sourceWidth), Double(Self.inputSize) / Double(sourceHeight))
        let scaledWidth = Double(sourceWidth) * scale
        let scaledHeight = Double(sourceHeight) * scale
        let paddingX = (Double(Self.inputSize) - scaledWidth) / 2
        let paddingY = (Double(Self.inputSize) - scaledHeight) / 2
        let transform = PoseLetterboxTransform(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                               scale: scale, paddingX: paddingX, paddingY: paddingY,
                                               inputSize: Self.inputSize)
        let target = CGRect(x: 0, y: 0, width: CGFloat(Self.inputSize), height: CGFloat(Self.inputSize))
        let source = CIImage(cvPixelBuffer: pixel).transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        )
        let offset = CGAffineTransform(translationX: CGFloat(paddingX) - source.extent.minX,
                                       y: CGFloat(paddingY) - source.extent.minY)
        let background = CIImage(color: CIColor(red: 114.0 / 255.0, green: 114.0 / 255.0, blue: 114.0 / 255.0))
            .cropped(to: target)
        let canvas = source.transformed(by: offset).composited(over: background).cropped(to: target)
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.inputSize, Self.inputSize,
                                  kCVPixelFormatType_32BGRA, attributes, &output) == kCVReturnSuccess,
              let output else { throw YOLO26PoseDetectorError.invalidFrame }
        imageContext.render(canvas, to: output, bounds: target, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (output, transform)
    }

    private static func compiledModelURL(for url: URL) throws -> URL {
        if url.pathExtension == "mlmodelc" {
            guard FileManager.default.fileExists(atPath: url.path) else { throw YOLO26PoseDetectorError.modelUnavailable }
            return url
        }
        guard url.pathExtension == "mlpackage" else { throw YOLO26PoseDetectorError.unsupportedModel }
        let coreMLDirectory = url.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        let modelFile = coreMLDirectory.appendingPathComponent("model.mlmodel")
        let weightsFile = coreMLDirectory.appendingPathComponent("weights/weight.bin")
        guard FileManager.default.fileExists(atPath: modelFile.path),
              FileManager.default.fileExists(atPath: weightsFile.path) else {
            throw YOLO26PoseDetectorError.modelUnavailable
        }
        let digest = SHA256.hash(data: try Data(contentsOf: modelFile) + Data(contentsOf: weightsFile))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let destination = cacheDirectory.appendingPathComponent("yolo26s-pose-\(digest).mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let compiled = try MLModel.compileModel(at: url)
        do { try FileManager.default.copyItem(at: compiled, to: destination) }
        catch where FileManager.default.fileExists(atPath: destination.path) {}
        return destination
    }
}