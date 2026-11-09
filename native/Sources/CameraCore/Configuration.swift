import Foundation

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct Camera: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var location: String?
    public var substream: String
    public var mainstream: String?
    public var localDeviceID: String?
    public var screenDisplayID: String?
    public var fileURL: URL?
    public var fileBookmarkData: Data?
    public var enabled: Bool
    public var yoloEnabled: Bool
    public var aiChatEnabled: Bool
    public var isapiEventsEnabled: Bool
    public var isapiHTTPS: Bool
    public var isapiPort: Int

    public init(id: UUID = UUID(), name: String, location: String? = nil, substream: String,
                mainstream: String? = nil, enabled: Bool = true, localDeviceID: String? = nil,
                screenDisplayID: String? = nil,
                fileURL: URL? = nil,
                fileBookmarkData: Data? = nil,
                yoloEnabled: Bool = false, aiChatEnabled: Bool = true,
                isapiEventsEnabled: Bool = false, isapiHTTPS: Bool = false, isapiPort: Int = 80) {
        self.localDeviceID = localDeviceID
        self.screenDisplayID = screenDisplayID
        self.fileURL = fileURL
        self.fileBookmarkData = fileBookmarkData
        self.id = id
        self.name = name
        self.location = location
        self.substream = substream
        self.mainstream = mainstream
        self.enabled = enabled
        self.yoloEnabled = yoloEnabled
        self.aiChatEnabled = aiChatEnabled
        self.isapiEventsEnabled = isapiEventsEnabled
        self.isapiHTTPS = isapiHTTPS
        self.isapiPort = isapiPort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, location, substream, mainstream, localDeviceID, screenDisplayID, fileURL, fileBookmarkData
        case enabled, yoloEnabled, aiChatEnabled
        case isapiEventsEnabled, isapiHTTPS, isapiPort
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        location = try values.decodeIfPresent(String.self, forKey: .location)
        substream = try values.decode(String.self, forKey: .substream)
        mainstream = try values.decodeIfPresent(String.self, forKey: .mainstream)
        localDeviceID = try values.decodeIfPresent(String.self, forKey: .localDeviceID)
        screenDisplayID = try values.decodeIfPresent(String.self, forKey: .screenDisplayID)
        fileURL = try values.decodeIfPresent(URL.self, forKey: .fileURL)
        fileBookmarkData = try values.decodeIfPresent(Data.self, forKey: .fileBookmarkData)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        yoloEnabled = try values.decodeIfPresent(Bool.self, forKey: .yoloEnabled) ?? false
        aiChatEnabled = try values.decodeIfPresent(Bool.self, forKey: .aiChatEnabled) ?? true
        isapiEventsEnabled = try values.decodeIfPresent(Bool.self, forKey: .isapiEventsEnabled) ?? false
        isapiHTTPS = try values.decodeIfPresent(Bool.self, forKey: .isapiHTTPS) ?? false
        isapiPort = try values.decodeIfPresent(Int.self, forKey: .isapiPort) ?? 80
    }

    public func source(expanded: Bool) -> String {
        fileURL?.absoluteString ?? screenDisplayID.map { "screen://\($0)" }
            ?? (expanded ? (mainstream ?? substream) : substream)
    }

    public func streamName(expanded: Bool) -> String {
        "cam_" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            + (expanded && mainstream != nil ? "_main" : "_sub")
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalid("Camera name is required.")
        }
        guard (1...65535).contains(isapiPort),
              isapiEventsEnabled == false || (localDeviceID == nil && screenDisplayID == nil && fileURL == nil) else {
            throw ConfigurationError.invalid("ISAPI events require a network camera and a valid port.")
        }
        if let localDeviceID {
            guard !localDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  substream.isEmpty, mainstream == nil, screenDisplayID == nil, fileURL == nil else {
                throw ConfigurationError.invalid("Select a local camera without network stream URLs.")
            }
            return
        }
        if let screenDisplayID {
            guard UInt32(screenDisplayID) != nil, substream.isEmpty, mainstream == nil, fileURL == nil else {
                throw ConfigurationError.invalid("Select a display without camera stream URLs.")
            }
            return
        }
        if let fileURL {
            guard fileURL.isFileURL, !fileURL.path.isEmpty,
                  substream.isEmpty, mainstream == nil, screenDisplayID == nil else {
                throw ConfigurationError.invalid("Select a local video file without network stream URLs.")
            }
            return
        }
        for source in [substream, mainstream].compactMap({ $0 }) {
            guard let url = URLComponents(string: source),
                  ["rtsp", "rtsps", "onvif"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw ConfigurationError.invalid("Use a camera stream URL without credentials or fragments. Store credentials in Keychain.")
            }
        }
    }
}

public struct WallConfiguration: Codable, Equatable {
    public var cameras: [Camera] = []
    public var columns: Int = 4
    public var staleAfterMilliseconds: Int = 1000
    public var go2rtcPath: String = "/opt/homebrew/bin/go2rtc"
    public var apiPort: Int = 11984
    public var rtspPort: Int = 18554
    public var detectionThreshold: Double = 0.35
    public var detectionFPS: Double = 2

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case cameras, columns, staleAfterMilliseconds, go2rtcPath, apiPort, rtspPort
        case detectionThreshold, detectionFPS
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cameras = try values.decode([Camera].self, forKey: .cameras)
        columns = try values.decode(Int.self, forKey: .columns)
        staleAfterMilliseconds = try values.decode(Int.self, forKey: .staleAfterMilliseconds)
        go2rtcPath = try values.decode(String.self, forKey: .go2rtcPath)
        apiPort = try values.decode(Int.self, forKey: .apiPort)
        rtspPort = try values.decode(Int.self, forKey: .rtspPort)
        detectionThreshold = try values.decodeIfPresent(Double.self, forKey: .detectionThreshold) ?? 0.35
        detectionFPS = try values.decodeIfPresent(Double.self, forKey: .detectionFPS) ?? 2
    }

    public func applyingSettings(from draft: WallConfiguration) throws -> WallConfiguration {
        var next = self
        next.columns = draft.columns
        next.staleAfterMilliseconds = draft.staleAfterMilliseconds
        next.go2rtcPath = draft.go2rtcPath
        next.detectionThreshold = draft.detectionThreshold
        next.detectionFPS = draft.detectionFPS
        try next.validate()
        return next
    }

    public func validate() throws {
        guard (1...16).contains(columns), (200...30000).contains(staleAfterMilliseconds),
              (1024...65535).contains(apiPort), (1024...65535).contains(rtspPort),
              apiPort != rtspPort else {
            throw ConfigurationError.invalid("Invalid layout, stale threshold or local ports.")
        }
        guard detectionThreshold.isFinite, (0.1...0.9).contains(detectionThreshold),
              detectionFPS.isFinite, (1...5).contains(detectionFPS), detectionFPS.rounded() == detectionFPS else {
            throw ConfigurationError.invalid("Invalid YOLO confidence threshold or detection rate.")
        }
        guard !go2rtcPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalid("go2rtc executable path is required.")
        }
        guard Set(cameras.map(\.id)).count == cameras.count else {
            throw ConfigurationError.invalid("Camera IDs must be unique.")
        }
        for camera in cameras { try camera.validate() }
    }
}

public enum ConfigurationStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/cameras.json")
    }

    public static func load(from url: URL) throws -> WallConfiguration {
        let config = try JSONDecoder().decode(WallConfiguration.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public static func save(_ config: WallConfiguration, to url: URL) throws {
        try config.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}