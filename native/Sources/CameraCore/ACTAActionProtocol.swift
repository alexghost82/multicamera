import Foundation

// MARK: - 1. Action Classification & Safety Policies

public enum ACTAActionClassification: String, Codable, Sendable {
    /// Read-only inspection; does not mutate state or write to disk. Auto-approved.
    case inspect
    /// Reversible mutation (e.g. changing column count, adjusting sensitivity threshold, acknowledging an alert). Auto-approved.
    case reversible
    /// Affects active streaming or system services (reconnecting streams, switching models, restarting relays). Notice provided.
    case serviceAffecting
    /// Irreversible data mutation or deletion (deleting a camera, purging incident evidence, merging/splitting identities).
    /// Requires explicit two-phase operator confirmation before execution.
    case destructive
}

// MARK: - 2. Action Parameter Schema

public struct ACTAActionParameterSchema: Codable, Sendable, Equatable {
    public let name: String
    public let type: String // "string", "number", "integer", "boolean", "array", "object"
    public let description: String
    public let isRequired: Bool
    public let allowedValues: [String]?

    public init(
        name: String,
        type: String,
        description: String,
        isRequired: Bool = false,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedValues = allowedValues
    }
}

// MARK: - 3. Action Context & Result

public struct ACTAActionContext: Sendable {
    public let threadID: String
    public let initiator: String // "text_chat", "voice_asr", "ui_direct", "mission_schedule"
    public let now: Date
    public let trackingStore: (any Sendable)?
    public let isConfirmed: Bool

    public init(
        threadID: String = "default",
        initiator: String = "text_chat",
        now: Date = Date(),
        trackingStore: (any Sendable)? = nil,
        isConfirmed: Bool = false
    ) {
        self.threadID = threadID
        self.initiator = initiator
        self.now = now
        self.trackingStore = trackingStore
        self.isConfirmed = isConfirmed
    }
}

public struct ACTAActionResult: Codable, Sendable, Equatable {
    public let actionID: String
    public let success: Bool
    public let summary: String
    public let outputJSON: String
    public let verified: Bool
    public let requiresOperatorConfirmation: Bool
    public let confirmationToken: String?
    public let error: String?

    public init(
        actionID: String,
        success: Bool,
        summary: String,
        outputJSON: String = "{}",
        verified: Bool = true,
        requiresOperatorConfirmation: Bool = false,
        confirmationToken: String? = nil,
        error: String? = nil
    ) {
        self.actionID = actionID
        self.success = success
        self.summary = summary
        self.outputJSON = outputJSON
        self.verified = verified
        self.requiresOperatorConfirmation = requiresOperatorConfirmation
        self.confirmationToken = confirmationToken
        self.error = error
    }

    public static func failed(actionID: String, error: String) -> ACTAActionResult {
        ACTAActionResult(
            actionID: actionID,
            success: false,
            summary: "Execution failed: \(error)",
            outputJSON: "{\"error\": \"\(error)\"}",
            verified: false,
            error: error
        )
    }

    public static func needsConfirmation(actionID: String, summary: String, token: String) -> ACTAActionResult {
        ACTAActionResult(
            actionID: actionID,
            success: false,
            summary: summary,
            outputJSON: "{\"status\": \"confirmation_required\", \"confirmation_token\": \"\(token)\"}",
            verified: false,
            requiresOperatorConfirmation: true,
            confirmationToken: token
        )
    }
}

// MARK: - 4. Action Protocol

public protocol ACTAActionProtocol: Sendable {
    var id: String { get }
    var title: String { get }
    var description: String { get }
    var classification: ACTAActionClassification { get }
    var parameters: [ACTAActionParameterSchema] { get }

    func execute(
        parameters: [String: String],
        context: ACTAActionContext
    ) async throws -> ACTAActionResult

    func verify(
        parameters: [String: String],
        context: ACTAActionContext
    ) async throws -> Bool
}

public extension ACTAActionProtocol {
    func verify(
        parameters: [String: String],
        context: ACTAActionContext
    ) async throws -> Bool {
        // Default verification for read-only or self-verifying actions
        return true
    }
}
