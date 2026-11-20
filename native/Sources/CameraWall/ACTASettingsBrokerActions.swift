import AppKit
import CameraCore
import Foundation

// MARK: - Testable Keychain Store Seam (preserves CameraWall.GhostCredentials / GhostKey / AlertKey)

protocol ACTAAPIKeyStore: Sendable {
    func saveKey(_ value: String, account: String) -> Bool
    func hasKey(account: String) -> Bool
}

struct SystemACTAAPIKeyStore: ACTAAPIKeyStore {
    func saveKey(_ value: String, account: String) -> Bool {
        ACTAKeychainStore.saveKey(value, account: account)
    }

    func hasKey(account: String) -> Bool {
        ACTAKeychainStore.loadKey(account: account) != nil
    }
}

enum ACTAAPIKeyAccount: String, CaseIterable, Sendable {
    case primary
    case alert

    var keychainAccount: String {
        switch self {
        case .primary: return ACTAKeychainStore.primaryKeyAccount
        case .alert: return ACTAKeychainStore.alertKeyAccount
        }
    }
}

// MARK: - settings.set_api_key (secret never enters LLM arguments, review text, or audit logs)

struct ACTASetAPIKeyAction: ACTAPreparedConfirmationAction {
    typealias SecurePrompt = @MainActor @Sendable (ACTAAPIKeyAccount) -> String?

    @MainActor
    final class State {
        var verifiedAccount: ACTAAPIKeyAccount?
    }

    struct ConfirmationSnapshot: Sendable {
        let account: ACTAAPIKeyAccount
        let hadExistingKey: Bool
        let threadID: String
    }

    let id = "settings.set_api_key"
    let title = "Set Keychain API Key"
    let description = "Open a local native secure prompt for the operator to store an API key in macOS Keychain for the primary or alert account after operator review. The key itself is never passed through model arguments, logs, or tool outputs."
    let classification = ACTAActionClassification.securitySensitive
    let parameters = [
        ACTAActionParameterSchema(
            name: "account",
            type: "string",
            description: "Keychain account slot: primary or alert",
            isRequired: true,
            allowedValues: ["primary", "alert"]
        )
    ]

    private let keyStore: any ACTAAPIKeyStore
    private let promptForSecret: SecurePrompt
    private let state: State

    @MainActor
    init(
        keyStore: any ACTAAPIKeyStore = SystemACTAAPIKeyStore(),
        promptForSecret: SecurePrompt? = nil
    ) {
        self.keyStore = keyStore
        self.promptForSecret = promptForSecret ?? { Self.defaultSecurePrompt($0) }
        self.state = State()
    }

    private static func account(from parameters: [String: String]) throws -> ACTAAPIKeyAccount {
        guard Set(parameters.keys) == ["account"],
              let raw = parameters["account"],
              let account = ACTAAPIKeyAccount(rawValue: raw) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Expected account primary or alert.")
        }
        return account
    }

    func validate(parameters: [String: String]) throws {
        _ = try Self.account(from: parameters)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let account = try Self.account(from: parameters)
        let hadExisting = keyStore.hasKey(account: account.keychainAccount)
        let summary = "Prompt operator natively to store API key in macOS Keychain slot '\(account.rawValue)' (currently \(hadExisting ? "configured" : "empty")). Secret never enters model context."
        return ACTAPreparedConfirmation(
            snapshot: ConfirmationSnapshot(account: account, hadExistingKey: hadExisting, threadID: context.threadID),
            reviewSummary: summary
        )
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        let account = try Self.account(from: parameters)
        guard account == snapshot.account, snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        return await MainActor.run {
            state.verifiedAccount = nil
            guard let entered = promptForSecret(account) else {
                return .failed(actionID: id, error: "OPERATOR_CANCELLED: Key entry was cancelled.")
            }
            let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failed(actionID: id, error: "INVALID_ARGUMENT: API key cannot be empty; use settings.clear_api_key to remove.")
            }
            guard keyStore.saveKey(trimmed, account: account.keychainAccount),
                  keyStore.hasKey(account: account.keychainAccount) else {
                return .failed(actionID: id, error: "KEYCHAIN_ERROR: Could not persist API key to macOS Keychain.")
            }
            state.verifiedAccount = account
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "API key stored in macOS Keychain for '\(account.rawValue)'.",
                outputJSON: "{\"account\":\"\(account.rawValue)\",\"configured\":true}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let account = try Self.account(from: parameters)
        return await MainActor.run {
            defer { state.verifiedAccount = nil }
            guard state.verifiedAccount == account else { return false }
            return keyStore.hasKey(account: account.keychainAccount)
        }
    }

    @MainActor
    private static func defaultSecurePrompt(_ account: ACTAAPIKeyAccount) -> String? {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Enter API Key", comment: "")
        alert.informativeText = account == .primary
            ? NSLocalizedString("Store key in macOS Keychain (primary account).", comment: "")
            : NSLocalizedString("Store key in macOS Keychain (alert account).", comment: "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

// MARK: - settings.clear_api_key

struct ACTAClearAPIKeyAction: ACTAPreparedConfirmationAction {
    @MainActor
    final class State {
        var clearedAccount: ACTAAPIKeyAccount?
    }

    struct ConfirmationSnapshot: Sendable {
        let account: ACTAAPIKeyAccount
        let hadExistingKey: Bool
        let threadID: String
    }

    let id = "settings.clear_api_key"
    let title = "Clear Keychain API Key"
    let description = "Remove a stored API key from macOS Keychain for the primary or alert account after operator review."
    let classification = ACTAActionClassification.destructive
    let parameters = [
        ACTAActionParameterSchema(
            name: "account",
            type: "string",
            description: "Keychain account slot: primary or alert",
            isRequired: true,
            allowedValues: ["primary", "alert"]
        )
    ]

    private let keyStore: any ACTAAPIKeyStore
    private let state: State

    @MainActor
    init(keyStore: any ACTAAPIKeyStore = SystemACTAAPIKeyStore()) {
        self.keyStore = keyStore
        self.state = State()
    }

    private static func account(from parameters: [String: String]) throws -> ACTAAPIKeyAccount {
        guard Set(parameters.keys) == ["account"],
              let raw = parameters["account"],
              let account = ACTAAPIKeyAccount(rawValue: raw) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Expected account primary or alert.")
        }
        return account
    }

    func validate(parameters: [String: String]) throws {
        _ = try Self.account(from: parameters)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let account = try Self.account(from: parameters)
        let hadExisting = keyStore.hasKey(account: account.keychainAccount)
        return ACTAPreparedConfirmation(
            snapshot: ConfirmationSnapshot(account: account, hadExistingKey: hadExisting, threadID: context.threadID),
            reviewSummary: "Clear stored API key from macOS Keychain slot '\(account.rawValue)' (currently \(hadExisting ? "configured" : "empty"))."
        )
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        let account = try Self.account(from: parameters)
        guard account == snapshot.account, snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        return await MainActor.run {
            state.clearedAccount = nil
            guard keyStore.saveKey("", account: account.keychainAccount),
                  !keyStore.hasKey(account: account.keychainAccount) else {
                return .failed(actionID: id, error: "KEYCHAIN_ERROR: Could not remove API key from macOS Keychain.")
            }
            state.clearedAccount = account
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "API key removed from macOS Keychain for '\(account.rawValue)'.",
                outputJSON: "{\"account\":\"\(account.rawValue)\",\"configured\":false}"
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let account = try Self.account(from: parameters)
        return await MainActor.run {
            defer { state.clearedAccount = nil }
            guard state.clearedAccount == account else { return false }
            return !keyStore.hasKey(account: account.keychainAccount)
        }
    }
}

// MARK: - settings.toggle_showcase (loopback 127.0.0.1 only; bearer token never disclosed to model)

struct ACTAToggleShowcaseAction: ACTAPreparedConfirmationAction {
    struct ConfirmationSnapshot: Sendable {
        let requestedRunning: Bool
        let previousRunning: Bool
        let featureEnabled: Bool
        let threadID: String
    }

    let id = "settings.toggle_showcase"
    let title = "Start or Stop Local Showcase"
    let description = "Start or stop the loopback-only (127.0.0.1) Local Showcase HTTP server after operator review. The ephemeral bearer token URL is never exposed in tool output."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(
            name: "running",
            type: "boolean",
            description: "true to start loopback showcase server, false to stop it",
            isRequired: true
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    private static func requestedRunning(_ parameters: [String: String]) throws -> Bool {
        guard Set(parameters.keys) == ["running"], let raw = parameters["running"] else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide boolean running.")
        }
        switch raw {
        case "true", "1": return true
        case "false", "0": return false
        default: throw ConfigurationError.invalid("INVALID_ARGUMENT: running must be a boolean.")
        }
    }

    func validate(parameters: [String: String]) throws {
        _ = try Self.requestedRunning(parameters)
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let target = try Self.requestedRunning(parameters)
        return try await MainActor.run {
            let currentlyRunning = model.localShowcaseURL != nil
            let featureEnabled = model.featurePreferences.enabledFeatures.contains(.publicShowcase)
            if target && !featureEnabled {
                throw CameraFeatureStoreError.featureDisabled(.publicShowcase)
            }
            if target && model.featurePreferences.allowPublicAccess {
                throw ConfigurationError.invalid("Public showcase access is disabled for this local-only server.")
            }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    requestedRunning: target,
                    previousRunning: currentlyRunning,
                    featureEnabled: featureEnabled,
                    threadID: context.threadID
                ),
                reviewSummary: target
                    ? "Start loopback-only Local Showcase server (127.0.0.1). Bearer link stays in native GUI only."
                    : "Stop Local Showcase server."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        let target = try Self.requestedRunning(parameters)
        guard target == snapshot.requestedRunning, snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        return try await MainActor.run {
            if target {
                if model.localShowcaseURL == nil {
                    try model.startLocalShowcase()
                }
            } else {
                model.stopLocalShowcase()
            }
            let running = model.localShowcaseURL != nil
            let redacted = model.localShowcaseURL.map { actaRedactedStreamURL($0.absoluteString) } ?? ""
            let payload: [String: Any] = [
                "running": running,
                "status": model.localShowcaseStatus,
                "redacted_endpoint": redacted
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: running ? "Local loopback showcase server started (token withheld from model)." : "Local showcase server stopped.",
                outputJSON: json
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let target = try Self.requestedRunning(parameters)
        return await MainActor.run {
            (model.localShowcaseURL != nil) == target
        }
    }
}

// MARK: - settings.update_models

struct ACTAUpdateModelsAction: ACTAPreparedConfirmationAction {
    struct ParsedRequest: Sendable {
        let service: LocalModelService
        let enabled: Bool?
        let modelPath: String?
        let resetToBundled: Bool
    }

    struct ConfirmationSnapshot: Sendable {
        let request: ParsedRequest
        let prior: ModelSelectionPreferences
        let threadID: String
    }

    let id = "settings.update_models"
    let title = "Update Local AI Model Selection"
    let description = "Enable or disable a local AI model service or configure its verified local file path after operator review. Does not download models or certify inference throughput."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters = [
        ACTAActionParameterSchema(
            name: "service",
            type: "string",
            description: "Model service identifier",
            isRequired: true,
            allowedValues: LocalModelService.allCases.map(\.rawValue)
        ),
        ACTAActionParameterSchema(
            name: "enabled",
            type: "boolean",
            description: "Enable or disable this local model service"
        ),
        ACTAActionParameterSchema(
            name: "model_path",
            type: "string",
            description: "Absolute local filesystem path to a compatible model file/bundle"
        ),
        ACTAActionParameterSchema(
            name: "reset_to_bundled",
            type: "boolean",
            description: "Clear custom path and revert to bundled model"
        )
    ]

    private unowned let model: WallModel

    init(model: WallModel) {
        self.model = model
    }

    private static func parse(_ parameters: [String: String]) throws -> ParsedRequest {
        let allowedKeys: Set<String> = ["service", "enabled", "model_path", "reset_to_bundled"]
        guard Set(parameters.keys).isSubset(of: allowedKeys),
              let rawService = parameters["service"],
              let service = LocalModelService(rawValue: rawService) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown or missing model service.")
        }
        let enabled: Bool?
        if let raw = parameters["enabled"] {
            switch raw {
            case "true", "1": enabled = true
            case "false", "0": enabled = false
            default: throw ConfigurationError.invalid("INVALID_ARGUMENT: enabled must be boolean.")
            }
        } else {
            enabled = nil
        }
        let resetToBundled: Bool
        if let raw = parameters["reset_to_bundled"] {
            switch raw {
            case "true", "1": resetToBundled = true
            case "false", "0": resetToBundled = false
            default: throw ConfigurationError.invalid("INVALID_ARGUMENT: reset_to_bundled must be boolean.")
            }
        } else {
            resetToBundled = false
        }
        let modelPath = parameters["model_path"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resetToBundled && modelPath != nil {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Cannot combine model_path with reset_to_bundled=true.")
        }
        if let modelPath, (modelPath.isEmpty || !modelPath.hasPrefix("/") || modelPath.contains("://")) {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: model_path must be an existing absolute local path.")
        }
        guard enabled != nil || modelPath != nil || resetToBundled else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Specify enabled, model_path, or reset_to_bundled.")
        }
        return ParsedRequest(service: service, enabled: enabled, modelPath: modelPath, resetToBundled: resetToBundled)
    }

    private static func applying(_ request: ParsedRequest, to prior: ModelSelectionPreferences) -> ModelSelectionPreferences {
        var next = prior
        if let enabled = request.enabled {
            if enabled { next.enabled.insert(request.service) }
            else { next.enabled.remove(request.service) }
        }
        if request.resetToBundled {
            next.paths.removeValue(forKey: request.service)
        } else if let modelPath = request.modelPath {
            next.paths[request.service] = modelPath
        }
        return next
    }

    func validate(parameters: [String: String]) throws {
        let request = try Self.parse(parameters)
        if let path = request.modelPath {
            var candidate = ModelSelectionPreferences()
            candidate.paths[request.service] = path
            try candidate.validate()
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let request = try Self.parse(parameters)
        return try await MainActor.run {
            let url = model.configURL.deletingLastPathComponent().appendingPathComponent("model-preferences.json")
            let disk = try ModelSelectionPreferences.load(from: url)
            guard disk == model.modelPreferences else {
                throw ConfigurationError.invalid("Model preferences changed on disk; reload before making changes.")
            }
            let next = Self.applying(request, to: disk)
            try next.validate()
            let pathSummary = request.resetToBundled ? "bundled" : (request.modelPath ?? (next.paths[request.service] ?? "bundled"))
            let enabledSummary = next.enabled.contains(request.service) ? "enabled" : "disabled"
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(request: request, prior: disk, threadID: context.threadID),
                reviewSummary: "Update local model '\(request.service.rawValue)': \(enabledSummary), path=\(pathSummary). Reloads local model runtime."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        let request = try Self.parse(parameters)
        guard snapshot.threadID == context.threadID, snapshot.request.service == request.service else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request or thread changed.")
        }
        return try await MainActor.run {
            let url = model.configURL.deletingLastPathComponent().appendingPathComponent("model-preferences.json")
            let disk = try ModelSelectionPreferences.load(from: url)
            guard disk == snapshot.prior, model.modelPreferences == snapshot.prior else {
                return .failed(actionID: id, error: "STALE_STATE: Model preferences changed since review.")
            }
            let next = Self.applying(request, to: disk)
            try next.validate()
            try model.saveModelPreferences(next)
            guard try ModelSelectionPreferences.load(from: url) == next,
                  model.modelPreferences == next,
                  ModelSelectionRegistry.snapshot().preferences == next else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Model preferences persistence verification failed.")
            }
            let payload: [String: Any] = [
                "service": request.service.rawValue,
                "enabled": next.enabled.contains(request.service),
                "path": next.paths[request.service] ?? "",
                "readiness_verified": false
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
            return ACTAActionResult(
                actionID: id,
                success: true,
                summary: "Model selection saved and runtime reload scheduled; inference readiness is not certified.",
                outputJSON: json
            )
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let request = try Self.parse(parameters)
        return try await MainActor.run {
            let url = model.configURL.deletingLastPathComponent().appendingPathComponent("model-preferences.json")
            let disk = try ModelSelectionPreferences.load(from: url)
            guard disk == model.modelPreferences, ModelSelectionRegistry.snapshot().preferences == disk else { return false }
            if let enabled = request.enabled, disk.enabled.contains(request.service) != enabled { return false }
            if request.resetToBundled, disk.paths[request.service] != nil { return false }
            if let path = request.modelPath, disk.paths[request.service] != path { return false }
            return true
        }
    }
}

// MARK: - settings.reload_models

struct ACTAReloadModelsAction: ACTAPreparedConfirmationAction {
    typealias ReloadHook = @MainActor @Sendable () async -> Bool

    @MainActor
    final class State {
        var reloadedGeneration: UUID?
    }

    struct ConfirmationSnapshot: Sendable {
        let registryGeneration: UUID
        let enabledServices: [String]
        let threadID: String
    }

    let id = "settings.reload_models"
    let title = "Reload Local AI Models"
    let description = "Invalidate and reload all enabled local AI models after operator review. Does not certify inference readiness or throughput."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters: [ACTAActionParameterSchema] = []

    private unowned let model: WallModel
    private let reloadHook: ReloadHook?
    private let state: State

    @MainActor
    init(model: WallModel, reloadHook: ReloadHook? = nil) {
        self.model = model
        self.reloadHook = reloadHook
        self.state = State()
    }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: This action takes no parameters.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        return try await MainActor.run {
            let snapshot = ModelSelectionRegistry.snapshot()
            guard snapshot.preferences == model.modelPreferences else {
                throw ConfigurationError.invalid("Model preferences and registry are out of sync.")
            }
            let enabled = snapshot.preferences.enabled.map(\.rawValue).sorted()
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    registryGeneration: snapshot.generation,
                    enabledServices: enabled,
                    threadID: context.threadID
                ),
                reviewSummary: "Invalidate and reload local AI models (\(enabled.joined(separator: ", "))). Active VLM/detection tasks will be cancelled."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        let currentGen = await MainActor.run { ModelSelectionRegistry.snapshot().generation }
        guard currentGen == snapshot.registryGeneration else {
            return .failed(actionID: id, error: "STALE_STATE: Model configuration changed since review.")
        }
        let ok: Bool
        if let reloadHook {
            ok = await reloadHook()
        } else {
            await MainActor.run {
                model.modelRuntime.invalidate()
                model.notice = "Reloading local AI models..."
            }
            await LocalVLMClient.unloadModels()
            await MainActor.run {
                model.prepareModels()
            }
            ok = true
        }
        guard ok else {
            return .failed(actionID: id, error: "RELOAD_FAILED: Local model reload did not complete.")
        }
        await MainActor.run { state.reloadedGeneration = snapshot.registryGeneration }
        let payload: [String: Any] = [
            "reloaded_services": snapshot.enabledServices,
            "inference_verified": false
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Local model reload initiated; runtime readiness and inference are not certified.",
            outputJSON: json
        )
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            defer { state.reloadedGeneration = nil }
            return state.reloadedGeneration != nil
        }
    }
}

// MARK: - settings.update_system (Unified Reviewed Broker Action: language OR system fields)

struct ACTAReviewedSystemSettingsAction: ACTAPreparedConfirmationAction {
    enum Mode: Sendable {
        case language(ACTAReviewedLanguageAction.ConfirmationSnapshot)
        case system(columns: Int?, threshold: Double?, fps: Double?, staleMs: Int?, expectedRevision: UUID)
    }

    struct ConfirmationSnapshot: Sendable {
        let mode: Mode
        let threadID: String
    }

    let id = "settings.update_system"
    let title = "Update System Settings or Interface Language"
    let description = "Update either the interface language (en/ru) or system display/detection parameters (columns, detection_threshold, detection_fps, stale_threshold_ms) after operator review. Language and system config must be changed in separate requests."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "language", type: "string", description: "Interface language", allowedValues: ["en", "ru"]),
        ACTAActionParameterSchema(name: "columns", type: "integer", description: "Grid columns (1...16)"),
        ACTAActionParameterSchema(name: "detection_threshold", type: "number", description: "YOLO detection confidence threshold (0.1...0.9)"),
        ACTAActionParameterSchema(name: "detection_fps", type: "integer", description: "YOLO detection FPS (1...5)"),
        ACTAActionParameterSchema(name: "stale_threshold_ms", type: "integer", description: "Stale stream timeout in milliseconds (200...30000)")
    ]

    private unowned let model: WallModel
    private let languageAction: ACTAReviewedLanguageAction?

    @MainActor
    init(model: WallModel, languageSettings: LanguageSettings?) {
        self.model = model
        self.languageAction = languageSettings.map { ACTAReviewedLanguageAction(settings: $0) }
    }

    private static let systemKeys: Set<String> = ["columns", "detection_threshold", "detection_fps", "stale_threshold_ms"]

    private static func validateInputs(_ parameters: [String: String]) throws {
        guard !parameters.isEmpty else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Specify language or at least one system setting.")
        }
        let hasLanguage = parameters["language"] != nil
        let hasSystem = !Set(parameters.keys).intersection(systemKeys).isEmpty
        if hasLanguage && hasSystem {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Change interface language and system configuration in separate requests.")
        }
        if hasLanguage {
            guard Set(parameters.keys) == ["language"], let lang = parameters["language"], AppLanguage(rawValue: lang) != nil else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide language en or ru.")
            }
            return
        }
        guard Set(parameters.keys).isSubset(of: systemKeys) else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Unknown system settings field.")
        }
        if let raw = parameters["columns"] {
            guard let v = Int(raw), (1...16).contains(v) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: columns must be 1...16.")
            }
        }
        if let raw = parameters["detection_threshold"] {
            guard let v = Double(raw), v.isFinite, (0.1...0.9).contains(v) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: detection_threshold must be 0.1...0.9.")
            }
        }
        if let raw = parameters["detection_fps"] {
            guard let v = Int(raw), (1...5).contains(v) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: detection_fps must be 1...5.")
            }
        }
        if let raw = parameters["stale_threshold_ms"] {
            guard let v = Int(raw), (200...30000).contains(v) else {
                throw ConfigurationError.invalid("INVALID_ARGUMENT: stale_threshold_ms must be 200...30000.")
            }
        }
    }

    func validate(parameters: [String: String]) throws {
        try Self.validateInputs(parameters)
        if parameters["language"] != nil, languageAction == nil {
            throw ConfigurationError.invalid("UNAVAILABLE: Interface language settings instance is unavailable.")
        }
    }

    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(
        parameters: [String: String], context: ACTAActionContext
    ) async throws -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        try validate(parameters: parameters)
        if parameters["language"] != nil {
            guard let languageAction else {
                throw ConfigurationError.invalid("UNAVAILABLE: Interface language settings instance is unavailable.")
            }
            let prepared = try await languageAction.prepareConfirmation(parameters: parameters, context: context)
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(mode: .language(prepared.snapshot), threadID: context.threadID),
                reviewSummary: prepared.reviewSummary
            )
        }
        return try await MainActor.run {
            let current = try model.cameraConfigurationChecked()
            let cols = parameters["columns"].flatMap(Int.init)
            let thresh = parameters["detection_threshold"].flatMap(Double.init)
            let fps = parameters["detection_fps"].flatMap(Double.init)
            let stale = parameters["stale_threshold_ms"].flatMap(Int.init)
            var changes: [String] = []
            if let cols { changes.append("columns \(current.columns)->\(cols)") }
            if let thresh { changes.append("detection_threshold \(current.detectionThreshold)->\(thresh)") }
            if let fps { changes.append("detection_fps \(current.detectionFPS)->\(fps)") }
            if let stale { changes.append("stale_threshold_ms \(current.staleAfterMilliseconds)->\(stale)") }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(
                    mode: .system(columns: cols, threshold: thresh, fps: fps, staleMs: stale, expectedRevision: model.cameraInventoryRevision),
                    threadID: context.threadID
                ),
                reviewSummary: "Update system settings: \(changes.joined(separator: ", "))."
            )
        }
    }

    func executeConfirmed(
        parameters: [String: String], context: ACTAActionContext, snapshot: ConfirmationSnapshot
    ) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        guard snapshot.threadID == context.threadID else {
            return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Thread changed.")
        }
        switch snapshot.mode {
        case .language(let langSnapshot):
            guard let languageAction else {
                return .failed(actionID: id, error: "UNAVAILABLE: Interface language settings instance is unavailable.")
            }
            return try await languageAction.executeConfirmed(parameters: parameters, context: context, snapshot: langSnapshot)
        case .system(let cols, let thresh, let fps, let stale, let expectedRevision):
            return try await MainActor.run {
                guard model.cameraInventoryRevision == expectedRevision else {
                    return .failed(actionID: id, error: "STALE_STATE: System configuration changed since review.")
                }
                var draft = try model.cameraConfigurationChecked()
                if let cols { draft.columns = cols }
                if let thresh { draft.detectionThreshold = thresh }
                if let fps { draft.detectionFPS = fps }
                if let stale { draft.staleAfterMilliseconds = stale }
                try draft.validate()
                try model.saveSystemSettings(draft)
                let saved = try model.cameraConfigurationChecked()
                guard saved.columns == draft.columns,
                      saved.detectionThreshold == draft.detectionThreshold,
                      saved.detectionFPS == draft.detectionFPS,
                      saved.staleAfterMilliseconds == draft.staleAfterMilliseconds else {
                    return .failed(actionID: id, error: "STORAGE_ERROR: System settings verification failed.")
                }
                let payload: [String: Any] = [
                    "columns": saved.columns,
                    "detectionThreshold": saved.detectionThreshold,
                    "detectionFPS": saved.detectionFPS,
                    "staleAfterMilliseconds": saved.staleAfterMilliseconds
                ]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
                return ACTAActionResult(actionID: id, success: true, summary: "System settings saved and verified.", outputJSON: json)
            }
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try validate(parameters: parameters)
        if parameters["language"] != nil {
            guard let languageAction else { return false }
            return try await languageAction.verify(parameters: parameters, context: context)
        }
        return try await MainActor.run {
            let saved = try model.cameraConfigurationChecked()
            if let v = parameters["columns"].flatMap(Int.init), saved.columns != v { return false }
            if let v = parameters["detection_threshold"].flatMap(Double.init), saved.detectionThreshold != v { return false }
            if let v = parameters["detection_fps"].flatMap(Double.init), saved.detectionFPS != v { return false }
            if let v = parameters["stale_threshold_ms"].flatMap(Int.init), saved.staleAfterMilliseconds != v { return false }
            return true
        }
    }
}
