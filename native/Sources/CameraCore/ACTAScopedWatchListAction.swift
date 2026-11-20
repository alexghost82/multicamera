import Foundation

/// Only active rules from one consistent snapshot. Providers must throw if the
/// service is disabled, absent, or its state cannot be read; never invent an empty list.
public protocol ACTAWatchListReadProvider: Sendable {
    func activeWatchMetadata() async throws -> [ACTAWatchMetadata]
}

public enum ACTAWatchListReadError: Error, Sendable {
    case unavailable
}

/// Deliberately excludes rule and camera identifiers, text, dates, and evidence.
public struct ACTAWatchMetadata: Encodable, Sendable {
    public enum CameraScope: String, Encodable, Sendable {
        case all, selected
    }
    public enum Expiration: String, Encodable, Sendable {
        case indefinite, timed
    }

    public let cameraScope: CameraScope
    public let expiration: Expiration

    public init(cameraScope: CameraScope, expiration: Expiration) {
        self.cameraScope = cameraScope
        self.expiration = expiration
    }
}

/// Opt-in only: the host must register and authorize this action in a local broker.
public struct ACTAScopedWatchListAction: ACTAActionProtocol {
    public let id = "watch.list"
    public let title = "List Watch Rule Metadata"
    public let description = "List active rules by camera scope and expiration type, without identifiers or conditions."
    public let classification = ACTAActionClassification.inspect
    public let parameters: [ACTAActionParameterSchema] = []
    private let provider: (any ACTAWatchListReadProvider)?

    public init(provider: (any ACTAWatchListReadProvider)? = nil) {
        self.provider = provider
    }

    private struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: No parameters are accepted." }
    }

    private struct Output: Encodable {
        let watch_rules: [ACTAWatchMetadata]
    }

    public func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw InvalidArguments() }
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard parameters.isEmpty else {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: No parameters are accepted.")
        }
        guard let provider else {
            return .failed(actionID: id, error: "UNAVAILABLE: Watch service is not connected.")
        }
        do {
            try Task.checkCancellation()
            let rules = try await provider.activeWatchMetadata()
            try Task.checkCancellation()
            guard rules.count <= 24 else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Watch read failed.")
            }
            let sorted = rules.sorted {
                if $0.cameraScope.rawValue != $1.cameraScope.rawValue {
                    return $0.cameraScope.rawValue < $1.cameraScope.rawValue
                }
                return $0.expiration.rawValue < $1.expiration.rawValue
            }
            let data = try JSONEncoder().encode(Output(watch_rules: sorted))
            return ACTAActionResult(actionID: id, success: true, summary: "Watch metadata retrieved.",
                                    outputJSON: String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch ACTAWatchListReadError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: Watch service is not connected.")
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Watch read failed.")
        }
    }
}
