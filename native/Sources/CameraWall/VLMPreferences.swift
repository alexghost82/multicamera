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
    var ghostBackendMode: GhostAIBackendMode = .mlxInProcess
    var ghostVLLMBaseURL: String = "http://127.0.0.1:8000/v1"
    var ghostVLLMModelName: String = "Qwen/Qwen2.5-VL-7B-Instruct"
    var ghostOpenAIBaseURL: String = "https://api.openai.com/v1/responses"
    var ghostPreferredLanguage: GhostPromptLanguage = .ru
    var ghostSpokenBriefingEnabled: Bool = false

    func validate() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (15...3600).contains(intervalSeconds), alertRules.count <= 20,
              alertRules.allSatisfy({ !$0.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.condition.count <= 500 }) else {
            throw ConfigurationError.invalid("Check the VLM model, schedule interval and alert rules.")
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case model, scheduleEnabled, intervalSeconds, analyzeAllEnabledCameras, scheduledCameraIDs, alertRules
        case ghostBackendMode, ghostVLLMBaseURL, ghostVLLMModelName, ghostOpenAIBaseURL, ghostPreferredLanguage, ghostSpokenBriefingEnabled
    }

    init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? VLMPreferences.defaultModelPath
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 15
        analyzeAllEnabledCameras = try c.decodeIfPresent(Bool.self, forKey: .analyzeAllEnabledCameras) ?? true
        scheduledCameraIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .scheduledCameraIDs) ?? []
        alertRules = try c.decodeIfPresent([VLMAlertRule].self, forKey: .alertRules) ?? []
        ghostBackendMode = try c.decodeIfPresent(GhostAIBackendMode.self, forKey: .ghostBackendMode) ?? .mlxInProcess
        ghostVLLMBaseURL = try c.decodeIfPresent(String.self, forKey: .ghostVLLMBaseURL) ?? "http://127.0.0.1:8000/v1"
        ghostVLLMModelName = try c.decodeIfPresent(String.self, forKey: .ghostVLLMModelName) ?? "Qwen/Qwen2.5-VL-7B-Instruct"
        ghostOpenAIBaseURL = try c.decodeIfPresent(String.self, forKey: .ghostOpenAIBaseURL) ?? "https://api.openai.com/v1/responses"
        ghostPreferredLanguage = try c.decodeIfPresent(GhostPromptLanguage.self, forKey: .ghostPreferredLanguage) ?? .ru
        ghostSpokenBriefingEnabled = try c.decodeIfPresent(Bool.self, forKey: .ghostSpokenBriefingEnabled) ?? false
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
