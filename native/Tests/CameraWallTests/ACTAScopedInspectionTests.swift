import CameraCore
import Foundation
import XCTest
@testable import CameraWall

func makeInspectionTestSession(
    store: LocalTrackingStore, threadID: String,
    scopes: Set<String> = ACTAAnalyticsCoordinator.localInspectionIDs
) async throws -> (ACTALocalActionBroker, ACTABrokerSession) {
    let host = await ACTALocalActionBroker.make(actions: [], allowedActionIDs: [],
        allowedInspectionIDs: scopes, audit: { event in
            let outcome: String
            switch event.phase {
            case .request: outcome = "request"
            case .validated: outcome = "validated"
            case .review: outcome = event.approved == true ? "approved" : "rejected"
            case .result: outcome = event.outcome ?? "failed"
            }
            try store.recordDurableACTAToolCallAudit(ACTAToolCallAuditRecord(
                threadID: event.threadID, toolName: event.actionID, argsJSON: "{}",
                resultRows: outcome == "success" ? 1 : 0, durationMs: 0,
                ok: outcome == "success", error: "BROKER_\(outcome)"))
        })
    let created = try XCTUnwrap(host)
    let session = await created.broker.openSession(operatorKey: created.operatorKey, input: .chat,
        threadID: threadID, actionIDs: [], inspectionIDs: scopes)
    return (created.broker, try XCTUnwrap(session))
}

private final class InspectionAuditProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ACTABrokerAuditEvent] = []
    func record(_ event: ACTABrokerAuditEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [ACTABrokerAuditEvent] { lock.withLock { events } }
}

private final class FailingInspectionAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failureAt: Int
    init(failureAt: Int) { self.failureAt = failureAt }
    func record(_ event: ACTABrokerAuditEvent) throws {
        let current = lock.withLock { count += 1; return count }
        if current == failureAt { throw CocoaError(.fileWriteUnknown) }
    }
}

private actor InspectionInferenceGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func block() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

final class ACTAScopedInspectionTests: XCTestCase {
    func testInspectionOutputRejectsMalformedAndInvalidErrors() throws {
        for output in ["not json", "[]", #"{"error":42}"#,
                       #"{"error":"TOOL_OUTPUT_INVALID: Failed."}"#] {
            XCTAssertThrowsError(try ACTAAnalyticsCoordinator.requireAuthorizedToolOutput(output)) {
                guard case ACTAAnalyticsCoordinator.InspectionFailure.invalidOutput = $0 else {
                    return XCTFail("Unexpected error: \($0)")
                }
            }
        }
        XCTAssertNoThrow(try ACTAAnalyticsCoordinator.requireAuthorizedToolOutput(#"{"tool":"get_timeline","rows":[]}"#))
        XCTAssertNoThrow(try ACTAAnalyticsCoordinator.requireAuthorizedToolOutput(#"{"error":"UNSUPPORTED: Unavailable."}"#))
    }

    private func session(
        threadID: String, input: ACTABrokerLocalInput, scopes: Set<String>, audit: InspectionAuditProbe
    ) async throws -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let host = await ACTALocalActionBroker.make(actions: [], allowedActionIDs: [],
            allowedInspectionIDs: scopes, audit: { audit.record($0) })
        let created = try XCTUnwrap(host)
        let issued = await created.broker.openSession(operatorKey: created.operatorKey, input: input,
            threadID: threadID, actionIDs: [], inspectionIDs: scopes)
        return (created.broker, created.operatorKey, try XCTUnwrap(issued))
    }

    private func store() throws -> (URL, LocalTrackingStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-scoped-inspection-\(UUID().uuidString)", isDirectory: true)
        return (root, try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite")))
    }

    func testDirectModelAndVoiceInspectionsAreScopedAndAuditNoArguments() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let audit = InspectionAuditProbe()
        let (broker, key, scoped) = try await session(threadID: "test", input: .voice,
                                                       scopes: ["live_look"], audit: audit)
        let image = Data("synthetic image".utf8)
        let frame = ACTALiveCameraFrame(cameraID: UUID(), cameraName: "Fixture", jpegData: image)
        let noSession = await coordinator.executeAgentTool(toolName: "live_look", threadID: "test", liveFrames: [frame])
        XCTAssertTrue(noSession.outputJSON.contains("UNAUTHORIZED:"))
        XCTAssertTrue(noSession.attachedImages.isEmpty)
        XCTAssertTrue(try store.loadACTAChatClips(threadID: "test").isEmpty)

        let outsideScope = await coordinator.executeAgentTool(toolName: "get_timeline", threadID: "test",
                                                               broker: broker, brokerSession: scoped)
        XCTAssertTrue(outsideScope.outputJSON.contains("UNAUTHORIZED:"))
        let wrongThread = await coordinator.executeAgentTool(toolName: "live_look", threadID: "other",
            liveFrames: [frame], broker: broker, brokerSession: scoped)
        XCTAssertTrue(wrongThread.outputJSON.contains("UNAUTHORIZED:"))
        let (otherBroker, _, _) = try await session(threadID: "test", input: .chat,
                                                     scopes: ["live_look"], audit: audit)
        let foreign = await coordinator.executeAgentTool(toolName: "live_look", threadID: "test",
            liveFrames: [frame], broker: otherBroker, brokerSession: scoped)
        XCTAssertTrue(foreign.outputJSON.contains("UNAUTHORIZED:"))

        let call = ACTAAgentFunctionCall(callID: "one", name: "live_look",
                                         argumentsJSON: #"{"camera":"synthetic-private-value"}"#)
        let deniedFrame = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: ["live_look"], liveFrames: [frame], broker: broker, brokerSession: scoped)
        XCTAssertTrue(deniedFrame.attachedImages.isEmpty)
        let allowed = await coordinator.executeAgentTool(toolName: "live_look", threadID: "test",
            liveFrames: [frame], broker: broker, brokerSession: scoped)
        XCTAssertEqual(allowed.attachedImages, [image])
        XCTAssertNotNil(allowed.savedClipID)
        XCTAssertEqual(try store.loadACTAChatClips(threadID: "test").count, 1)
        XCTAssertTrue(audit.snapshot().allSatisfy {
            !$0.actionID.contains("synthetic-private-value") && !$0.threadID.contains("synthetic-private-value")
        })
        XCTAssertTrue(try store.executeReadOnlyACTASQL(
            "SELECT args_json FROM ghost_chat_tool_calls").allSatisfy { $0["args_json"] == "{}" })

        scoped.invalidate(operatorKey: key)
        let revoked = await coordinator.executeAgentTool(toolName: "live_look", threadID: "test",
            liveFrames: [frame], broker: broker, brokerSession: scoped)
        XCTAssertTrue(revoked.outputJSON.contains("UNAUTHORIZED:"))
        XCTAssertEqual(try store.loadACTAChatClips(threadID: "test").count, 1)
        await broker.closeSession(scoped, operatorKey: key)
    }

    func testOverviewRequiresItsOwnCapabilityAndRevocationSuppressesInferenceResult() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = InspectionInferenceGate()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { _, _ in
                await gate.block()
                return #"{"answerMarkdown":"synthetic answer","confidence":0.8}"#
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let audit = InspectionAuditProbe()
        let (limitedBroker, _, limited) = try await session(threadID: "limited", input: .chat,
            scopes: [ACTAAnalyticsCoordinator.historyBootstrapInspection], audit: audit)
        let denied = await coordinator.askACTAChatAgent(question: "Question", threadID: "limited",
                                                       broker: limitedBroker, brokerSession: limited)
        XCTAssertTrue(denied.answerMarkdown.contains("UNAUTHORIZED:"))
        XCTAssertTrue(try store.loadACTAChatMessages(threadID: "limited").isEmpty)

        let scopes: Set<String> = [ACTAAnalyticsCoordinator.historyBootstrapInspection,
                                   ACTAAnalyticsCoordinator.historyOverviewInspection]
        let (broker, key, active) = try await session(threadID: "test", input: .chat, scopes: scopes, audit: audit)
        let task = Task {
            await coordinator.askACTAChatAgent(question: "Question", threadID: "test",
                                               broker: broker, brokerSession: active)
        }
        await gate.waitForStart()
        active.invalidate(operatorKey: key)
        await gate.release()
        let answer = await task.value
        XCTAssertTrue(answer.answerMarkdown.contains("UNAUTHORIZED:"))
        XCTAssertFalse(try store.loadACTAChatMessages(threadID: "test").contains { $0.role == "assistant" })
        XCTAssertTrue(audit.snapshot().contains { $0.actionID == "inspection.history.overview" })
        await broker.closeSession(active, operatorKey: key)
    }

    func testFailedBeginOrEndAuditNeverReleasesInspectionOutput() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        for failureAt in [1, 2] {
            let audit = FailingInspectionAudit(failureAt: failureAt)
            let created = await ACTALocalActionBroker.make(
                actions: [], allowedActionIDs: [], allowedInspectionIDs: ["get_timeline"],
                audit: { try audit.record($0) })
            let host = try XCTUnwrap(created)
            let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                threadID: "test", actionIDs: [], inspectionIDs: ["get_timeline"])
            let scoped = try XCTUnwrap(issued)
            let result = await coordinator.executeAgentTool(toolName: "get_timeline", threadID: "test",
                                                             broker: host.broker, brokerSession: scoped)
            XCTAssertTrue(result.outputJSON.contains("AUDIT_FAILED:"))
            XCTAssertEqual(result.resultRows, 0)
            XCTAssertTrue(result.attachedImages.isEmpty)
            await host.broker.closeSession(scoped, operatorKey: host.operatorKey)
        }
    }
}
