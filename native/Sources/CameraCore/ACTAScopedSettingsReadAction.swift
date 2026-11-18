import Foundation

/// A provider must never substitute defaults for an absent or unreadable configuration.
public protocol ACTAExistingSystemSettingsReadProvider: Sendable {
    func loadExistingConfiguration() async throws -> WallConfiguration
}

/// Opt-in adapter to the existing validated configuration store; no default path is supplied.
public struct ACTAConfigurationStoreSettingsReadProvider: ACTAExistingSystemSettingsReadProvider {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func loadExistingConfiguration() throws -> WallConfiguration {
        try ConfigurationStore.load(from: url)
    }
}

/// Intended for explicit registration in an audited, scoped broker, not the legacy registry.
public struct ACTAScopedSettingsReadAction: ACTAActionProtocol {
    public let id = "settings.get_section"
    public let title = "Get Safe Settings Section"
    public let description = "Read only grid columns and stale timeout from general or system settings; no endpoints, paths, permissions, or health status."
    public let classification = ACTAActionClassification.inspect
    public let parameters = [
        ACTAActionParameterSchema(name: "section", type: "string",
                                  description: "general or system", isRequired: true,
                                  allowedValues: ["general", "system"])
    ]

    private let provider: (any ACTAExistingSystemSettingsReadProvider)?

    public init(provider: (any ACTAExistingSystemSettingsReadProvider)? = nil) {
        self.provider = provider
    }

    private struct Payload: Encodable {
        let columns: Int
        let staleAfterMilliseconds: Int
    }

    private struct InvalidArguments: LocalizedError {
        var errorDescription: String? { "INVALID_ARGUMENT: Expected general or system section." }
    }

    public func validate(parameters: [String: String]) throws {
        guard parameters.count == 1, let section = parameters["section"],
              section == "general" || section == "system" else {
            throw InvalidArguments()
        }
    }

    public func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        do {
            try validate(parameters: parameters)
        } catch {
            return .failed(actionID: id, error: "INVALID_ARGUMENT: Expected general or system section.")
        }
        guard let provider else {
            return .failed(actionID: id, error: "UNAVAILABLE: Settings service is not connected.")
        }
        do {
            try Task.checkCancellation()
            let config = try await provider.loadExistingConfiguration()
            try Task.checkCancellation()
            guard (1...16).contains(config.columns), (200...30000).contains(config.staleAfterMilliseconds) else {
                return .failed(actionID: id, error: "STORAGE_ERROR: Settings read failed.")
            }
            let payload = Payload(columns: config.columns, staleAfterMilliseconds: config.staleAfterMilliseconds)
            let output = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            return ACTAActionResult(actionID: id, success: true, summary: "Settings retrieved.",
                                    outputJSON: output)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(actionID: id, error: "STORAGE_ERROR: Settings read failed.")
        }
    }
}
