import CoreGraphics
import CoreImage
import Foundation
import OnnxRuntimeBindings

enum ReIDModelKind: String, CaseIterable, Hashable, Sendable {
    case person
    case vehicle

    var fileName: String {
        switch self {
        case .person: "yolo26m-reid.onnx"
        case .vehicle: "osnet_ain_x1_0_vehicle_reid.onnx"
        }
    }

    var width: Int { self == .person ? 128 : 208 }
    var height: Int { self == .person ? 256 : 208 }
    var usesImageNetNormalization: Bool { self == .vehicle }
    var environmentKey: String { self == .person ? "CAMERAWALL_REID_PERSON_MODEL" : "CAMERAWALL_REID_VEHICLE_MODEL" }

    static func forLabel(_ label: String) -> ReIDModelKind? {
        if label == "person" { return .person }
        if ["bicycle", "car", "motorcycle", "bus", "train", "truck", "boat"].contains(label) {
            return .vehicle
        }
        return nil
    }
}

enum ONNXReIDError: LocalizedError {
    case modelMissing(String)
    case invalidImage
    case invalidModelOutput(Int)
    case coreMLUnavailable

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): return "Missing ReID model \(name). Run make -C native reid-models."
        case .invalidImage: return "Could not decode crop for local ReID inference."
        case .invalidModelOutput(let count): return "Expected a 512-value ReID embedding, got \(count)."
        case .coreMLUnavailable: return "ONNX Runtime CoreML provider is not available on this Mac."
        }
    }
}

private struct ONNXModelSession {
    let session: ORTSession
    let inputName: String
    let outputName: String
}

final class ONNXReIDEncoder: @unchecked Sendable {
    static let shared: ONNXReIDEncoder? = try? ONNXReIDEncoder()

    private let environment: ORTEnv
    private let sessionLock = NSLock()
    private let cacheLock = NSLock()
    private var sessions: [ReIDModelKind: ONNXModelSession] = [:]
    private var embeddingCache: [UUID: [Float]] = [:]

    init() throws {
        guard ORTIsCoreMLExecutionProviderAvailable() else { throw ONNXReIDError.coreMLUnavailable }
        environment = try ORTEnv(loggingLevel: .error)
    }

    func prepare(_ kind: ReIDModelKind) throws {
        _ = try session(for: kind)
    }

    static func modelURL(for kind: ReIDModelKind) -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment[kind.environmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(kind.fileName))
        }
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(nativeRoot.appendingPathComponent(".build/models/\(kind.fileName)"))
        let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(working.appendingPathComponent("native/.build/models/\(kind.fileName)"))
        candidates.append(working.appendingPathComponent(".build/models/\(kind.fileName)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func preprocess(_ jpeg: Data, kind: ReIDModelKind) throws -> [Float] {
        guard let image = CIImage(data: jpeg), !image.extent.isEmpty else { throw ONNXReIDError.invalidImage }
        let extent = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = CGAffineTransform(scaleX: CGFloat(kind.width) / extent.width,
                                      y: CGFloat(kind.height) / extent.height)
        let resized = normalized.transformed(by: scale)
        let bounds = CGRect(x: 0, y: 0, width: kind.width, height: kind.height)
        guard let cgImage = CIContext(options: [.cacheIntermediates: false]).createCGImage(resized, from: bounds) else {
            throw ONNXReIDError.invalidImage
        }

        let bytesPerRow = kind.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * kind.height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drewImage = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: kind.width, height: kind.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: bounds)
            return true
        }
        guard drewImage else { throw ONNXReIDError.invalidImage }

        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        let planeSize = kind.width * kind.height
        var chw = [Float](repeating: 0, count: 3 * planeSize)
        for y in 0..<kind.height {
            for x in 0..<kind.width {
                let source = y * bytesPerRow + x * 4
                let target = y * kind.width + x
                for channel in 0..<3 {
                    var value = Float(pixels[source + channel]) / 255
                    if kind.usesImageNetNormalization {
                        value = (value - mean[channel]) / std[channel]
                    }
                    chw[channel * planeSize + target] = value
                }
            }
        }
        return chw
    }

    func embedding(jpeg: Data, trackID: UUID, label: String) throws -> [Float] {
        guard let kind = ReIDModelKind.forLabel(label) else { throw ONNXReIDError.invalidImage }
        cacheLock.lock()
        if let cached = embeddingCache[trackID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let features = try Self.preprocess(jpeg, kind: kind)
        let model = try session(for: kind)
        let tensorData = NSMutableData(bytes: features, length: features.count * MemoryLayout<Float>.size)
        let input = try ORTValue(tensorData: tensorData, elementType: .float,
                                 shape: [1, 3, kind.height, kind.width].map(NSNumber.init(value:)))
        let outputs = try model.session.run(withInputs: [model.inputName: input],
                                            outputNames: [model.outputName], runOptions: nil)
        guard let output = outputs[model.outputName] else { throw ONNXReIDError.invalidModelOutput(0) }
        let outputData = try output.tensorData()
        let outputCount = outputData.length / MemoryLayout<Float>.size
        let outputValues = outputData.bytes.assumingMemoryBound(to: Float.self)
        let values = Array(UnsafeBufferPointer(start: outputValues, count: outputCount))
        guard values.count == 512 else { throw ONNXReIDError.invalidModelOutput(values.count) }
        let norm = sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-8 else { throw ONNXReIDError.invalidModelOutput(values.count) }
        let normalized = values.map { $0 / norm }

        cacheLock.lock()
        if embeddingCache.count >= 1000 { embeddingCache.removeAll(keepingCapacity: true) }
        embeddingCache[trackID] = normalized
        cacheLock.unlock()
        return normalized
    }

    private func session(for kind: ReIDModelKind) throws -> ONNXModelSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let existing = sessions[kind] { return existing }
        guard let url = Self.modelURL(for: kind) else { throw ONNXReIDError.modelMissing(kind.fileName) }

        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        let coreMLOptions = ORTCoreMLExecutionProviderOptions()
        coreMLOptions.onlyAllowStaticInputShapes = true
        coreMLOptions.createMLProgram = true
        try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        let session = try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        guard let inputName = try session.inputNames().first,
              let outputName = try session.outputNames().first else {
            throw ONNXReIDError.invalidModelOutput(0)
        }
        let result = ONNXModelSession(session: session, inputName: inputName, outputName: outputName)
        sessions[kind] = result
        return result
    }
}