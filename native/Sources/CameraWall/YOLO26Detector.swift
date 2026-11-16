import Foundation
import CoreML
import Vision
import CoreVideo
import CameraCore

struct DetectionResult: Sendable {
    var objects: [DetectedObject]
    var inferenceMilliseconds: Double
}

final class YOLO26Detector: @unchecked Sendable {
    static let modelIdentifier = "yolo26n-detect"
    private let queue = DispatchQueue(label: "CameraWall.YOLO26", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var model: VNCoreMLModel?
    private var inputSize = CGSize(width: 640, height: 640)

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

    func resetModel() {
        queue.async { [self] in model = nil }
    }

    static var defaultModelURL: URL? {
        if let selected = ModelSelectionRegistry.path(.yolo) { return selected }
        let modelDirectory = "yolo26n.mlmodelc"
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CAMERAWALL_YOLO_MODEL"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(modelDirectory, isDirectory: true))
        }
        candidates.append(contentsOf: [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(modelDirectory)", isDirectory: true),
            sourceRoot.appendingPathComponent(".build/models/\(modelDirectory)", isDirectory: true),
            workingDirectory.appendingPathComponent(".build/models/\(modelDirectory)", isDirectory: true),
            workingDirectory.appendingPathComponent("native/.build/models/\(modelDirectory)", isDirectory: true)
        ])

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("coremldata.bin").path)
        }
    }

    @discardableResult
    func submit(pixel: CVPixelBuffer, threshold: Double, completion: @escaping @Sendable (Result<DetectionResult, Error>) -> Void) -> Bool {
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

    func detect(pixel: CVPixelBuffer, threshold: Double) throws -> DetectionResult {
        try ModelSelectionRegistry.require(.yolo)
        let visionModel = try loadedModel()
        let started = ProcessInfo.processInfo.systemUptime
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up).perform([request])
        let objects: [DetectedObject]
        if let recognized = request.results as? [VNRecognizedObjectObservation], !recognized.isEmpty {
            objects = recognized.enumerated().compactMap { index, object in
                guard let label = object.labels.first, Double(label.confidence) >= threshold else { return nil }
                return DetectedObject(id: index, label: label.identifier, confidence: Double(label.confidence), box: object.boundingBox)
            }
        } else if let tensor = (request.results as? [VNCoreMLFeatureValueObservation])?.compactMap({ $0.featureValue.multiArrayValue }).first {
            objects = try Self.decode(tensor, input: inputSize, threshold: threshold)
        } else {
            throw ConfigurationError.invalid("YOLO26 produced an unsupported output. Use the official YOLO26n detect Core ML model.")
        }
        return DetectionResult(objects: objects, inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    private func loadedModel() throws -> VNCoreMLModel {
        if let model { return model }
        guard let url = Self.defaultModelURL else {
            throw ConfigurationError.invalid("YOLO26 model missing. Run make -C native model and rebuild the app.")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let coreModel = try MLModel(contentsOf: url, configuration: configuration)
        if let image = coreModel.modelDescription.inputDescriptionsByName.values.compactMap(\.imageConstraint).first {
            inputSize = CGSize(width: image.pixelsWide, height: image.pixelsHigh)
        }
        let visionModel = try VNCoreMLModel(for: coreModel)
        model = visionModel
        return visionModel
    }

    static func decode(_ tensor: MLMultiArray, input: CGSize, threshold: Double) throws -> [DetectedObject] {
        let shape = tensor.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[2] == 6, input.width > 0, input.height > 0 else {
            throw ConfigurationError.invalid("Expected YOLO26 NMS-free output [1, N, 6].")
        }
        var objects: [DetectedObject] = []
        for row in 0..<shape[1] {
            let values = (0..<6).map { tensor[[0, NSNumber(value: row), NSNumber(value: $0)]].doubleValue }
            guard values.allSatisfy(\.isFinite), values[4] >= threshold,
                  values[4] <= 1, values[5] >= 0, values[5] < Double(labels.count) else { continue }
            let left = max(0, min(1, values[0] / input.width))
            let top = max(0, min(1, values[1] / input.height))
            let right = max(0, min(1, values[2] / input.width))
            let bottom = max(0, min(1, values[3] / input.height))
            guard right > left, bottom > top else { continue }
            objects.append(DetectedObject(id: row, label: labels[Int(values[5])], confidence: values[4],
                box: CGRect(x: left, y: 1 - bottom, width: right - left, height: bottom - top)))
        }
        return objects.sorted { $0.confidence > $1.confidence }
    }

    private static let labels = "person,bicycle,car,motorcycle,airplane,bus,train,truck,boat,traffic light,fire hydrant,stop sign,parking meter,bench,bird,cat,dog,horse,sheep,cow,elephant,bear,zebra,giraffe,backpack,umbrella,handbag,tie,suitcase,frisbee,skis,snowboard,sports ball,kite,baseball bat,baseball glove,skateboard,surfboard,tennis racket,bottle,wine glass,cup,fork,knife,spoon,bowl,banana,apple,sandwich,orange,broccoli,carrot,hot dog,pizza,donut,cake,chair,couch,potted plant,bed,dining table,toilet,tv,laptop,mouse,remote,keyboard,cell phone,microwave,oven,toaster,sink,refrigerator,book,clock,vase,scissors,teddy bear,hair drier,toothbrush".components(separatedBy: ",")
}