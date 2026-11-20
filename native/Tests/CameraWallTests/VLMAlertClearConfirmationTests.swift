import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class VLMAlertClearConfirmationTests: XCTestCase {
    private func fixture(_ body: (URL, [VLMAlert]) throws -> Void) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".vlm-clear-confirmation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("alerts.json")
        let alerts = [VLMAlert(cameraID: UUID(), cameraName: "Synthetic camera",
                               condition: "Condition", evidence: "Evidence")]
        try VLMStore.save(alerts, to: url)
        try body(url, alerts)
    }

    func testConfirmationRejectsChangedVisibleOrDiskImages() throws {
        try fixture { url, alerts in
            let confirmation = try XCTUnwrap(VLMAlertClearConfirmation.capture(visible: alerts, from: url))
            XCTAssertTrue(try confirmation.isCurrent(visible: alerts, from: url))
            XCTAssertFalse(try confirmation.isCurrent(visible: [], from: url))
            var changed = alerts
            changed[0].evidence = "New evidence"
            try VLMStore.save(changed, to: url)
            XCTAssertFalse(try confirmation.isCurrent(visible: alerts, from: url))
            XCTAssertNil(try VLMAlertClearConfirmation.capture(visible: alerts, from: url))
        }
    }

    func testConfirmationRejectsEmptyMissingAndInvalidSources() throws {
        try fixture { url, alerts in
            XCTAssertNil(try VLMAlertClearConfirmation.capture(visible: [], from: url))
            let confirmation = try XCTUnwrap(VLMAlertClearConfirmation.capture(visible: alerts, from: url))
            try Data("{".utf8).write(to: url)
            XCTAssertThrowsError(try VLMAlertClearConfirmation.capture(visible: alerts, from: url))
            XCTAssertFalse(try confirmation.isCurrent(visible: alerts, from: url))
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try confirmation.isCurrent(visible: alerts, from: url))
            XCTAssertThrowsError(try VLMAlertClearConfirmation.capture(visible: alerts, from: url))
        }
    }

    func testExternalWriterInvalidatesConfirmation() throws {
        try fixture { url, alerts in
            let confirmation = try XCTUnwrap(VLMAlertClearConfirmation.capture(visible: alerts, from: url))
            let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.json")
            var updated = alerts
            updated[0].condition = "Externally updated"
            try VLMStore.save(updated, to: replacement)
            let writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/bin/cp")
            writer.arguments = [replacement.path, url.path]
            try writer.run()
            writer.waitUntilExit()
            XCTAssertEqual(writer.terminationStatus, 0)
            XCTAssertFalse(try confirmation.isCurrent(visible: alerts, from: url))
            XCTAssertEqual(try VLMStore.loadAlerts(from: url), updated)
        }
    }
}
