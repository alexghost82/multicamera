import Foundation

/// In-process capabilities owned by trusted host code, not serializable credentials.
public final class ACTABrokerOperator: Sendable {
    fileprivate init() {}
}

public final class ACTABrokerSession: Sendable {
    fileprivate init() {}
}

public final class ACTABrokerReviewHandle: Sendable {
    fileprivate init() {}
}

public enum ACTABrokerLocalInput: Sendable {
    case chat, voice
}

/// The trusted UI must display every parameter and the complete title before approval.
public struct ACTABrokerReview: Sendable {
    public let handle: ACTABrokerReviewHandle
    public let actionID: String
    public let threadID: String
    public let parameters: [String: String]
    public let title: String
}

public struct ACTABrokerAuditEvent: Sendable {
    public enum Phase: Sendable {
        case request, validated, review, result
    }
    public let phase: Phase
    public let actionID: String
    public let threadID: String
    public let approved: Bool?
    public let outcome: String?
}

/// A separate opt-in broker. The host must keep its operator and session capabilities
/// out of model/tool data and must provide durable auditing and an exact-review UI.
/// This is not a process boundary and does not protect calls made directly to domain services.
public actor ACTALocalActionBroker {
    public typealias Audit = @Sendable (ACTABrokerAuditEvent) throws -> Void

    private struct SessionState {
        let session: ACTABrokerSession
        let requester: ACTALocalPrincipal
        let reviewer: ACTALocalPrincipal
        let threadID: String
        let input: ACTABrokerLocalInput
        let actionIDs: Set<String>
    }
    private struct Pending {
        let session: ACTABrokerSession
        let review: ACTABrokerReview
        let token: String
        let expiresAt: Date
    }
    private final class ValidatedArguments: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String]?
        func set(_ arguments: [String: String]) { lock.lock(); defer { lock.unlock() }; value = arguments }
        func get() -> [String: String]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let registry: ACTAActionRegistry
    private let authority: ACTALocalAuthority
    private let operatorKey: ACTABrokerOperator
    private let allowedActionIDs: Set<String>
    private let audit: Audit
    private var sessions: [ObjectIdentifier: SessionState] = [:]
    private var pending: [ObjectIdentifier: Pending] = [:]

    private init(
        registry: ACTAActionRegistry, authority: ACTALocalAuthority, operatorKey: ACTABrokerOperator,
        allowedActionIDs: Set<String>, audit: @escaping Audit
    ) {
        self.registry = registry
        self.authority = authority
        self.operatorKey = operatorKey
        self.allowedActionIDs = allowedActionIDs
        self.audit = audit
    }

    /// Only explicitly registered, scoped actions can be used. No scheduler capability is issued.
    public nonisolated static func make(
        actions: [any ACTAActionProtocol], allowedActionIDs: Set<String>, audit: @escaping Audit
    ) async -> (broker: ACTALocalActionBroker, operatorKey: ACTABrokerOperator)? {
        let ids = actions.map(\.id)
        guard !allowedActionIDs.isEmpty, Set(ids).count == ids.count,
              allowedActionIDs.isSubset(of: Set(ids)) else { return nil }
        let (registry, authority) = ACTAActionRegistry.makeAuthorized(forceMutationConfirmation: true)
        for action in actions {
            guard await registry.register(action, authority: authority) else { return nil }
        }
        let operatorKey = ACTABrokerOperator()
        return (ACTALocalActionBroker(registry: registry, authority: authority, operatorKey: operatorKey,
                                      allowedActionIDs: allowedActionIDs, audit: audit), operatorKey)
    }

    public func openSession(
        operatorKey: ACTABrokerOperator, input: ACTABrokerLocalInput, threadID: String, actionIDs: Set<String>
    ) async -> ACTABrokerSession? {
        guard self.operatorKey === operatorKey, !threadID.isEmpty, !actionIDs.isEmpty,
              actionIDs.isSubset(of: allowedActionIDs) else { return nil }
        guard let requester = await registry.issuePrincipal(authority: authority, actionIDs: actionIDs,
                                                            canRequest: true, canReview: false),
              let reviewer = await registry.issuePrincipal(authority: authority, actionIDs: actionIDs,
                                                           canRequest: false, canReview: true) else { return nil }
        let session = ACTABrokerSession()
        sessions[ObjectIdentifier(session)] = SessionState(session: session, requester: requester,
                                                           reviewer: reviewer, threadID: threadID, input: input,
                                                           actionIDs: actionIDs)
        return session
    }

    public func closeSession(_ session: ACTABrokerSession, operatorKey: ACTABrokerOperator) async {
        guard self.operatorKey === operatorKey,
              let state = sessions.removeValue(forKey: ObjectIdentifier(session)), state.session === session else { return }
        pending = pending.filter { $0.value.session !== session }
        await registry.revoke(state.requester, authority: authority)
        await registry.revoke(state.reviewer, authority: authority)
    }

    public func catalogue(session: ACTABrokerSession) async -> [ACTAActionDescriptor] {
        guard let state = sessionState(session) else { return [] }
        let result = await registry.authorizedCatalog(principal: state.requester)
        return sessionState(session) == nil ? [] : result
    }

    /// Only the trusted host supplies the session. Model arguments contain no capability.
    /// Mutation results returned here never expose review tokens, titles, or parameters.
    public func request(
        session: ACTABrokerSession, actionID: String, argumentsJSON: String
    ) async -> ACTAActionResult {
        cleanupExpiredReviews()
        guard let state = sessionState(session) else {
            do {
                try audit(ACTABrokerAuditEvent(phase: .request, actionID: "[unrecognized]",
                                                threadID: "", approved: nil, outcome: nil))
            } catch { return auditFailed(actionID) }
            return recordResult(denied("[unrecognized]"), threadID: "")
        }
        let startedAt = Date()
        let auditedActionID = state.actionIDs.contains(actionID) ? actionID : "[unrecognized]"
        do {
            try audit(ACTABrokerAuditEvent(phase: .request, actionID: auditedActionID, threadID: state.threadID,
                                            approved: nil, outcome: nil))
        } catch { return auditFailed(actionID) }
        guard state.actionIDs.contains(actionID) else {
            return recordResult(denied(auditedActionID), threadID: state.threadID)
        }
        let arguments = ValidatedArguments()
        let audit = self.audit
        let result: ACTAActionResult
        do {
            result = try await registry.executeJSON(actionID: actionID, argumentsJSON: argumentsJSON,
                context: ACTAActionContext(threadID: state.threadID,
                                           initiator: state.input == .chat ? "text_chat" : "voice_asr"),
                principal: state.requester, beforeExecution: { parameters in
                    guard try JSONEncoder().encode(parameters).count <= ACTAActionRegistry.maxPreparedReviewSummaryUTF8Bytes else {
                        throw BrokerError.reviewTooLarge
                    }
                    guard Self.parametersAreDisplayable(parameters) else { throw BrokerError.undisplayable }
                    do {
                        try audit(ACTABrokerAuditEvent(phase: .validated, actionID: actionID,
                                                       threadID: state.threadID, approved: nil, outcome: nil))
                    } catch { throw BrokerError.auditFailed }
                    arguments.set(parameters)
                })
        } catch is CancellationError {
            return recordResult(.failed(actionID: actionID, error: "ACTION_CANCELLED: Request did not complete."),
                                threadID: state.threadID)
        } catch {
            return recordResult(.failed(actionID: actionID, error: "ACTION_FAILED: Request did not complete."),
                                threadID: state.threadID)
        }
        guard sessionState(session) != nil else { return recordResult(denied(actionID), threadID: state.threadID) }
        guard result.requiresOperatorConfirmation else {
            return recordResult(Self.safeModelResult(result), threadID: state.threadID)
        }
        guard let token = result.confirmationToken, let parameters = arguments.get() else {
            return recordResult(.failed(actionID: actionID, error: "REVIEW_UNAVAILABLE: No validated review is available."),
                                threadID: state.threadID)
        }
        guard result.summary.utf8.count <= 16 * 1024 else {
            return recordResult(.failed(actionID: actionID, error: "REVIEW_UNDISPLAYABLE: Review is too large."),
                                threadID: state.threadID)
        }
        let expiresAt = startedAt.addingTimeInterval(300)
        guard expiresAt > Date() else {
            return recordResult(.failed(actionID: actionID, error: "REVIEW_EXPIRED: Prepare the request again."),
                                threadID: state.threadID)
        }
        let handle = ACTABrokerReviewHandle()
        let review = ACTABrokerReview(handle: handle, actionID: actionID, threadID: state.threadID,
                                      parameters: parameters, title: result.summary)
        let response = ACTAActionResult(actionID: actionID, success: false, summary: "Operator review required.",
                                        outputJSON: #"{"status":"confirmation_required"}"#,
                                        verified: false, requiresOperatorConfirmation: true)
        let recorded = recordResult(response, threadID: state.threadID)
        guard recorded.requiresOperatorConfirmation else { return recorded }
        pending[ObjectIdentifier(handle)] = Pending(session: session, review: review, token: token, expiresAt: expiresAt)
        return recorded
    }

    /// This API is for trusted operator UI only, never for model/tool responses.
    public func reviews(operatorKey: ACTABrokerOperator, session: ACTABrokerSession) -> [ACTABrokerReview] {
        cleanupExpiredReviews()
        guard self.operatorKey === operatorKey, sessionState(session) != nil else { return [] }
        return pending.values.filter { $0.session === session }.map(\.review)
    }

    public func resolve(
        operatorKey: ACTABrokerOperator, session: ACTABrokerSession,
        reviewed: ACTABrokerReview, approved: Bool
    ) async -> ACTAActionResult {
        cleanupExpiredReviews()
        guard self.operatorKey === operatorKey, let state = sessionState(session),
              let item = pending[ObjectIdentifier(reviewed.handle)], item.session === session,
              item.review.handle === reviewed.handle,
              Self.sameReview(item.review, reviewed) else {
            return recordResult(denied("[unrecognized]"), threadID: "")
        }
        do {
            try audit(ACTABrokerAuditEvent(phase: .review, actionID: reviewed.actionID,
                                            threadID: state.threadID, approved: approved, outcome: nil))
        } catch { return auditFailed(reviewed.actionID) }
        pending.removeValue(forKey: ObjectIdentifier(reviewed.handle))
        do {
            let result = try await registry.confirmAndExecute(token: item.token, confirmed: approved,
                expectedActionID: item.review.actionID, expectedParameters: item.review.parameters,
                expectedThreadID: item.review.threadID, expectedReviewTitle: item.review.title,
                principal: state.reviewer)
            return recordResult(result, threadID: state.threadID)
        } catch is CancellationError {
            return recordResult(.failed(actionID: reviewed.actionID, error: "ACTION_CANCELLED: Review did not complete."),
                                threadID: state.threadID)
        } catch {
            return recordResult(.failed(actionID: reviewed.actionID, error: "CONFIRMATION_FAILED: Review did not complete."),
                                threadID: state.threadID)
        }
    }

    private func sessionState(_ session: ACTABrokerSession) -> SessionState? {
        guard let state = sessions[ObjectIdentifier(session)], state.session === session else { return nil }
        return state
    }

    private func denied(_ actionID: String) -> ACTAActionResult {
        .failed(actionID: actionID, error: "AUTHORIZATION_DENIED: Invalid or closed local session.")
    }

    private func auditFailed(_ actionID: String) -> ACTAActionResult {
        .failed(actionID: actionID, error: "AUDIT_FAILED: Action was not executed.")
    }

    private func recordResult(_ result: ACTAActionResult, threadID: String) -> ACTAActionResult {
        do {
            try audit(ACTABrokerAuditEvent(phase: .result, actionID: result.actionID, threadID: threadID,
                                            approved: nil,
                                            outcome: result.requiresOperatorConfirmation ? "confirmation_required"
                                                : result.success ? "success" : "failed"))
            return result
        } catch {
            return .failed(actionID: result.actionID,
                           error: "AUDIT_FAILED: Outcome could not be recorded; action may have executed.")
        }
    }

    private enum BrokerError: LocalizedError {
        case reviewTooLarge, auditFailed, undisplayable
        var errorDescription: String? {
            switch self {
            case .reviewTooLarge: return "REVIEW_TOO_LARGE: Parameters exceed the review limit."
            case .auditFailed: return "AUDIT_FAILED: Action was not executed."
            case .undisplayable: return "REVIEW_UNDISPLAYABLE: Request cannot be safely reviewed."
            }
        }
    }

    private func cleanupExpiredReviews() {
        let now = Date()
        pending = pending.filter { $0.value.expiresAt > now }
    }

    private static func parametersAreDisplayable(_ parameters: [String: String]) -> Bool {
        guard parameters.count <= 64,
              parameters.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 8 * 1024 else { return false }
        return parameters.allSatisfy { key, value in
            let name = key.lowercased()
            return !["password", "secret", "credential", "token", "key", "url"].contains(where: name.contains)
                && !value.contains("://")
        }
    }

    private static func safeModelResult(_ result: ACTAActionResult) -> ACTAActionResult {
        guard !result.success else { return result }
        let prefix = result.error?.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "ACTION_FAILED"
        let allowed = ["INVALID_ARGUMENT", "AUTHORIZATION_DENIED", "AUDIT_FAILED",
                       "REVIEW_UNDISPLAYABLE", "REVIEW_TOO_LARGE", "ACTION_BUSY",
                       "CONFIRMATION_PREPARATION_FAILED", "CONFIRMATION_REVOKED"]
        return .failed(actionID: result.actionID,
                       error: "\(allowed.contains(prefix) ? prefix : "ACTION_FAILED"): Request failed.")
    }

    private static func sameReview(_ left: ACTABrokerReview, _ right: ACTABrokerReview) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        guard same(left.actionID, right.actionID), same(left.threadID, right.threadID),
              same(left.title, right.title), left.parameters.count == right.parameters.count else { return false }
        let lhs = left.parameters.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        let rhs = right.parameters.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        return zip(lhs, rhs).allSatisfy { pair in
            same(pair.0.key, pair.1.key) && same(pair.0.value, pair.1.value)
        }
    }
}
