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
    /// Changes privacy or security policy; requires explicit operator approval.
    case securitySensitive
}

// MARK: - 2. Action Parameter Schema

public struct ACTAActionParameterSchema: Codable, Sendable, Equatable {
    public let name: String
    public let type: String // "string", "number", "integer", "boolean", "array", "object"
    public let description: String
    public let isRequired: Bool
    public let allowedValues: [String]?
    public let allowsEmpty: Bool

    public init(
        name: String,
        type: String,
        description: String,
        isRequired: Bool = false,
        allowedValues: [String]? = nil,
        allowsEmpty: Bool = false
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedValues = allowedValues
        self.allowsEmpty = allowsEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, description, isRequired, allowedValues, allowsEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        description = try container.decode(String.self, forKey: .description)
        isRequired = try container.decode(Bool.self, forKey: .isRequired)
        allowedValues = try container.decodeIfPresent([String].self, forKey: .allowedValues)
        allowsEmpty = try container.decodeIfPresent(Bool.self, forKey: .allowsEmpty) ?? false
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
            outputJSON: String(decoding: (try? JSONEncoder().encode(["error": error])) ?? Data("{}".utf8), as: UTF8.self),
            verified: false,
            error: error
        )
    }

    public static func unsupported(actionID: String) -> ACTAActionResult {
        failed(actionID: actionID, error: "UNSUPPORTED: Domain service is not connected for \(actionID).")
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
    func requiresConfirmation(parameters: [String: String]) -> Bool
    func validate(parameters: [String: String]) throws

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
    func validate(parameters: [String: String]) throws {}

    func requiresConfirmation(parameters: [String: String]) -> Bool {
        [.destructive, .securitySensitive].contains(classification)
    }

    func verify(
        parameters: [String: String],
        context: ACTAActionContext
    ) async throws -> Bool {
        // Mutations must explicitly implement verification; absence is never evidence of success.
        return classification == .inspect
    }
}
