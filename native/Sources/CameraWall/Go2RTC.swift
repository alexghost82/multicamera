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
protocol RelayChild: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

@MainActor
private final class SystemRelayChild: RelayChild {
    private let process: Process
    private let readinessPipe: Pipe?
    private var guardianReady = false
    private var terminationPending = false

    init(executable: URL, configuration: URL, lease: CoordinatedCameraConfigurationStore.RuntimeLease? = nil,
         guardianExecutable: URL? = Bundle.main.executableURL, onExit: @escaping @Sendable () -> Void) throws {
        let process = Process()
        let readinessPipe: Pipe?
        if let lease {
            guard let guardianExecutable else { throw ConfigurationError.invalid("Relay guardian is unavailable.") }
            process.executableURL = guardianExecutable
            process.arguments = ["--relay-lease-guardian", String(getpid()), executable.path, configuration.path]
            process.standardInput = try lease.duplicateForChild()
            readinessPipe = Pipe()
            process.standardOutput = readinessPipe
        } else {
            process.executableURL = executable
            process.arguments = ["-config", configuration.path]
            process.standardInput = FileHandle.nullDevice
            readinessPipe = nil
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in onExit() }
        try process.run()
        self.process = process
        self.readinessPipe = readinessPipe
        readinessPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            handle.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, data == Data([0x52]) else { return }
                self.guardianReady = true
                if self.terminationPending, self.process.isRunning { self.process.terminate() }
            }
        }
    }

    var isRunning: Bool { process.isRunning }
    func terminate() {
        guard process.isRunning else { return }
        if readinessPipe != nil && !guardianReady {
            terminationPending = true
        } else {
            process.terminate()
        }
    }
}

// Reservations are shared by all relay instances in this application, including
// discovery. They are released only after the actual child exit notification.
@MainActor
private final class RelayPortReservations {
    static let shared = RelayPortReservations()
    private var owners: [Int: UUID] = [:]
    private var children: [UUID: any RelayChild] = [:]
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(_ ports: Set<Int>, owner: UUID) -> Bool {
        guard ports.allSatisfy({ owners[$0] == nil }) else { return false }
        for port in ports { owners[port] = owner }
        return true
    }

    func release(_ ports: Set<Int>, owner: UUID) {
        for port in ports where owners[port] == owner { owners[port] = nil }
        children[owner] = nil
        if children.isEmpty {
            let waiters = exitWaiters
            exitWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func retain(_ child: any RelayChild, owner: UUID) { children[owner] = child }

    func waitForChildren() async {
        guard !children.isEmpty else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }
}

@MainActor
private final class RelayChildExitGroup {
    private var owners: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func add(_ owner: UUID) { owners.insert(owner) }

    func remove(_ owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        guard !owners.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
final class Go2RTC {
    typealias ChildFactory = @MainActor (URL, URL, @escaping @Sendable () -> Void) throws -> any RelayChild
    private static let allRequests = RelayChildExitGroup()
    private final class ReadinessResult {
        var result: Result<Data, Error>?
    }
    private var process: (any RelayChild)?
    private var generation = UUID()
    private var acceptingRequests = true
    private var token = ""
    private var apiPort = 11984
    private var rtspPort = 18554
    private var reconnectRegistrations = 0
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let runningOverride: (() -> Bool)?
    private let childFactory: ChildFactory
    private let childExits = RelayChildExitGroup()
    private let starters = RelayChildExitGroup()
    private let readinessRequests = RelayChildExitGroup()
    private let requests = RelayChildExitGroup()
    private let configurationDirectory: URL
    private let reservationTimeout: Duration
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    init(transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         runningOverride: (() -> Bool)? = nil,
         configurationDirectory: URL = FileManager.default.temporaryDirectory,
         reservationTimeout: Duration = .seconds(5),
         childFactory: ChildFactory? = nil,
         cameraLease: CoordinatedCameraConfigurationStore.RuntimeLease? = nil,
         guardianExecutable: URL? = Bundle.main.executableURL) {
        self.transport = transport
        self.runningOverride = runningOverride
        self.configurationDirectory = configurationDirectory
        self.reservationTimeout = reservationTimeout
        let requiresLease = cameraLease != nil
        self.childFactory = childFactory ?? { [weak cameraLease] executable, configuration, onExit in
            guard !requiresLease || cameraLease != nil else {
                throw ConfigurationError.invalid("Camera runtime lease is no longer available.")
            }
            return try SystemRelayChild(executable: executable, configuration: configuration,
                                        lease: cameraLease, guardianExecutable: guardianExecutable, onExit: onExit)
        }
    }

    var running: Bool { runningOverride?() ?? (process?.isRunning == true) }

    /// Call only after all potential relay starters have been stopped or fenced.
    static func waitForAllChildrenToExit() async {
        await RelayPortReservations.shared.waitForChildren()
    }

    /// Call only after all request producers have been stopped or fenced.
    static func waitForAllPendingRequests() async {
        await allRequests.wait()
    }

    /// Call after this instance has stopped and all of its starters are joined.
    func waitForChildrenToExit() async {
        await childExits.wait()
    }

    /// Call after all starters have finished; cancelled transports can return late.
    func waitForPendingReadinessRequests() async {
        await readinessRequests.wait()
    }

    /// Call after all request producers for this instance have been fenced and joined.
    func waitForPendingRequests() async {
        await requests.wait()
    }

    /// The caller must fence new starts. A later stop or start invalidates this wait.
    func waitForStopped() async throws {
        let expected = generation
        guard !acceptingRequests else { throw CancellationError() }
        await starters.wait()
        await readinessRequests.wait()
        await requests.wait()
        await childExits.wait()
        try Task.checkCancellation()
        guard !acceptingRequests, generation == expected else { throw CancellationError() }
    }

    static func executablePath(configuredPath: String, bundleURL: URL) -> String {
        let bundledPath = bundleURL.appendingPathComponent("Contents/Helpers/go2rtc").path
        return FileManager.default.isExecutableFile(atPath: bundledPath) ? bundledPath : configuredPath
    }

    func start(config: WallConfiguration) async throws {
        try Task.checkCancellation()
        let starterID = UUID()
        starters.add(starterID)
        defer { starters.remove(starterID) }
        stop()
        generation = UUID()
        let attempt = generation
        acceptingRequests = true
        var started = false
        defer { if !started, generation == attempt { stop() } }
        let ports = Set([config.apiPort, config.rtspPort])
        let owner = UUID()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: reservationTimeout)
        var waited = false
        while true {
            try checkStart(attempt)
            let now = clock.now
            if (!waited || now < deadline) && RelayPortReservations.shared.acquire(ports, owner: owner) { break }
            guard now < deadline else {
                throw ConfigurationError.invalid("Previous go2rtc process has not exited; its ports are still reserved. Try again after it stops.")
            }
            waited = true
            try await clock.sleep(until: min(deadline, now.advanced(by: .milliseconds(20))))
        }
        var launched = false
        defer {
            if !launched { RelayPortReservations.shared.release(ports, owner: owner) }
        }
        try checkStart(attempt)
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
        let directory = configurationDirectory.appendingPathComponent("CameraWall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        var directoryHandedOff = false
        defer { if !directoryHandedOff { try? FileManager.default.removeItem(at: directory) } }
        let file = directory.appendingPathComponent("relay.json")
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.withoutEscapingSlashes])
        guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationError.invalid("Cannot create private relay configuration.")
        }
        try checkStart(attempt)
        let childExits = self.childExits
        let child = try childFactory(URL(fileURLWithPath: executablePath), file) {
            try? FileManager.default.removeItem(at: directory)
            Task { @MainActor in
                RelayPortReservations.shared.release(ports, owner: owner)
                childExits.remove(owner)
            }
        }
        directoryHandedOff = true
        launched = true
        RelayPortReservations.shared.retain(child, owner: owner)
        childExits.add(owner)
        process = child
        do {
            var lastFailure = "No response"
            for _ in 0..<40 {
                try checkStart(attempt)
                guard child.isRunning else { throw ConfigurationError.invalid("go2rtc stopped. Check executable and local ports.") }
                do {
                    _ = try await readinessRequest(attempt: attempt, child: child)
                    try checkStart(attempt)
                    guard child.isRunning else { throw ConfigurationError.invalid("go2rtc stopped. Check executable and local ports.") }
                    try? FileManager.default.removeItem(at: directory)
                    started = true
                    return
                } catch let failure as ConfigurationError {
                    lastFailure = failure.localizedDescription
                } catch let failure as URLError {
                    lastFailure = "Network error \(failure.code.rawValue)"
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw ConfigurationError.invalid("go2rtc did not start: \(lastFailure). Check local ports.")
        } catch {
            if generation == attempt { stop() }
            throw error
        }
    }

    private func checkStart(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }

    private func readinessRequest(attempt: UUID, child: any RelayChild) async throws -> Data {
        let state = ReadinessResult()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let requestID = UUID()
        readinessRequests.add(requestID)
        Self.allRequests.add(requestID)
        let requestTask = Task { @MainActor in
            defer {
                self.readinessRequests.remove(requestID)
                Self.allRequests.remove(requestID)
            }
            do {
                try self.checkStart(attempt)
                state.result = .success(try await self.request(method: "GET", items: [], generation: attempt))
            }
            catch { state.result = .failure(error) }
        }
        defer { requestTask.cancel() }
        while state.result == nil {
            try checkStart(attempt)
            guard child.isRunning else { throw ConfigurationError.invalid("go2rtc stopped. Check executable and local ports.") }
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try checkStart(attempt)
        return try state.result!.get()
    }
    func register(camera: Camera, expanded: Bool) async throws -> String {
        try checkRequest(generation)
        return try await register(source: camera.source(expanded: expanded),
                                  name: camera.streamName(expanded: expanded),
                                  credentials: CameraKeychain.read(camera.id))
    }

    func register(source address: String, name: String, credentials: Credentials?) async throws -> String {
        let attempt = generation
        try checkRequest(attempt)
        let operation = beginRequest()
        defer { endRequest(operation) }
        guard var source = URLComponents(string: address) else { throw ConfigurationError.invalid("Invalid camera URL.") }
        if let credentials, !credentials.username.isEmpty {
            source.user = credentials.username
            source.password = credentials.password
        }
        guard let address = source.string else { throw ConfigurationError.invalid("Invalid camera URL.") }
        _ = try await request(method: "PATCH", items: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "src", value: address)], generation: attempt)
        try checkRequest(attempt)
        return "rtsp://127.0.0.1:\(rtspPort)/\(name)?video"
    }

    // Never reuse a reconnect name: an HTTP cancellation or timeout does not
    // prove that the relay did not apply the PATCH later.
    func registerReconnect(camera: Camera, expanded: Bool, attemptID: UUID,
                           credentials: Credentials?) async throws -> String {
        try checkRequest(generation)
        guard reconnectRegistrations < 64 else {
            throw ConfigurationError.invalid("Reconnect limit reached; restart the video wall to clear relay registrations.")
        }
        reconnectRegistrations += 1
        let name = camera.streamName(expanded: expanded) + "_r_" +
            attemptID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return try await register(source: camera.source(expanded: expanded), name: name, credentials: credentials)
    }

    func profiles(address: CameraAddress, credentials: Credentials) async throws -> [String] {
        let attempt = generation
        try checkRequest(attempt)
        let operation = beginRequest()
        defer { endRequest(operation) }
        let ports = address.port.map { [$0] } ?? [80, 8080, 8899]
        for port in ports {
            try checkRequest(attempt)
            var source = URLComponents(string: address.onvifURL(port: port))!
            if !credentials.username.isEmpty { source.user = credentials.username; source.password = credentials.password }
            do {
                let data = try await request(method: "GET", items: [URLQueryItem(name: "src", value: source.string)],
                                             path: "/api/onvif", timeout: 6, generation: attempt)
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
                try checkRequest(attempt)
            }
        }
        return []
    }

    private struct ONVIFSources: Decodable {
        struct Source: Decodable { var url: String }
        var sources: [Source]
    }

    private func checkRequest(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard acceptingRequests, generation == expected else { throw CancellationError() }
    }

    private func beginRequest() -> UUID {
        let requestID = UUID()
        requests.add(requestID)
        Self.allRequests.add(requestID)
        return requestID
    }

    private func endRequest(_ id: UUID) {
        requests.remove(id)
        Self.allRequests.remove(id)
    }

    private func request(method: String, items: [URLQueryItem], path: String = "/api/streams",
                         timeout: TimeInterval = 2, generation expected: UUID) async throws -> Data {
        try checkRequest(expected)
        let requestID = beginRequest()
        defer { endRequest(requestID) }
        var url = URLComponents(string: "http://127.0.0.1:\(apiPort)\(path)")!
        url.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let auth = Data("camerawall:\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            if let transport {
                (data, response) = try await transport(request)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            try checkRequest(expected)
            throw error
        }
        try checkRequest(expected)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConfigurationError.invalid("go2rtc HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    func stop() {
        if acceptingRequests { generation = UUID() }
        acceptingRequests = false
        let child = process
        process = nil
        child?.terminate()
    }
}