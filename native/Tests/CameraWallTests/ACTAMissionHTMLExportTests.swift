import CameraCore
import Foundation
import XCTest
#if !ACTA_STANDALONE
@testable import CameraWall
#endif

private struct MissionHTMLFixtureSelector: ACTAReviewedHTMLSelectionProvider {
    let selection: ACTAReviewedHTMLSelection
    func selectAndReview() async throws -> ACTAReviewedHTMLSelection { selection }
}

final class ACTAMissionHTMLExportTests: XCTestCase {
    func testRealReportThroughBrokerAndCreateOnlyPublisher() async throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".mission-html-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.html")
        let run = CameraMissionRun(missionID: UUID(), cameraID: UUID(), missionName: "Synthetic <gate>",
                                   status: .completed, summary: "Synthetic & observation")
        let bytes = ACTAMissionHTMLExport.render(runs: [run])
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(text.contains("Synthetic &lt;gate&gt;"))
        XCTAssertTrue(text.contains("Synthetic &amp; observation"))
        let selection = ACTAReviewedHTMLSelection(kind: "mission", bytes: bytes, destination: file)
        let action = ACTAReviewedHTMLExportAction(selector: MissionHTMLFixtureSelector(selection: selection),
                                                  publisher: ACTAMissionHTMLPublisher())
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let injected = await host.broker.request(session: session, actionID: action.id,
                                                  argumentsJSON: #"{"path":"/model.html"}"#)
        XCTAssertFalse(injected.success)
        let coordinator = await ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
        let name = "acta__monitor__export_report_html"
        let call = ACTAAgentFunctionCall(callID: "export", name: name, argumentsJSON: "{}")
        let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: review, approved: false)
        XCTAssertFalse(rejected.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let renewed = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(renewed.requiresOperatorConfirmation)
        let approvedReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let approvedReview = try XCTUnwrap(approvedReviews.first)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: approvedReview, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let next = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(next.requiresOperatorConfirmation)
        let nextReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let nextReview = try XCTUnwrap(nextReviews.first)
        let collision = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                  reviewed: nextReview, approved: true)
        XCTAssertFalse(collision.success)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(try ACTACreateOnlyExport.verify(Data("different".utf8), at: file))
    }
}
