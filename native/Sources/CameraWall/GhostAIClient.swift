import CameraCore
import CoreGraphics
import Foundation
import Security

// MARK: - 1. AI Backend Mode & Task Lane Routing

public enum GhostAIBackendMode: String, Codable, Sendable, CaseIterable {
    case mlxInProcess = "mlx"
    case localVLLM = "vllm"
    case openAI = "openai"
    case hybridAuto = "hybrid"
    case dryRun = "dry_run"

    public var displayName: String {
        switch self {
        case .mlxInProcess: return "Local MLX (Qwen3.5-9B)"
        case .localVLLM: return "Local vLLM HTTP Server"
        case .openAI: return "OpenAI Responses API"
        case .hybridAuto: return "Hybrid Auto (Local + Cloud Failover)"
        case .dryRun: return "Dry-Run / Offline Mock"
        }
    }
}

public enum GhostAILane: String, Codable, Sendable, CaseIterable {
    case chat
    case alert
    case background

    public var maxConcurrentRequests: Int {
        switch self {
        case .chat: return 4
        case .alert: return 4
        case .background: return 2
        }
    }
}

public enum GhostAITier: String, Codable, Sendable {
    case nano = "gpt-5.4-nano"
    case mini = "gpt-5.4-mini"
    case full = "gpt-5.4"
}

public struct GhostAIConfiguration: Codable, Sendable, Equatable {
    public var mode: GhostAIBackendMode
    public var vllmBaseURL: String
    public var vllmModelName: String
    public var openAIBaseURL: String
    public var backupRelayURL: String
    public var privacyBlurFacesInCloud: Bool
    public var privacyBlurPlatesInCloud: Bool
    public var dailyBudgetLimitUSD: Double
    public var monthlyBudgetLimitUSD: Double
    public var preferredLanguage: GhostPromptLanguage

    public init(
        mode: GhostAIBackendMode = .hybridAuto,
        vllmBaseURL: String = "http://10.0.0.57:8000/v1",
        vllmModelName: String = "Qwen/Qwen2.5-VL-7B-Instruct",
        openAIBaseURL: String = "https://api.openai.com/v1/responses",
        backupRelayURL: String = "http://127.0.0.1:8018/api/backup/responses",
        privacyBlurFacesInCloud: Bool = false,
        privacyBlurPlatesInCloud: Bool = false,
        dailyBudgetLimitUSD: Double = 80.0,
        monthlyBudgetLimitUSD: Double = 400.0,
        preferredLanguage: GhostPromptLanguage = .ru
    ) {
        self.mode = mode
        self.vllmBaseURL = vllmBaseURL
        self.vllmModelName = vllmModelName
        self.openAIBaseURL = openAIBaseURL
        self.backupRelayURL = backupRelayURL
        self.privacyBlurFacesInCloud = privacyBlurFacesInCloud
        self.privacyBlurPlatesInCloud = privacyBlurPlatesInCloud
        self.dailyBudgetLimitUSD = dailyBudgetLimitUSD
        self.monthlyBudgetLimitUSD = monthlyBudgetLimitUSD
        self.preferredLanguage = preferredLanguage
    }
}

// MARK: - 2. Keychain Credential Store (GhostKey & AlertKey)

public enum GhostKeychainStore {
    public static let serviceName = "com.giraffai.ghost.credentials"
    public static let primaryKeyAccount = "GhostKey"
    public static let alertKeyAccount = "AlertKey"

    public static func saveKey(_ key: String, account: String = primaryKeyAccount) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !trimmed.isEmpty else { return true }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    public static func loadKey(account: String = primaryKeyAccount) -> String? {
        if let envKey = ProcessInfo.processInfo.environment[account == alertKeyAccount ? "GHOST_ALERT_OPENAI_API_KEY" : "OPENAI_API_KEY"],
           !envKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let str = String(data: data, encoding: .utf8), !str.isEmpty else {
            return nil
        }
        return str
    }
}

// MARK: - 3. Budget Tracker & CER (Cost-Efficiency Ratio)

public struct GhostBudgetSnapshot: Codable, Sendable, Equatable {
    public var dailySpendUSD: Double
    public var monthlySpendUSD: Double
    public var totalCalls: Int
    public var totalVerifiedDetections: Int
    public var costEfficiencyRatio: Double

    public init(
        dailySpendUSD: Double = 0,
        monthlySpendUSD: Double = 0,
        totalCalls: Int = 0,
        totalVerifiedDetections: Int = 0
    ) {
        self.dailySpendUSD = dailySpendUSD
        self.monthlySpendUSD = monthlySpendUSD
        self.totalCalls = totalCalls
        self.totalVerifiedDetections = totalVerifiedDetections
        self.costEfficiencyRatio = totalVerifiedDetections > 0
            ? (dailySpendUSD / Double(totalVerifiedDetections))
            : 0.0
    }
}

public final class GhostBudgetTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var dailySpendUSD: Double = 0
    private var monthlySpendUSD: Double = 0
    private var totalCalls: Int = 0
    private var totalVerifiedDetections: Int = 0

    public init() {}

    public func recordUsage(
        tier: GhostAITier,
        inputTokens: Int,
        outputTokens: Int,
        verifiedDetections: Int = 0,
        isLocalFree: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        totalCalls += 1
        totalVerifiedDetections += max(0, verifiedDetections)
        guard !isLocalFree else { return }

        let (inRatePerM, outRatePerM): (Double, Double)
        switch tier {
        case .nano:
            inRatePerM = 0.10
            outRatePerM = 0.40
        case .mini:
            inRatePerM = 0.40
            outRatePerM = 1.60
        case .full:
            inRatePerM = 2.50
            outRatePerM = 10.00
        }
        let cost = (Double(inputTokens) / 1_000_000.0) * inRatePerM + (Double(outputTokens) / 1_000_000.0) * outRatePerM
        dailySpendUSD += cost
        monthlySpendUSD += cost
    }

    public func isWithinBudget(config: GhostAIConfiguration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dailySpendUSD < config.dailyBudgetLimitUSD && monthlySpendUSD < config.monthlyBudgetLimitUSD
    }

    public func snapshot() -> GhostBudgetSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return GhostBudgetSnapshot(
            dailySpendUSD: dailySpendUSD,
            monthlySpendUSD: monthlySpendUSD,
            totalCalls: totalCalls,
            totalVerifiedDetections: totalVerifiedDetections
        )
    }
}

// MARK: - 4. Circuit Breaker & Health Probe (ghstHC)

public struct GhostHealthStatus: Codable, Sendable, Equatable {
    public var isHealthy: Bool
    public var circuitOpen: Bool
    public var consecutiveFailures: Int
    public var ewmaLatencyMs: Double
    public var activeBackend: String
    public var lastCheckedAt: Date

    public init(
        isHealthy: Bool = true,
        circuitOpen: Bool = false,
        consecutiveFailures: Int = 0,
        ewmaLatencyMs: Double = 0,
        activeBackend: String = "hybrid",
        lastCheckedAt: Date = Date()
    ) {
        self.isHealthy = isHealthy
        self.circuitOpen = circuitOpen
        self.consecutiveFailures = consecutiveFailures
        self.ewmaLatencyMs = ewmaLatencyMs
        self.activeBackend = activeBackend
        self.lastCheckedAt = lastCheckedAt
    }
}

public final class GhostCircuitBreaker: @unchecked Sendable {
    public static let failureThreshold: Int = 8
    public static let openCooldownSeconds: TimeInterval = 30.0
    public static let ewmaAlpha: Double = 0.25

    private let lock = NSLock()
    private var consecutiveFailures: Int = 0
    private var openedAt: Date?
    private var ewmaLatencyMs: Double = 180.0
    private var lastBackend: String = "mlx"

    public init() {}

    public func allowRequest(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let openedAt else { return true }
        if now.timeIntervalSince(openedAt) >= Self.openCooldownSeconds {
            self.openedAt = nil
            self.consecutiveFailures = max(0, Self.failureThreshold - 2)
            return true
        }
        return false
    }

    public func recordSuccess(latencyMs: Double, backend: String) {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
        openedAt = nil
        ewmaLatencyMs = (1.0 - Self.ewmaAlpha) * ewmaLatencyMs + Self.ewmaAlpha * max(1.0, latencyMs)
        lastBackend = backend
    }

    public func recordFailure(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            openedAt = now
        }
    }

    public func status(now: Date = Date()) -> GhostHealthStatus {
        lock.lock()
        defer { lock.unlock() }
        let isOpen: Bool
        if let openedAt {
            isOpen = now.timeIntervalSince(openedAt) < Self.openCooldownSeconds
        } else {
            isOpen = false
        }
        return GhostHealthStatus(
            isHealthy: !isOpen,
            circuitOpen: isOpen,
            consecutiveFailures: consecutiveFailures,
            ewmaLatencyMs: ewmaLatencyMs,
            activeBackend: lastBackend,
            lastCheckedAt: now
        )
    }
}

// MARK: - 5. Async Semaphore per Lane

public actor GhostAsyncLaneLimiter {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

// MARK: - 6. Hybrid Ghost AI Client (MLX + Local vLLM + OpenAI + Backup Failover)

public final class GhostAIClient: @unchecked Sendable {
    private let lock = NSLock()
    private var config: GhostAIConfiguration
    private let localVLM: LocalVLMClient?
    private var cacheStore: LocalTrackingStore?
    public let budgetTracker = GhostBudgetTracker()
    public let circuitBreaker = GhostCircuitBreaker()

    private let chatLane = GhostAsyncLaneLimiter(limit: GhostAILane.chat.maxConcurrentRequests)
    private let alertLane = GhostAsyncLaneLimiter(limit: GhostAILane.alert.maxConcurrentRequests)
    private let backgroundLane = GhostAsyncLaneLimiter(limit: GhostAILane.background.maxConcurrentRequests)
    private let urlSession: URLSession

    init(
        config: GhostAIConfiguration = GhostAIConfiguration(),
        localVLM: LocalVLMClient? = nil,
        cacheStore: LocalTrackingStore? = nil
    ) {
        self.config = config
        self.localVLM = localVLM
        self.cacheStore = cacheStore
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 180.0
        sessionConfig.timeoutIntervalForResource = 180.0
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    public func attachCacheStore(_ store: LocalTrackingStore?) {
        lock.lock()
        defer { lock.unlock() }
        self.cacheStore = store
    }

    private func currentCacheStore() -> LocalTrackingStore? {
        lock.lock()
        defer { lock.unlock() }
        return cacheStore
    }

    public func configuration() -> GhostAIConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    public func updateConfiguration(_ newConfig: GhostAIConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        config = newConfig
    }

    private func limiter(for lane: GhostAILane) -> GhostAsyncLaneLimiter {
        switch lane {
        case .chat: return chatLane
        case .alert: return alertLane
        case .background: return backgroundLane
        }
    }

    /// Executes a structured JSON generation task across the configured hybrid backend with SHA-256 content-hash deduplication.
    public func generateStructured<T: Codable & Sendable>(
        lane: GhostAILane,
        tier: GhostAITier,
        taskType: String = "structured",
        promptVersion: String = "v1",
        prompt: String,
        jpegImages: [Data] = [],
        previousResponseID: String? = nil,
        owedOutputs: [GhostPendingOutputDebt] = [],
        useContentCache: Bool = true,
        responseType: T.Type,
        fallbackFactory: @Sendable () -> T
    ) async -> T {
        let currentConfig = configuration()
        let store = currentCacheStore()
        let requestHash = GhostAIRequestHasher.computeHash(
            taskType: "\(taskType):\(String(describing: T.self))",
            promptVersion: promptVersion,
            prompt: prompt,
            images: jpegImages
        )

        if useContentCache, previousResponseID == nil,
           let cachedJSON = try? store?.cachedGhostAIResponse(requestHash: requestHash),
           let data = cachedJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            circuitBreaker.recordSuccess(latencyMs: 1.0, backend: "cache")
            return decoded
        }

        if currentConfig.mode == .dryRun {
            budgetTracker.recordUsage(tier: tier, inputTokens: 120, outputTokens: 60, isLocalFree: true)
            circuitBreaker.recordSuccess(latencyMs: 5.0, backend: "dry_run")
            let result = fallbackFactory()
            if useContentCache, previousResponseID == nil,
               let encoded = try? JSONEncoder().encode(result),
               let jsonStr = String(data: encoded, encoding: .utf8) {
                try? store?.saveGhostAICacheResponse(
                    requestHash: requestHash,
                    taskType: taskType,
                    promptVersion: promptVersion,
                    responseJSON: jsonStr
                )
            }
            return result
        }

        let laneLimiter = limiter(for: lane)
        return await laneLimiter.withPermit {
            let start = Date()
            do {
                let rawJSON = try await dispatchRawRequest(
                    config: currentConfig,
                    lane: lane,
                    tier: tier,
                    prompt: prompt,
                    jpegImages: jpegImages,
                    previousResponseID: previousResponseID,
                    owedOutputs: owedOutputs
                )
                let cleaned = Self.extractJSONObject(from: rawJSON)
                if let data = cleaned.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(T.self, from: data) {
                    let elapsedMs = Date().timeIntervalSince(start) * 1000.0
                    circuitBreaker.recordSuccess(latencyMs: elapsedMs, backend: currentConfig.mode.rawValue)
                    if useContentCache, previousResponseID == nil {
                        try? store?.saveGhostAICacheResponse(
                            requestHash: requestHash,
                            taskType: taskType,
                            promptVersion: promptVersion,
                            responseJSON: cleaned
                        )
                    }
                    return decoded
                }
            } catch {
                circuitBreaker.recordFailure()
            }
            return fallbackFactory()
        }
    }

    private func dispatchRawRequest(
        config: GhostAIConfiguration,
        lane: GhostAILane,
        tier: GhostAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [GhostPendingOutputDebt] = []
    ) async throws -> String {
        switch config.mode {
        case .dryRun:
            return "{}"
        case .mlxInProcess:
            return try await callMLX(prompt: prompt, jpegImages: jpegImages, tier: tier)
        case .localVLLM:
            return try await callLocalVLLM(config: config, prompt: prompt, jpegImages: jpegImages, tier: tier)
        case .openAI:
            return try await callOpenAIWithBackup(
                config: config,
                lane: lane,
                tier: tier,
                prompt: prompt,
                jpegImages: jpegImages,
                previousResponseID: previousResponseID,
                owedOutputs: owedOutputs
            )
        case .hybridAuto:
            // Prefer Local vLLM if reachable, else OpenAI if key + budget available, else MLX in-process
            if circuitBreaker.allowRequest(), let vllmText = try? await callLocalVLLM(config: config, prompt: prompt, jpegImages: jpegImages, tier: tier) {
                return vllmText
            }
            if budgetTracker.isWithinBudget(config: config),
               let openAIText = try? await callOpenAIWithBackup(
                   config: config,
                   lane: lane,
                   tier: tier,
                   prompt: prompt,
                   jpegImages: jpegImages,
                   previousResponseID: previousResponseID,
                   owedOutputs: owedOutputs
               ) {
                return openAIText
            }
            return try await callMLX(prompt: prompt, jpegImages: jpegImages, tier: tier)
        }
    }

    private func callMLX(prompt: String, jpegImages: [Data], tier: GhostAITier) async throws -> String {
        guard let localVLM else {
            throw URLError(.cannotConnectToHost)
        }
        let text: String
        if !jpegImages.isEmpty {
            text = try await localVLM.analyze(images: Array(jpegImages.prefix(4)), prompt: prompt)
        } else {
            text = try await localVLM.analyze(text: prompt)
        }
        budgetTracker.recordUsage(tier: tier, inputTokens: prompt.count / 4, outputTokens: text.count / 4, isLocalFree: true)
        return text
    }

    private func callLocalVLLM(
        config: GhostAIConfiguration,
        prompt: String,
        jpegImages: [Data],
        tier: GhostAITier
    ) async throws -> String {
        let base = config.vllmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw URLError(.badURL)
        }

        var contentArray: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        for img in jpegImages {
            let b64 = img.base64EncodedString()
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(b64)"]
            ])
        }

        let payload: [String: Any] = [
            "model": config.vllmModelName,
            "messages": [
                ["role": "user", "content": contentArray]
            ],
            "temperature": 0.1,
            "max_tokens": 2048
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        budgetTracker.recordUsage(tier: tier, inputTokens: prompt.count / 4, outputTokens: content.count / 4, isLocalFree: true)
        return content
    }

    private func callOpenAIWithBackup(
        config: GhostAIConfiguration,
        lane: GhostAILane,
        tier: GhostAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [GhostPendingOutputDebt] = []
    ) async throws -> String {
        let preferredAccount = (lane == .alert) ? GhostKeychainStore.alertKeyAccount : GhostKeychainStore.primaryKeyAccount
        let apiKey = GhostKeychainStore.loadKey(account: preferredAccount)
            ?? GhostKeychainStore.loadKey(account: GhostKeychainStore.primaryKeyAccount)

        if let apiKey, let primaryURL = URL(string: config.openAIBaseURL) {
            if let text = try? await sendResponsesPayload(
                url: primaryURL,
                apiKey: apiKey,
                tier: tier,
                prompt: prompt,
                jpegImages: jpegImages,
                previousResponseID: previousResponseID,
                owedOutputs: owedOutputs
            ) {
                return text
            }
        }

        // Failover to local backup relay (http://127.0.0.1:8018/api/backup/responses)
        guard let backupURL = URL(string: config.backupRelayURL) else {
            throw URLError(.badURL)
        }
        return try await sendResponsesPayload(
            url: backupURL,
            apiKey: apiKey ?? "backup-relay",
            tier: tier,
            prompt: prompt,
            jpegImages: jpegImages,
            previousResponseID: previousResponseID,
            owedOutputs: owedOutputs
        )
    }

    public static func buildOpenAIResponsesBody(
        tier: GhostAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [GhostPendingOutputDebt] = [],
        store: Bool = true
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []
        // Settle owed function_call_output items from previous terminal tool call (e.g. present_answer)
        if previousResponseID != nil {
            for debt in owedOutputs {
                inputItems.append([
                    "type": "function_call_output",
                    "call_id": debt.callID,
                    "output": debt.outputJSON
                ])
            }
        }

        var contentItems: [[String: Any]] = [
            ["type": "input_text", "text": prompt]
        ]
        for img in jpegImages {
            let b64 = img.base64EncodedString()
            contentItems.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(b64)"
            ])
        }
        inputItems.append([
            "role": "user",
            "content": contentItems
        ])

        var body: [String: Any] = [
            "model": tier.rawValue,
            "store": store,
            "input": inputItems
        ]
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }
        return body
    }

    private func sendResponsesPayload(
        url: URL,
        apiKey: String,
        tier: GhostAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [GhostPendingOutputDebt] = []
    ) async throws -> String {
        let body = Self.buildOpenAIResponsesBody(
            tier: tier,
            prompt: prompt,
            jpegImages: jpegImages,
            previousResponseID: previousResponseID,
            owedOutputs: owedOutputs,
            store: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let extracted: String
        if let outputText = root["output_text"] as? String {
            extracted = outputText
        } else if let outputArr = root["output"] as? [[String: Any]],
                  let contentArr = outputArr.first?["content"] as? [[String: Any]],
                  let textVal = contentArr.first?["text"] as? String {
            extracted = textVal
        } else {
            throw URLError(.cannotParseResponse)
        }

        budgetTracker.recordUsage(
            tier: tier,
            inputTokens: prompt.count / 4 + jpegImages.count * 250,
            outputTokens: extracted.count / 4,
            isLocalFree: false
        )
        return extracted
    }

    public static func extractJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}") else {
            return trimmed
        }
        return String(trimmed[firstBrace...lastBrace])
    }
}

// MARK: - 7. Israeli Government Vehicle Registry Client (data.gov.il)

public final class GhostIsraeliVehicleRegistryClient: @unchecked Sendable {
    private let urlSession: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10.0
        self.urlSession = URLSession(configuration: cfg)
    }

    public func lookupPlate(
        rawPlate: String,
        store: LocalTrackingStore? = nil
    ) async -> GhostVehicleRegistryRecord? {
        guard let normalized = GhostVehicleRegistryRecord.normalizeIsraeliPlate(rawPlate) else {
            return nil
        }
        if let cached = try? store?.cachedVehicleRegistryRecord(plateNumber: normalized) {
            return cached
        }

        let resources = [
            GhostVehicleRegistryRecord.privateVehiclesResourceID,
            GhostVehicleRegistryRecord.motorcyclesResourceID,
            GhostVehicleRegistryRecord.heavyVehiclesResourceID
        ]

        for resourceID in resources {
            if let record = try? await queryCKAN(resourceID: resourceID, plateNumber: normalized) {
                try? store?.cacheVehicleRegistryRecord(record)
                return record
            }
        }
        return nil
    }

    private func queryCKAN(resourceID: String, plateNumber: String) async throws -> GhostVehicleRegistryRecord? {
        var components = URLComponents(string: "https://data.gov.il/api/3/action/datastore_search")
        components?.queryItems = [
            URLQueryItem(name: "resource_id", value: resourceID),
            URLQueryItem(name: "q", value: plateNumber),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let records = result["records"] as? [[String: Any]],
              let first = records.first else {
            return nil
        }

        let manufacturer = (first["tozeret_nm"] as? String) ?? (first["tozeret_eretz_nm"] as? String)
        let model = (first["kinuy_mishari"] as? String) ?? (first["degem_nm"] as? String)
        let year = (first["shnat_yitzur"] as? Int) ?? Int((first["shnat_yitzur"] as? String) ?? "")
        let color = first["tzeva_rechev"] as? String
        let fuel = first["sug_delek_nm"] as? String
        let ownership = first["baalut"] as? String
        let validUntil = first["tokef_dt"] as? String

        return GhostVehicleRegistryRecord(
            plateNumber: plateNumber,
            manufacturer: manufacturer,
            commercialModel: model,
            manufactureYear: year,
            colorName: color,
            fuelType: fuel,
            ownershipType: ownership,
            testValidUntil: validUntil,
            sourceResourceID: resourceID,
            fetchedAt: Date()
        )
    }
}
