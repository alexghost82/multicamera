import CameraCore
import Foundation

// MARK: - 1. Errors & Configuration

public enum ACTALocalVLLMError: LocalizedError, Equatable, Sendable {
    case invalidLoopbackEndpoint
    case serverNotInstalled
    case serverUnavailable(String)
    case modelMismatch(expected: String, loaded: [String])
    case backpressureRejected
    case requestFailed(statusCode: Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidLoopbackEndpoint:
            return "VLLM_INVALID_ENDPOINT: Local vLLM Metal requires a loopback 127.0.0.1 or localhost URL."
        case .serverNotInstalled:
            return "VLLM_NOT_INSTALLED: Local vLLM Metal binary was not found in Homebrew paths."
        case .serverUnavailable(let detail):
            return "VLLM_UNAVAILABLE: \(detail)"
        case .modelMismatch(let expected, let loaded):
            return "VLLM_MODEL_MISMATCH: Expected model '\(expected)', loaded: \(loaded.joined(separator: ", "))."
        case .backpressureRejected:
            return "VLLM_BACKPRESSURE: Local vLLM Metal queue is full; background request was shed to protect interactive latency."
        case .requestFailed(let code):
            return "VLLM_HTTP_ERROR: Local vLLM Metal returned HTTP \(code)."
        case .invalidResponse:
            return "VLLM_INVALID_RESPONSE: Local vLLM Metal returned an unreadable response."
        }
    }
}

public enum ACTALocalVLLMServerState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case degraded
    case error
}

public struct ACTALocalVLLMTelemetrySnapshot: Equatable, Sendable {
    public let state: ACTALocalVLLMServerState
    public let loadedModel: String?
    public let activeInteractiveRequests: Int
    public let activeBackgroundRequests: Int
    public let queuedRequests: Int
    public let lastTTFTMs: Double?
    public let lastTokensPerSecond: Double?
    public let p50LatencyMs: Double?
    public let p95LatencyMs: Double?
    public let lastError: String?

    public static let stopped = ACTALocalVLLMTelemetrySnapshot(
        state: .stopped,
        loadedModel: nil,
        activeInteractiveRequests: 0,
        activeBackgroundRequests: 0,
        queuedRequests: 0,
        lastTTFTMs: nil,
        lastTokensPerSecond: nil,
        p50LatencyMs: nil,
        p95LatencyMs: nil,
        lastError: nil
    )
}

public struct ACTALocalVLLMLaunchConfig: Equatable, Sendable {
    public let modelPath: String
    public let servedModelName: String
    public let port: Int
    public let maxModelLen: Int
    public let maxNumSeqs: Int
    public let gpuMemoryUtilization: Double
    public let toolCallParser: String

    public init(
        modelPath: String,
        servedModelName: String = "qwen3.5-9b",
        port: Int = 8000,
        maxModelLen: Int = 8192,
        maxNumSeqs: Int = 4,
        gpuMemoryUtilization: Double = 0.65,
        toolCallParser: String = "qwen3_coder"
    ) {
        self.modelPath = modelPath
        self.servedModelName = servedModelName
        self.port = max(1024, min(65535, port))
        self.maxModelLen = max(1024, min(32768, maxModelLen))
        self.maxNumSeqs = max(1, min(16, maxNumSeqs))
        self.gpuMemoryUtilization = max(0.30, min(0.90, gpuMemoryUtilization))
        self.toolCallParser = toolCallParser
    }

    public var loopbackBaseURL: String {
        "http://127.0.0.1:\(port)/v1"
    }
}

// MARK: - 2. SSE Stream & OpenAI Tool-Call Parser

public struct ACTALocalVLLMStreamParseResult: Equatable, Sendable {
    public let content: String
    public let toolCalls: [ACTAAgentFunctionCall]
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let chunkCount: Int
}

/// Incremental parser for OpenAI-compatible `/v1/chat/completions` SSE streams (`stream: true`).
/// Accumulates both streamed text chunks and indexed `delta.tool_calls` fragments.
public struct ACTALocalVLLMSSEParser: Sendable {
    private struct PartialToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    private var lineBuffer = ""
    private var contentParts: [String] = []
    private var partialToolCalls: [Int: PartialToolCall] = [:]
    private var promptTokens: Int?
    private var completionTokens: Int?
    private var chunkCount = 0
    private(set) var finished = false

    public init() {}

    /// Feeds raw UTF-8 text from an SSE stream and returns any newly decoded visible content chunks.
    public mutating func feed(_ chunk: String) -> [String] {
        guard !finished else { return [] }
        lineBuffer.append(chunk)
        var emitted: [String] = []
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(...newline)
            if let text = processLine(line) {
                emitted.append(text)
            }
        }
        return emitted
    }

    public mutating func finalize() -> ACTALocalVLLMStreamParseResult {
        if !lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = processLine(lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            lineBuffer = ""
        }
        let sortedCalls: [ACTAAgentFunctionCall] = partialToolCalls.keys.sorted().compactMap { idx in
            guard let item = partialToolCalls[idx], !item.name.isEmpty else { return nil }
            let rawArgs = item.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedArgs = rawArgs.isEmpty ? "{}" : rawArgs
            return ACTAAgentFunctionCall(
                callID: item.id.isEmpty ? "call_vllm_\(UUID().uuidString.prefix(12))" : item.id,
                name: item.name,
                argumentsJSON: normalizedArgs,
                rawArgumentsJSON: normalizedArgs
            )
        }
        return ACTALocalVLLMStreamParseResult(
            content: contentParts.joined(),
            toolCalls: sortedCalls,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            chunkCount: chunkCount
        )
    }

    private mutating func processLine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" {
            finished = true
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let usage = root["usage"] as? [String: Any] {
            if let pt = usage["prompt_tokens"] as? Int { promptTokens = pt }
            if let ct = usage["completion_tokens"] as? Int { completionTokens = ct }
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return nil
        }
        if let tcArray = delta["tool_calls"] as? [[String: Any]] {
            chunkCount += 1
            for entry in tcArray {
                let idx = (entry["index"] as? Int) ?? 0
                var current = partialToolCalls[idx] ?? PartialToolCall(id: "", name: "", arguments: "")
                if let id = entry["id"] as? String, !id.isEmpty { current.id = id }
                if let fn = entry["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty { current.name += name }
                    if let args = fn["arguments"] as? String, !args.isEmpty { current.arguments += args }
                }
                partialToolCalls[idx] = current
            }
        }
        if let text = delta["content"] as? String, !text.isEmpty {
            chunkCount += 1
            contentParts.append(text)
            return text
        }
        return nil
    }

    /// Parses a non-streaming `/v1/chat/completions` JSON response (supporting both native `tool_calls` and text).
    public static func parseNonStreamingJSON(_ data: Data) throws -> ACTALocalVLLMStreamParseResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ACTALocalVLLMError.invalidResponse
        }
        let content = (message["content"] as? String) ?? ""
        var calls: [ACTAAgentFunctionCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for entry in rawCalls {
                guard let fn = entry["function"] as? [String: Any],
                      let name = fn["name"] as? String, !name.isEmpty else { continue }
                let callID = (entry["id"] as? String) ?? "call_vllm_\(UUID().uuidString.prefix(12))"
                let args: String
                if let str = fn["arguments"] as? String {
                    args = str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : str
                } else if let obj = fn["arguments"], JSONSerialization.isValidJSONObject(obj),
                          let encoded = try? JSONSerialization.data(withJSONObject: obj) {
                    args = String(decoding: encoded, as: UTF8.self)
                } else {
                    args = "{}"
                }
                calls.append(ACTAAgentFunctionCall(callID: callID, name: name, argumentsJSON: args, rawArgumentsJSON: args))
            }
        }
        let usage = root["usage"] as? [String: Any]
        return ACTALocalVLLMStreamParseResult(
            content: content,
            toolCalls: calls,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int,
            chunkCount: content.isEmpty && calls.isEmpty ? 0 : 1
        )
    }
}

// MARK: - 3. Priority Bounded Concurrency & Backpressure Limiter

/// Bounded parallel concurrency scheduler for local vLLM Metal.
/// Reserves interactive slots for operator voice/chat, prioritizes interactive waiters,
/// and sheds overflowing background requests with `.backpressureRejected`.
public actor ACTALocalVLLMLaneLimiter {
    public enum Priority: Sendable {
        case interactive
        case background
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }

    public private(set) var maxTotalConcurrency: Int
    public private(set) var reservedInteractiveSlots: Int
    public let maxQueueDepth: Int

    private var activeInteractive = 0
    private var activeBackground = 0
    private var waiters: [Waiter] = []

    public init(maxTotalConcurrency: Int = 4, reservedInteractiveSlots: Int = 1, maxQueueDepth: Int = 8) {
        let clamped = max(1, min(16, maxTotalConcurrency))
        self.maxTotalConcurrency = clamped
        self.reservedInteractiveSlots = max(0, min(reservedInteractiveSlots, max(0, clamped - 1)))
        self.maxQueueDepth = max(1, maxQueueDepth)
    }

    public func updateMaxTotalConcurrency(_ newMax: Int) {
        let clamped = max(1, min(16, newMax))
        maxTotalConcurrency = clamped
        reservedInteractiveSlots = clamped > 1 ? 1 : 0
        while dispatchNextWaiter() {}
    }

    public var maxBackgroundConcurrency: Int {
        max(1, maxTotalConcurrency - reservedInteractiveSlots)
    }

    public func counts() -> (interactive: Int, background: Int, queued: Int) {
        (activeInteractive, activeBackground, waiters.count)
    }

    public func withPermit<T: Sendable>(
        priority: Priority,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority: priority)
        defer { release(priority: priority) }
        return try await operation()
    }

    private func canRunImmediately(_ priority: Priority) -> Bool {
        let total = activeInteractive + activeBackground
        guard total < maxTotalConcurrency else { return false }
        switch priority {
        case .interactive:
            return true
        case .background:
            return activeBackground < maxBackgroundConcurrency
        }
    }

    private func acquire(priority: Priority) async throws {
        try Task.checkCancellation()
        if canRunImmediately(priority) {
            if priority == .interactive { activeInteractive += 1 } else { activeBackground += 1 }
            return
        }
        if priority == .background, waiters.count >= maxQueueDepth {
            throw ACTALocalVLLMError.backpressureRejected
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = Waiter(id: waiterID, priority: priority, continuation: continuation)
                if priority == .interactive {
                    let insertIndex = waiters.firstIndex(where: { $0.priority == .background }) ?? waiters.endIndex
                    waiters.insert(waiter, at: insertIndex)
                } else {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let removed = waiters.remove(at: idx)
        removed.continuation.resume(throwing: CancellationError())
    }

    private func release(priority: Priority) {
        if priority == .interactive {
            activeInteractive = max(0, activeInteractive - 1)
        } else {
            activeBackground = max(0, activeBackground - 1)
        }
        _ = dispatchNextWaiter()
    }

    @discardableResult
    private func dispatchNextWaiter() -> Bool {
        for index in waiters.indices {
            let candidate = waiters[index]
            if canRunImmediately(candidate.priority) {
                waiters.remove(at: index)
                if candidate.priority == .interactive { activeInteractive += 1 } else { activeBackground += 1 }
                candidate.continuation.resume()
                return true
            }
        }
        return false
    }
}

// MARK: - 4. Managed Local vLLM Metal Process Lifecycle

public protocol ACTALocalVLLMManagedProcess: Sendable {
    var isRunning: Bool { get }
    func terminateGracefully()
}

final class SystemACTALocalVLLMProcess: ACTALocalVLLMManagedProcess, @unchecked Sendable {
    static let candidatePaths = [
        "/opt/homebrew/bin/vllm",
        "/usr/local/bin/vllm"
    ]

    static func installedExecutablePath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private let process: Process

    var isRunning: Bool { process.isRunning }

    init(executablePath: String, config: ACTALocalVLLMLaunchConfig, apiKey: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = [
            "serve", config.modelPath,
            "--host", "127.0.0.1",
            "--port", String(config.port),
            "--served-model-name", config.servedModelName,
            "--api-key", apiKey,
            "--max-model-len", String(config.maxModelLen),
            "--max-num-seqs", String(config.maxNumSeqs),
            "--gpu-memory-utilization", String(format: "%.2f", config.gpuMemoryUtilization),
            "--enable-auto-tool-choice",
            "--tool-call-parser", config.toolCallParser
        ]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["VLLM_MLX_DEVICE"] = "gpu"
        env["VLLM_METAL_MULTIMODAL_MODE"] = "auto"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc
    }

    func terminateGracefully() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// Manages local loopback `vllm-metal` server lifecycle, health verification, per-launch bearer auth,
/// and rolling TTFT/throughput/latency telemetry.
public actor ACTALocalVLLMServerManager {
    public typealias ProcessFactory = @Sendable (ACTALocalVLLMLaunchConfig, String) throws -> any ACTALocalVLLMManagedProcess
    public typealias HTTPFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private var managedProcess: (any ACTALocalVLLMManagedProcess)?
    private var activeConfig: ACTALocalVLLMLaunchConfig?
    private var ephemeralAPIKey: String?
    private var state: ACTALocalVLLMServerState = .stopped
    private var loadedModel: String?
    private var lastError: String?
    private var lastTTFTMs: Double?
    private var lastTokPerSec: Double?
    private var latencySamplesMs: [Double] = []
    private let maxSamples = 64

    private let processFactory: ProcessFactory
    private let httpFetch: HTTPFetch
    public let limiter: ACTALocalVLLMLaneLimiter

    public init(
        maxConcurrentRequests: Int = 4,
        maxQueueDepth: Int = 8,
        processFactory: ProcessFactory? = nil,
        httpFetch: HTTPFetch? = nil
    ) {
        self.limiter = ACTALocalVLLMLaneLimiter(
            maxTotalConcurrency: maxConcurrentRequests,
            reservedInteractiveSlots: 1,
            maxQueueDepth: maxQueueDepth
        )
        self.processFactory = processFactory ?? { config, key in
            guard let executable = SystemACTALocalVLLMProcess.installedExecutablePath() else {
                throw ACTALocalVLLMError.serverNotInstalled
            }
            return try SystemACTALocalVLLMProcess(executablePath: executable, config: config, apiKey: key)
        }
        self.httpFetch = httpFetch ?? { request in
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: cfg)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ACTALocalVLLMError.invalidResponse
            }
            return (data, http)
        }
    }

    public static func generateEphemeralAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "acta-local-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func managedCredentials() -> (baseURL: String, modelName: String, apiKey: String)? {
        guard let config = activeConfig, let key = ephemeralAPIKey,
              managedProcess?.isRunning == true, state == .running else {
            return nil
        }
        return (config.loopbackBaseURL, config.servedModelName, key)
    }

    public func start(config: ACTALocalVLLMLaunchConfig, readinessTimeoutSeconds: TimeInterval = 90) async throws -> ACTALocalVLLMTelemetrySnapshot {
        stop()
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            state = .error
            lastError = "Model checkpoint not found at local path."
            throw ACTALocalVLLMError.serverUnavailable("Model checkpoint not found on disk.")
        }
        let key = Self.generateEphemeralAPIKey()
        state = .starting
        lastError = nil
        do {
            let process = try processFactory(config, key)
            managedProcess = process
            activeConfig = config
            ephemeralAPIKey = key
        } catch {
            state = .error
            lastError = error.localizedDescription
            throw error
        }

        let deadline = Date().addingTimeInterval(max(0.5, readinessTimeoutSeconds))
        while Date() < deadline {
            try Task.checkCancellation()
            guard managedProcess?.isRunning == true else {
                stop()
                state = .error
                lastError = "Local vLLM Metal process exited during startup."
                throw ACTALocalVLLMError.serverUnavailable("Process exited during startup.")
            }
            if let ok = try? await probeModelsEndpoint(
                baseURL: config.loopbackBaseURL,
                expectedModel: config.servedModelName,
                apiKey: key
            ), ok {
                state = .running
                loadedModel = config.servedModelName
                lastError = nil
                return await telemetrySnapshot()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        state = .error
        lastError = "Local vLLM Metal startup timed out."
        throw ACTALocalVLLMError.serverUnavailable("Startup timed out.")
    }

    public func stop() {
        managedProcess?.terminateGracefully()
        managedProcess = nil
        activeConfig = nil
        ephemeralAPIKey = nil
        loadedModel = nil
        state = .stopped
    }

    @discardableResult
    public func checkHealth(
        baseURL: String,
        expectedModel: String,
        apiKey: String? = nil
    ) async throws -> ACTALocalVLLMTelemetrySnapshot {
        guard let parsed = URL(string: baseURL), ACTAAIClient.isLoopbackURL(parsed) else {
            state = .error
            lastError = ACTALocalVLLMError.invalidLoopbackEndpoint.localizedDescription
            throw ACTALocalVLLMError.invalidLoopbackEndpoint
        }
        let token = apiKey ?? ephemeralAPIKey
        do {
            let matched = try await probeModelsEndpoint(baseURL: baseURL, expectedModel: expectedModel, apiKey: token)
            if matched {
                state = .running
                loadedModel = expectedModel
                lastError = nil
                return await telemetrySnapshot()
            } else {
                state = .degraded
                throw ACTALocalVLLMError.modelMismatch(expected: expectedModel, loaded: [])
            }
        } catch {
            state = .degraded
            lastError = error.localizedDescription
            throw error
        }
    }

    public func recordInferenceMetrics(ttftMs: Double, totalLatencyMs: Double, tokensPerSecond: Double) {
        lastTTFTMs = ttftMs
        lastTokPerSec = tokensPerSecond
        latencySamplesMs.append(totalLatencyMs)
        if latencySamplesMs.count > maxSamples {
            latencySamplesMs.removeFirst(latencySamplesMs.count - maxSamples)
        }
    }

    public func telemetrySnapshot() async -> ACTALocalVLLMTelemetrySnapshot {
        let counts = await limiter.counts()
        let sorted = latencySamplesMs.sorted()
        let p50: Double? = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        let p95: Double? = sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let currentState: ACTALocalVLLMServerState
        if managedProcess != nil, managedProcess?.isRunning == false, state == .running {
            currentState = .degraded
        } else {
            currentState = state
        }
        return ACTALocalVLLMTelemetrySnapshot(
            state: currentState,
            loadedModel: loadedModel,
            activeInteractiveRequests: counts.interactive,
            activeBackgroundRequests: counts.background,
            queuedRequests: counts.queued,
            lastTTFTMs: lastTTFTMs,
            lastTokensPerSecond: lastTokPerSec,
            p50LatencyMs: p50,
            p95LatencyMs: p95,
            lastError: lastError
        )
    }

    private func probeModelsEndpoint(baseURL: String, expectedModel: String, apiKey: String?) async throws -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/models"), ACTAAIClient.isLoopbackURL(url) else {
            throw ACTALocalVLLMError.invalidLoopbackEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await httpFetch(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ACTALocalVLLMError.requestFailed(statusCode: response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw ACTALocalVLLMError.invalidResponse
        }
        let ids = list.compactMap { $0["id"] as? String }
        if ids.contains(expectedModel) {
            return true
        }
        throw ACTALocalVLLMError.modelMismatch(expected: expectedModel, loaded: ids)
    }
}

// MARK: - 5. Streaming OpenAI-Compatible Local vLLM Metal Client

public final class ACTALocalVLLMClient: @unchecked Sendable {
    public typealias StreamTransport = @Sendable (URLRequest, @escaping @Sendable (String) -> Void) async throws -> Int

    private let serverManager: ACTALocalVLLMServerManager
    private let streamTransport: StreamTransport

    public init(
        serverManager: ACTALocalVLLMServerManager = ACTALocalVLLMServerManager(),
        streamTransport: StreamTransport? = nil
    ) {
        self.serverManager = serverManager
        self.streamTransport = streamTransport ?? { request, onChunk in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 180
            let session = URLSession(configuration: config)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ACTALocalVLLMError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                return http.statusCode
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                onChunk(line + "\n")
            }
            return http.statusCode
        }
    }

    public func telemetrySnapshot() async -> ACTALocalVLLMTelemetrySnapshot {
        await serverManager.telemetrySnapshot()
    }

    public func updateMaxConcurrency(_ maxConcurrent: Int) async {
        await serverManager.limiter.updateMaxTotalConcurrency(maxConcurrent)
    }

    public func withLanePermit<T: Sendable>(
        priority: ACTALocalVLLMLaneLimiter.Priority,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await serverManager.limiter.withPermit(priority: priority, operation: operation)
    }

    public func runAgentStep(
        baseURL: String,
        modelName: String,
        apiKey: String?,
        request: ACTAAgentRequest,
        priority: ACTALocalVLLMLaneLimiter.Priority = .interactive,
        authorization: (@Sendable () -> Bool)? = nil,
        onAnswerPreview: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> ACTAAgentTurnResult {
        guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/chat/completions"),
              ACTAAIClient.isLoopbackURL(url) else {
            throw ACTALocalVLLMError.invalidLoopbackEndpoint
        }
        let body = Self.buildChatCompletionsAgentBody(modelName: modelName, request: request, stream: true)
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let immutableRequest = httpRequest

        return try await serverManager.limiter.withPermit(priority: priority) {
            try Task.checkCancellation()
            guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }

            let startedAt = Date()
            let stateBox = LockedStreamState(onAnswerPreview: onAnswerPreview, authorization: authorization)

            let statusCode = try await withTaskCancellationHandler {
                try await self.streamTransport(immutableRequest) { rawSSEChunk in
                    stateBox.consumeSSE(rawSSEChunk, startedAt: startedAt)
                }
            } onCancel: {
                stateBox.closePreview()
            }

            try Task.checkCancellation()
            guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
            guard (200..<300).contains(statusCode) else {
                throw ACTALocalVLLMError.requestFailed(statusCode: statusCode)
            }

            let parsed = stateBox.finalize()
            let totalMs = Date().timeIntervalSince(startedAt) * 1000.0
            let ttftMs = stateBox.ttftMs ?? totalMs
            let completionTokens = parsed.completionTokens ?? max(1, parsed.chunkCount)
            let genSeconds = max(0.001, (totalMs - ttftMs) / 1000.0)
            await self.serverManager.recordInferenceMetrics(
                ttftMs: ttftMs,
                totalLatencyMs: totalMs,
                tokensPerSecond: Double(completionTokens) / genSeconds
            )

            // Prefer native OpenAI tool_calls; fall back to structured JSON tool call parsing if emitted in content
            if !parsed.toolCalls.isEmpty {
                let text = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return ACTAAgentTurnResult(
                    responseID: nil,
                    text: text.isEmpty ? nil : text,
                    functionCalls: parsed.toolCalls,
                    backend: .vllm
                )
            }
            let fallback = ACTAAIClient.parseLocalAgentReply(parsed.content)
            return ACTAAgentTurnResult(
                responseID: nil,
                text: fallback.text,
                functionCalls: fallback.calls,
                backend: .vllm
            )
        }
    }

    public static func buildChatCompletionsAgentBody(
        modelName: String,
        request: ACTAAgentRequest,
        stream: Bool
    ) -> [String: Any] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": request.instructions]
        ]
        for item in request.fullInput {
            switch item {
            case .user(let text, let images):
                if images.isEmpty {
                    messages.append(["role": "user", "content": text])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": text]]
                    for img in images.prefix(4) {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]
                        ])
                    }
                    messages.append(["role": "user", "content": parts])
                }
            case .assistantText(let text):
                messages.append(["role": "assistant", "content": text])
            case .functionCall(let call):
                messages.append([
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [[
                        "id": call.callID,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON
                        ]
                    ]]
                ])
            case .functionOutput(let callID, let output):
                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": output
                ])
            }
        }

        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": 0.1,
            "max_tokens": 2048,
            "stream": stream,
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        if stream {
            body["stream_options"] = ["include_usage": true]
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersObject
                    ]
                ]
            }
            switch request.toolChoice {
            case .auto:
                body["tool_choice"] = "auto"
            case .required:
                body["tool_choice"] = "required"
            case .function(let name):
                body["tool_choice"] = ["type": "function", "function": ["name": name]]
            }
        }
        return body
    }
}

private final class LockedStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = ACTALocalVLLMSSEParser()
    private var firstTokenMs: Double?
    private var previewClosed = false
    private var previewRevision = 0
    private var accumulatedPreview = ""
    private let onAnswerPreview: (@Sendable (String, Int) -> Void)?
    private let authorization: (@Sendable () -> Bool)?

    init(
        onAnswerPreview: (@Sendable (String, Int) -> Void)?,
        authorization: (@Sendable () -> Bool)?
    ) {
        self.onAnswerPreview = onAnswerPreview
        self.authorization = authorization
    }

    var ttftMs: Double? { lock.withLock { firstTokenMs } }

    func closePreview() {
        lock.withLock { previewClosed = true }
    }

    func consumeSSE(_ chunk: String, startedAt: Date) {
        let emitted: (String, Int)? = lock.withLock {
            let texts = parser.feed(chunk)
            if !texts.isEmpty, firstTokenMs == nil {
                firstTokenMs = Date().timeIntervalSince(startedAt) * 1000.0
            }
            guard !texts.isEmpty, !previewClosed, authorization?() ?? true else { return nil }
            accumulatedPreview.append(texts.joined())
            // Only stream human-readable prose previews, never raw tool-call JSON wrappers
            let trimmed = accumulatedPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("{") else { return nil }
            previewRevision += 1
            return (trimmed, previewRevision)
        }
        if let emitted, let onAnswerPreview {
            onAnswerPreview(emitted.0, emitted.1)
        }
    }

    func finalize() -> ACTALocalVLLMStreamParseResult {
        lock.withLock {
            previewClosed = true
            return parser.finalize()
        }
    }
}
