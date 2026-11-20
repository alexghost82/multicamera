import CameraCore
import Foundation

enum ACTACameraFavorites {
    static let key = "ACTA.favoriteCameraIDs"

    static func decode(_ value: String) -> Set<UUID> {
        Set(value.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    static func encode(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func checkedToggle(_ cameraID: UUID, storedValue: Any?) throws -> String {
        guard let storedValue else { return encode([cameraID]) }
        guard let value = storedValue as? String else { throw InvalidPreference() }
        if value.isEmpty { return encode([cameraID]) }
        var ids = Set<UUID>()
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let id = UUID(uuidString: String(component)), ids.insert(id).inserted else {
                throw InvalidPreference()
            }
        }
        if ids.contains(cameraID) { ids.remove(cameraID) } else { ids.insert(cameraID) }
        return encode(ids)
    }

    struct InvalidPreference: Error {}
}

@MainActor
protocol ACTACameraFavoritesStorage: Sendable {
    func read() throws -> String
    func write(_ value: String) throws
}

@MainActor
struct ACTAUserDefaultsCameraFavoritesStorage: ACTACameraFavoritesStorage {
    func read() -> String { UserDefaults.standard.string(forKey: ACTACameraFavorites.key) ?? "" }
    func write(_ value: String) { UserDefaults.standard.set(value, forKey: ACTACameraFavorites.key) }
}

struct ACTACameraSetFavoriteAction: ACTAActionProtocol {
    let id = "camera.set_favorite"
    let title = "Set Camera Favorite"
    let description = "Unavailable until camera identity and favorite preference writers are coordinated."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or unique name", isRequired: true),
        ACTAActionParameterSchema(name: "favorite", type: "boolean", description: "True to add, false to remove", isRequired: true)
    ]

    let storage: any ACTACameraFavoritesStorage
    let resolve: @MainActor @Sendable (String) -> UUID?

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "UNAVAILABLE: Favorite updates require coordinated camera and preference writers.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        false
    }
}
