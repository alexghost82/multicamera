import Foundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
@_exported import Tokenizers

enum LocalVLMError: LocalizedError {
    case invalidImage
    case modelNotFound(String)
    case emptyResponse
    case invalidResponse
    case invalidStructuredResponse
    case unexpectedResponseLanguage
    case invalidResponseCharacters
    case unsupportedQuestionLanguage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not encode the camera frame as JPEG."
        case .modelNotFound(let path): return "The native VLM model was not found at \(path)."
        case .emptyResponse: return "The native VLM returned an empty response."
        case .invalidResponse: return "The native VLM response could not be processed."
        case .invalidStructuredResponse: return "The local model did not return a complete JSON answer. Retry the request."
        case .unexpectedResponseLanguage: return "The local model answered in a different language. Retry the request."
        case .invalidResponseCharacters: return "The local model returned unsupported symbols or service tokens. Retry the request."
        case .unsupportedQuestionLanguage: return "Could not determine the question language. Ask a complete question in Russian, Hebrew or English."
        }
    }
}

final class LocalVLMClient {
    static let maximumEvidenceImageBytes = 1_000_000
    static let maximumBatchImages = 4

    private let model: String

    init(model: String) {
        self.model = model
    }

    func prepare() async throws {
        try await NativeVLMEngine.shared.prepare(model: model)
    }

    func analyze(image: Data, prompt: String) async throws -> String {
        try await NativeVLMEngine.shared.analyze(image: image, prompt: prompt, model: model)
    }

    func analyze(images: [Data], prompt: String) async throws -> String {
        try await NativeVLMEngine.shared.analyze(images: images, prompt: prompt, model: model)
    }

    func analyze(text: String) async throws -> String {
        try await NativeVLMEngine.shared.analyze(image: nil, prompt: text, model: model)
    }
}

private actor NativeVLMEngine {
    static let shared = NativeVLMEngine()

    private var container: ModelContainer?
    private var loadedModelPath: String?
    private var pendingLoads: [String: Task<ModelContainer, Error>] = [:]

    func prepare(model: String) async throws {
        _ = try await loadContainer(model: model)
    }

    func analyze(image: Data?, prompt: String, model: String) async throws -> String {
        try await analyze(images: image.map { [$0] } ?? [], prompt: prompt, model: model)
    }

    func analyze(images: [Data], prompt: String, model: String) async throws -> String {
                  guard images.count <= LocalVLMClient.maximumBatchImages,
              images.allSatisfy({ $0.count <= LocalVLMClient.maximumEvidenceImageBytes }) else {
            throw LocalVLMError.invalidResponse
        }
        let container = try await loadContainer(model: model)
        try Task.checkCancellation()
                var imageURLs: [URL] = []
        defer { imageURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
                for image in images { imageURLs.append(try writeTemporaryImage(image)) }
                let inputImageURLs = imageURLs

                let parameters = GenerateParameters(maxTokens: images.count > 1 ? 1536 : 1024, temperature: 0.1)
        let response = try await container.perform { context in
                    var input = UserInput(prompt: prompt, images: inputImageURLs.map { .url($0) })
            input.additionalContext = ["enable_thinking": false]
            input.processing.resize = .init(width: 1024, height: 1024)
            let prepared = try await context.processor.prepare(input: input)
            var output = ""
            for await event in try MLXLMCommon.generate(
                input: prepared,
                parameters: parameters,
                context: context
            ) {
                try Task.checkCancellation()
                if case .chunk(let text) = event { output += text }
            }
            return output
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalVLMError.emptyResponse }
        return trimmed
    }

    private func loadContainer(model: String) async throws -> ModelContainer {
        let modelURL = resolveModelURL(model)
        let path = modelURL.path
        if loadedModelPath == path, let container { return container }
        if let pending = pendingLoads[path] { return try await pending.value }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalVLMError.modelNotFound(modelURL.path)
        }
        let pending = Task {
            try await VLMModelFactory.shared.loadContainer(
                from: modelURL,
                using: #huggingFaceTokenizerLoader()
            )
        }
        pendingLoads[path] = pending
        defer { pendingLoads[path] = nil }
        let loaded = try await pending.value
        container = loaded
        loadedModelPath = path
        return loaded
    }

    private func resolveModelURL(_ model: String) -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("qwen3.5-9b", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: model, isDirectory: true).standardizedFileURL
    }

    private func writeTemporaryImage(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraWall-VLM", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

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
        guard let cgImage = context.createCGImage(resized, from: resized.extent) else {
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
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}
