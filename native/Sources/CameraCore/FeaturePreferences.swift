import Foundation

public enum CameraFeatureID: String, Codable, CaseIterable, Hashable, Sendable {
    case additionalVideoSources
    case enhancedDetection
    case crossCameraIdentity
    case visionDescriptions
    case historyResearch
    case operatorActions
    case chronologicalMemory
    case operationalAlerts
    case scheduledMissions
    case plateRecognition
    case knowledgeSearch
    case independentWatcher
    case publicShowcase
    case accessControl
}

public struct CameraFeaturePreferences: Codable, Equatable, Sendable {
    public var enabledFeatures: Set<CameraFeatureID>
    public var retainFullFrames: Bool
    public var allowExternalAI: Bool
    public var allowVoiceInput: Bool
    public var allowPlateRegistryLookup: Bool
    public var allowPublicAccess: Bool
    public var retentionDays: Int

    public init(
        enabledFeatures: Set<CameraFeatureID> = [],
        retainFullFrames: Bool = false,
        allowExternalAI: Bool = false,
        allowVoiceInput: Bool = false,
        allowPlateRegistryLookup: Bool = false,
        allowPublicAccess: Bool = false,
        retentionDays: Int = 30
    ) {
        self.enabledFeatures = enabledFeatures
        self.retainFullFrames = retainFullFrames
        self.allowExternalAI = allowExternalAI
        self.allowVoiceInput = allowVoiceInput
        self.allowPlateRegistryLookup = allowPlateRegistryLookup
        self.allowPublicAccess = allowPublicAccess
        self.retentionDays = retentionDays
    }

    public func validate() throws {
        guard (1...365).contains(retentionDays) else {
            throw ConfigurationError.invalid("Feature retention must be between 1 and 365 days.")
        }
    }
}

public enum CameraFeaturePreferencesStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/feature-preferences.json")
    }

    public static func load(from url: URL = defaultURL) throws -> CameraFeaturePreferences {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CameraFeaturePreferences()
        }
        let preferences = try JSONDecoder().decode(CameraFeaturePreferences.self, from: Data(contentsOf: url))
        try preferences.validate()
        return preferences
    }

    public static func save(_ preferences: CameraFeaturePreferences, to url: URL = defaultURL) throws {
        try preferences.validate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(preferences).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}