import Foundation
import CoreFoundation

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
        fileprivate let actionGeneration: UUID
    }

    private var mutationInProgress = false
    private var actions: [String: any ACTAActionProtocol] = [:]
    private var actionGenerations: [String: UUID] = [:]
    private var pendingConfirmations: [String: PendingConfirmation] = [:]
    private let confirmationNow: @Sendable () -> Date

    public init() {
        confirmationNow = { Date() }
    }

    init(confirmationNow: @escaping @Sendable () -> Date) {
        self.confirmationNow = confirmationNow
    }

    // MARK: - Registration

    public func register(_ action: any ACTAActionProtocol) {
        pendingConfirmations = pendingConfirmations.filter { $0.value.actionID != action.id }
        actions[action.id] = action
        actionGenerations[action.id] = UUID()
    }

    public func unregister(actionID: String) {
        pendingConfirmations = pendingConfirmations.filter { $0.value.actionID != actionID }
        actions.removeValue(forKey: actionID)
        actionGenerations.removeValue(forKey: actionID)
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
        let unconfirmedContext = ACTAActionContext(
            threadID: context.threadID,
            initiator: context.initiator,
            now: context.now,
            trackingStore: context.trackingStore,
            isConfirmed: false
        )
        return try await executeValidated(
            actionID: actionID, parameters: parameters, context: unconfirmedContext, confirmed: false
        )
    }

    /// Validates model-generated JSON against the action captured by this actor before any audit,
    /// confirmation, or execution. Direct string callers retain their existing contract.
    public func executeJSON(
        actionID: String,
        argumentsJSON: String,
        context: ACTAActionContext = ACTAActionContext(),
        beforeExecution: @escaping @Sendable ([String: String]) throws -> Void = { _ in }
    ) async throws -> ACTAActionResult {
        let unconfirmedContext = ACTAActionContext(
            threadID: context.threadID, initiator: context.initiator, now: context.now,
            trackingStore: context.trackingStore, isConfirmed: false
        )
        return try await executeValidated(
            actionID: actionID, parameters: [:], context: unconfirmedContext, confirmed: false,
            argumentsJSON: argumentsJSON, beforeExecution: beforeExecution
        )
    }

    private func executeValidated(
        actionID: String,
        parameters: [String: String],
        context: ACTAActionContext,
        confirmed: Bool,
        argumentsJSON: String? = nil,
        beforeExecution: (@Sendable ([String: String]) throws -> Void)? = nil,
        expectedGeneration: UUID? = nil
    ) async throws -> ACTAActionResult {
        if let expectedGeneration, actionGenerations[actionID] != expectedGeneration {
            return .failed(actionID: actionID, error: "CONFIRMATION_REVOKED: The action was replaced or unregistered.")
        }
        guard let action = actions[actionID], let actionGeneration = actionGenerations[actionID] else {
            return ACTAActionResult.failed(
                actionID: actionID,
                error: "UNSUPPORTED: Unsupported action: '\(actionID)'. Available actions: \(actions.keys.sorted().joined(separator: ", "))"
            )
        }

        // Capture the action and its schema before the first suspension point.
        let actionParameters = action.parameters
        // Validate before requesting confirmation or allowing any side effect.
        var parameters = parameters
        if let argumentsJSON {
            do {
                parameters = try Self.jsonParameters(argumentsJSON, schema: actionParameters)
            } catch {
                return .failed(actionID: actionID, error: error.localizedDescription)
            }
        }
        let schema = Dictionary(uniqueKeysWithValues: actionParameters.map { ($0.name, $0) })
        guard Set(parameters.keys).isSubset(of: Set(schema.keys)) else {
            return .failed(actionID: actionID, error: "INVALID_ARGUMENT: Unknown parameter.")
        }
        for field in actionParameters {
            guard let value = parameters[field.name] else {
                if field.isRequired { return .failed(actionID: actionID, error: "INVALID_ARGUMENT: Missing \(field.name).") }
                continue
            }
            let valid: Bool
            switch field.type {
            case "boolean": valid = Self.canonicalBoolean(value) != nil
            case "integer": valid = Int(value) != nil
            case "number": valid = Double(value)?.isFinite == true
            case "string": valid = !field.isRequired || field.allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: valid = false
            }
            guard valid, field.allowedValues?.contains(value) ?? true else {
                return .failed(actionID: actionID, error: "INVALID_ARGUMENT: Invalid \(field.name).")
            }
            if field.type == "boolean" {
                parameters[field.name] = Self.canonicalBoolean(value)
            }
        }
        do { try action.validate(parameters: parameters) }
        catch { return .failed(actionID: actionID, error: error.localizedDescription) }
        try Task.checkCancellation()
        if argumentsJSON != nil {
            do { try beforeExecution?(parameters) }
            catch { return .failed(actionID: actionID, error: error.localizedDescription) }
        }

        // 1. Check Destructive / Security Confirmation Gate
        if action.requiresConfirmation(parameters: parameters) && !confirmed {
            cleanupExpiredConfirmations()
            var token: String
            repeat {
                token = "CONFIRM-" + UUID().uuidString
            } while pendingConfirmations[token] != nil
            let createdAt = confirmationNow()
            let pending = PendingConfirmation(
                token: token,
                actionID: actionID,
                parameters: parameters,
                context: context,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(300), // 5 minutes TTL
                actionGeneration: actionGeneration
            )
            pendingConfirmations[token] = pending

            let paramDesc = parameters.keys.sorted().map { key in
                let sensitive = key.lowercased() == "note"
                    || ["password", "secret", "token", "key", "credential", "url"].contains { key.lowercased().contains($0) }
                return "\(key)=\(sensitive ? "[redacted]" : String((parameters[key] ?? "").prefix(256)))"
            }.joined(separator: ", ")
            let summary = "Operator confirmation required for protected action '\(action.title)' [\(actionID)] with parameters: (\(paramDesc)). Token: \(token)"
            return ACTAActionResult.needsConfirmation(actionID: actionID, summary: summary, token: token)
        }

        // Actor reentrancy across execute/verify must not permit lost-update mutations.
        // Reject overlapping writes explicitly; callers may retry after the active action completes.
        let isMutation = action.classification != .inspect
        if isMutation && mutationInProgress {
            return .failed(actionID: actionID, error: "ACTION_BUSY: Another mutation is still executing or verifying.")
        }
        if isMutation { mutationInProgress = true }
        defer { if isMutation { mutationInProgress = false } }

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
        return try await executePending(pending, confirmed: confirmed)
    }

    /// Confirms only the intent reviewed by the operator. A mismatch does not consume the token.
    public func confirmAndExecute(
        token: String,
        confirmed: Bool,
        expectedActionID: String,
        expectedParameters: [String: String],
        expectedThreadID: String
    ) async throws -> ACTAActionResult {
        cleanupExpiredConfirmations()
        guard let pending = pendingConfirmations[token] else {
            return ACTAActionResult.failed(actionID: "unknown", error: "Confirmation token '\(token)' is invalid or expired.")
        }
        guard matches(pending, actionID: expectedActionID, parameters: expectedParameters, threadID: expectedThreadID) else {
            return .failed(actionID: pending.actionID, error: "CONFIRMATION_MISMATCH: Reviewed action does not match the pending confirmation.")
        }
        pendingConfirmations.removeValue(forKey: token)
        return try await executePending(pending, confirmed: confirmed)
    }

    public func confirmationMatches(token: String, actionID: String, parameters: [String: String], threadID: String) -> Bool {
        cleanupExpiredConfirmations()
        guard let pending = pendingConfirmations[token] else { return false }
        return matches(pending, actionID: actionID, parameters: parameters, threadID: threadID)
    }

    private func matches(_ pending: PendingConfirmation, actionID: String,
                         parameters: [String: String], threadID: String) -> Bool {
        guard pending.actionID == actionID, pending.context.threadID == threadID,
              let action = actions[pending.actionID] else {
            return false
        }
        var normalized = parameters
        for field in action.parameters where field.type == "boolean" {
            if let value = normalized[field.name] {
                guard let canonical = Self.canonicalBoolean(value) else { return false }
                normalized[field.name] = canonical
            }
        }
        return normalized == pending.parameters
    }

    private func executePending(_ pending: PendingConfirmation, confirmed: Bool) async throws -> ACTAActionResult {
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

        return try await executeValidated(
            actionID: pending.actionID,
            parameters: pending.parameters,
            context: confirmedContext,
            confirmed: true,
            expectedGeneration: pending.actionGeneration
        )
    }

    private func cleanupExpiredConfirmations() {
        let now = confirmationNow()
        pendingConfirmations = pendingConfirmations.filter { $0.value.expiresAt > now }
    }

    private static func canonicalBoolean(_ value: String) -> String? {
        switch value {
        case "true", "1": return "true"
        case "false", "0": return "false"
        default: return nil
        }
    }

    private struct JSONArgumentError: LocalizedError {
        let message: String
        var errorDescription: String? { "INVALID_ARGUMENT: \(message)" }
    }

    private static func jsonParameters(
        _ json: String, schema: [ACTAActionParameterSchema]
    ) throws -> [String: String] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw JSONArgumentError(message: "Arguments must be a valid JSON object.")
        }
        let literals = try Self.jsonScalarLiterals(json)
        let fields = Dictionary(uniqueKeysWithValues: schema.map { ($0.name, $0) })
        guard Set(object.keys).isSubset(of: Set(fields.keys)) else {
            throw JSONArgumentError(message: "Unknown parameter.")
        }
        for (key, value) in object {
            guard let field = fields[key] else { throw JSONArgumentError(message: "Unknown parameter.") }
            switch field.type {
            case "string":
                guard value is String else {
                    throw JSONArgumentError(message: "Invalid type for \(key).")
                }
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw JSONArgumentError(message: "Invalid type for \(key).")
                }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let literal = literals[key], Self.jsonInteger(literal) != nil else {
                    throw JSONArgumentError(message: "Invalid type for \(key).")
                }
            case "number":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let literal = literals[key], Double(literal)?.isFinite == true else {
                    throw JSONArgumentError(message: "Invalid type for \(key).")
                }
            default:
                throw JSONArgumentError(message: "Unsupported schema type for \(key).")
            }
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            switch (fields[key]?.type, value) {
            case ("string", let string as String):
                result[key] = string
            case ("boolean", let number as NSNumber):
                result[key] = number.boolValue ? "true" : "false"
            case ("integer", _):
                guard let literal = literals[key], let integer = Self.jsonInteger(literal) else {
                    throw JSONArgumentError(message: "Invalid integer for \(key).")
                }
                result[key] = String(integer)
            case ("number", _):
                result[key] = literals[key]
            default:
                throw JSONArgumentError(message: "Unsupported schema type for \(key).")
            }
        }
        return result
    }

    // JSONSerialization can round a fractional literal to an integer; keep the original spelling.
    private static func jsonScalarLiterals(_ json: String) throws -> [String: String] {
        let bytes = Array(json.utf8)
        var index = 0
        func skipWhitespace() {
            while index < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
        }
        func stringEnd() throws {
            guard index < bytes.count, bytes[index] == 34 else {
                throw JSONArgumentError(message: "Arguments must be a valid JSON object.")
            }
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { index += 1; return }
                index += 1
            }
            throw JSONArgumentError(message: "Arguments must be a valid JSON object.")
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 123 else {
            throw JSONArgumentError(message: "Arguments must be a valid JSON object.")
        }
        index += 1
        var literals: [String: String] = [:]
        while true {
            skipWhitespace()
            guard index < bytes.count else { throw JSONArgumentError(message: "Invalid JSON object.") }
            if bytes[index] == 125 { return literals }
            let keyStart = index
            try stringEnd()
            let keyJSON = "[" + String(decoding: bytes[keyStart..<index], as: UTF8.self) + "]"
            guard let keys = try? JSONSerialization.jsonObject(with: Data(keyJSON.utf8)) as? [String],
                  let key = keys.first, literals[key] == nil else {
                throw JSONArgumentError(message: "Invalid or duplicate parameter.")
            }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 58 else { throw JSONArgumentError(message: "Invalid JSON object.") }
            index += 1
            skipWhitespace()
            guard index < bytes.count else { throw JSONArgumentError(message: "Invalid JSON object.") }
            let start = index
            if bytes[index] == 34 {
                try stringEnd()
            } else {
                guard bytes[index] != 123, bytes[index] != 91 else {
                    throw JSONArgumentError(message: "Invalid type for \(key).")
                }
                while index < bytes.count && bytes[index] != 44 && bytes[index] != 125 { index += 1 }
            }
            literals[key] = String(decoding: bytes[start..<index], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            skipWhitespace()
            guard index < bytes.count else { throw JSONArgumentError(message: "Invalid JSON object.") }
            if bytes[index] == 125 { return literals }
            guard bytes[index] == 44 else { throw JSONArgumentError(message: "Invalid JSON object.") }
            index += 1
        }
    }

    private static func jsonInteger(_ literal: String) -> Int? {
        let parts = literal.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let negative = parts[0].hasPrefix("-")
        let coefficient = negative ? parts[0].dropFirst() : parts[0][...]
        let decimal = coefficient.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { return nil }
        let coefficientDigits = String(decimal.joined())
        guard coefficientDigits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var digits = String(coefficientDigits.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        let fractionCount = decimal.count == 2 ? decimal[1].count : 0
        let (scale, overflow) = exponent.subtractingReportingOverflow(fractionCount)
        guard !overflow else { return nil }
        if scale < 0 {
            guard scale >= -digits.count else { return nil }
            let count = -scale
            guard digits.suffix(count).allSatisfy({ $0 == "0" }) else { return nil }
            digits.removeLast(count)
        } else {
            guard scale <= 19, digits.count + scale <= 19 else { return nil }
            digits += String(repeating: "0", count: scale)
        }
        return Int((negative ? "-" : "") + digits)
    }
}
