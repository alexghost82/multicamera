import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class FavoriteFake: ACTACameraFavoritesStorage {
    var value = ""
    var writes = 0
    var discardWrites = false
    func read() -> String { value }
    func write(_ value: String) {
        writes += 1
        if !discardWrites { self.value = value }
    }
}

@MainActor
private final class FavoriteFileFixture: ACTACameraFavoritesStorage {
    let url: URL
    init(url: URL) { self.url = url }
    func read() throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func write(_ value: String) throws { try value.write(to: url, atomically: true, encoding: .utf8) }
}

@MainActor
final class ACTACameraFavoriteActionTests: XCTestCase {
    private let camera = UUID()
    private let other = UUID()

    private func action(_ store: any ACTACameraFavoritesStorage) -> ACTACameraSetFavoriteAction {
        let camera = camera
        return ACTACameraSetFavoriteAction(storage: store, resolve: { value in
            value == camera.uuidString || value == "Entrance" ? camera : nil
        })
    }

    func testSharedFormatAndFileBackedRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(".favorite-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FavoriteFileFixture(url: url)
        try store.write("\(other.uuidString),invalid,\(other.uuidString)")
        let registry = ACTAActionRegistry()
        await registry.register(action(store))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__camera__set_favorite" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), ["camera_id", "favorite"])

        let added = try await registry.executeJSON(actionID: "camera.set_favorite",
            argumentsJSON: "{\"camera_id\":\"Entrance\",\"favorite\":true}")
        XCTAssertTrue(added.success, added.summary)
        XCTAssertTrue(added.verified)
        XCTAssertEqual(ACTACameraFavorites.decode(try store.read()), [camera, other])
        XCTAssertEqual(try store.read(), ACTACameraFavorites.encode([camera, other]))
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(added.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(output["camera_id"] as? String, camera.uuidString)
        XCTAssertEqual(output["favorite"] as? Bool, true)

        try store.write(ACTACameraFavorites.toggling(camera, in: store.read()))
        XCTAssertEqual(ACTACameraFavorites.decode(try store.read()), [other])
        try store.write(ACTACameraFavorites.toggling(camera, in: store.read()))
        let removed = try await registry.execute(actionID: "camera.set_favorite",
            parameters: ["camera_id": camera.uuidString, "favorite": "false"])
        XCTAssertTrue(removed.success, removed.summary)
        XCTAssertEqual(ACTACameraFavorites.decode(try store.read()), [other])
    }

    func testInvalidRequestsAndDiscardedWriteNeverReportSuccess() async throws {
        let store = FavoriteFake()
        let registry = ACTAActionRegistry()
        await registry.register(action(store))
        for json in [
            "{\"camera_id\":\"missing\",\"favorite\":true}",
            "{\"camera_id\":\"Entrance\",\"favorite\":\"true\"}",
            "{\"camera_id\":\"Entrance\"}",
            "{\"camera_id\":\"Entrance\",\"favorite\":true,\"extra\":1}"
        ] {
            let result = try await registry.executeJSON(actionID: "camera.set_favorite", argumentsJSON: json)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.verified)
        }
        XCTAssertEqual(store.writes, 0)
        store.discardWrites = true
        let result = try await registry.execute(actionID: "camera.set_favorite",
            parameters: ["camera_id": "Entrance", "favorite": "true"])
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(store.value, "")
        store.value = ACTACameraFavorites.encode([camera, other])
        let failedRemoval = try await registry.execute(actionID: "camera.set_favorite",
            parameters: ["camera_id": "Entrance", "favorite": "false"])
        XCTAssertFalse(failedRemoval.success)
        XCTAssertEqual(ACTACameraFavorites.decode(store.read()), [camera, other])
    }

    func testReadAfterWriteVerificationDetectsSubsequentChange() async throws {
        let store = FavoriteFake()
        let action = action(store)
        let result = try await action.execute(parameters: ["camera_id": "Entrance", "favorite": "true"],
                                              context: ACTAActionContext())
        XCTAssertTrue(result.success)
        store.value = ""
        let verified = try await action.verify(parameters: ["camera_id": "Entrance", "favorite": "true"],
                                               context: ACTAActionContext())
        XCTAssertFalse(verified)
    }
}
