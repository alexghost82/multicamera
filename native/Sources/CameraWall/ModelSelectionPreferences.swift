import Foundation
import CameraCore

struct ModelSelectionPreferences: Codable, Equatable, Sendable {
    var enabled: Set<LocalModelService> = Set(LocalModelService.allCases)
    /// An empty path selects the bundled model. Formats must match the existing model contract.
    var paths: [LocalModelService: String] = [:]

    func validate() throws {
        for (service, path) in paths where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let validExtension = service == .yolo ? url.pathExtension == "mlmodelc"
                : service == .pose ? ["mlmodelc", "mlpackage", "mlmodel"].contains(url.pathExtension)
                : service == .qwen ? true : url.pathExtension == "onnx"
            guard path.hasPrefix("/"), validExtension, FileManager.default.fileExists(atPath: path) else {
                throw ConfigurationError.invalid("Select an existing model with the supported format.")
            }
        }
    }

    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Synchronous inference queues read a locked snapshot; SwiftUI owns and persists the editable value.
enum ModelSelectionRegistry {
    private static let lock = NSLock()
    private static var preferences = ModelSelectionPreferences()
    private static var generation = UUID()
    static func update(_ value: ModelSelectionPreferences) {
        lock.lock(); defer { lock.unlock() }
        preferences = value
        generation = UUID()
    }
    static func snapshot() -> (preferences: ModelSelectionPreferences, generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        return (preferences, generation)
    }
    static func isEnabled(_ service: LocalModelService) -> Bool { lock.lock(); defer { lock.unlock() }; return preferences.enabled.contains(service) }
    static func path(_ service: LocalModelService) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let path = preferences.paths[service], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    static func require(_ service: LocalModelService) throws {
        guard isEnabled(service) else { throw ConfigurationError.invalid("This model is disabled in Settings.") }
    }
}
