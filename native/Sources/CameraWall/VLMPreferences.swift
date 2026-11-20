import Foundation
import CameraCore

struct VLMPreferences: Codable, Equatable {
    private static var defaultModelPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/models/qwen3.5-9b")
            .standardizedFileURL.path
    }

    var model = VLMPreferences.defaultModelPath
    var scheduleEnabled = false
    var intervalSeconds = 15
    var analyzeAllEnabledCameras = true
    var scheduledCameraIDs: Set<UUID> = []
    var alertRules: [VLMAlertRule] = []
    var actaBackendMode: ACTAAIBackendMode = .mlxInProcess
    var actaVLLMBaseURL: String = "http://127.0.0.1:8000/v1"
    var actaVLLMModelName: String = "Qwen/Qwen2.5-VL-7B-Instruct"
    var actaVLLMAllowLocalMLXFallback: Bool = false
    var actaVLLMMaxConcurrentRequests: Int = 4
    var actaVLLMGPUMemoryUtilization: Double = 0.65
    var actaOpenAIBaseURL: String = "https://api.openai.com/v1/responses"
    var actaPreferredLanguage: ACTAPromptLanguage = .ru
    var actaSpokenBriefingEnabled: Bool = false
    var cloudNanoModel = ACTAAITier.nano.rawValue
    var cloudMiniModel = ACTAAITier.mini.rawValue
    var cloudFullModel = ACTAAITier.full.rawValue
    var actaBackupRelayURL = "http://127.0.0.1:8018/api/backup/responses"
    var privacyBlurFacesInCloud = true
    var privacyBlurPlatesInCloud = true
    var dailyBudgetLimitUSD = 80.0
    var monthlyBudgetLimitUSD = 400.0


    func validate() throws {
        for value in [actaVLLMBaseURL, actaOpenAIBaseURL, actaBackupRelayURL] {
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil else {
                throw ConfigurationError.invalid("Enter an HTTP or HTTPS endpoint without credentials or fragments.")
            }
        }
        guard [cloudNanoModel, cloudMiniModel, cloudFullModel, actaVLLMModelName].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              alertRules.allSatisfy({ (15...86400).contains($0.cooldownSeconds) }) else {
            throw ConfigurationError.invalid("Check model names and alert cooldowns.")
        }
        guard dailyBudgetLimitUSD.isFinite, monthlyBudgetLimitUSD.isFinite, dailyBudgetLimitUSD >= 0, monthlyBudgetLimitUSD >= dailyBudgetLimitUSD else {
            throw ConfigurationError.invalid("Check the daily and monthly AI budget limits.")
        }
        guard (1...16).contains(actaVLLMMaxConcurrentRequests),
              actaVLLMGPUMemoryUtilization.isFinite,
              (0.30...0.90).contains(actaVLLMGPUMemoryUtilization) else {
            throw ConfigurationError.invalid("Check local vLLM concurrency (1-16) and GPU memory utilization (0.30-0.90).")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (15...3600).contains(intervalSeconds), alertRules.count <= 20,
              alertRules.allSatisfy({ !$0.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.condition.count <= 500 }) else {
            throw ConfigurationError.invalid("Check the VLM model, schedule interval and alert rules.")
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case cloudNanoModel, cloudMiniModel, cloudFullModel
        case actaBackupRelayURL, privacyBlurFacesInCloud, privacyBlurPlatesInCloud, dailyBudgetLimitUSD, monthlyBudgetLimitUSD
        case model, scheduleEnabled, intervalSeconds, analyzeAllEnabledCameras, scheduledCameraIDs, alertRules
        case actaBackendMode = "ghostBackendMode"
        case actaVLLMBaseURL = "ghostVLLMBaseURL"
        case actaVLLMModelName = "ghostVLLMModelName"
        case actaVLLMAllowLocalMLXFallback
        case actaVLLMMaxConcurrentRequests
        case actaVLLMGPUMemoryUtilization
        case actaOpenAIBaseURL = "ghostOpenAIBaseURL"
        case actaPreferredLanguage = "ghostPreferredLanguage"
        case actaSpokenBriefingEnabled = "ghostSpokenBriefingEnabled"
    }

    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cloudNanoModel = try c.decodeIfPresent(String.self, forKey: .cloudNanoModel) ?? ACTAAITier.nano.rawValue
        cloudMiniModel = try c.decodeIfPresent(String.self, forKey: .cloudMiniModel) ?? ACTAAITier.mini.rawValue
        cloudFullModel = try c.decodeIfPresent(String.self, forKey: .cloudFullModel) ?? ACTAAITier.full.rawValue
        actaBackupRelayURL = try c.decodeIfPresent(String.self, forKey: .actaBackupRelayURL) ?? "http://127.0.0.1:8018/api/backup/responses"
        privacyBlurFacesInCloud = try c.decodeIfPresent(Bool.self, forKey: .privacyBlurFacesInCloud) ?? true
        privacyBlurPlatesInCloud = try c.decodeIfPresent(Bool.self, forKey: .privacyBlurPlatesInCloud) ?? true
        dailyBudgetLimitUSD = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetLimitUSD) ?? 80
        monthlyBudgetLimitUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyBudgetLimitUSD) ?? 400
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? VLMPreferences.defaultModelPath
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 15
        analyzeAllEnabledCameras = try c.decodeIfPresent(Bool.self, forKey: .analyzeAllEnabledCameras) ?? true
        scheduledCameraIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .scheduledCameraIDs) ?? []
        alertRules = try c.decodeIfPresent([VLMAlertRule].self, forKey: .alertRules) ?? []
        actaBackendMode = try c.decodeIfPresent(ACTAAIBackendMode.self, forKey: .actaBackendMode) ?? .mlxInProcess
        actaVLLMBaseURL = try c.decodeIfPresent(String.self, forKey: .actaVLLMBaseURL) ?? "http://127.0.0.1:8000/v1"
        actaVLLMModelName = try c.decodeIfPresent(String.self, forKey: .actaVLLMModelName) ?? "Qwen/Qwen2.5-VL-7B-Instruct"
        actaVLLMAllowLocalMLXFallback = try c.decodeIfPresent(Bool.self, forKey: .actaVLLMAllowLocalMLXFallback) ?? false
        actaVLLMMaxConcurrentRequests = try c.decodeIfPresent(Int.self, forKey: .actaVLLMMaxConcurrentRequests) ?? 4
        actaVLLMGPUMemoryUtilization = try c.decodeIfPresent(Double.self, forKey: .actaVLLMGPUMemoryUtilization) ?? 0.65
        actaOpenAIBaseURL = try c.decodeIfPresent(String.self, forKey: .actaOpenAIBaseURL) ?? "https://api.openai.com/v1/responses"
        actaPreferredLanguage = try c.decodeIfPresent(ACTAPromptLanguage.self, forKey: .actaPreferredLanguage) ?? .ru
        actaSpokenBriefingEnabled = try c.decodeIfPresent(Bool.self, forKey: .actaSpokenBriefingEnabled) ?? false
    }
}

struct VLMAlertRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var condition: String
    var enabled = true
    var cooldownSeconds = 300
    var priority: OperationsAlertReview.Priority = .normal
}

extension VLMAlertRule {
    private enum CodingKeys: String, CodingKey { case id, condition, enabled, cooldownSeconds, priority }

    init(from decoder: Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        condition = try values.decode(String.self, forKey: .condition)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cooldownSeconds = try values.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 300
        priority = try values.decodeIfPresent(OperationsAlertReview.Priority.self, forKey: .priority) ?? .normal
    }
}

struct VLMChatMessage: Identifiable, Equatable {
    enum Role: String { case operatorMessage, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let cameraNames: [String]
    let createdAt = Date()
}

enum VLMChatDelivery {
    static func appendAnswer(_ text: String, cameraNames: [String], scheduled: Bool, to messages: inout [VLMChatMessage]) {
        guard !scheduled else { return }
        messages.append(VLMChatMessage(role: .assistant, text: text, cameraNames: cameraNames))
    }
}

struct VLMManualQuestionQueue {
    struct Request: Equatable {
        let question: String
        let cameraIDs: Set<UUID>
    }

    private(set) var pending: Request?

    mutating func enqueue(question: String, cameraIDs: Set<UUID>) -> Bool {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending == nil, !text.isEmpty, text.count <= 2000, !cameraIDs.isEmpty else { return false }
        pending = Request(question: text, cameraIDs: cameraIDs)
        return true
    }

    mutating func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

struct VLMAnalysisSchedule {
    private(set) var lastScheduledAt: [UUID: TimeInterval] = [:]
    private(set) var lastSubmissionAt: TimeInterval = 0
    private(set) var cursor = 0

    func nextCamera(in cameraIDs: [UUID], now: TimeInterval, intervalSeconds: Int,
                    isEligible: (UUID) -> Bool) -> UUID? {
        guard !cameraIDs.isEmpty, now - lastSubmissionAt >= 0.5 else { return nil }
        for offset in cameraIDs.indices {
            let index = (cursor + offset) % cameraIDs.count
            let cameraID = cameraIDs[index]
            guard now - (lastScheduledAt[cameraID] ?? 0) >= Double(intervalSeconds),
                  isEligible(cameraID) else { continue }
            return cameraID
        }
        return nil
    }

    mutating func markSubmitted(cameraID: UUID, in cameraIDs: [UUID], at now: TimeInterval) {
        guard let index = cameraIDs.firstIndex(of: cameraID), !cameraIDs.isEmpty else { return }
        lastScheduledAt[cameraID] = now
        lastSubmissionAt = now
        cursor = (index + 1) % cameraIDs.count
    }

    mutating func reset() {
        lastScheduledAt.removeAll()
        lastSubmissionAt = 0
        cursor = 0
    }
}

struct VLMAlert: Codable, Equatable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var cameraID: UUID
    var cameraName: String
    var condition: String
    var evidence: String
    var priority: OperationsAlertReview.Priority = .normal
    var watchID: UUID? = nil
    var sourceTrackID: UUID? = nil
    var clipID: UUID? = nil
}

extension VLMAlert {
    private enum CodingKeys: String, CodingKey { case id, createdAt, cameraID, cameraName, condition, evidence, priority, watchID, sourceTrackID, clipID }

    init(from decoder: Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        cameraID = try values.decode(UUID.self, forKey: .cameraID)
        cameraName = try values.decode(String.self, forKey: .cameraName)
        condition = try values.decode(String.self, forKey: .condition)
        evidence = try values.decode(String.self, forKey: .evidence)
        priority = try values.decodeIfPresent(OperationsAlertReview.Priority.self, forKey: .priority) ?? .normal
        watchID = try values.decodeIfPresent(UUID.self, forKey: .watchID)
        sourceTrackID = try values.decodeIfPresent(UUID.self, forKey: .sourceTrackID)
        clipID = try values.decodeIfPresent(UUID.self, forKey: .clipID)
    }
}

enum VLMStore {
    static func loadPreferences(from url: URL) throws -> VLMPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return VLMPreferences() }
        return try JSONDecoder().decode(VLMPreferences.self, from: Data(contentsOf: url))
    }

    static func save(_ preferences: VLMPreferences, to url: URL) throws {
        try preferences.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(encoder.encode(preferences), to: url)
    }

    static func loadAlerts(from url: URL) throws -> [VLMAlert] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VLMAlert].self, from: Data(contentsOf: url))
    }

    static func save(_ alerts: [VLMAlert], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(encoder.encode(Array(alerts.prefix(100))), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct VLMAlertClearConfirmation {
    private let alerts: [VLMAlert]
    private let diskImage: Data

    static func capture(visible: [VLMAlert], from url: URL) throws -> VLMAlertClearConfirmation? {
        guard !visible.isEmpty else { return nil }
        let image = try Data(contentsOf: url)
        guard try JSONDecoder().decode([VLMAlert].self, from: image) == visible else { return nil }
        return VLMAlertClearConfirmation(alerts: visible, diskImage: image)
    }

    func isCurrent(visible: [VLMAlert], from url: URL) throws -> Bool {
        guard visible == alerts else { return false }
        return try Data(contentsOf: url) == diskImage
    }
}
