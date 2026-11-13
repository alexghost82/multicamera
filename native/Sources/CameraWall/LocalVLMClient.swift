import Foundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import MLX
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

/// Operator-initiated requests are `interactive`; periodic and automatic work is `background`.
/// Background work never occupies every model instance, so operator requests run alongside it.
enum VLMWorkload: Sendable {
    case interactive
    case background
}

final class LocalVLMClient {
    static let maximumEvidenceImageBytes = 1_000_000
    static let maximumBatchImages = 4

    private let model: String
    private let workload: VLMWorkload

    init(model: String, workload: VLMWorkload = .background) {
        self.model = model
        self.workload = workload
    }

    func prepare() async throws {
        try await NativeVLMEngine.shared.prepare(model: model)
    }

    func analyze(image: Data, prompt: String) async throws -> String {
        try await NativeVLMEngine.shared.analyze(images: [image], prompt: prompt, model: model, workload: workload)
    }

    func analyze(images: [Data], prompt: String) async throws -> String {
        try await NativeVLMEngine.shared.analyze(images: images, prompt: prompt, model: model, workload: workload)
    }

    func analyze(text: String) async throws -> String {
        try await NativeVLMEngine.shared.analyze(images: [], prompt: text, model: model, workload: workload)
    }
}

/// A bounded set of independently loaded resources (model instances) shared by concurrent requests.
/// Interactive requests may use every instance; background requests are limited to `capacity - 1`
/// when more than one instance fits, keeping one instance available for the operator.
actor VLMInstancePool<Resource: Sendable> {
    struct Lease: Sendable {
        let slot: Int
        let resource: Resource
    }

    private struct Slot {
        var resource: Resource?
        var workload: VLMWorkload?
        var idleToken = UUID()
    }

    private struct Waiter {
        let id: UUID
        let workload: VLMWorkload
        let continuation: CheckedContinuation<Int, Error>
    }

    let capacity: Int
    private let idleEviction: Duration?
    private let load: @Sendable () async throws -> Resource
    private let evicted: @Sendable () -> Void
    private var slots: [Slot] = []
    private var waiters: [Waiter] = []

    init(capacity: Int, idleEviction: Duration? = nil,
         load: @escaping @Sendable () async throws -> Resource,
         evicted: @escaping @Sendable () -> Void = {}) {
        self.capacity = max(1, capacity)
        self.idleEviction = idleEviction
        self.load = load
        self.evicted = evicted
    }

    var backgroundLimit: Int { capacity > 1 ? capacity - 1 : 1 }
    var loadedCount: Int { slots.filter { $0.resource != nil }.count }
    var activeCount: Int { slots.filter { $0.workload != nil }.count }

    func acquire(_ workload: VLMWorkload) async throws -> Lease {
        try Task.checkCancellation()
        let slot: Int
        if let reserved = reserve(workload) {
            slot = reserved
        } else {
            let id = UUID()
            slot = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, workload: workload, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
        do {
            if let resource = slots[slot].resource { return Lease(slot: slot, resource: resource) }
            let resource = try await load()
            slots[slot].resource = resource
            return Lease(slot: slot, resource: resource)
        } catch {
            release(slot)
            throw error
        }
    }

    func release(_ slot: Int) {
        guard slots.indices.contains(slot), slots[slot].workload != nil else { return }
        slots[slot].workload = nil
        let token = UUID()
        slots[slot].idleToken = token
        dispatchWaiters()
        if slot > 0, slots[slot].workload == nil, slots[slot].resource != nil, let idleEviction {
            Task { [weak self] in
                try? await Task.sleep(for: idleEviction)
                await self?.evictIfIdle(slot, token: token)
            }
        }
    }

    private func reserve(_ workload: VLMWorkload) -> Int? {
        if workload == .background,
           slots.filter({ $0.workload == .background }).count >= backgroundLimit { return nil }
        let index = slots.indices.first { slots[$0].workload == nil && slots[$0].resource != nil }
            ?? slots.indices.first { slots[$0].workload == nil }
        if let index {
            slots[index].workload = workload
            return index
        }
        guard slots.count < capacity else { return nil }
        slots.append(Slot(resource: nil, workload: workload))
        return slots.count - 1
    }

    private func dispatchWaiters() {
        for priority in [VLMWorkload.interactive, .background] {
            for waiter in waiters where waiter.workload == priority {
                guard let slot = reserve(priority) else { continue }
                waiters.removeAll { $0.id == waiter.id }
                waiter.continuation.resume(returning: slot)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func evictIfIdle(_ slot: Int, token: UUID) {
        guard slots.indices.contains(slot), slots[slot].workload == nil,
              slots[slot].idleToken == token, slots[slot].resource != nil else { return }
        slots[slot].resource = nil
        evicted()
    }
}

private actor NativeVLMEngine {
    static let shared = NativeVLMEngine()
    static let extraInstanceIdleSeconds = 180

    /// Each Qwen3.5-9B 4-bit instance needs roughly 7 GB including runtime buffers; keep about
    /// 10 GB for macOS, video decoding and detection models.
    static var instanceCapacity: Int {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return min(3, max(1, Int((gigabytes - 10) / 7)))
    }

    private var pools: [String: VLMInstancePool<ModelContainer>] = [:]

    func prepare(model: String) async throws {
        let pool = try pool(for: model)
        let lease = try await pool.acquire(.interactive)
        await pool.release(lease.slot)
    }

    func analyze(images: [Data], prompt: String, model: String, workload: VLMWorkload) async throws -> String {
        guard images.count <= LocalVLMClient.maximumBatchImages,
              images.allSatisfy({ $0.count <= LocalVLMClient.maximumEvidenceImageBytes }) else {
            throw LocalVLMError.invalidResponse
        }
        let pool = try pool(for: model)
        let lease = try await pool.acquire(workload)
        do {
            let response = try await Self.generate(images: images, prompt: prompt, container: lease.resource)
            await pool.release(lease.slot)
            return response
        } catch {
            await pool.release(lease.slot)
            throw error
        }
    }

    private static func generate(images: [Data], prompt: String, container: ModelContainer) async throws -> String {
        try Task.checkCancellation()
        var imageURLs: [URL] = []
        defer { imageURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        for image in images { imageURLs.append(try writeTemporaryImage(image)) }
        let inputImageURLs = imageURLs

        let parameters = GenerateParameters(maxTokens: images.count > 1 ? 1536 : 1024, temperature: 0.1)
        // A private GPU stream per request lets concurrent instances interleave on the GPU.
        let response = try await MLX.Stream.withNewDefaultStream(device: .gpu) {
            try await container.perform { context in
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
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalVLMError.emptyResponse }
        return trimmed
    }

    private func pool(for model: String) throws -> VLMInstancePool<ModelContainer> {
        let modelURL = resolveModelURL(model)
        let path = modelURL.path
        if let pool = pools[path] { return pool }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LocalVLMError.modelNotFound(path)
        }
        let pool = VLMInstancePool<ModelContainer>(
            capacity: Self.instanceCapacity,
            idleEviction: .seconds(Self.extraInstanceIdleSeconds),
            load: {
                try await VLMModelFactory.shared.loadContainer(
                    from: modelURL,
                    using: #huggingFaceTokenizerLoader()
                )
            },
            evicted: { MLX.Memory.clearCache() }
        )
        // Requests already holding an instance of a replaced model finish with it.
        pools = [path: pool]
        return pool
    }

    private func resolveModelURL(_ model: String) -> URL {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("qwen3.5-9b", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: model, isDirectory: true).standardizedFileURL
    }

    private static func writeTemporaryImage(_ data: Data) throws -> URL {
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
