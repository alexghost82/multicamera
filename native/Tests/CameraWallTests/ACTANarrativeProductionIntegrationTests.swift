import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTANarrativeProductionIntegrationTests: XCTestCase {
    func testModelSharesPinStateWithReviewedModelRoute() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".narrative-cas-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try IsolatedWallFixtureSupport.prepare(root)
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(enabledFeatures: []),
                                               to: root.appendingPathComponent("features.json"))
        let model = WallModel(
            configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("unused-pose.mlmodel"),
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                                                         databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        IsolatedWallFixtureSupport.assertSafe(model)

        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracks.sqlite"))
        let id = UUID()
        try store.saveACTANarrativeChapter(id: id, cameraID: UUID(), cameraName: "fixture",
            startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "fixture", summary: "fixture"))
        try store.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        let presentation = try XCTUnwrap(model.narrativePresentation)
        try presentation.refresh()
        let displayed = try XCTUnwrap(presentation.rows.first)
        let action = try XCTUnwrap(model.makeNarrativePinAction())
        let ids = WallModel.modelFacingActionIDs([action])
        XCTAssertTrue(ids.contains(action.id))
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: "fixture", actionIDs: ids)
        let session = try XCTUnwrap(opened)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
        let name = "acta__memory__toggle_pin"
        let call = ACTAAgentFunctionCall(callID: "pin", name: name,
            argumentsJSON: #"{"chapter_id":"\#(id.uuidString)","pinned":true}"#)
        let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertFalse(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: try XCTUnwrap(reviews.first), approved: true)
        XCTAssertTrue(approved.success && approved.verified)
        XCTAssertTrue(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
        XCTAssertTrue(try XCTUnwrap(presentation.rows.first).chapter.pinned)
        XCTAssertThrowsError(try presentation.toggle(displayed))

        let stale = try XCTUnwrap(presentation.rows.first)
        try store.setACTANarrativePinned(chapterID: id.uuidString, pinned: false)
        try store.setACTANarrativePinned(chapterID: id.uuidString, pinned: true)
        XCTAssertThrowsError(try presentation.toggle(stale))
        XCTAssertNil(model.makeNarrativePinAction())
        let blocked = await host.broker.request(session: session, actionID: action.id,
            argumentsJSON: #"{"chapter_id":"\#(id.uuidString)","pinned":false}"#)
        XCTAssertFalse(blocked.requiresOperatorConfirmation)
        XCTAssertFalse(blocked.success)
        try presentation.refresh()
        XCTAssertNotNil(model.makeNarrativePinAction())
        XCTAssertTrue(try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: id.uuidString)).pinned)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }
}
