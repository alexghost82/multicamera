import Foundation

/// Only these three decisions are accepted from a secondary model. Transport and
/// parsing failures are handled as unavailable, never as implicit confirmation.
public struct IncidentVerification: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case confirmed, rejected, inconclusive
    }

    public let decision: Decision
    public let summary: String

    public var status: SecondaryVerificationStatus {
        switch decision {
        case .confirmed: return .confirmed
        case .rejected: return .rejected
        case .inconclusive: return .inconclusive
        }
    }

    public static func parse(_ response: String) throws -> Self {
        guard let data = response.data(using: .utf8), data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["decision", "summary"]) else {
            throw VerificationError.invalidResponse
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 2000 else {
            throw VerificationError.invalidResponse
        }
        return Self(decision: result.decision, summary: summary)
    }

    public enum VerificationError: Error { case invalidResponse }
}
