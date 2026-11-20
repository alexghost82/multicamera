import Foundation
import Darwin

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

public enum CameraFeaturePreferencesStoreError: LocalizedError, Equatable {
    case busy, unsafeLock

    public var errorDescription: String? {
        switch self {
        case .busy: return "Feature preferences are busy. Please try again."
        case .unsafeLock: return "Feature preferences lock is unsafe or was replaced; the operation may require reconciliation."
        }
    }
}

public enum CameraFeaturePreferencesStore {
    public struct Snapshot: Sendable {
        public let preferences: CameraFeaturePreferences
        public let revision: String?
    }

    private struct Revision: Decodable {
        let _identityPolicyRevision: String?
    }

    private struct RevisionedPreferences: Encodable {
        let preferences: CameraFeaturePreferences
        let revision: String

        private enum CodingKeys: String, CodingKey { case _identityPolicyRevision }

        func encode(to encoder: Encoder) throws {
            try preferences.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(revision, forKey: ._identityPolicyRevision)
        }
    }

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
        try withLock(to: url) {
            try saveLocked(preferences, to: url)
        }
    }

    /// The callback must not re-enter this store. All cooperating writers use the same lock.
    public static func withLockedSnapshot<T>(
        from url: URL = defaultURL, _ body: (Snapshot) throws -> T
    ) throws -> T {
        try withLock(to: url) {
            let data = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
            let preferences = try data.map { try JSONDecoder().decode(CameraFeaturePreferences.self, from: $0) }
                ?? CameraFeaturePreferences()
            try preferences.validate()
            let revision = try data.map { try JSONDecoder().decode(Revision.self, from: $0)._identityPolicyRevision } ?? nil
            if let revision, UUID(uuidString: revision) == nil {
                throw ConfigurationError.invalid("Invalid feature policy revision.")
            }
            return try body(Snapshot(preferences: preferences, revision: revision))
        }
    }

    @discardableResult
    public static func update(
        at url: URL = defaultURL, _ body: (inout CameraFeaturePreferences) throws -> Void
    ) throws -> CameraFeaturePreferences {
        try withLock(to: url) {
            var preferences = try load(from: url)
            try body(&preferences)
            try preferences.validate()
            try saveLocked(preferences, to: url)
            return preferences
        }
    }

    private static func withLock<T>(to url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK || failure == EAGAIN { throw CameraFeaturePreferencesStoreError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }
        func validateLock() throws {
            var opened = stat()
            var current = stat()
            guard fstat(fd, &opened) == 0, lstat(lockURL.path, &current) == 0,
                  opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
                  opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
                  current.st_mode & S_IFMT == S_IFREG,
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw CameraFeaturePreferencesStoreError.unsafeLock
            }
        }
        try validateLock()
        do {
            let result = try body()
            try validateLock()
            return result
        } catch {
            try validateLock()
            throw error
        }
    }

    private static func saveLocked(_ preferences: CameraFeaturePreferences, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(RevisionedPreferences(preferences: preferences, revision: UUID().uuidString))
            .write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}