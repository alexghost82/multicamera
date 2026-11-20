import CameraCore
import CoreGraphics
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers
import Vision

// MARK: - 1. AI Backend Mode & Task Lane Routing

public enum ACTAAIBackendMode: String, Codable, Sendable, CaseIterable {
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

public enum ACTAAILane: String, Codable, Sendable, CaseIterable {
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

public enum ACTAAITier: String, Codable, Sendable {
    case nano = "gpt-5.4-nano"
    case mini = "gpt-5.4-mini"
    case full = "gpt-5.4"
}

public struct ACTAAIConfiguration: Codable, Sendable, Equatable {
    public var tierModelNames: [String: String]
    public var mode: ACTAAIBackendMode
    public var vllmBaseURL: String
    public var vllmModelName: String
    public var openAIBaseURL: String
    public var backupRelayURL: String
    public var privacyBlurFacesInCloud: Bool
    public var privacyBlurPlatesInCloud: Bool
    public var allowExternalAI: Bool
    public var allowPlateRegistryLookup: Bool
    public var dailyBudgetLimitUSD: Double
    public var monthlyBudgetLimitUSD: Double
    public var preferredLanguage: ACTAPromptLanguage

    public init(
        mode: ACTAAIBackendMode = .mlxInProcess,
        tierModelNames: [String: String] = [:],
        vllmBaseURL: String = "http://127.0.0.1:8000/v1",
        vllmModelName: String = "Qwen/Qwen2.5-VL-7B-Instruct",
        openAIBaseURL: String = "https://api.openai.com/v1/responses",
        backupRelayURL: String = "http://127.0.0.1:8018/api/backup/responses",
        privacyBlurFacesInCloud: Bool = true,
        privacyBlurPlatesInCloud: Bool = true,
        allowExternalAI: Bool = false,
        allowPlateRegistryLookup: Bool = false,
        dailyBudgetLimitUSD: Double = 80.0,
        monthlyBudgetLimitUSD: Double = 400.0,
        preferredLanguage: ACTAPromptLanguage = .ru
    ) {
        self.tierModelNames = tierModelNames
        self.mode = mode
        self.vllmBaseURL = vllmBaseURL
        self.vllmModelName = vllmModelName
        self.openAIBaseURL = openAIBaseURL
        self.backupRelayURL = backupRelayURL
        self.privacyBlurFacesInCloud = privacyBlurFacesInCloud
        self.privacyBlurPlatesInCloud = privacyBlurPlatesInCloud
        self.allowExternalAI = allowExternalAI
        self.allowPlateRegistryLookup = allowPlateRegistryLookup
        self.dailyBudgetLimitUSD = dailyBudgetLimitUSD
        self.monthlyBudgetLimitUSD = monthlyBudgetLimitUSD
        self.preferredLanguage = preferredLanguage
    }
}

// MARK: - 1b. Cloud Privacy Redactor (Faces & License Plates Blur / Pixelation)

public enum ACTACloudPrivacyRedactor {
    /// Detects faces (`VNDetectFaceRectanglesRequest`) and license-plate/text regions (`VNRecognizeTextRequest`)
    /// and applies an irreversible pixelation mosaic over all matched regions before cloud transmission.
    public static func redactJPEG(
        _ jpegData: Data,
        blurFaces: Bool,
        blurPlates: Bool,
        additionalNormalizedBoxes: [CGRect] = []
    ) -> Data {
        guard blurFaces || blurPlates || !additionalNormalizedBoxes.isEmpty else {
            return jpegData
        }
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return jpegData
        }

        var normalizedBoxes: [CGRect] = additionalNormalizedBoxes
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        var requests: [VNRequest] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        if blurFaces {
            requests.append(faceRequest)
        }
        if blurPlates {
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false
            requests.append(textRequest)
        }
        if !requests.isEmpty {
            try? handler.perform(requests)
            if blurFaces, let faceResults = faceRequest.results {
                normalizedBoxes.append(contentsOf: faceResults.map(\.boundingBox))
            }
            if blurPlates, let textResults = textRequest.results {
                for observation in textResults {
                    let candidate = observation.topCandidates(1).first?.string ?? ""
                    let alnumCount = candidate.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                    if alnumCount >= 3 {
                        normalizedBoxes.append(observation.boundingBox)
                    }
                }
            }
        }

        guard !normalizedBoxes.isEmpty else {
            return jpegData
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return jpegData }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return jpegData
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Apply irreversible block pixelation + darkening across each normalized box (Vision origin is bottom-left)
        let blockSize = max(6, min(width, height) / 16)
        for normBox in normalizedBoxes {
            let expanded = normBox.insetBy(dx: -normBox.width * 0.08, dy: -normBox.height * 0.08)
            let clampedMinX = max(0, min(width - 1, Int(floor(expanded.minX * CGFloat(width)))))
            let clampedMaxX = max(0, min(width, Int(ceil(expanded.maxX * CGFloat(width)))))
            let topY = 1.0 - expanded.maxY
            let bottomY = 1.0 - expanded.minY
            let clampedMinY = max(0, min(height - 1, Int(floor(topY * CGFloat(height)))))
            let clampedMaxY = max(0, min(height, Int(ceil(bottomY * CGFloat(height)))))
            guard clampedMaxX > clampedMinX, clampedMaxY > clampedMinY else { continue }

            var by = clampedMinY
            while by < clampedMaxY {
                let byEnd = min(clampedMaxY, by + blockSize)
                var bx = clampedMinX
                while bx < clampedMaxX {
                    let bxEnd = min(clampedMaxX, bx + blockSize)
                    var sumR = 0, sumG = 0, sumB = 0, count = 0
                    for y in by..<byEnd {
                        for x in bx..<bxEnd {
                            let idx = (y * width + x) * 4
                            sumR += Int(pixels[idx])
                            sumG += Int(pixels[idx + 1])
                            sumB += Int(pixels[idx + 2])
                            count += 1
                        }
                    }
                    if count > 0 {
                        let avgR = UInt8((sumR / count) / 2)
                        let avgG = UInt8((sumG / count) / 2)
                        let avgB = UInt8((sumB / count) / 2)
                        for y in by..<byEnd {
                            for x in bx..<bxEnd {
                                let idx = (y * width + x) * 4
                                pixels[idx] = avgR
                                pixels[idx + 1] = avgG
                                pixels[idx + 2] = avgB
                                pixels[idx + 3] = 255
                            }
                        }
                    }
                    bx += blockSize
                }
                by += blockSize
            }
        }

        guard let redactedCG = ctx.makeImage() else { return jpegData }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return jpegData
        }
        CGImageDestinationAddImage(dest, redactedCG, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return jpegData }
        return outData as Data
    }

    public static func redactImages(_ images: [Data], config: ACTAAIConfiguration) -> [Data] {
        guard config.privacyBlurFacesInCloud || config.privacyBlurPlatesInCloud else {
            return images
        }
        return images.map {
            redactJPEG(
                $0,
                blurFaces: config.privacyBlurFacesInCloud,
                blurPlates: config.privacyBlurPlatesInCloud
            )
        }
    }
}

// MARK: - 2. Keychain Credential Store (ACTAKey & AlertKey)

public enum ACTAKeychainStore {
    public static let serviceName = "CameraWall.GhostCredentials"
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
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    public static func loadKey(account: String = primaryKeyAccount) -> String? {
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

public struct ACTABudgetSnapshot: Codable, Sendable, Equatable {
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

public final class ACTABudgetTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var dailySpendUSD: Double = 0
    private var monthlySpendUSD: Double = 0
    private var totalCalls: Int = 0
    private var totalVerifiedDetections: Int = 0

    public init() {}

    public func recordUsage(
        tier: ACTAAITier,
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

    public func isWithinBudget(config: ACTAAIConfiguration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dailySpendUSD < config.dailyBudgetLimitUSD && monthlySpendUSD < config.monthlyBudgetLimitUSD
    }

    public func snapshot() -> ACTABudgetSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ACTABudgetSnapshot(
            dailySpendUSD: dailySpendUSD,
            monthlySpendUSD: monthlySpendUSD,
            totalCalls: totalCalls,
            totalVerifiedDetections: totalVerifiedDetections
        )
    }
}

// MARK: - 4. Circuit Breaker & Health Probe (ghstHC)

public struct ACTAHealthStatus: Codable, Sendable, Equatable {
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

public final class ACTACircuitBreaker: @unchecked Sendable {
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

    public func status(now: Date = Date()) -> ACTAHealthStatus {
        lock.lock()
        defer { lock.unlock() }
        let isOpen: Bool
        if let openedAt {
            isOpen = now.timeIntervalSince(openedAt) < Self.openCooldownSeconds
        } else {
            isOpen = false
        }
        return ACTAHealthStatus(
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

public actor ACTAAsyncLaneLimiter {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
#if DEBUG
    private var testWaitHook: (@Sendable () -> Void)?
    func setTestWaitHook(_ hook: (@Sendable () -> Void)?) { testWaitHook = hook }
#endif

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
#if DEBUG
            testWaitHook?()
#endif
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

// MARK: - 5b. Agent Tool-Calling Types

/// Refuse cross-origin redirects so a loopback service cannot forward images or
/// credentials to another host behind the caller's external-data consent gate.
final class ACTAHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allowsRedirect(from source: URL?, to destination: URL?) -> Bool {
        guard let source, let destination else { return false }
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return source.scheme?.lowercased() == destination.scheme?.lowercased()
            && source.host?.lowercased() == destination.host?.lowercased()
            && port(source) == port(destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowsRedirect(from: response.url, to: request.url) ? request : nil)
    }
}

public typealias ACTAHTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public struct ACTAAgentToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersSchemaJSON: String

    public init(name: String, description: String, parametersSchemaJSON: String) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }

    /// Builds an object schema whose properties are `(name, jsonType, description)` triples.
    public static func object(
        name: String,
        description: String,
        properties: [(String, String, String)] = [],
        required: [String] = []
    ) -> ACTAAgentToolSpec {
        var props: [String: Any] = [:]
        for (key, type, desc) in properties {
            props[key] = ["type": type, "description": desc]
        }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ACTAAgentToolSpec(name: name, description: description, parametersSchemaJSON: String(decoding: data, as: UTF8.self))
    }

    var parametersObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(parametersSchemaJSON.utf8))) as? [String: Any]
            ?? ["type": "object", "properties": [String: Any]()]
    }
}

public struct ACTAAgentFunctionCall: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var argumentsJSON: String {
        didSet { rawArgumentsJSON = argumentsJSON }
    }
    public private(set) var rawArgumentsJSON: String

    public init(callID: String, name: String, argumentsJSON: String, rawArgumentsJSON: String? = nil) {
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON.isEmpty ? "{}" : argumentsJSON
        self.rawArgumentsJSON = rawArgumentsJSON ?? argumentsJSON
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.callID == rhs.callID && lhs.name == rhs.name && lhs.argumentsJSON == rhs.argumentsJSON
    }

    /// Flattens the JSON arguments into strings (numbers/bools stringified, nested values re-encoded as JSON).
    public var arguments: [String: String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (key, value) in obj {
            switch value {
            case let str as String: out[key] = str
            case let num as NSNumber:
                out[key] = CFGetTypeID(num) == CFBooleanGetTypeID() ? (num.boolValue ? "true" : "false") : num.stringValue
            case is NSNull: continue
            default:
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    out[key] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        return out
    }
}

private struct ACTARawJSONRanges {
    private let bytes: [UInt8]
    private var index = 0

    init(_ json: String) { bytes = Array(json.utf8) }

    private mutating func whitespace() {
        while index < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
    }

    private mutating func stringEnd() -> Bool {
        guard index < bytes.count, bytes[index] == 34 else { return false }
        index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 { index += 1; return true }
            index += 1
        }
        return false
    }

    private mutating func value() -> String? {
        whitespace()
        guard index < bytes.count else { return nil }
        let start = index
        if bytes[index] == 34 {
            guard stringEnd() else { return nil }
        } else if bytes[index] == 123 || bytes[index] == 91 {
            var depth = 0
            while index < bytes.count {
                if bytes[index] == 34 {
                    guard stringEnd() else { return nil }
                    continue
                }
                if bytes[index] == 123 || bytes[index] == 91 { depth += 1 }
                if bytes[index] == 125 || bytes[index] == 93 {
                    depth -= 1
                    if depth == 0 { index += 1; break }
                }
                index += 1
            }
            guard depth == 0 else { return nil }
        } else {
            while index < bytes.count && ![UInt8(44), 125, 93, 32, 9, 10, 13].contains(bytes[index]) {
                index += 1
            }
        }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func object() -> [String: String]? {
        whitespace()
        guard index < bytes.count, bytes[index] == 123 else { return nil }
        index += 1
        var fields: [String: String] = [:]
        while true {
            whitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == 125 { return fields }
            let start = index
            guard stringEnd() else { return nil }
            let keyJSON = "[" + String(decoding: bytes[start..<index], as: UTF8.self) + "]"
            guard let keys = try? JSONSerialization.jsonObject(with: Data(keyJSON.utf8)) as? [String],
                  let key = keys.first, fields[key] == nil else { return nil }
            whitespace()
            guard index < bytes.count, bytes[index] == 58 else { return nil }
            index += 1
            guard let raw = value() else { return nil }
            fields[key] = raw
            whitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == 125 { return fields }
            guard bytes[index] == 44 else { return nil }
            index += 1
        }
    }

    mutating func array() -> [String]? {
        whitespace()
        guard index < bytes.count, bytes[index] == 91 else { return nil }
        index += 1
        var items: [String] = []
        while true {
            whitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == 93 { return items }
            guard let raw = value() else { return nil }
            items.append(raw)
            whitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == 93 { return items }
            guard bytes[index] == 44 else { return nil }
            index += 1
        }
    }
}

public enum ACTAAgentItem: Sendable, Equatable {
    case user(text: String, images: [Data])
    case assistantText(String)
    case functionCall(ACTAAgentFunctionCall)
    case functionOutput(callID: String, output: String)
}

public enum ACTAAgentToolChoice: Sendable, Equatable {
    case auto
    case required
    case function(String)
}

public enum ACTAAgentBackend: String, Sendable, Equatable {
    case openAI = "openai"
    case vllm
    case mlx
    /// Deterministic offline/dry-run planner; never chains.
    case offline
}

public struct ACTAAgentRequest: Sendable {
    public var tier: ACTAAITier
    public var operatorQuestion: String?
    public var instructions: String
    /// Complete conversation, used by stateless backends or when no chain head is available.
    public var fullInput: [ACTAAgentItem]
    /// Only the items the server has not seen yet; sent together with `previousResponseID`.
    public var chainedInput: [ACTAAgentItem]
    public var previousResponseID: String?
    public var tools: [ACTAAgentToolSpec]
    public var toolChoice: ACTAAgentToolChoice

    public init(
        tier: ACTAAITier = .full,
        operatorQuestion: String? = nil,
        instructions: String,
        fullInput: [ACTAAgentItem],
        chainedInput: [ACTAAgentItem] = [],
        previousResponseID: String? = nil,
        tools: [ACTAAgentToolSpec],
        toolChoice: ACTAAgentToolChoice = .auto
    ) {
        self.tier = tier
        self.operatorQuestion = operatorQuestion
        self.instructions = instructions
        self.fullInput = fullInput
        self.chainedInput = chainedInput
        self.previousResponseID = previousResponseID
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

public struct ACTAAgentTurnResult: Sendable, Equatable {
    /// Real Responses API `id` (nil for stateless backends).
    public var responseID: String?
    public var text: String?
    public var functionCalls: [ACTAAgentFunctionCall]
    public var backend: ACTAAgentBackend
    /// True when the request was sent with `previous_response_id`.
    public var usedChain: Bool

    public init(responseID: String?, text: String?, functionCalls: [ACTAAgentFunctionCall], backend: ACTAAgentBackend, usedChain: Bool = false) {
        self.responseID = responseID
        self.text = text
        self.functionCalls = functionCalls
        self.backend = backend
        self.usedChain = usedChain
    }
}

public enum ACTAAgentError: LocalizedError, Equatable {
    case chainRejected
    case noBackendAvailable
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .chainRejected: return "The agent response chain was rejected."
        case .noBackendAvailable: return "Agent inference requires the explicitly selected in-process MLX model; HTTP servers and cloud backends are not permitted."
        case .badResponse: return "The agent model returned an invalid response."
        }
    }
}

typealias ACTALocalAgentInference = @Sendable (_ prompt: String, _ images: [Data]) async throws -> String
typealias ACTALocalAgentStreamInference = @Sendable (
    _ prompt: String,
    _ images: [Data],
    _ onChunk: (@Sendable (String) -> Void)?
) async throws -> String

private enum ACTARequestAuthorizationError: Error {
    case revoked
}

// MARK: - 6. Hybrid Ghost AI Client (MLX + Local vLLM + OpenAI + Backup Failover)

public final class ACTAAIClient: @unchecked Sendable {
    private let lock = NSLock()
    private var config: ACTAAIConfiguration
    private var configRevision: UInt64 = 0
    private let localVLM: LocalVLMClient?
    private var cacheStore: LocalTrackingStore?
    public let budgetTracker = ACTABudgetTracker()
    public let circuitBreaker = ACTACircuitBreaker()

    private let chatLane = ACTAAsyncLaneLimiter(limit: ACTAAILane.chat.maxConcurrentRequests)
    private let alertLane = ACTAAsyncLaneLimiter(limit: ACTAAILane.alert.maxConcurrentRequests)
    private let backgroundLane = ACTAAsyncLaneLimiter(limit: ACTAAILane.background.maxConcurrentRequests)
    private let agentTrace: (@Sendable (String) -> Void)?
    private let localAgentInference: ACTALocalAgentInference?
    private let localAgentStreamInference: ACTALocalAgentStreamInference?
    private let transport: ACTAHTTPTransport
    private let keyProvider: @Sendable (String) -> String?
#if DEBUG
    func setBackgroundLaneTestWaitHook(_ hook: (@Sendable () -> Void)?) async {
        await backgroundLane.setTestWaitHook(hook)
    }
#endif

    init(
        config: ACTAAIConfiguration = ACTAAIConfiguration(),
        localVLM: LocalVLMClient? = nil,
        cacheStore: LocalTrackingStore? = nil,
        transport: ACTAHTTPTransport? = nil,
        keyProvider: @escaping @Sendable (String) -> String? = { ACTAKeychainStore.loadKey(account: $0) },
        agentTrace: (@Sendable (String) -> Void)? = nil,
        localAgentInference: ACTALocalAgentInference? = nil,
        localAgentStreamInference: ACTALocalAgentStreamInference? = nil
    ) {
        self.config = config
        self.agentTrace = agentTrace
        self.localAgentInference = localAgentInference
        self.localAgentStreamInference = localAgentStreamInference
        self.localVLM = localVLM
        self.cacheStore = cacheStore
        self.keyProvider = keyProvider
        if let transport {
            self.transport = transport
        } else {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = 180.0
            sessionConfig.timeoutIntervalForResource = 180.0
            let session = URLSession(configuration: sessionConfig, delegate: ACTAHTTPRedirectPolicy(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
        }
    }

    func sendAuthorized(_ request: URLRequest, requiresExternalConsent: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let current = configuration()
        let cloudMode = current.mode == .openAI || current.mode == .hybridAuto
        guard let url = request.url,
              (!requiresExternalConsent || (current.allowExternalAI && cloudMode)),
              Self.isLoopbackURL(url) || current.allowExternalAI else {
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        return try await transport(request)
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

    public func configuration() -> ACTAAIConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    public func updateConfiguration(_ newConfig: ACTAAIConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        if config != newConfig { configRevision &+= 1 }
        config = newConfig
    }

    private func configurationSnapshot() -> (ACTAAIConfiguration, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (config, configRevision)
    }

    private func isCurrentConfiguration(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return configRevision == revision
    }

    private func limiter(for lane: ACTAAILane) -> ACTAAsyncLaneLimiter {
        switch lane {
        case .chat: return chatLane
        case .alert: return alertLane
        case .background: return backgroundLane
        }
    }

    /// Executes a structured JSON generation task across the configured hybrid backend with SHA-256 content-hash deduplication.
    public func generateStructured<T: Codable & Sendable>(
        lane: ACTAAILane,
        tier: ACTAAITier,
        taskType: String = "structured",
        promptVersion: String = "v1",
        prompt: String,
        jpegImages: [Data] = [],
        previousResponseID: String? = nil,
        owedOutputs: [ACTAPendingOutputDebt] = [],
        useContentCache: Bool = true,
        onFailureFallback: (@Sendable () -> Void)? = nil,
        beforeDispatch: (@Sendable () async -> Bool)? = nil,
        responseType: T.Type,
        fallbackFactory: @Sendable () -> T
    ) async -> T {
        let (currentConfig, revision) = configurationSnapshot()
        let store = currentCacheStore()
        let requestHash = ACTAAIRequestHasher.computeHash(
            taskType: "\(taskType):\(String(describing: T.self))",
            promptVersion: promptVersion,
            prompt: prompt,
            images: jpegImages
        )

        if useContentCache, previousResponseID == nil,
           let cachedJSON = try? store?.cachedACTAAIResponse(requestHash: requestHash),
           let data = cachedJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            circuitBreaker.recordSuccess(latencyMs: 1.0, backend: "cache")
            return decoded
        }

        if currentConfig.mode == .dryRun {
            onFailureFallback?()
            budgetTracker.recordUsage(tier: tier, inputTokens: 120, outputTokens: 60, isLocalFree: true)
            circuitBreaker.recordSuccess(latencyMs: 5.0, backend: "dry_run")
            let result = fallbackFactory()
            if useContentCache, previousResponseID == nil,
               let encoded = try? JSONEncoder().encode(result),
               let jsonStr = String(data: encoded, encoding: .utf8) {
                try? store?.saveACTAAICacheResponse(
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
            let authorizeDispatch: @Sendable () async throws -> Void = {
                if let beforeDispatch {
                    let allowed = await beforeDispatch()
                    guard allowed, !Task.isCancelled, self.isCurrentConfiguration(revision) else {
                        throw ACTARequestAuthorizationError.revoked
                    }
                } else {
                    try Task.checkCancellation()
                }
            }
            let start = Date()
            do {
                try await authorizeDispatch()
                let rawJSON = try await dispatchRawRequest(
                    config: currentConfig,
                    lane: lane,
                    tier: tier,
                    prompt: prompt,
                    jpegImages: jpegImages,
                    previousResponseID: previousResponseID,
                    owedOutputs: owedOutputs,
                    authorizeDispatch: authorizeDispatch
                )
                let cleaned = Self.extractJSONObject(from: rawJSON)
                if let data = cleaned.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(T.self, from: data) {
                    let elapsedMs = Date().timeIntervalSince(start) * 1000.0
                    circuitBreaker.recordSuccess(latencyMs: elapsedMs, backend: currentConfig.mode.rawValue)
                    if useContentCache, previousResponseID == nil {
                        try? store?.saveACTAAICacheResponse(
                            requestHash: requestHash,
                            taskType: taskType,
                            promptVersion: promptVersion,
                            responseJSON: cleaned
                        )
                    }
                    return decoded
                }
            } catch is ACTARequestAuthorizationError {
                onFailureFallback?()
                return fallbackFactory()
            } catch is CancellationError {
                onFailureFallback?()
                return fallbackFactory()
            } catch {
                circuitBreaker.recordFailure()
            }
            onFailureFallback?()
            return fallbackFactory()
        }
    }

    public static func isLoopbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
    }

    private func dispatchRawRequest(
        config: ACTAAIConfiguration,
        lane: ACTAAILane,
        tier: ACTAAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [ACTAPendingOutputDebt] = [],
        authorizeDispatch: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        switch config.mode {
        case .dryRun:
            return "{}"
        case .mlxInProcess:
            try await authorizeDispatch()
            return try await callMLX(prompt: prompt, jpegImages: jpegImages, tier: tier)
        case .localVLLM:
            return try await callLocalVLLM(config: config, prompt: prompt, jpegImages: jpegImages, tier: tier,
                                           authorizeDispatch: authorizeDispatch)
        case .openAI:
            return try await callOpenAIWithBackup(
                config: config,
                lane: lane,
                tier: tier,
                prompt: prompt,
                jpegImages: jpegImages,
                previousResponseID: previousResponseID,
                owedOutputs: owedOutputs,
                authorizeDispatch: authorizeDispatch
            )
        case .hybridAuto:
            // Prefer Local vLLM if reachable, else OpenAI if external AI consented + key + budget available, else MLX in-process
            if circuitBreaker.allowRequest() {
                do {
                    return try await callLocalVLLM(config: config, prompt: prompt, jpegImages: jpegImages,
                                                   tier: tier, authorizeDispatch: authorizeDispatch)
                } catch is ACTARequestAuthorizationError {
                    throw ACTARequestAuthorizationError.revoked
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
            }
            if config.allowExternalAI, budgetTracker.isWithinBudget(config: config) {
                do {
                    return try await callOpenAIWithBackup(
                        config: config, lane: lane, tier: tier, prompt: prompt, jpegImages: jpegImages,
                            previousResponseID: previousResponseID, owedOutputs: owedOutputs,
                        authorizeDispatch: authorizeDispatch
                    )
                } catch is ACTARequestAuthorizationError {
                    throw ACTARequestAuthorizationError.revoked
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
            }
            try await authorizeDispatch()
            return try await callMLX(prompt: prompt, jpegImages: jpegImages, tier: tier)
        }
    }

    private func callMLX(prompt: String, jpegImages: [Data], tier: ACTAAITier) async throws -> String {
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
        config: ACTAAIConfiguration,
        prompt: String,
        jpegImages: [Data],
        tier: ACTAAITier,
        authorizeDispatch: (@Sendable () async throws -> Void)? = nil
    ) async throws -> String {
        let base = config.vllmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw URLError(.badURL)
        }
        let isLoopback = Self.isLoopbackURL(url)
        if !isLoopback {
            guard config.allowExternalAI else {
                throw URLError(.appTransportSecurityRequiresSecureConnection)
            }
        }
        let outgoingImages = isLoopback
            ? jpegImages
            : ACTACloudPrivacyRedactor.redactImages(jpegImages, config: config)

        var contentArray: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        for img in outgoingImages {
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

        try await authorizeDispatch?()
        let (data, http) = try await sendAuthorized(request)
        guard (200..<300).contains(http.statusCode) else {
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
        config: ACTAAIConfiguration,
        lane: ACTAAILane,
        tier: ACTAAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [ACTAPendingOutputDebt] = [],
        authorizeDispatch: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        guard config.allowExternalAI else {
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        let outgoingImages = ACTACloudPrivacyRedactor.redactImages(jpegImages, config: config)
        let preferredAccount = (lane == .alert) ? ACTAKeychainStore.alertKeyAccount : ACTAKeychainStore.primaryKeyAccount
        let apiKey = keyProvider(preferredAccount) ?? keyProvider(ACTAKeychainStore.primaryKeyAccount)

        if let apiKey, let primaryURL = URL(string: config.openAIBaseURL) {
            do {
                return try await sendResponsesPayload(
                    url: primaryURL, apiKey: apiKey, tier: tier, prompt: prompt, jpegImages: outgoingImages,
                    previousResponseID: previousResponseID, owedOutputs: owedOutputs,
                    modelName: config.tierModelNames[tier.rawValue] ?? tier.rawValue,
                    authorizeDispatch: authorizeDispatch
                )
            } catch is ACTARequestAuthorizationError {
                throw ACTARequestAuthorizationError.revoked
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
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
            jpegImages: outgoingImages,
            previousResponseID: previousResponseID,
            owedOutputs: owedOutputs,
            modelName: config.tierModelNames[tier.rawValue] ?? tier.rawValue,
            authorizeDispatch: authorizeDispatch
        )
    }

    public static func buildOpenAIResponsesBody(
        tier: ACTAAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [ACTAPendingOutputDebt] = [],
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
        tier: ACTAAITier,
        prompt: String,
        jpegImages: [Data],
        previousResponseID: String? = nil,
        owedOutputs: [ACTAPendingOutputDebt] = [],
        modelName: String,
        authorizeDispatch: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        var body = Self.buildOpenAIResponsesBody(
            tier: tier,
            prompt: prompt,
            jpegImages: jpegImages,
            previousResponseID: previousResponseID,
            owedOutputs: owedOutputs,
            store: true
        )
        body["model"] = modelName

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await authorizeDispatch()
        let (data, http) = try await sendAuthorized(request, requiresExternalConsent: true)
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        guard let extracted = Self.parseResponsesOutput(root).text else {
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

    // MARK: Agent tool-calling loop step

    /// Runs one model step of a tool-calling agent. The caller executes returned `functionCalls` and loops.
    /// Only the explicitly selected in-process MLX backend may receive agent data.
    /// A loopback HTTP server is an external process and is not a local inference guarantee.
    public func runAgentStep(
        lane: ACTAAILane = .chat,
        request: ACTAAgentRequest,
        pinnedBackend: ACTAAgentBackend? = nil,
        authorization: (@Sendable () -> Bool)? = nil,
        onAnswerPreview: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> ACTAAgentTurnResult {
        guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
        let (currentConfig, revision) = configurationSnapshot()
        guard currentConfig.mode == .mlxInProcess,
              pinnedBackend == nil || pinnedBackend == .mlx else {
            throw ACTAAgentError.noBackendAvailable
        }
        return try await limiter(for: lane).withPermit {
            try Task.checkCancellation()
            guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
            guard self.isCurrentConfiguration(revision) else { throw ACTAAgentError.noBackendAvailable }
            let result = try await self.agentStepLocal(request: request, authorization: authorization,
                                                       onAnswerPreview: onAnswerPreview)
            guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
            return result
        }
    }

    private func agentStepLocal(
        request: ACTAAgentRequest,
        authorization: (@Sendable () -> Bool)?,
        onAnswerPreview: (@Sendable (String, Int) -> Void)?
    ) async throws -> ACTAAgentTurnResult {
        let forceAnswer: Bool
        if case .function("present_answer") = request.toolChoice { forceAnswer = true } else { forceAnswer = false }
        let prompt: String
        if forceAnswer {
            let context = request.fullInput.map { item -> String in
                switch item {
                case .user(let text, _): return text
                case .assistantText(let text): return "Earlier assistant: " + String(text.prefix(700))
                case .functionOutput(_, let output): return output
                case .functionCall: return ""
                }
            }.joined(separator: "\n")
            prompt = """
            \(request.instructions)
            Context and operator question:
            \(context)
            CURRENT OPERATOR QUESTION: \(request.operatorQuestion ?? "Answer the last operator question above.")
            Return ONLY this compact JSON object (no tool_calls wrapper, no Markdown fence):
            {"citedRecordIDs":["S1"],"answerMarkdown":"Your concise answer in the operator's language, at most 180 words, one short paragraph per relevant camera","confidence":0.7}
            Replace S1 with actual supporting aliases from the catalogue. Put source aliases ONLY in citedRecordIDs, not in the answer text. Do not list UUIDs, propose actions, add recommendations, or repeat the JSON field names in answerMarkdown. Never claim that no other events occurred merely because only a sample was retrieved.
            """
        } else { prompt = Self.renderLocalAgentPrompt(request: request) }
        agentTrace?("REQUEST chars=\(prompt.count) backend=mlx")
        var images: [Data] = []
        for item in request.fullInput {
            if case .user(_, let imgs) = item { images.append(contentsOf: imgs) }
        }
        let recentImages = Array(images.suffix(4))
        let raw: String
        guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
        let preview = onAnswerPreview.map { callback in
            ACTALocalAnswerStream { text, revision in
                guard !Task.isCancelled, authorization?() ?? true else { return }
                callback(text, revision)
            }
        }
        let onChunk: (@Sendable (String) -> Void)? = preview.map { stream in
            { @Sendable chunk in
                guard !Task.isCancelled, authorization?() ?? true else {
                    stream.close()
                    return
                }
                stream.append(chunk)
            }
        }
        defer { preview?.close() }
        raw = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: String
            if let localAgentStreamInference {
                response = try await localAgentStreamInference(prompt, recentImages, onChunk)
            } else if let localAgentInference {
                response = try await localAgentInference(prompt, recentImages)
            } else {
                guard let localVLM else { throw ACTAAgentError.noBackendAvailable }
                if recentImages.isEmpty { response = try await localVLM.analyze(text: prompt, maxTokens: 2048, requestWorkload: .interactive, onChunk: onChunk) }
                else { response = try await localVLM.analyze(images: recentImages, prompt: prompt, maxTokens: 2048, requestWorkload: .interactive, onChunk: onChunk) }
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            preview?.close()
        }
        guard authorization?() ?? true else { throw ACTARequestAuthorizationError.revoked }
        agentTrace?("RESPONSE chars=\(raw.count) backend=mlx")
        let parsed = Self.parseLocalAgentReply(raw)
        return ACTAAgentTurnResult(responseID: nil, text: parsed.text, functionCalls: parsed.calls, backend: .mlx)
    }

    public static func buildOpenAIAgentBody(request: ACTAAgentRequest) -> [String: Any] {
        let chained = (request.previousResponseID?.isEmpty == false)
        let items = chained ? request.chainedInput : request.fullInput
        var body: [String: Any] = [
            "model": request.tier.rawValue,
            "store": true,
            "instructions": request.instructions,
            "input": items.map(encodeResponsesItem),
            "parallel_tool_calls": true
        ]
        if chained, let previous = request.previousResponseID {
            body["previous_response_id"] = previous
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parametersObject
                ]
            }
            switch request.toolChoice {
            case .auto: body["tool_choice"] = "auto"
            case .required: body["tool_choice"] = "required"
            case .function(let name): body["tool_choice"] = ["type": "function", "name": name]
            }
        }
        return body
    }

    static func encodeResponsesItem(_ item: ACTAAgentItem) -> [String: Any] {
        switch item {
        case .user(let text, let images):
            var content: [[String: Any]] = [["type": "input_text", "text": text]]
            for img in images {
                content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(img.base64EncodedString())"])
            }
            return ["role": "user", "content": content]
        case .assistantText(let text):
            return ["role": "assistant", "content": text]
        case .functionCall(let call):
            return ["type": "function_call", "call_id": call.callID, "name": call.name, "arguments": call.argumentsJSON]
        case .functionOutput(let callID, let output):
            return ["type": "function_call_output", "call_id": callID, "output": output]
        }
    }

    /// Extracts assistant text and `function_call` items from a Responses API payload, skipping `reasoning` items.
    public static func parseResponsesOutput(_ root: [String: Any]) -> (text: String?, calls: [ACTAAgentFunctionCall]) {
        var texts: [String] = []
        var calls: [ACTAAgentFunctionCall] = []
        for item in (root["output"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "function_call":
                guard let name = item["name"] as? String else { continue }
                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? "call_\(UUID().uuidString.prefix(12))"
                let raw = (item["arguments"] as? String) ?? ""
                calls.append(ACTAAgentFunctionCall(callID: callID, name: name, argumentsJSON: raw))
            case "message", nil:
                for part in (item["content"] as? [[String: Any]]) ?? [] {
                    if let type = part["type"] as? String, type != "output_text", type != "text" { continue }
                    if let text = part["text"] as? String { texts.append(text) }
                }
            default:
                continue
            }
        }
        if texts.isEmpty, let outputText = root["output_text"] as? String {
            texts.append(outputText)
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined.isEmpty ? nil : joined, calls)
    }

    static func renderLocalAgentPrompt(request: ACTAAgentRequest) -> String {
        let catalog = request.tools.map { "- `\($0.name)`: \($0.description) Parameters schema: \($0.parametersSchemaJSON)" }
            .joined(separator: "\n")
        let transcript = request.fullInput.map { item -> String in
            switch item {
            case .user(let text, let images):
                return "[USER]\(images.isEmpty ? "" : " (+\(images.count) image(s))"): \(text)"
            case .assistantText(let text):
                return "[ASSISTANT]: \(text)"
            case .functionCall(let call):
                return "[TOOL CALL \(call.callID)] \(call.name) \(call.argumentsJSON)"
            case .functionOutput(let callID, let output):
                return "[TOOL RESULT \(callID)]: \(output.count > 6000 ? String(output.prefix(6000)) + "…" : output)"
            }
        }.joined(separator: "\n")
        let choiceLine: String
        switch request.toolChoice {
        case .function(let name): choiceLine = "You MUST call `\(name)` now."
        case .required: choiceLine = "You MUST call at least one tool."
        case .auto: choiceLine = "Call data tools while you need more evidence; call `present_answer` when ready."
        }
        return """
        \(request.instructions)

        ## Available tools
        \(catalog)

        ## Conversation so far
        \(transcript)

        ## Reply format
        Reply with exactly ONE JSON object and nothing else:
        {"tool_calls":[{"name":"<tool name>","arguments":{...}}]}
        \(choiceLine)
        """
    }

    static func parseLocalAgentReply(_ raw: String) -> (text: String?, calls: [ACTAAgentFunctionCall]) {
        let cleaned = extractJSONObject(from: raw)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any] else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : trimmed, [])
        }
        func makeCall(_ entry: [String: Any], rawEntry: String?) -> ACTAAgentFunctionCall? {
            guard let name = (entry["name"] as? String) ?? (entry["tool"] as? String) else { return nil }
            let args = entry["arguments"] ?? entry["args"] ?? [String: Any]()
            let argsJSON: String
            if let str = args as? String {
                argsJSON = str
            } else if JSONSerialization.isValidJSONObject(args),
                      let data = try? JSONSerialization.data(withJSONObject: args) {
                argsJSON = String(decoding: data, as: UTF8.self)
            } else {
                argsJSON = "{}"
            }
            var rawJSON = ""
            if let rawEntry {
                var reader = ACTARawJSONRanges(rawEntry)
                if let fields = reader.object() {
                    if let literal = fields["arguments"] ?? fields["args"] {
                        rawJSON = (args as? String) ?? literal
                    }
                }
            }
            return ACTAAgentFunctionCall(callID: "call_local_\(UUID().uuidString.prefix(12))", name: name,
                                         argumentsJSON: argsJSON, rawArgumentsJSON: rawJSON)
        }
        if let list = obj["tool_calls"] as? [[String: Any]] {
            var reader = ACTARawJSONRanges(cleaned)
            let rawList: [String]?
            if let rawArray = reader.object()?["tool_calls"] {
                var arrayReader = ACTARawJSONRanges(rawArray)
                rawList = arrayReader.array()
            } else {
                rawList = nil
            }
            return (nil, list.enumerated().compactMap { index, entry in
                makeCall(entry, rawEntry: rawList.flatMap { index < $0.count ? $0[index] : nil })
            })
        }
        if let call = makeCall(obj, rawEntry: cleaned) {
            return (nil, [call])
        }
        if obj["answerMarkdown"] != nil {
            return (nil, [ACTAAgentFunctionCall(callID: "call_local_\(UUID().uuidString.prefix(12))", name: "present_answer", argumentsJSON: cleaned)])
        }
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
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

public final class ACTAIsraeliVehicleRegistryClient: @unchecked Sendable {
    private let urlSession: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10.0
        self.urlSession = URLSession(configuration: cfg)
    }

    public func lookupPlate(
        rawPlate: String,
        store: LocalTrackingStore? = nil,
        allowExternalLookup: Bool = false
    ) async -> ACTAVehicleRegistryRecord? {
        guard let normalized = ACTAVehicleRegistryRecord.normalizeIsraeliPlate(rawPlate) else {
            return nil
        }
        if let cached = try? store?.cachedVehicleRegistryRecord(plateNumber: normalized) {
            return cached
        }
        guard allowExternalLookup else {
            return nil
        }

        let resources = [
            ACTAVehicleRegistryRecord.privateVehiclesResourceID,
            ACTAVehicleRegistryRecord.motorcyclesResourceID,
            ACTAVehicleRegistryRecord.heavyVehiclesResourceID
        ]

        for resourceID in resources {
            if let record = try? await queryCKAN(resourceID: resourceID, plateNumber: normalized) {
                try? store?.cacheVehicleRegistryRecord(record)
                return record
            }
        }
        return nil
    }

    private func queryCKAN(resourceID: String, plateNumber: String) async throws -> ACTAVehicleRegistryRecord? {
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

        return ACTAVehicleRegistryRecord(
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
