import Foundation

/// Central thread-safe registry and execution coordinator for all ACTA domain actions.
public actor ACTAActionRegistry {
    public static let shared = ACTAActionRegistry()

    public struct PendingConfirmation: Sendable {
        public let token: String
        public let actionID: String
        public let parameters: [String: String]
        public let context: ACTAActionContext
        public let createdAt: Date
        public let expiresAt: Date
    }

    private var actions: [String: any ACTAActionProtocol] = [:]
    private var pendingConfirmations: [String: PendingConfirmation] = [:]

    public init() {}

    // MARK: - Registration

    public func register(_ action: any ACTAActionProtocol) {
        actions[action.id] = action
    }

    public func unregister(actionID: String) {
        actions.removeValue(forKey: actionID)
    }

    public func action(for id: String) -> (any ACTAActionProtocol)? {
        return actions[id]
    }

    public func allActions() -> [any ACTAActionProtocol] {
        return Array(actions.values).sorted(by: { $0.id < $1.id })
    }

    // MARK: - OpenAI Function-Calling Tool Export

    public func openAITools() -> [[String: Any]] {
        return actions.values.sorted(by: { $0.id < $1.id }).map { action in
            var properties: [String: Any] = [:]
            var required: [String] = []

            for p in action.parameters {
                var propDict: [String: Any] = [
                    "type": p.type,
                    "description": p.description
                ]
                if let allowed = p.allowedValues {
                    propDict["enum"] = allowed
                }
                properties[p.name] = propDict
                if p.isRequired {
                    required.append(p.name)
                }
            }

            return [
                "type": "function",
                "function": [
                    "name": action.id,
                    "description": action.description,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": required
                    ]
                ]
            ]
        }
    }

    // MARK: - Execution & Policy Verification

    public func execute(
        actionID: String,
        parameters: [String: String],
        context: ACTAActionContext = ACTAActionContext()
    ) async throws -> ACTAActionResult {
        guard let action = actions[actionID] else {
            return ACTAActionResult.failed(
                actionID: actionID,
                error: "Unsupported action: '\(actionID)'. Available actions: \(actions.keys.sorted().joined(separator: ", "))"
            )
        }

        // 1. Check Destructive Confirmation Gate
        if action.classification == .destructive && !context.isConfirmed {
            let token = "CONFIRM-" + UUID().uuidString.prefix(8).uppercased()
            let pending = PendingConfirmation(
                token: token,
                actionID: actionID,
                parameters: parameters,
                context: context,
                createdAt: context.now,
                expiresAt: context.now.addingTimeInterval(300) // 5 minutes TTL
            )
            pendingConfirmations[token] = pending

            let paramDesc = parameters.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            let summary = "Operator confirmation required for destructive action '\(action.title)' [\(actionID)] with parameters: (\(paramDesc)). Token: \(token)"
            return ACTAActionResult.needsConfirmation(actionID: actionID, summary: summary, token: token)
        }

        // 2. Execute Action
        let result: ACTAActionResult
        do {
            result = try await action.execute(parameters: parameters, context: context)
        } catch {
            return ACTAActionResult.failed(actionID: actionID, error: error.localizedDescription)
        }

        guard result.success else {
            return result
        }

        // 3. Read-After-Write Verification
        let isVerified: Bool
        do {
            isVerified = try await action.verify(parameters: parameters, context: context)
        } catch {
            isVerified = false
        }

        if !isVerified {
            return ACTAActionResult(
                actionID: actionID,
                success: false,
                summary: "Action '\(actionID)' completed execution, but read-after-write verification failed.",
                outputJSON: result.outputJSON,
                verified: false,
                error: "Read-after-write verification failed for \(actionID)"
            )
        }

        return result
    }

    // MARK: - Confirmation Resolution

    public func confirmAndExecute(token: String, confirmed: Bool) async throws -> ACTAActionResult {
        cleanupExpiredConfirmations()
        guard let pending = pendingConfirmations.removeValue(forKey: token) else {
            return ACTAActionResult.failed(actionID: "unknown", error: "Confirmation token '\(token)' is invalid or expired.")
        }

        guard confirmed else {
            return ACTAActionResult(
                actionID: pending.actionID,
                success: false,
                summary: "Operator rejected destructive action '\(pending.actionID)'. Execution cancelled.",
                outputJSON: "{\"status\": \"cancelled_by_operator\"}",
                verified: true,
                error: nil
            )
        }

        let confirmedContext = ACTAActionContext(
            threadID: pending.context.threadID,
            initiator: pending.context.initiator,
            now: Date(),
            trackingStore: pending.context.trackingStore,
            isConfirmed: true
        )

        return try await execute(
            actionID: pending.actionID,
            parameters: pending.parameters,
            context: confirmedContext
        )
    }

    private func cleanupExpiredConfirmations() {
        let now = Date()
        pendingConfirmations = pendingConfirmations.filter { $0.value.expiresAt > now }
    }
}
