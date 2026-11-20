import CameraCore
import Foundation

// MARK: - Process-Local Revisioned Favorite Domain (UserDefaults has no cross-process atomicity)

@MainActor
final class ACTALocalFavoriteReviewDomain: ACTAFavoriteReviewDomain {
    private unowned let model: WallModel
    private let storage: any ACTACameraFavoritesStorage
    private var localRevision = UUID()
    private var lastInventoryRevision: UUID

    init(model: WallModel, storage: (any ACTACameraFavoritesStorage)? = nil) {
        self.model = model
        self.storage = storage ?? ACTAUserDefaultsCameraFavoritesStorage()
        self.lastInventoryRevision = model.cameraInventoryRevision
    }

    private func syncInventoryRevision() {
        if model.cameraInventoryRevision != lastInventoryRevision {
            lastInventoryRevision = model.cameraInventoryRevision
            localRevision = UUID()
        }
    }

    func capture(request: String) throws -> ACTAFavoriteObservation? {
        syncInventoryRevision()
        _ = try model.cameraConfigurationChecked()
        guard let camera = actaResolveCamera(request, model: model) else { return nil }
        let raw = try storage.read()
        let preference: String? = raw.isEmpty ? "" : raw
        if let preference, !preference.isEmpty {
            let decoded = ACTACameraFavorites.decode(preference)
            guard ACTACameraFavorites.encode(decoded) == preference else {
                throw ConfigurationError.invalid("Favorite camera preference is malformed; refusing to overwrite.")
            }
        }
        return ACTAFavoriteObservation(revision: localRevision, cameraID: camera.id, preference: preference)
    }

    func commit(
        request: String, expected: ACTAFavoriteObservation, replacement: String?
    ) throws -> ACTAFavoriteObservation? {
        syncInventoryRevision()
        guard expected.revision == localRevision else { return nil }
        guard let current = try capture(request: request), current == expected else { return nil }
        let nextValue = replacement ?? ""
        try storage.write(nextValue)
        localRevision = UUID()
        let readback = try storage.read()
        guard readback == nextValue else { return nil }
        return ACTAFavoriteObservation(revision: localRevision, cameraID: current.cameraID, preference: readback)
    }
}

// MARK: - Process-Local Analytics Camera Inventory for Prepared Overrides

@MainActor
final class ACTAWallAnalyticsCameraInventory: ACTAAnalyticsCameraInventory {
    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    func withCamera<T>(id: UUID, _ body: (UUID) throws -> T) throws -> T? {
        let beforeRev = model.cameraInventoryRevision
        let config = try model.cameraConfigurationChecked()
        guard config.cameras.contains(where: { $0.id == id }) else { return nil }
        let result = try body(beforeRev)
        let afterConfig = try model.cameraConfigurationChecked()
        guard model.cameraInventoryRevision == beforeRev,
              afterConfig.cameras.contains(where: { $0.id == id }) else {
            throw ConfigurationError.invalid("Camera inventory changed during analytics update.")
        }
        return result
    }
}

// MARK: - Structured Credential-Free Network Camera Add (Broker-Displayable)

struct ACTABrokerCameraNetworkAddAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let name: String
        let substreamURL: String
        let mainstreamURL: String?
        let inventoryRevision: UUID
        let threadID: String
    }

    let id = "camera.add_network"
    let title = "Add Anonymous Network Camera"
    let description = "Register a disabled anonymous RTSP/RTSPS/ONVIF camera using structured scheme, host, port, and path (no credentials, query, or fragment) after operator review. Does not certify stream connectivity."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "name", type: "string", description: "Camera display name (1...200 chars)", isRequired: true),
        ACTAActionParameterSchema(name: "scheme", type: "string", description: "Protocol scheme", isRequired: true, allowedValues: ["rtsp", "rtsps", "onvif"]),
        ACTAActionParameterSchema(name: "host", type: "string", description: "Hostname or IP address without credentials", isRequired: true),
        ACTAActionParameterSchema(name: "port", type: "integer", description: "Optional TCP port (1...65535)"),
        ACTAActionParameterSchema(name: "path", type: "string", description: "Optional stream path starting with / (no query or fragment)"),
        ACTAActionParameterSchema(name: "mainstream_path", type: "string", description: "Optional high-resolution stream path starting with /")
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    static func buildAnonymousURL(scheme: String, host: String, port: Int?, path: String?) throws -> String {
        let cleanScheme = scheme.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["rtsp", "rtsps", "onvif"].contains(cleanScheme) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Scheme must be rtsp, rtsps, or onvif.")
        }
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty,
              !cleanHost.contains("@"),
              !cleanHost.contains("/"),
              !cleanHost.contains("?"),
              !cleanHost.contains("#"),
              !cleanHost.contains("://") else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Host must not contain credentials, scheme, or path.")
        }
        if let port, !(1...65535).contains(port) {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Port must be in 1...65535.")
        }
        let cleanPath: String
        if let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            guard rawPath.hasPrefix("/"),
                  !rawPath.contains("?"),
                  !rawPath.contains("#"),
                  !rawPath.contains("@"),
                  !rawPath.contains("://") else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Path must start with / and contain no query or credentials.")
            }
            cleanPath = rawPath
        } else {
            cleanPath = ""
        }
        var components = URLComponents()
        components.scheme = cleanScheme
        components.host = cleanHost
        components.port = port
        components.path = cleanPath
        guard let built = components.string else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Could not construct a valid stream address.")
        }
        return try WallCameraConfigurationAction.networkURL(built)
    }

    private func parse(_ parameters: [String: String]) throws -> (name: String, substream: String, mainstream: String?) {
        let cleanName = (parameters["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 200 else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Camera name requires 1...200 characters.")
        }
        let port: Int?
        if let rawPort = parameters["port"] {
            guard let p = Int(rawPort), (1...65535).contains(p) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Port must be in 1...65535.")
            }
            port = p
        } else {
            port = nil
        }
        let substream = try Self.buildAnonymousURL(
            scheme: parameters["scheme"] ?? "",
            host: parameters["host"] ?? "",
            port: port,
            path: parameters["path"]
        )
        let mainstream: String?
        if let msPath = parameters["mainstream_path"] {
            mainstream = try Self.buildAnonymousURL(
                scheme: parameters["scheme"] ?? "",
                host: parameters["host"] ?? "",
                port: port,
                path: msPath
            )
        } else {
            mainstream = nil
        }
        return (cleanName, substream, mainstream)
    }

    func validate(parameters: [String: String]) throws {
        _ = try parse(parameters)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let parsed = try parse(parameters)
        return try await MainActor.run {
            let config = try model.cameraConfigurationChecked()
            guard !config.cameras.contains(where: {
                $0.localDeviceID == nil && $0.screenDisplayID == nil && $0.fileURL == nil && $0.substream == parsed.substream
            }) else {
                throw ConfigurationError.invalid("Camera source is already configured; edit the existing camera instead.")
            }
            let summary = "Register disabled network camera '\(parsed.name)' on host '\(parameters["host"] ?? "")' (scheme=\(parameters["scheme"] ?? ""))."
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    name: parsed.name,
                    substreamURL: parsed.substream,
                    mainstreamURL: parsed.mainstream,
                    inventoryRevision: model.cameraInventoryRevision,
                    threadID: context.threadID
                ),
                reviewSummary: summary
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        return try await MainActor.run {
            guard model.cameraInventoryRevision == snapshot.inventoryRevision else {
                return .failed(actionID: id, error: "STALE_STATE: Camera configuration changed since review.")
            }
            let camera = Camera(
                name: snapshot.name,
                substream: snapshot.substreamURL,
                mainstream: snapshot.mainstreamURL,
                enabled: false
            )
            try model.saveCameraConfigurationChecked(camera)
            let saved = try model.cameraConfigurationChecked()
            guard saved.cameras.contains(where: { $0.id == camera.id && $0.name == camera.name && !$0.enabled }) else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Camera registration persistence verification failed.")
            }
            let payload: [String: Any] = [
                "camera_id": camera.id.uuidString,
                "name": camera.name,
                "enabled": false,
                "configured": true,
                "connection_verified": false
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Network camera registered disabled; connectivity is not certified.",
                outputJSON: json
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let parsed = try parse(parameters)
        return try await MainActor.run {
            let saved = try model.cameraConfigurationChecked()
            return saved.cameras.contains { $0.name == parsed.name && $0.substream == parsed.substream && !$0.enabled }
        }
    }
}

// MARK: - Broker-Displayable Camera Edit (Structured Endpoint Fields + Metadata)

struct ACTABrokerCameraEditAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let cameraID: UUID
        let delegatedParameters: [String: String]
        let inventoryRevision: UUID
        let threadID: String
    }

    let id = "camera.edit"
    let title = "Edit Camera Configuration"
    let description = "Edit camera metadata, location, disabled local/screen source IDs, or structured anonymous network endpoint (scheme/host/port/path) after operator review. Stored credentials are never moved across endpoints."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or unique name", isRequired: true),
        ACTAActionParameterSchema(name: "name", type: "string", description: "New camera name"),
        ACTAActionParameterSchema(name: "location", type: "string", description: "Camera location label"),
        ACTAActionParameterSchema(name: "clear_location", type: "boolean", description: "Clear camera location"),
        ACTAActionParameterSchema(name: "scheme", type: "string", description: "Network scheme", allowedValues: ["rtsp", "rtsps", "onvif"]),
        ACTAActionParameterSchema(name: "host", type: "string", description: "Network host without credentials"),
        ACTAActionParameterSchema(name: "port", type: "integer", description: "Network port (1...65535)"),
        ACTAActionParameterSchema(name: "path", type: "string", description: "Substream path starting with /"),
        ACTAActionParameterSchema(name: "mainstream_path", type: "string", description: "Mainstream path starting with /"),
        ACTAActionParameterSchema(name: "clear_mainstream", type: "boolean", description: "Clear mainstream URL"),
        ACTAActionParameterSchema(name: "device_id", type: "string", description: "Replacement local device ID (disabled source while stopped)"),
        ACTAActionParameterSchema(name: "display_id", type: "integer", description: "Replacement display ID (disabled source while stopped)")
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    private func translate(_ parameters: [String: String]) throws -> [String: String] {
        var mapped: [String: String] = [:]
        for key in ["camera_id", "name", "location", "clear_location", "clear_mainstream", "device_id", "display_id"] {
            if let value = parameters[key] { mapped[key] = value }
        }
        let hasNet = parameters["scheme"] != nil || parameters["host"] != nil || parameters["port"] != nil || parameters["path"] != nil
        let hasMainstream = parameters["mainstream_path"] != nil
        if hasNet || hasMainstream {
            guard let scheme = parameters["scheme"], let host = parameters["host"] else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Updating network endpoint requires both scheme and host.")
            }
            let port = parameters["port"].flatMap(Int.init)
            if parameters["port"] != nil && port == nil {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Port must be an integer.")
            }
            if hasNet {
                mapped["url"] = try ACTABrokerCameraNetworkAddAction.buildAnonymousURL(
                    scheme: scheme, host: host, port: port, path: parameters["path"]
                )
            }
            if let msPath = parameters["mainstream_path"] {
                mapped["mainstream"] = try ACTABrokerCameraNetworkAddAction.buildAnonymousURL(
                    scheme: scheme, host: host, port: port, path: msPath
                )
            }
        }
        guard mapped.count > 1 else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Specify at least one camera field to edit.")
        }
        return mapped
    }

    func validate(parameters: [String: String]) throws {
        let mapped = try translate(parameters)
        try WallCameraConfigurationAction(kind: .edit, model: model).validate(parameters: mapped)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let mapped = try translate(parameters)
        try WallCameraConfigurationAction(kind: .edit, model: model).validate(parameters: mapped)
        return try await MainActor.run {
            _ = try model.cameraConfigurationChecked()
            guard let rawID = parameters["camera_id"], let cam = actaResolveCamera(rawID, model: model) else {
                throw ConfigurationError.invalid("Camera does not exist or its name is ambiguous; specify a UUID.")
            }
            let fields = parameters.keys.filter { $0 != "camera_id" }.sorted().joined(separator: ", ")
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    cameraID: cam.id,
                    delegatedParameters: mapped,
                    inventoryRevision: model.cameraInventoryRevision,
                    threadID: context.threadID
                ),
                reviewSummary: "Edit camera '\(cam.name)' (\(cam.id.uuidString)): fields=[\(fields)]."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        let currentRev = await MainActor.run { model.cameraInventoryRevision }
        guard currentRev == snapshot.inventoryRevision else {
            return .failed(actionID: id, error: "STALE_STATE: Camera configuration changed since review.")
        }
        return try await WallCameraConfigurationAction(kind: .edit, model: model)
            .execute(parameters: snapshot.delegatedParameters, context: context)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let mapped = try translate(parameters)
        return try await WallCameraConfigurationAction(kind: .edit, model: model)
            .verify(parameters: mapped, context: context)
    }
}

// MARK: - camera.set_all_running (Start / Stop Camera Wall)

struct ACTACameraSetAllRunningAction: ACTAPreparedConfirmationAction {
    typealias LifecycleHook = @MainActor @Sendable (Bool) -> Void

    struct ConfirmationSnapshot: Sendable {
        let targetRunning: Bool
        let previousRunning: Bool
        let enabledCount: Int
        let threadID: String
    }

    let id = "camera.set_all_running"
    let title = "Start or Stop Camera Wall"
    let description = "Start or stop the entire camera wall after operator review. Verifies wall running/connecting state, not live stream frame readiness."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "running", type: "boolean", description: "true to start camera wall, false to stop all cameras", isRequired: true)
    ]

    private unowned let model: WallModel
    private let lifecycleHook: LifecycleHook?

    init(model: WallModel, lifecycleHook: LifecycleHook? = nil) {
        self.model = model
        self.lifecycleHook = lifecycleHook
    }

    private static func target(_ parameters: [String: String]) throws -> Bool {
        guard Set(parameters.keys) == ["running"], let raw = parameters["running"] else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide boolean running.")
        }
        switch raw {
        case "true", "1": return true
        case "false", "0": return false
        default: throw ConfigurationError.invalid("INVALID_ARGUMENT: running must be boolean.")
        }
    }

    func validate(parameters: [String: String]) throws {
        _ = try Self.target(parameters)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let targetRunning = try Self.target(parameters)
        return try await MainActor.run {
            let config = try model.cameraConfigurationChecked()
            let enabledCount = config.cameras.filter(\.enabled).count
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    targetRunning: targetRunning,
                    previousRunning: model.running,
                    enabledCount: enabledCount,
                    threadID: context.threadID
                ),
                reviewSummary: targetRunning
                    ? "Start camera wall (\(enabledCount) enabled cameras). Stream frame readiness is not guaranteed."
                    : "Stop camera wall and disconnect active camera streams."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        let targetRunning = try Self.target(parameters)
        guard targetRunning == snapshot.targetRunning, snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        return try await MainActor.run {
            if let lifecycleHook {
                lifecycleHook(targetRunning)
            } else if targetRunning {
                model.start()
            } else {
                model.stop()
            }
            let payload: [String: Any] = [
                "requested_running": targetRunning,
                "running": model.running,
                "connecting": model.connecting,
                "stream_readiness_verified": false
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: targetRunning
                    ? "Camera wall start requested; stream readiness is not certified."
                    : "Camera wall stopped.",
                outputJSON: json
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let targetRunning = try Self.target(parameters)
        return await MainActor.run {
            if lifecycleHook != nil { return true }
            if targetRunning {
                return model.running || model.connecting
            }
            return !model.running && !model.connecting
        }
    }
}

// MARK: - camera.import_sources (Strict Confirmed Import from Local Text File; Credentials Never Disclosed)

struct ACTACameraImportSourcesAction: ACTAPreparedConfirmationAction {
    struct ParsedEntry: Sendable {
        let redactedSubstream: String
        let username: String
        let password: String
    }

    struct ConfirmationSnapshot: Sendable {
        let filePath: String
        let count: Int
        let previousCameraCount: Int
        let inventoryRevision: UUID
        let threadID: String
    }

    let id = "camera.import_sources"
    let title = "Import Camera Sources from File"
    let description = "Import RTSP/RTSPS camera lines from a local plain-text file after operator review. Any embedded credentials are stored directly in Keychain and never disclosed to model output or audit logs."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(name: "file_path", type: "string", description: "Absolute local path to plain-text source list", isRequired: true),
        ACTAActionParameterSchema(name: "start_enabled", type: "boolean", description: "Enable imported cameras immediately (default: false)")
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    private static func validatePath(_ parameters: [String: String]) throws -> (String, Bool) {
        guard let rawPath = parameters["file_path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawPath.hasPrefix("/"),
              !rawPath.contains("://") else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: file_path must be an absolute local file path.")
        }
        let startEnabled: Bool
        if let raw = parameters["start_enabled"] {
            switch raw {
            case "true", "1": startEnabled = true
            case "false", "0": startEnabled = false
            default: throw ConfigurationError.invalid("INVALID_ARGUMENT: start_enabled must be boolean.")
            }
        } else {
            startEnabled = false
        }
        return (rawPath, startEnabled)
    }

    private static func parseFile(at path: String) throws -> [ParsedEntry] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw ConfigurationError.invalid("Import file does not exist or is a directory.")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var entries: [ParsedEntry] = []
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard var parts = URLComponents(string: line),
                  ["rtsp", "rtsps", "onvif"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host?.isEmpty == false else {
                throw ConfigurationError.invalid("Invalid camera source on line \(offset + 1).")
            }
            let user = parts.user ?? ""
            let pass = parts.password ?? ""
            parts.user = nil
            parts.password = nil
            guard let cleanURL = parts.string else {
                throw ConfigurationError.invalid("Invalid camera source on line \(offset + 1).")
            }
            entries.append(ParsedEntry(redactedSubstream: cleanURL, username: user, password: pass))
        }
        guard !entries.isEmpty else {
            throw ConfigurationError.invalid("Import file contains no camera entries.")
        }
        return entries
    }

    func validate(parameters: [String: String]) throws {
        let (path, _) = try Self.validatePath(parameters)
        _ = try Self.parseFile(at: path)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (path, startEnabled) = try Self.validatePath(parameters)
        let entries = try Self.parseFile(at: path)
        return try await MainActor.run {
            let config = try model.cameraConfigurationChecked()
            let withCreds = entries.filter { !$0.username.isEmpty || !$0.password.isEmpty }.count
            let summary = "Import \(entries.count) camera(s) from '\(URL(fileURLWithPath: path).lastPathComponent)' (enabled=\(startEnabled), credentialed=\(withCreds)). Credentials are saved directly to Keychain and never logged."
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    filePath: path,
                    count: entries.count,
                    previousCameraCount: config.cameras.count,
                    inventoryRevision: model.cameraInventoryRevision,
                    threadID: context.threadID
                ),
                reviewSummary: summary
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        let (path, startEnabled) = try Self.validatePath(parameters)
        guard path == snapshot.filePath, snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: File path or thread changed.")
        }
        let entries = try Self.parseFile(at: path)
        guard entries.count == snapshot.count else {
            return .failed(actionID: id, error: "STALE_STATE: Import file contents changed since review.")
        }
        return try await MainActor.run {
            guard model.cameraInventoryRevision == snapshot.inventoryRevision else {
                return .failed(actionID: id, error: "STALE_STATE: Camera configuration changed since review.")
            }
            var next = try model.cameraConfigurationChecked()
            var createdCredentials: [(UUID, Credentials)] = []
            var addedIDs: [String] = []
            for entry in entries {
                let cam = Camera(
                    name: "Camera \(next.cameras.count + 1)",
                    substream: entry.redactedSubstream,
                    enabled: startEnabled
                )
                try cam.validate()
                next.cameras.append(cam)
                addedIDs.append(cam.id.uuidString)
                if !entry.username.isEmpty || !entry.password.isEmpty {
                    createdCredentials.append((cam.id, Credentials(username: entry.username, password: entry.password)))
                }
            }
            try next.validate()
            do {
                for (camID, creds) in createdCredentials {
                    try model.cameraCredentialStore.save(creds, for: camID)
                }
                try model.apply(next)
            } catch {
                for (camID, _) in createdCredentials {
                    try? model.cameraCredentialStore.remove(camID)
                }
                return .failed(actionID: id, error: "IMPORT_FAILED: \(error.localizedDescription)")
            }
            let verified = try model.cameraConfigurationChecked()
            guard verified.cameras.count == snapshot.previousCameraCount + entries.count else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Imported camera count verification failed.")
            }
            let payload: [String: Any] = [
                "imported_count": entries.count,
                "camera_ids": addedIDs,
                "connection_verified": false
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Imported \(entries.count) camera source(s); stream connectivity is not certified.",
                outputJSON: json
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        true
    }
}
