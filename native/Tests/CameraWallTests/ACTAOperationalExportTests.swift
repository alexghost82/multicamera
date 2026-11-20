import CameraCore
import Foundation
import PDFKit
import XCTest
#if !ACTA_STANDALONE
@testable import CameraWall
#endif

private actor FileExportFixtureSelector: ACTAReviewedFileSelector {
    var selection: ACTAReviewedFileSelection
    init(_ selection: ACTAReviewedFileSelection) { self.selection = selection }
    func selectAndReview() async throws -> ACTAReviewedFileSelection { selection }
    func replace(_ selection: ACTAReviewedFileSelection) { self.selection = selection }
}

private final class FileExportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 10
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value = 311 }
}

final class ACTAOperationalExportTests: XCTestCase {
    func testRealPDFAndSyntheticDiagnosticsUseReviewedCreateOnlyPublication() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".operational-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = CameraMissionRun(missionID: UUID(), cameraID: UUID(), missionName: "Synthetic gate",
                                   status: .completed, summary: "Synthetic observation")
        let pdf = try CameraMissionRun.CameraMissionReport.renderPDFData(runs: [run])
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertTrue(document.string?.contains("Synthetic observation") == true)
        let fixtures: [(ACTAReviewedFileKind, Data)] = [
            (.diagnostics, Data(#"{"cameras":[],"fixture":"only"}"#.utf8)), (.missionPDF, pdf)
        ]
        for (kind, bytes) in fixtures {
            let destination = directory.appendingPathComponent("file." + kind.fileExtension)
            let selection = ACTAReviewedFileSelection(kind: kind, bytes: bytes, destination: destination)
            let selector = FileExportFixtureSelector(selection)
            let action = ACTAReviewedFileExportAction(kind: kind, selector: selector)
            let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
            let host = try XCTUnwrap(made)
            let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                        threadID: "fixture", actionIDs: [action.id])
            let session = try XCTUnwrap(opened)
            let injection = await host.broker.request(session: session, actionID: action.id,
                                                       argumentsJSON: #"{"path":"/model.json"}"#)
            XCTAssertFalse(injection.success)
            let coordinator = await ACTAAnalyticsCoordinator(aiClient: IsolatedWallFixtureSupport.client())
            let name = kind == .diagnostics ? "acta__settings__export_diagnostics" : "acta__mission__export_pdf"
            let call = ACTAAgentFunctionCall(callID: "export", name: name, argumentsJSON: "{}")
            let pending = await coordinator.executeModelGeneratedAgentTool(call, threadID: "fixture",
                requestToolNames: [name], broker: host.broker, brokerSession: session)
            XCTAssertTrue(pending.outputJSON.contains("requires_operator_confirmation"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            await selector.replace(.init(kind: kind, bytes: Data("changed".utf8),
                                         destination: directory.appendingPathComponent("other." + kind.fileExtension)))
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: review, approved: true)
            XCTAssertTrue(result.success && result.verified, result.summary)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: review, approved: true)
            XCTAssertFalse(replay.success)
            await selector.replace(selection)
            let collisionRequest = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            XCTAssertTrue(collisionRequest.requiresOperatorConfirmation)
            let collisionReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let collisionReview = try XCTUnwrap(collisionReviews.first)
            let collision = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                       reviewed: collisionReview, approved: true)
            XCTAssertFalse(collision.success)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    func testEscapedPreviewAndCompleteHex() {
        XCTAssertEqual(ACTAReviewedFileExportUI.escaped("a\\\n\u{202E}é"), "a\\\\\\u{A}\n\\u{202E}\\u{E9}")
        XCTAssertEqual(ACTAReviewedFileExportUI.hex(Data([0x00, 0x7f, 0xff])), "00 7F FF ")
    }

    func testExpiredOrMismatchedReviewAndLateCollision() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".operational-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file.json")
        let selector = FileExportFixtureSelector(.init(kind: .diagnostics,
                                                        bytes: Data(#"{"fixture":true}"#.utf8), destination: url))
        let clock = FileExportClock()
        let action = ACTAReviewedFileExportAction(kind: .diagnostics, selector: selector, now: { clock.now() })
        let prepared = try await action.prepareConfirmation(parameters: [:], context: .init(threadID: "one"))
        let mismatch = try await action.executeConfirmed(parameters: [:],
            context: .init(threadID: "other", isConfirmed: true), snapshot: prepared.snapshot)
        XCTAssertFalse(mismatch.success)
        let replay = try await action.executeConfirmed(parameters: [:],
            context: .init(threadID: "one", isConfirmed: true), snapshot: prepared.snapshot)
        XCTAssertFalse(replay.success)
        let expired = try await action.prepareConfirmation(parameters: [:], context: .init(threadID: "one"))
        clock.advance()
        let denied = try await action.executeConfirmed(parameters: [:],
            context: .init(threadID: "one", isConfirmed: true), snapshot: expired.snapshot)
        XCTAssertFalse(denied.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let collision = try await action.prepareConfirmation(parameters: [:], context: .init(threadID: "one"))
        let original = Data("existing".utf8)
        try original.write(to: url)
        let result = try await action.executeConfirmed(parameters: [:],
            context: .init(threadID: "one", isConfirmed: true), snapshot: collision.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
