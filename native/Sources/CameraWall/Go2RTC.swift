import Foundation
import Security
import CameraCore

struct Credentials: Codable, Equatable, Sendable {
    var username: String
    var password: String
}

enum CameraKeychain {
    static func read(_ id: UUID) throws -> Credentials? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ConfigurationError.invalid("Keychain read failed (\(status)).")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials, for id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = base(id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConfigurationError.invalid("Keychain write failed (\(added)).") }
        } else if status != errSecSuccess {
            throw ConfigurationError.invalid("Keychain update failed (\(status)).")
        }
    }

    static func remove(_ id: UUID) { try? removeChecked(id) }

    static func removeChecked(_ id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.invalid("Keychain delete failed (\(status)).")
        }
    }

    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "CameraWall.RTSP",
         kSecAttrAccount as String: id.uuidString]
    }
}

protocol CameraCredentialStore: Sendable {
    func read(_ id: UUID) throws -> Credentials?
    func save(_ credentials: Credentials, for id: UUID) throws
    func remove(_ id: UUID) throws
}

struct SystemCameraCredentialStore: CameraCredentialStore {
    func read(_ id: UUID) throws -> Credentials? { try CameraKeychain.read(id) }
    func save(_ credentials: Credentials, for id: UUID) throws { try CameraKeychain.save(credentials, for: id) }
    func remove(_ id: UUID) throws { try CameraKeychain.removeChecked(id) }
}

@MainActor
final class Go2RTC {
    private var process: Process?
    private var token = ""
    private var apiPort = 11984
    private var rtspPort = 18554
    private var reconnectRegistrations = 0
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let runningOverride: (() -> Bool)?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    init(transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         runningOverride: (() -> Bool)? = nil) {
        self.transport = transport
        self.runningOverride = runningOverride
    }

    var running: Bool { runningOverride?() ?? (process?.isRunning == true) }

    static func executablePath(configuredPath: String, bundleURL: URL) -> String {
        let bundledPath = bundleURL.appendingPathComponent("Contents/Helpers/go2rtc").path
        return FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : configuredPath
    }

    func start(config: WallConfiguration) async throws {
        stop()
        reconnectRegistrations = 0
        apiPort = config.apiPort
        rtspPort = config.rtspPort
        // Keep API password compact for compatibility with go2rtc auth parsers.
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let executablePath = Self.executablePath(configuredPath: config.go2rtcPath, bundleURL: Bundle.main.bundleURL)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ConfigurationError.invalid("go2rtc executable not found. Set its path in Settings.")
        }
        let settings: [String: Any] = [
            "app": ["modules": ["api", "streams", "rtsp", "onvif"]],
            "api": ["listen": "127.0.0.1:\(apiPort)", "username": "camerawall",
                    "password": token, "local_auth": true, "allow_paths": ["/api/streams", "/api/onvif"]],
            "rtsp": ["listen": "127.0.0.1:\(rtspPort)", "default_query": "video"],
            "log": ["level": "disabled"], "streams": [String: String]()
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CameraWall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("relay.json")
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.withoutEscapingSlashes])
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationError.invalid("Cannot create private relay configuration.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executablePath)
        child.arguments = ["-config", file.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        var lastFailure = "No response"
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard child.isRunning else { throw ConfigurationError.invalid("go2rtc stopped. Check executable and local ports.") }
            do {
                _ = try await request(method: "GET", items: [])
                return
            } catch let failure as ConfigurationError {
                lastFailure = failure.localizedDescription
            } catch let failure as URLError {
                lastFailure = "Network error \(failure.code.rawValue)"
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
        throw ConfigurationError.invalid("go2rtc did not start: \(lastFailure). Check local ports.")
    }

    func register(camera: Camera, expanded: Bool) async throws -> String {
        try await register(source: camera.source(expanded: expanded),
                           name: camera.streamName(expanded: expanded),
                           credentials: CameraKeychain.read(camera.id))
    }

    func register(source address: String, name: String, credentials: Credentials?) async throws -> String {
        guard var source = URLComponents(string: address) else { throw ConfigurationError.invalid("Invalid camera URL.") }
        if let credentials, !credentials.username.isEmpty {
            source.user = credentials.username
            source.password = credentials.password
        }
        guard let address = source.string else { throw ConfigurationError.invalid("Invalid camera URL.") }
        _ = try await request(method: "PATCH", items: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "src", value: address)])
        return "rtsp://127.0.0.1:\(rtspPort)/\(name)?video"
    }

    // Never reuse a reconnect name: an HTTP cancellation or timeout does not
    // prove that the relay did not apply the PATCH later.
    func registerReconnect(camera: Camera, expanded: Bool, attemptID: UUID,
                           credentials: Credentials?) async throws -> String {
        guard reconnectRegistrations < 64 else {
            throw ConfigurationError.invalid("Reconnect limit reached; restart the video wall to clear relay registrations.")
        }
        reconnectRegistrations += 1
        let name = camera.streamName(expanded: expanded) + "_r_" +
            attemptID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return try await register(source: camera.source(expanded: expanded), name: name, credentials: credentials)
    }

    func profiles(address: CameraAddress, credentials: Credentials) async throws -> [String] {
        let ports = address.port.map { [$0] } ?? [80, 8080, 8899]
        for port in ports {
            try Task.checkCancellation()
            var source = URLComponents(string: address.onvifURL(port: port))!
            if !credentials.username.isEmpty { source.user = credentials.username; source.password = credentials.password }
            do {
                let data = try await request(method: "GET", items: [URLQueryItem(name: "src", value: source.string)],
                                             path: "/api/onvif", timeout: 6)
                let result = try JSONDecoder().decode(ONVIFSources.self, from: data)
                let sources = result.sources.compactMap { item -> String? in
                    guard var url = URLComponents(string: item.url), url.scheme == "onvif",
                          !((url.queryItems ?? []).contains { $0.name == "snapshot" }) else { return nil }
                    url.user = nil
                    url.password = nil
                    return url.string
                }
                if !sources.isEmpty { return sources }
            } catch {
                try Task.checkCancellation()
            }
        }
        return []
    }

    private struct ONVIFSources: Decodable {
        struct Source: Decodable { var url: String }
        var sources: [Source]
    }

    private func request(method: String, items: [URLQueryItem], path: String = "/api/streams", timeout: TimeInterval = 2) async throws -> Data {
        var url = URLComponents(string: "http://127.0.0.1:\(apiPort)\(path)")!
        url.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let auth = Data("camerawall:\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        if let transport {
            (data, response) = try await transport(request)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConfigurationError.invalid("go2rtc HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    func stop() {
        if let child = process, child.isRunning {
            child.terminate()
            child.waitUntilExit()
        }
        process = nil
    }
}