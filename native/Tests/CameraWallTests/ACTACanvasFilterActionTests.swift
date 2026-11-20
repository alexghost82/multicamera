import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class CanvasLocationInventory {
    var groups: Set<String>? = ["Entrance", "Other"]
    var revision = UUID()
}

@MainActor
final class ACTACanvasFilterActionTests: XCTestCase {
    private let inventoryRevision = UUID()

    func testSharedStatePatchAndTypedTransport() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        state.locationFilter = "Entrance"
        state.searchText = "previous"
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Entrance", "Other"] },
                                                           inventoryRevision: { self.inventoryRevision }))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let tool = try XCTUnwrap(tools.first { $0.name == "acta__canvas__set_filter" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tool.parametersSchemaJSON.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["favorites_only"]?["type"] as? String, "boolean")
        XCTAssertEqual(properties["location"]?["type"] as? String, "string")

        let result = try await registry.executeJSON(actionID: "canvas.set_filter",
            argumentsJSON: #"{"search":"","status":"offline","favorites_only":true,"events_only":true}"#)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.cameraScope, .offline)
        XCTAssertTrue(state.favoritesOnly)
        XCTAssertTrue(state.alertsOnly)
        XCTAssertEqual(state.locationFilter, "Entrance")

        state.searchText = "GUI edit"
        state.favoritesOnly = false
        let partial = try await registry.executeJSON(actionID: "canvas.set_filter", argumentsJSON: #"{"status":"live"}"#)
        XCTAssertTrue(partial.success, partial.summary)
        XCTAssertEqual(state.searchText, "GUI edit")
        XCTAssertFalse(state.favoritesOnly)
        XCTAssertTrue(state.alertsOnly)
        XCTAssertEqual(state.cameraScope, .live)
    }

    func testInvalidRequestsNeverMutate() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        await registry.register(ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Entrance"] },
                                                           inventoryRevision: { self.inventoryRevision }))
        for json in ["{}", #"{"status":"unknown"}"#, #"{"favorites_only":"true"}"#,
                     #"{"events_only":1}"#, #"{"location":"Unknown"}"#, #"{"location":"All Locations"}"#,
                     #"{"search":"ok","events_only":null}"#] {
            let result = try await registry.executeJSON(actionID: "canvas.set_filter", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.verified, json)
        }
        let tooLong = try await registry.execute(actionID: "canvas.set_filter",
            parameters: ["search": String(repeating: "a", count: 4097), "status": "live"])
        XCTAssertFalse(tooLong.success)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.cameraScope, .all)
        XCTAssertFalse(state.favoritesOnly)
        XCTAssertFalse(state.alertsOnly)
    }

    func testUnavailableViewsAndVerificationAfterGUIChanges() async throws {
        let bridge = ACTACanvasFilterBridge()
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Entrance"] },
                                               inventoryRevision: { self.inventoryRevision })
        let context = ACTAActionContext()
        let params = ["search": "gate"]
        let missing = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(missing.success)
        let first = ACTACanvasFilterState()
        let second = ACTACanvasFilterState()
        bridge.attach(first)
        bridge.attach(second)
        let ambiguous = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(ambiguous.success)
        XCTAssertEqual(first.searchText, "")
        XCTAssertEqual(second.searchText, "")
        bridge.detach(second)
        let applied = try await action.execute(parameters: params, context: context)
        XCTAssertTrue(applied.success)
        let verified = try await action.verify(parameters: params, context: context)
        XCTAssertTrue(verified)
        first.searchText = "changed by GUI"
        let changed = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(changed)
        first.searchText = "gate"
        bridge.detach(first)
        bridge.attach(second)
        second.searchText = "gate"
        let replaced = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(replaced)
    }

    func testLocationUpdatesAndRejectsStaleInventoryBeforeMutating() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let inventory = CanvasLocationInventory()
        bridge.attach(state)
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { inventory.groups },
                                               inventoryRevision: { inventory.revision })
        let context = ACTAActionContext()
        let selected = ["location": "Other"]
        let applied = try await action.execute(parameters: selected, context: context)
        XCTAssertTrue(applied.success)
        XCTAssertTrue(state.includes(name: "Entrance", location: nil, stale: false, favorite: false, hasEvents: false))
        XCTAssertTrue(state.includes(name: "Entrance", location: "Other", stale: false, favorite: false, hasEvents: false))
        XCTAssertFalse(state.includes(name: "Entrance", location: "Entrance", stale: false, favorite: false, hasEvents: false))
        let verified = try await action.verify(parameters: selected, context: context)
        XCTAssertTrue(verified)
        inventory.groups = ["Entrance"]
        let stale = try await action.verify(parameters: selected, context: context)
        XCTAssertFalse(stale)
        let rejected = try await action.execute(parameters: ["location": "Other", "search": "changed"], context: context)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.locationFilter, "Other")
        inventory.groups = nil
        let unavailable = try await action.execute(parameters: ["location": "Entrance"], context: context)
        XCTAssertFalse(unavailable.success)
        let cleared = try await action.execute(parameters: ["location": ""], context: context)
        XCTAssertTrue(cleared.success)
        XCTAssertNil(state.locationFilter)
        let clearVerified = try await action.verify(parameters: ["location": ""], context: context)
        XCTAssertTrue(clearVerified)
    }

    func testAppliedFiltersDriveSamePredicateAsCanvas() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Other", "GATE"] },
                                               inventoryRevision: { self.inventoryRevision })
        let applied = try await action.execute(parameters: [
            "search": "gate", "status": "live", "favorites_only": "true", "events_only": "true"
        ], context: ACTAActionContext())
        XCTAssertTrue(applied.success)
        XCTAssertTrue(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: true, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: nil, favorite: true, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: false, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: true, hasEvents: false))
        XCTAssertFalse(state.includes(name: "Entrance", location: "Lobby", stale: false, favorite: true, hasEvents: true))
        state.locationFilter = "Other"
        state.searchText = ""
        XCTAssertTrue(state.includes(name: "Entrance", location: " ", stale: false, favorite: true, hasEvents: true))
        XCTAssertFalse(state.includes(name: "Entrance", location: "GATE", stale: false, favorite: true, hasEvents: true))
        state.cameraScope = .offline
        XCTAssertTrue(state.includes(name: "Entrance", location: nil, stale: nil, favorite: true, hasEvents: true))
    }

    func testReviewedFilterCommitsAllFieldsAfterOneNotification() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let inventory = CanvasLocationInventory()
        bridge.attach(state)
        let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { inventory.groups },
                                               inventoryRevision: { inventory.revision })
        let parameters = ["search": "gate", "location": "Entrance", "status": "live",
                          "favorites_only": "true", "events_only": "true"]
        let context = ACTAActionContext(isConfirmed: true)
        let review = try await action.prepareConfirmation(parameters: parameters, context: context)
        var notifications = 0
        let subscription = state.objectWillChange.sink {
            notifications += 1
            XCTAssertEqual(state.searchText, "")
            XCTAssertNil(state.locationFilter)
            XCTAssertEqual(state.cameraScope, .all)
            XCTAssertFalse(state.favoritesOnly)
            XCTAssertFalse(state.alertsOnly)
        }
        let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(state.searchText, "gate")
        XCTAssertEqual(state.locationFilter, "Entrance")
        XCTAssertEqual(state.cameraScope, .live)
        XCTAssertTrue(state.favoritesOnly)
        XCTAssertTrue(state.alertsOnly)
        let verified = try await action.verify(parameters: parameters, context: context)
        XCTAssertTrue(verified)
        withExtendedLifetime(subscription) {}
    }

    func testReviewedFilterRejectsReentrantDetachStateAndInventoryABA() async throws {
        for mutation in 0..<3 {
            let bridge = ACTACanvasFilterBridge()
            let state = ACTACanvasFilterState()
            let inventory = CanvasLocationInventory()
            bridge.attach(state)
            let action = ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { inventory.groups },
                                                   inventoryRevision: { inventory.revision })
            let parameters = ["search": "gate", "status": "live", "events_only": "true"]
            let context = ACTAActionContext(isConfirmed: true)
            let review = try await action.prepareConfirmation(parameters: parameters, context: context)
            var fired = false
            let subscription = state.objectWillChange.sink {
                guard !fired else { return }
                fired = true
                switch mutation {
                case 0:
                    bridge.detach(state)
                    bridge.attach(state)
                case 1:
                    state.searchText = "intervening"
                    state.searchText = ""
                default:
                    inventory.groups = ["Other"]
                    inventory.revision = UUID()
                    inventory.groups = ["Entrance", "Other"]
                    inventory.revision = UUID()
                }
            }
            let result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                           snapshot: review.snapshot)
            XCTAssertFalse(result.success)
            XCTAssertEqual(state.searchText, "")
            XCTAssertEqual(state.cameraScope, .all)
            XCTAssertFalse(state.alertsOnly)
            let verified = try await action.verify(parameters: parameters, context: context)
            XCTAssertFalse(verified)
            withExtendedLifetime(subscription) {}
        }
    }

    func testReviewedCommitCannotRunInsideGUIWillChange() {
        let state = ACTACanvasFilterState()
        var commitRevision: UUID?
        let subscription = state.objectWillChange.sink {
            commitRevision = state.commitReviewed(expectedRevision: state.reviewRevision, isValid: { true }) {
                $0.favoritesOnly = true
            }
        }
        state.searchText = "GUI"
        XCTAssertNil(commitRevision)
        XCTAssertEqual(state.searchText, "GUI")
        XCTAssertFalse(state.favoritesOnly)
        withExtendedLifetime(subscription) {}
    }

    func testAnalysisChatLifecycleChangesOnlyOnCommittedSectionTransitions() {
        let state = ACTACanvasFilterState()
        let initial = state.analysisChatLifecycle
        state.analysisSection = .alerts
        let alerts = state.analysisChatLifecycle
        XCTAssertNotEqual(initial, alerts)
        state.analysisSection = .alerts
        XCTAssertEqual(alerts, state.analysisChatLifecycle)

        var fired = false
        let subscription = state.objectWillChange.sink {
            guard !fired else { return }
            fired = true
            state.searchText = "intervening"
        }
        let rejected = state.commitReviewed(expectedRevision: state.reviewRevision, isValid: { true }) {
            $0.analysisSection = .ask
        }
        XCTAssertNil(rejected)
        XCTAssertEqual(state.analysisSection, .alerts)
        XCTAssertEqual(state.analysisChatLifecycle, alerts)
        subscription.cancel()

        let committed = state.commitReviewed(expectedRevision: state.reviewRevision, isValid: { true }) {
            $0.analysisSection = .ask
        }
        XCTAssertNotNil(committed)
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertNotEqual(state.analysisChatLifecycle, alerts)
        let reopenedOwner = state.analysisChatLifecycle
        let previousRevision = state.reviewRevision
        state.invalidateAnalysisChatLifecycle()
        XCTAssertNotEqual(state.analysisChatLifecycle, reopenedOwner)
        XCTAssertNotEqual(state.reviewRevision, previousRevision)
    }
}
