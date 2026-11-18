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

    static func setting(_ favorite: Bool, for cameraID: UUID, in value: String) -> String {
        var ids = decode(value)
        if favorite { ids.insert(cameraID) } else { ids.remove(cameraID) }
        return encode(ids)
    }

    static func toggling(_ cameraID: UUID, in value: String) -> String {
        setting(!decode(value).contains(cameraID), for: cameraID, in: value)
    }
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
    let description = "Set a configured camera's favorite flag in the same preference used by the camera view. Readback verifies the current preference, not durable disk synchronization."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "camera_id", type: "string", description: "Camera UUID or unique name", isRequired: true),
        ACTAActionParameterSchema(name: "favorite", type: "boolean", description: "True to add, false to remove", isRequired: true)
    ]

    let storage: any ACTACameraFavoritesStorage
    let resolve: @MainActor @Sendable (String) -> UUID?

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            guard let value = parameters["camera_id"], let cameraID = resolve(value) else {
                return .failed(actionID: id, error: "Camera does not exist or its name is ambiguous; specify a UUID.")
            }
            guard let raw = parameters["favorite"], raw == "true" || raw == "false" else {
                return .failed(actionID: id, error: "INVALID_ARGUMENT: Invalid favorite.")
            }
            let favorite = raw == "true"
            let expected = ACTACameraFavorites.setting(favorite, for: cameraID, in: try storage.read())
            try storage.write(expected)
            guard try storage.read() == expected else {
                return .failed(actionID: id, error: "Favorite preference readback failed.")
            }
            let data = try JSONSerialization.data(withJSONObject: ["camera_id": cameraID.uuidString, "favorite": favorite])
            return ACTAActionResult(actionID: id, success: true,
                summary: "Favorite preference updated and read back; disk synchronization is not verified.",
                outputJSON: String(decoding: data, as: UTF8.self))
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try await MainActor.run {
            guard let value = parameters["camera_id"], let cameraID = resolve(value),
                  let raw = parameters["favorite"], raw == "true" || raw == "false" else { return false }
            return ACTACameraFavorites.decode(try storage.read()).contains(cameraID) == (raw == "true")
        }
    }
}
