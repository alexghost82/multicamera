import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAFiveCanvasActionsIntegrationTests: XCTestCase {
    func testProductionPolicyAndReviewedModelCallsForAllFiveActions() async throws {
        let state = ACTACanvasFilterState()
        let bridge = ACTACanvasFilterBridge()
        bridge.attach(state)
        let cameraID = UUID()
        let inventoryRevision = UUID()
        let actions: [any ACTAActionProtocol] = [
            ACTACanvasSetFilterAction(bridge: bridge, locationGroups: { ["Lobby"] },
                                      inventoryRevision: { inventoryRevision }),
            ACTACanvasSelectCamerasAction(bridge: bridge, enabledCameraIDs: { [cameraID] },
                                         inventoryRevision: { inventoryRevision }),
            ACTACanvasSetPresentationAction(bridge: bridge),
            ACTACanvasSetArrangeModeAction(bridge: bridge),
            ACTAAnalysisSetSectionAction(bridge: bridge)
        ]
        let ids = WallModel.modelFacingActionIDs(actions)
        XCTAssertEqual(ids, Set(actions.map(\.id)))
        let made = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: "fixture", actionIDs: ids)
        let session = try XCTUnwrap(opened)
        let catalogue = await host.broker.catalogue(session: session)
        XCTAssertEqual(Set(catalogue.map(\.id)), ids)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil }))

        let calls: [(String, String)] = [
            ("acta__canvas__set_filter", #"{"search":"gate","location":"Lobby","favorites_only":true}"#),
            ("acta__canvas__select_cameras", #"{"mode":"all"}"#),
            ("acta__canvas__set_presentation", #"{"mode":"list"}"#),
            ("acta__canvas__set_arrange_mode", #"{"enabled":true}"#),
            ("acta__analysis__set_section", #"{"section":"alerts"}"#)
        ]
        for (name, arguments) in calls {
            let call = ACTAAgentFunctionCall(callID: name, name: name, argumentsJSON: arguments)
            let result = await coordinator.executeModelGeneratedAgentTool(
                call, threadID: "fixture", requestToolNames: Set(calls.map(\.0)),
                broker: host.broker, brokerSession: session)
            XCTAssertTrue(result.outputJSON.contains("requires_operator_confirmation"), name)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            XCTAssertEqual(reviews.count, 1, name)
            let review = try XCTUnwrap(reviews.first)
            let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                      reviewed: review, approved: true)
            XCTAssertTrue(approved.success, "\(name): \(approved.error ?? "unknown error")")
            XCTAssertTrue(approved.verified, name)
        }
        XCTAssertEqual(state.searchText, "gate")
        XCTAssertEqual(state.locationFilter, "Lobby")
        XCTAssertTrue(state.favoritesOnly)
        XCTAssertEqual(state.selectedCameraIDs, [cameraID])
        XCTAssertEqual(state.presentation, .list)
        XCTAssertTrue(state.arrangeCameras)
        XCTAssertEqual(state.analysisSection, .alerts)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }
}
