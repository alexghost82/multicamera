import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class FavoriteFake: ACTACameraFavoritesStorage {
    var value = ""
    var writes = 0
    var reads = 0
    func read() -> String { reads += 1; return value }
    func write(_ value: String) {
        writes += 1
        self.value = value
    }
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

    func testLegacyActionFailsClosedEvenWhenManuallyRegistered() async throws {
        let store = FavoriteFake()
        store.value = ACTACameraFavorites.encode([camera, other])
        let registry = ACTAActionRegistry()
        await registry.register(action(store))
        let before = store.value
        for json in [#"{"camera_id":"Entrance","favorite":true}"#,
                     #"{"camera_id":"Entrance","favorite":false}"#] {
            let result = try await registry.executeJSON(actionID: "camera.set_favorite", argumentsJSON: json)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.verified)
        }
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.value, before)
        let verified = try await action(store).verify(parameters: ["camera_id": "Entrance", "favorite": "true"],
                                                       context: ACTAActionContext())
        XCTAssertFalse(verified)
        XCTAssertEqual(store.reads, 0)
    }

    func testBrokerApprovalCannotEnableLegacyFavoriteWrites() async throws {
        let store = FavoriteFake()
        store.value = ACTACameraFavorites.encode([other])
        let created = await ACTALocalActionBroker.make(
            actions: [action(store)], allowedActionIDs: ["camera.set_favorite"], audit: { _ in })
        let host = try XCTUnwrap(created)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "favorite-test", actionIDs: ["camera.set_favorite"])
        let session = try XCTUnwrap(opened)
        let pending = await host.broker.request(session: session, actionID: "camera.set_favorite",
            argumentsJSON: #"{"camera_id":"Entrance","favorite":true}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.verified)
        XCTAssertEqual(store.value, ACTACameraFavorites.encode([other]))
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(store.writes, 0)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testGUIFavoriteFormatStillTogglesCameraIDs() throws {
        let initial = ACTACameraFavorites.encode([other])
        let added = try ACTACameraFavorites.checkedToggle(camera, storedValue: initial)
        XCTAssertEqual(ACTACameraFavorites.decode(added), [camera, other])
        XCTAssertEqual(try ACTACameraFavorites.checkedToggle(camera, storedValue: added), initial)
    }

    func testCheckedGUITogglePreservesOtherIDsAndAcceptsOlderNoncanonicalOrdering() throws {
        let initial = "\(other.uuidString.lowercased()),\(camera.uuidString.lowercased())"
        let removed = try ACTACameraFavorites.checkedToggle(camera, storedValue: initial)
        XCTAssertEqual(ACTACameraFavorites.decode(removed), [other])
        let added = try ACTACameraFavorites.checkedToggle(camera, storedValue: removed)
        XCTAssertEqual(ACTACameraFavorites.decode(added), [camera, other])
        XCTAssertEqual(try ACTACameraFavorites.checkedToggle(camera, storedValue: nil),
                       ACTACameraFavorites.encode([camera]))
        XCTAssertEqual(try ACTACameraFavorites.checkedToggle(camera, storedValue: ""),
                       ACTACameraFavorites.encode([camera]))
    }

    func testCheckedGUIToggleRejectsDataThatWouldBeLost() {
        let id = other.uuidString
        let invalid: [Any] = [42, ["unexpected"], "\(id),invalid", "\(id),",
                              ",\(id)", "\(id),\(id.lowercased())"]
        for value in invalid {
            XCTAssertThrowsError(try ACTACameraFavorites.checkedToggle(camera, storedValue: value),
                                 "Accepted invalid value: \(value)")
        }
    }
}
