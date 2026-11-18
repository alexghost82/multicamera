import CameraCore
import Foundation

/// Configuration receipts deliberately do not certify capture permissions, decoding or stream readiness.
struct WallCameraConfigurationAction: ACTAActionProtocol {
    enum Kind: String, CaseIterable, Sendable {
        case network = "camera.add_network", local = "camera.add_local", screen = "camera.add_screen", file = "camera.add_file"
        case edit = "camera.edit", processing = "camera.set_processing"
    }
    let kind: Kind
    unowned let model: WallModel
    var id: String { kind.rawValue }
    var title: String { id }
    var description: String {
        switch kind {
        case .network: return "Register an anonymous RTSP/RTSPS/ONVIF source DISABLED. URLs cannot include credentials, query or fragment. Use the existing secure native GUI for credentials. No discovery/connection is certified."
        case .local: return "Register a local capture device ID DISABLED. This does not certify device availability or grant macOS permissions."
        case .screen: return "Register a display ID DISABLED. Does not capture the screen or bypass macOS permissions."
        case .file: return "Register a readable regular local file by absolute path DISABLED, using the app bookmark service. Video decoding is not certified."
        case .edit: return "Edit metadata or anonymous network URLs; edit device_id or display_id only for matching disabled sources while the wall is stopped. Credentials are unchanged. Existing running streams may reconnect for other edits."
        case .processing: return "Set one camera's YOLO or AI-chat flag. AI flag changes require confirmation; network/voice/privacy permissions remain unchanged."
        }
    }
    var classification: ACTAActionClassification { kind == .processing ? .reversible : .serviceAffecting }
    func requiresConfirmation(parameters: [String: String]) -> Bool {
        kind == .processing && parameters["feature"] == "ai_chat"
            || kind == .edit && (parameters["url"] != nil || parameters["mainstream"] != nil || parameters["clear_mainstream"] == "true")
    }
    func validate(parameters: [String: String]) throws {
        // Reject secrets before a confirmation token/proposal can persist raw arguments.
        if kind == .network || kind == .edit {
            for field in ["url", "mainstream"] {
                if let value = parameters[field] { _ = try Self.networkURL(value) }
            }
            if kind == .edit {
                if let deviceID = parameters["device_id"] {
                    guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          deviceID.utf8.count <= 1024 else {
                        throw ConfigurationError.invalid("A nonempty device ID of at most 1024 bytes is required.")
                    }
                }
                if let displayID = parameters["display_id"] {
                    guard let value = UInt32(displayID), value > 0 else {
                        throw ConfigurationError.invalid("A positive display ID is required.")
                    }
                }
                if parameters["device_id"] != nil || parameters["display_id"] != nil {
                    guard !(parameters["device_id"] != nil && parameters["display_id"] != nil),
                          parameters["url"] == nil, parameters["mainstream"] == nil,
                          parameters["clear_mainstream"] == nil else {
                        throw ConfigurationError.invalid("Specify one source ID without network source fields.")
                    }
                }
            }
        }
    }

    static func networkURL(_ value: String) throws -> String {
        guard let url = URLComponents(string: value), ["rtsp", "rtsps", "onvif"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.port.map({ (1...65535).contains($0) }) ?? true,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConfigurationError.invalid("Agent camera URLs require a host and no credentials, query or fragment. Use the secure camera editor for other URLs.")
        }
        return value
    }

    var parameters: [ACTAActionParameterSchema] {
        func field(_ name: String, _ type: String, _ required: Bool = false, _ values: [String]? = nil) -> ACTAActionParameterSchema {
            ACTAActionParameterSchema(name: name, type: type, description: name, isRequired: required, allowedValues: values)
        }
        switch kind {
        case .network: return [field("name", "string", true), field("url", "string", true), field("mainstream", "string")]
        case .local: return [field("name", "string", true), field("device_id", "string", true)]
        case .screen: return [field("name", "string", true), field("display_id", "integer", true)]
        case .file: return [field("file_path", "string", true), field("name", "string")]
        case .edit: return [field("camera_id", "string", true), field("name", "string"), field("location", "string"),
            field("clear_location", "boolean"), field("url", "string"), field("mainstream", "string"), field("clear_mainstream", "boolean"),
            field("device_id", "string"), field("display_id", "integer")]
        case .processing: return [field("camera_id", "string", true), field("feature", "string", true, ["yolo", "ai_chat"]), field("enabled", "boolean", true)]
        }
    }
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            _ = try model.cameraConfigurationChecked()
            func name(_ value: String) throws -> String {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 200 else { throw ConfigurationError.invalid("Camera name requires 1...200 characters.") }
                return clean
            }
            var camera: Camera
            switch kind {
            case .network:
                let url = try Self.networkURL(parameters["url"] ?? "")
                guard !model.config.cameras.contains(where: { $0.localDeviceID == nil && $0.screenDisplayID == nil && $0.fileURL == nil && $0.substream == url }) else {
                    throw ConfigurationError.invalid("Camera source is already configured; edit the existing camera instead.")
                }
                camera = Camera(name: try name(parameters["name"] ?? ""), substream: url,
                    mainstream: try parameters["mainstream"].map(Self.networkURL), enabled: false)
                try model.saveCameraConfigurationChecked(camera)
            case .local:
                camera = Camera(name: try name(parameters["name"] ?? ""), substream: "", enabled: false, localDeviceID: parameters["device_id"])
                try model.saveLocalCamera(camera, startAfterSave: false)
            case .screen:
                guard let value = parameters["display_id"].flatMap(UInt32.init), value > 0 else {
                    throw ConfigurationError.invalid("A positive display ID is required.")
                }
                camera = Camera(name: try name(parameters["name"] ?? ""), substream: "", enabled: false, screenDisplayID: String(value))
                try model.saveScreenCamera(camera, startAfterSave: false)
            case .file:
                let path = parameters["file_path"] ?? ""
                guard path.hasPrefix("/") else { throw ConfigurationError.invalid("Specify an absolute local file path.") }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard !model.config.cameras.contains(where: { $0.fileURL?.standardizedFileURL == url }) else {
                    throw ConfigurationError.invalid("Camera source is already configured; edit the existing camera instead.")
                }
                camera = try model.addVideoFileChecked(url, name: try parameters["name"].map(name))
            case .edit, .processing:
                guard let value = parameters["camera_id"], let selected = actaResolveCamera(value, model: model) else {
                    throw ConfigurationError.invalid("Camera does not exist or its name is ambiguous; specify a UUID.")
                }
                camera = selected
                if kind == .processing {
                    let enabled = parameters["enabled"] == "true"
                    switch parameters["feature"] {
                    case "yolo": model.setYOLOEnabled(for: camera.id, enabled: enabled); camera.yoloEnabled = enabled
                    case "ai_chat": model.setAIChatEnabled(for: camera.id, enabled: enabled); camera.aiChatEnabled = enabled
                    default: throw ConfigurationError.invalid("Unknown camera processing feature.")
                    }
                } else {
                    guard parameters.count > 1 else { throw ConfigurationError.invalid("Specify at least one camera change.") }
                    guard !(parameters["clear_location"] == "true" && parameters["location"] != nil),
                          !(parameters["clear_mainstream"] == "true" && parameters["mainstream"] != nil) else {
                        throw ConfigurationError.invalid("Do not set and clear the same camera field in one action.")
                    }
                    if parameters["device_id"] != nil || parameters["display_id"] != nil {
                        guard !camera.enabled, !model.running, !model.connecting,
                              !model.vlmBusy, !model.manualVLMBusy, model.manualQuestionQueue.pending == nil,
                              model.localAnalyticsEngine.engineState == .disabled,
                              model.tiles.values.allSatisfy({ $0.session == nil }) else {
                            throw ConfigurationError.invalid("Source IDs can be edited only for disabled sources while the wall and its camera processing are stopped.")
                        }
                        if let value = parameters["device_id"] {
                            guard camera.localDeviceID != nil, camera.screenDisplayID == nil, camera.fileURL == nil else {
                                throw ConfigurationError.invalid("Device ID requires an existing local camera.")
                            }
                            camera.localDeviceID = value
                        }
                        if let value = parameters["display_id"] {
                            guard camera.screenDisplayID != nil, camera.localDeviceID == nil, camera.fileURL == nil,
                                  let displayID = UInt32(value), displayID > 0 else {
                                throw ConfigurationError.invalid("Display ID requires an existing screen source and a positive display ID.")
                            }
                            camera.screenDisplayID = String(displayID)
                        }
                    }
                    if let value = parameters["name"] { camera.name = try name(value) }
                    if let value = parameters["location"] {
                        guard value.count <= 500 else { throw ConfigurationError.invalid("Camera location must not exceed 500 characters.") }
                        camera.location = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    }
                    if parameters["clear_location"] == "true" { camera.location = nil }
                    if parameters["url"] != nil || parameters["mainstream"] != nil,
                       let credentials = try model.cameraCredentialStore.read(camera.id),
                       !credentials.username.isEmpty || !credentials.password.isEmpty {
                        func endpoint(_ value: String) -> String {
                            guard let url = URLComponents(string: value) else { return "invalid" }
                            return "\(url.scheme?.lowercased() ?? "")|\(url.host?.lowercased() ?? "")|\(url.port.map(String.init) ?? "default")"
                        }
                        if let value = parameters["url"], endpoint(value) != endpoint(camera.substream) {
                            throw ConfigurationError.invalid("Use the secure camera editor to move stored credentials to a different network endpoint.")
                        }
                        if let value = parameters["mainstream"], endpoint(value) != endpoint(camera.mainstream ?? camera.substream) {
                            throw ConfigurationError.invalid("Use the secure camera editor to move stored credentials to a different network endpoint.")
                        }
                    }
                    if let value = parameters["url"] { camera.substream = try Self.networkURL(value) }
                    if let value = parameters["mainstream"] { camera.mainstream = try Self.networkURL(value) }
                    if parameters["clear_mainstream"] == "true" { camera.mainstream = nil }
                    try model.saveCameraConfigurationChecked(camera)
                }
            }
            let stored = try ConfigurationStore.load(from: model.configURL)
            guard stored == model.config, stored.cameras.first(where: { $0.id == camera.id }) == camera else {
                throw ConfigurationError.invalid("Camera configuration persistence verification failed.")
            }
            let output: [String: Any] = ["camera_id": camera.id.uuidString, "name": camera.name,
                "configured": true, "enabled": camera.enabled, "connection_verified": false]
            return ACTAActionResult(actionID: id, success: true, summary: "Camera configuration saved and verified; capture or connection readiness is not certified.",
                outputJSON: String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
        }
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}
