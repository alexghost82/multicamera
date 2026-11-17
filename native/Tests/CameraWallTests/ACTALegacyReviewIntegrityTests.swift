import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTALegacyReviewIntegrityTests: XCTestCase {
    func testNoteReviewShowsUnmodifiedTextButAuditRedactsIt() {
        let note = "See https://example.test/clip?token=synthetic for details"
        for actionID in ["incident.update_note", "alert.vlm_review"] {
            XCTAssertEqual(actaReviewArguments(actionID, ["note": note])["note"], note)
            XCTAssertEqual(actaActionAuditArguments(actionID, ["note": note])["note"], "[redacted]")
        }
    }

    func testReviewRequiresDisplayedIdentityProposal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracks.sqlite"))
        _ = try store.rebuildACTAIdentityDossier(identityID: "synthetic", displayName: "Original")
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let displayed = ACTAChatActionRecord(actionID: "legacy-review", threadID: "thread",
            actionType: "rename_identity", title: "Rename", parameters: [
                "identity_id": "synthetic", "new_name": "Reviewed"
            ])
        var changed = displayed
        changed.parameters["new_name"] = "Different"
        try store.saveACTAChatAction(changed)
        XCTAssertNil(coordinator.reviewAndExecuteChatAction(actionID: displayed.actionID, confirmed: true, expectedAction: displayed))
        XCTAssertEqual(try store.getACTAIdentityDossier(identityID: "synthetic")?.displayName, "Original")
        XCTAssertEqual(try store.loadACTAChatAction(actionID: displayed.actionID)?.status, "proposed")
        try store.saveACTAChatAction(displayed)
        XCTAssertEqual(coordinator.reviewAndExecuteChatAction(actionID: displayed.actionID, confirmed: true,
            expectedAction: displayed)?.status, "confirmed")
        XCTAssertEqual(try store.getACTAIdentityDossier(identityID: "synthetic")?.displayName, "Reviewed")
        XCTAssertNil(coordinator.reviewAndExecuteChatAction(actionID: displayed.actionID, confirmed: true, expectedAction: displayed))
    }
}
