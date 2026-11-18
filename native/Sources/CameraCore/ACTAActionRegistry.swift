import Foundation
import CoreFoundation

/// Central thread-safe registry and execution coordinator for all ACTA domain actions.
public actor ACTAActionRegistry {
    public static let shared = ACTAActionRegistry()

    /// Maximum pending tokens and in-flight preparations per registry.
    public static let maxPendingConfirmationCount = 64
    /// Maximum UTF-8 size of a prepared review summary (256 KiB).
    public static let maxPreparedReviewSummaryUTF8Bytes = 256 * 1024

    public struct PendingConfirmation: Sendable {
        public let token: String
        public let actionID: String
        public let parameters: [String: String]
        public let context: ACTAActionContext
        public let createdAt: Date
        public let expiresAt: Date
        public let reviewTitle: String
        fileprivate let actionGeneration: UUID
        fileprivate let preparedExecution: PreparedExecution?
        fileprivate let requester: ACTALocalPrincipal?
    }

    fileprivate struct PreparedExecution: Sendable {
        let reviewSummary: String
        let execute: @Sendable ([String: String], ACTAActionContext) async throws -> ACTAActionResult
    }

    private var mutationInProgress = false
    private var actions: [String: any ACTAActionProtocol] = [:]
    private var actionGenerations: [String: UUID] = [:]
    private var pendingConfirmations: [String: PendingConfirmation] = [:]
    private var preparationReservations = 0
    private let maxPendingConfirmations: Int
    private let confirmationNow: @Sendable () -> Date
    private let authority: ACTALocalAuthority?
    private let forceMutationConfirmation: Bool
    private struct Grant {
        let principal: ACTALocalPrincipal
        let actionIDs: Set<String>
        let canRequest: Bool
        let canReview: Bool
    }
    private var grants: [ObjectIdentifier: Grant] = [:]

    /// Legacy registry: callers are trusted and no registry authorization is enforced.
    public init() {
        confirmationNow = { Date() }
        maxPendingConfirmations = Self.maxPendingConfirmationCount
        authority = nil
        forceMutationConfirmation = false
    }

    init(confirmationNow: @escaping @Sendable () -> Date, maxPendingConfirmations: Int = ACTAActionRegistry.maxPendingConfirmationCount) {
        precondition(maxPendingConfirmations > 0)
        self.confirmationNow = confirmationNow
        self.maxPendingConfirmations = maxPendingConfirmations
        authority = nil
        forceMutationConfirmation = false
    }

    private init(authority: ACTALocalAuthority, forceMutationConfirmation: Bool) {
        self.authority = authority
        self.forceMutationConfirmation = forceMutationConfirmation
        confirmationNow = { Date() }
        maxPendingConfirmations = Self.maxPendingConfirmationCount
    }

    /// The caller must retain the authority privately and act as the trusted broker.
    /// This separate opt-in registry does not change the legacy shared registry.
    public nonisolated static func makeAuthorized(
        forceMutationConfirmation: Bool = false
    ) -> (registry: ACTAActionRegistry, authority: ACTALocalAuthority) {
        let authority = ACTALocalAuthority()
        return (ACTAActionRegistry(authority: authority, forceMutationConfirmation: forceMutationConfirmation), authority)
    }

    /// Capabilities are registry-specific, scoped to explicit action IDs, and revocable.
    public func issuePrincipal(
        authority: ACTALocalAuthority, actionIDs: Set<String>, canRequest: Bool, canReview: Bool
    ) -> ACTALocalPrincipal? {
        guard self.authority === authority, !actionIDs.isEmpty, canRequest || canReview else { return nil }
        let principal = ACTALocalPrincipal()
        grants[ObjectIdentifier(principal)] = Grant(
            principal: principal, actionIDs: actionIDs, canRequest: canRequest, canReview: canReview
        )
        return principal
    }

    @discardableResult
    public func revoke(_ principal: ACTALocalPrincipal, authority: ACTALocalAuthority) -> Bool {
        guard self.authority === authority, grants.removeValue(forKey: ObjectIdentifier(principal)) != nil else { return false }
        pendingConfirmations = pendingConfirmations.filter { $0.value.requester !== principal }
        return true
    }

    private func permits(_ principal: ACTALocalPrincipal?, actionID: String, review: Bool) -> Bool {
        guard let principal, let grant = grants[ObjectIdentifier(principal)],
              grant.principal === principal, grant.actionIDs.contains(actionID) else { return false }
        return review ? grant.canReview : grant.canRequest
    }

    // MARK: - Registration

    public func register(_ action: any ACTAActionProtocol) {
        guard authority == nil else { return }
        registerAction(action)
    }

    @discardableResult
    public func register(_ action: any ACTAActionProtocol, authority: ACTALocalAuthority) -> Bool {
        guard self.authority === authority else { return false }
        registerAction(action)
        return true
    }

    private func registerAction(_ action: any ACTAActionProtocol) {
        pendingConfirmations = pendingConfirmations.filter { $0.value.actionID != action.id }
        actions[action.id] = action
        actionGenerations[action.id] = UUID()
    }

    public func unregister(actionID: String) {
        guard authority == nil else { return }
        unregisterAction(actionID: actionID)
    }

    @discardableResult
    public func unregister(actionID: String, authority: ACTALocalAuthority) -> Bool {
        guard self.authority === authority else { return false }
        unregisterAction(actionID: actionID)
        return true
    }

    private func unregisterAction(actionID: String) {
        pendingConfirmations = pendingConfirmations.filter { $0.value.actionID != actionID }
        actions.removeValue(forKey: actionID)
        actionGenerations.removeValue(forKey: actionID)
    }

    public func action(for id: String) -> (any ACTAActionProtocol)? {
        guard authority == nil else { return nil }
        return actions[id]
    }

    public func allActions() -> [any ACTAActionProtocol] {
        guard authority == nil else { return [] }
        return Array(actions.values).sorted(by: { $0.id < $1.id })
    }

    /// Exposes only metadata in the requester's scope, never executable action objects.
    public func authorizedCatalog(principal: ACTALocalPrincipal) -> [ACTAActionDescriptor] {
        guard authority != nil else { return [] }
        return actions.values.filter { permits(principal, actionID: $0.id, review: false) }
            .sorted { $0.id < $1.id }
            .map {
                ACTAActionDescriptor(id: $0.id, title: $0.title, description: $0.description,
                                     classification: $0.classification, parameters: $0.parameters)
            }
    }

    // MARK: - OpenAI Function-Calling Tool Export

    public func openAITools() -> [[String: Any]] {
        guard authority == nil else { return [] }
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
        guard authority == nil else { return authorizationDenied(actionID) }
        return try await request(actionID: actionID, parameters: parameters, context: context, principal: nil)
    }

    public func execute(
        actionID: String, parameters: [String: String], context: ACTAActionContext = ACTAActionContext(),
        principal: ACTALocalPrincipal
    ) async throws -> ACTAActionResult {
        guard authority != nil, permits(principal, actionID: actionID, review: false) else {
            return authorizationDenied(actionID)
        }
        return try await request(actionID: actionID, parameters: parameters, context: context, principal: principal)
    }

    private func request(
        actionID: String, parameters: [String: String], context: ACTAActionContext, principal: ACTALocalPrincipal?
    ) async throws -> ACTAActionResult {
        let unconfirmedContext = ACTAActionContext(
            threadID: context.threadID,
            initiator: context.initiator,
            now: context.now,
            trackingStore: context.trackingStore,
            isConfirmed: false
        )
        return try await executeValidated(
            actionID: actionID, parameters: parameters, context: unconfirmedContext, confirmed: false,
            principal: principal
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
        guard authority == nil else { return authorizationDenied(actionID) }
        return try await requestJSON(actionID: actionID, argumentsJSON: argumentsJSON, context: context,
                                     principal: nil, beforeExecution: beforeExecution)
    }

    public func executeJSON(
        actionID: String, argumentsJSON: String, context: ACTAActionContext = ACTAActionContext(),
        principal: ACTALocalPrincipal,
        beforeExecution: @escaping @Sendable ([String: String]) throws -> Void = { _ in }
    ) async throws -> ACTAActionResult {
        guard authority != nil, permits(principal, actionID: actionID, review: false) else {
            return authorizationDenied(actionID)
        }
        return try await requestJSON(actionID: actionID, argumentsJSON: argumentsJSON, context: context,
                                     principal: principal, beforeExecution: beforeExecution)
    }

    private func requestJSON(
        actionID: String, argumentsJSON: String, context: ACTAActionContext, principal: ACTALocalPrincipal?,
        beforeExecution: @escaping @Sendable ([String: String]) throws -> Void
    ) async throws -> ACTAActionResult {
        let unconfirmedContext = ACTAActionContext(
            threadID: context.threadID, initiator: context.initiator, now: context.now,
            trackingStore: context.trackingStore, isConfirmed: false
        )
        return try await executeValidated(
            actionID: actionID, parameters: [:], context: unconfirmedContext, confirmed: false,
            argumentsJSON: argumentsJSON, beforeExecution: beforeExecution, principal: principal
        )
    }

    private func executeValidated(
        actionID: String,
        parameters: [String: String],
        context: ACTAActionContext,
        confirmed: Bool,
        argumentsJSON: String? = nil,
        beforeExecution: (@Sendable ([String: String]) throws -> Void)? = nil,
        expectedGeneration: UUID? = nil,
        preparedExecution: PreparedExecution? = nil,
        principal: ACTALocalPrincipal? = nil
    ) async throws -> ACTAActionResult {
        if authority != nil && !permits(principal, actionID: actionID, review: false) {
            return authorizationDenied(actionID)
        }
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
        let critical = action.classification == .destructive || action.classification == .securitySensitive
        let forced = forceMutationConfirmation && action.classification != .inspect
        if (forced || critical || action.requiresConfirmation(parameters: parameters)) && !confirmed {
            cleanupExpiredConfirmations()
            guard pendingConfirmations.count + preparationReservations < maxPendingConfirmations else {
                return .failed(actionID: actionID, error: "CONFIRMATION_CAPACITY: Too many pending confirmations; resolve or wait for existing confirmations to expire.")
            }
            preparationReservations += 1
            defer { preparationReservations -= 1 }
            let prepared: PreparedExecution?
            if let preparingAction = action as? any ACTAPreparedConfirmationAction {
                do {
                    prepared = try await Self.prepare(preparingAction, parameters: parameters, context: context)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    guard actionGenerations[actionID] == actionGeneration else {
                        return .failed(actionID: actionID, error: "CONFIRMATION_REVOKED: The action was replaced or unregistered.")
                    }
                    return .failed(actionID: actionID, error: "CONFIRMATION_PREPARATION_FAILED: Unable to prepare operator review.")
                }
                try Task.checkCancellation()
                guard actionGenerations[actionID] == actionGeneration else {
                    return .failed(actionID: actionID, error: "CONFIRMATION_REVOKED: The action was replaced or unregistered.")
                }
            } else {
                prepared = nil
            }
            // Preparation suspends the actor; a requester may have been revoked meanwhile.
            if authority != nil && !permits(principal, actionID: actionID, review: false) {
                return authorizationDenied(actionID)
            }
            if let prepared,
               (prepared.reviewSummary.utf8.count > Self.maxPreparedReviewSummaryUTF8Bytes
                || prepared.reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                return .failed(actionID: actionID, error: "CONFIRMATION_REVIEW_INVALID: Prepared review must be nonempty and at most \(Self.maxPreparedReviewSummaryUTF8Bytes) UTF-8 bytes.")
            }
            cleanupExpiredConfirmations()
            var token: String
            repeat {
                token = "CONFIRM-" + UUID().uuidString
            } while pendingConfirmations[token] != nil
            let paramDesc = parameters.keys.sorted().map { key in
                let sensitive = key.lowercased() == "note"
                    || ["password", "secret", "token", "key", "credential", "url"].contains { key.lowercased().contains($0) }
                return "\(key)=\(sensitive ? "[redacted]" : String((parameters[key] ?? "").prefix(256)))"
            }.joined(separator: ", ")
            let review = prepared.map { "review: \($0.reviewSummary)" } ?? "parameters: (\(paramDesc))"
            let summary = "Operator confirmation required for protected action '\(action.title)' [\(actionID)] with \(review). Token: \(token)"
            let createdAt = confirmationNow()
            let pending = PendingConfirmation(
                token: token,
                actionID: actionID,
                parameters: parameters,
                context: context,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(300), // 5 minutes TTL
                reviewTitle: summary,
                actionGeneration: actionGeneration,
                preparedExecution: prepared,
                requester: principal
            )
            pendingConfirmations[token] = pending

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
            if confirmed, let preparedExecution {
                result = try await preparedExecution.execute(parameters, context)
            } else {
                result = try await action.execute(parameters: parameters, context: context)
            }
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

    private func authorizationDenied(_ actionID: String) -> ACTAActionResult {
        .failed(actionID: actionID, error: "AUTHORIZATION_DENIED: Local capability is missing, revoked, or out of scope.")
    }

    private static func prepare<Action: ACTAPreparedConfirmationAction>(
        _ action: Action, parameters: [String: String], context: ACTAActionContext
    ) async throws -> PreparedExecution {
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        return PreparedExecution(reviewSummary: prepared.reviewSummary) { parameters, context in
            try await action.executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
        }
    }

    public func confirmAndExecute(token: String, confirmed: Bool) async throws -> ACTAActionResult {
        guard authority == nil else { return authorizationDenied("unknown") }
        cleanupExpiredConfirmations()
        guard let pending = pendingConfirmations[token] else {
            return ACTAActionResult.failed(actionID: "unknown", error: "Confirmation token '\(token)' is invalid or expired.")
        }
        guard approvalMatchesReview(pending, confirmed: confirmed, reviewTitle: nil) else {
            return .failed(actionID: pending.actionID, error: "CONFIRMATION_MISMATCH: Reviewed action does not match the pending confirmation.")
        }
        pendingConfirmations.removeValue(forKey: token)
        return try await executePending(pending, confirmed: confirmed)
    }

    /// Confirms only the intent reviewed by the operator. Prepared actions require the title-bound overload for approval.
    public func confirmAndExecute(
        token: String,
        confirmed: Bool,
        expectedActionID: String,
        expectedParameters: [String: String],
        expectedThreadID: String
    ) async throws -> ACTAActionResult {
        guard authority == nil else { return authorizationDenied(expectedActionID) }
        return try await confirmReviewed(token: token, confirmed: confirmed, expectedActionID: expectedActionID,
                                  expectedParameters: expectedParameters, expectedThreadID: expectedThreadID,
                                  expectedReviewTitle: nil)
    }

    /// Also binds approval or rejection to the exact summary displayed to the operator.
    public func confirmAndExecute(
        token: String,
        confirmed: Bool,
        expectedActionID: String,
        expectedParameters: [String: String],
        expectedThreadID: String,
        expectedReviewTitle: String
    ) async throws -> ACTAActionResult {
        guard authority == nil else { return authorizationDenied(expectedActionID) }
        return try await confirmReviewed(token: token, confirmed: confirmed, expectedActionID: expectedActionID,
                                  expectedParameters: expectedParameters, expectedThreadID: expectedThreadID,
                                  expectedReviewTitle: expectedReviewTitle)
    }

    /// Requires a local review capability and the exact displayed review; possession
    /// does not by itself prove a human reviewed it.
    public func confirmAndExecute(
        token: String, confirmed: Bool, expectedActionID: String, expectedParameters: [String: String],
        expectedThreadID: String, expectedReviewTitle: String, principal: ACTALocalPrincipal
    ) async throws -> ACTAActionResult {
        guard authority != nil, permits(principal, actionID: expectedActionID, review: true) else {
            return authorizationDenied(expectedActionID)
        }
        return try await confirmReviewed(token: token, confirmed: confirmed, expectedActionID: expectedActionID,
                                         expectedParameters: expectedParameters, expectedThreadID: expectedThreadID,
                                         expectedReviewTitle: expectedReviewTitle)
    }

    private func confirmReviewed(
        token: String, confirmed: Bool, expectedActionID: String,
        expectedParameters: [String: String], expectedThreadID: String, expectedReviewTitle: String?
    ) async throws -> ACTAActionResult {
        cleanupExpiredConfirmations()
        guard let pending = pendingConfirmations[token] else {
            return ACTAActionResult.failed(actionID: "unknown", error: "Confirmation token '\(token)' is invalid or expired.")
        }
        guard approvalMatchesReview(pending, confirmed: confirmed, reviewTitle: expectedReviewTitle),
              matches(pending, actionID: expectedActionID, parameters: expectedParameters,
                      threadID: expectedThreadID, reviewTitle: expectedReviewTitle) else {
            return .failed(actionID: pending.actionID, error: "CONFIRMATION_MISMATCH: Reviewed action does not match the pending confirmation.")
        }
        pendingConfirmations.removeValue(forKey: token)
        return try await executePending(pending, confirmed: confirmed)
    }

    private func approvalMatchesReview(_ pending: PendingConfirmation, confirmed: Bool, reviewTitle: String?) -> Bool {
        guard confirmed, pending.preparedExecution != nil else { return true }
        guard let reviewTitle else { return false }
        return reviewTitle.utf8.elementsEqual(pending.reviewTitle.utf8)
    }

    public func confirmationMatches(token: String, actionID: String, parameters: [String: String], threadID: String) -> Bool {
        guard authority == nil else { return false }
        return confirmationMatchesReviewed(token: token, actionID: actionID, parameters: parameters,
                                    threadID: threadID, reviewTitle: nil)
    }

    public func confirmationMatches(
        token: String, actionID: String, parameters: [String: String], threadID: String, expectedReviewTitle: String
    ) -> Bool {
        guard authority == nil else { return false }
        return confirmationMatchesReviewed(token: token, actionID: actionID, parameters: parameters,
                                    threadID: threadID, reviewTitle: expectedReviewTitle)
    }

    private func confirmationMatchesReviewed(
        token: String, actionID: String, parameters: [String: String], threadID: String, reviewTitle: String?
    ) -> Bool {
        cleanupExpiredConfirmations()
        guard let pending = pendingConfirmations[token] else { return false }
        return matches(pending, actionID: actionID, parameters: parameters, threadID: threadID, reviewTitle: reviewTitle)
    }

    private func matches(_ pending: PendingConfirmation, actionID: String,
                         parameters: [String: String], threadID: String, reviewTitle: String?) -> Bool {
        guard pending.actionID == actionID, pending.context.threadID == threadID,
              reviewTitle.map({ $0.utf8.elementsEqual(pending.reviewTitle.utf8) }) ?? true,
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
            expectedGeneration: pending.actionGeneration,
            preparedExecution: pending.preparedExecution,
            principal: pending.requester
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
