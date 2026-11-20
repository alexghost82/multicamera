import CameraCore
import Foundation

// MARK: - Phase 3 Local vLLM Metal Serving Broker Actions (GUI↔Agent Parity)

private func encodeVLLMJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func telemetryPayload(
    snapshot: ACTALocalVLLMTelemetrySnapshot,
    preferences: VLMPreferences
) -> [String: Any] {
    var payload: [String: Any] = [
        "backendMode": preferences.actaBackendMode.rawValue,
        "baseURL": preferences.actaVLLMBaseURL,
        "modelName": preferences.actaVLLMModelName,
        "maxConcurrentRequests": preferences.actaVLLMMaxConcurrentRequests,
        "allowLocalMLXFallback": preferences.actaVLLMAllowLocalMLXFallback,
        "gpuMemoryUtilization": preferences.actaVLLMGPUMemoryUtilization,
        "serverState": snapshot.state.rawValue,
        "loadedModel": snapshot.loadedModel ?? "",
        "activeInteractiveRequests": snapshot.activeInteractiveRequests,
        "activeBackgroundRequests": snapshot.activeBackgroundRequests,
        "queuedRequests": snapshot.queuedRequests,
        "lastError": snapshot.lastError ?? ""
    ]
    if let ttft = snapshot.lastTTFTMs { payload["lastTTFTMs"] = ttft }
    if let tokS = snapshot.lastTokensPerSecond { payload["lastTokensPerSecond"] = tokS }
    if let p50 = snapshot.p50LatencyMs { payload["p50LatencyMs"] = p50 }
    if let p95 = snapshot.p95LatencyMs { payload["p95LatencyMs"] = p95 }
    return payload
}

struct ACTAGetVLLMStatusAction: ACTAActionProtocol {
    let id = "settings.get_vllm_status"
    let title = "Get local vLLM Metal status and settings"
    let description = "Inspect local vLLM Metal serving configuration, server lifecycle state, queue depth, and rolling TTFT/throughput telemetry. Never exposes API keys."
    let classification = ACTAActionClassification.inspect
    let parameters: [ACTAActionParameterSchema] = []
    unowned let model: WallModel

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else {
            throw ConfigurationError.invalid("settings.get_vllm_status accepts no parameters.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        try Task.checkCancellation()
        let snapshot = await model.localVLLMServerManager.telemetrySnapshot()
        let preferences = await MainActor.run { model.vlmPreferences }
        let json = try encodeVLLMJSON(telemetryPayload(snapshot: snapshot, preferences: preferences))
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Local vLLM Metal status is \(snapshot.state.rawValue) (max parallel: \(preferences.actaVLLMMaxConcurrentRequests), local MLX fallback: \(preferences.actaVLLMAllowLocalMLXFallback)).",
            outputJSON: json
        )
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        true
    }
}

struct ACTAUpdateVLLMServingAction: ACTAActionProtocol {
    let id = "settings.update_vllm_serving"
    let title = "Update local vLLM Metal serving settings"
    let description = "Update bounded parallel concurrency limit (1-16), opt-in local-only MLX fallback (never cloud), and GPU memory utilization (0.30-0.90) for local vLLM Metal after operator confirmation."
    let classification = ACTAActionClassification.securitySensitive
    unowned let model: WallModel

    let parameters = [
        ACTAActionParameterSchema(
            name: "maxConcurrentRequests",
            type: "integer",
            description: "Maximum parallel local vLLM requests (1 to 16)"
        ),
        ACTAActionParameterSchema(
            name: "allowLocalMLXFallback",
            type: "boolean",
            description: "Allow local-only fallback to in-process MLX when vLLM Metal is unavailable (never cloud/OpenAI)"
        ),
        ACTAActionParameterSchema(
            name: "gpuMemoryUtilization",
            type: "number",
            description: "vLLM Metal GPU memory utilization fraction (0.30 to 0.90)"
        )
    ]

    private struct Patch {
        var maxConcurrent: Int?
        var allowLocalMLXFallback: Bool?
        var gpuMemoryUtilization: Double?

        init(_ parameters: [String: String]) throws {
            let allowed: Set<String> = ["maxConcurrentRequests", "allowLocalMLXFallback", "gpuMemoryUtilization"]
            guard !parameters.isEmpty, Set(parameters.keys).isSubset(of: allowed) else {
                throw ConfigurationError.invalid("Specify at least one supported vLLM serving field: maxConcurrentRequests, allowLocalMLXFallback, or gpuMemoryUtilization.")
            }
            if let raw = parameters["maxConcurrentRequests"] {
                guard let value = Int(raw), (1...16).contains(value) else {
                    throw ConfigurationError.invalid("maxConcurrentRequests must be an integer between 1 and 16.")
                }
                maxConcurrent = value
            }
            if let raw = parameters["allowLocalMLXFallback"] {
                switch raw {
                case "true": allowLocalMLXFallback = true
                case "false": allowLocalMLXFallback = false
                default: throw ConfigurationError.invalid("allowLocalMLXFallback must be a boolean.")
                }
            }
            if let raw = parameters["gpuMemoryUtilization"] {
                guard let value = Double(raw), value.isFinite, (0.30...0.90).contains(value) else {
                    throw ConfigurationError.invalid("gpuMemoryUtilization must be a finite number between 0.30 and 0.90.")
                }
                gpuMemoryUtilization = value
            }
        }

        func applying(to preferences: VLMPreferences) -> VLMPreferences {
            var next = preferences
            if let maxConcurrent { next.actaVLLMMaxConcurrentRequests = maxConcurrent }
            if let allowLocalMLXFallback { next.actaVLLMAllowLocalMLXFallback = allowLocalMLXFallback }
            if let gpuMemoryUtilization { next.actaVLLMGPUMemoryUtilization = gpuMemoryUtilization }
            return next
        }
    }

    func validate(parameters: [String: String]) throws {
        _ = try Patch(parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let patch = try Patch(parameters)
        guard context.isConfirmed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
        }
        let next = try await MainActor.run { () throws -> VLMPreferences in
            try Task.checkCancellation()
            guard let client = model.actaAnalytics?.aiClient else {
                throw ConfigurationError.invalid("AI client is unavailable.")
            }
            let current = model.vlmPreferences
            let policy = try model.featurePolicySnapshotChecked()
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == current,
                  client.configuration() == model.expectedACTAAIConfiguration(for: current, featurePreferences: policy) else {
                throw ConfigurationError.invalid("AI preferences or runtime configuration changed; reload them before making changes.")
            }
            let updated = patch.applying(to: current)
            try updated.validate()
            try model.saveVLMPreferences(updated)
            let savedPolicy = try model.featurePolicySnapshotChecked()
            guard try VLMStore.loadPreferences(from: model.vlmPreferencesURL) == updated,
                  model.vlmPreferences == updated,
                  client.configuration() == model.expectedACTAAIConfiguration(for: updated, featurePreferences: savedPolicy) else {
                throw ConfigurationError.invalid("Local vLLM serving settings persistence or runtime verification failed.")
            }
            return updated
        }
        await model.localVLLMServerManager.limiter.updateMaxTotalConcurrency(next.actaVLLMMaxConcurrentRequests)
        if let client = await MainActor.run(body: { model.actaAnalytics?.aiClient }) {
            await client.updateLocalVLLMMaxConcurrency(next.actaVLLMMaxConcurrentRequests)
        }
        let output: [String: Any] = [
            "maxConcurrentRequests": next.actaVLLMMaxConcurrentRequests,
            "allowLocalMLXFallback": next.actaVLLMAllowLocalMLXFallback,
            "gpuMemoryUtilization": next.actaVLLMGPUMemoryUtilization
        ]
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Local vLLM Metal serving settings saved and verified.",
            outputJSON: try encodeVLLMJSON(output)
        )
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let patch = try Patch(parameters)
        let limiterMax = await model.localVLLMServerManager.limiter.maxTotalConcurrency
        return try await MainActor.run {
            guard let client = model.actaAnalytics?.aiClient else { return false }
            let current = model.vlmPreferences
            let stored = try VLMStore.loadPreferences(from: model.vlmPreferencesURL)
            let policy = try model.featurePolicySnapshotChecked()
            return patch.applying(to: current) == current
                && stored == current
                && limiterMax == current.actaVLLMMaxConcurrentRequests
                && client.configuration() == model.expectedACTAAIConfiguration(for: current, featurePreferences: policy)
        }
    }
}

struct ACTAControlVLLMServerAction: ACTAActionProtocol {
    let id = "settings.control_vllm_server"
    let title = "Control managed local vLLM Metal server"
    let description = "Start, stop, or health-check the local loopback vLLM Metal server after operator confirmation. Never exposes ephemeral API keys."
    let classification = ACTAActionClassification.securitySensitive
    unowned let model: WallModel

    let parameters = [
        ACTAActionParameterSchema(
            name: "operation",
            type: "string",
            description: "Lifecycle operation: start, stop, or check_health",
            isRequired: true,
            allowedValues: ["start", "stop", "check_health"]
        )
    ]

    private func parseOperation(_ parameters: [String: String]) throws -> String {
        guard parameters.count == 1,
              let op = parameters["operation"],
              ["start", "stop", "check_health"].contains(op) else {
            throw ConfigurationError.invalid("Specify operation as start, stop, or check_health.")
        }
        return op
    }

    func validate(parameters: [String: String]) throws {
        _ = try parseOperation(parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let operation = try parseOperation(parameters)
        guard context.isConfirmed else {
            return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator confirmation is required.")
        }
        try Task.checkCancellation()
        let snapshot: ACTALocalVLLMTelemetrySnapshot
        switch operation {
        case "start":
            snapshot = try await model.startManagedLocalVLLMAndWait()
        case "stop":
            snapshot = await model.stopManagedLocalVLLMAndWait()
        case "check_health":
            snapshot = try await model.refreshLocalVLLMHealthAndWait()
        default:
            throw ConfigurationError.invalid("Unsupported vLLM server operation: \(operation)")
        }
        let preferences = await MainActor.run { model.vlmPreferences }
        var payload = telemetryPayload(snapshot: snapshot, preferences: preferences)
        payload["operation"] = operation
        return ACTAActionResult(
            actionID: id,
            success: true,
            summary: "Local vLLM Metal operation '\(operation)' completed (state: \(snapshot.state.rawValue)).",
            outputJSON: try encodeVLLMJSON(payload)
        )
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let operation = try parseOperation(parameters)
        let snapshot = await model.localVLLMServerManager.telemetrySnapshot()
        switch operation {
        case "start":
            return snapshot.state == .running
        case "stop":
            return snapshot.state == .stopped
        case "check_health":
            return snapshot.state == .running || snapshot.state == .stopped || snapshot.state == .degraded
        default:
            return false
        }
    }
}
