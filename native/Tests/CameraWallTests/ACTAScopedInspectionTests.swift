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

private actor InspectionInferenceProbe {
    private(set) var prompts: [String] = []
    private(set) var images: [[Data]] = []
    func record(prompt: String, images: [Data]) {
        prompts.append(prompt)
        self.images.append(images)
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

    func testAmbiguousAndUnknownCamerasNeverBroadenLiveInspection() async throws {
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
        let north = UUID(), south = UUID(), duplicate = UUID()
        let directory = [north: "Front North", south: "Front South", duplicate: "Front North"]
        let frames = [
            ACTALiveCameraFrame(cameraID: north, cameraName: "Front North", jpegData: Data("north".utf8)),
            ACTALiveCameraFrame(cameraID: south, cameraName: "Front South", jpegData: Data("south".utf8)),
            ACTALiveCameraFrame(cameraID: duplicate, cameraName: "Front North", jpegData: Data("duplicate".utf8))
        ]
        for name in ["Front", "Front North"] {
            let result = await coordinator.executeAgentTool(toolName: "live_look", arguments: ["camera": name],
                threadID: "test", liveFrames: frames, cameraNames: directory, broker: broker, brokerSession: scoped)
            XCTAssertTrue(result.outputJSON.contains("AMBIGUOUS_CAMERA:"))
            XCTAssertTrue(result.attachedImages.isEmpty)
            XCTAssertNil(result.savedClipID)
        }
        let unknown = await coordinator.executeAgentTool(toolName: "live_look", arguments: ["camera": "unknown"],
            threadID: "test", liveFrames: frames, cameraNames: directory, broker: broker, brokerSession: scoped)
        XCTAssertTrue(unknown.outputJSON.contains("CAMERA_NOT_FOUND:"))
        XCTAssertTrue(unknown.attachedImages.isEmpty)
        XCTAssertTrue(try store.loadACTAChatClips(threadID: "test").isEmpty)

        let exact = await coordinator.executeAgentTool(toolName: "live_look",
            arguments: ["camera": "Front South"], threadID: "test", liveFrames: frames,
            cameraNames: directory, broker: broker, brokerSession: scoped)
        XCTAssertEqual(exact.attachedImages, [Data("south".utf8)])
        XCTAssertNotNil(exact.savedClipID)

        let missing = UUID()
        let misleading = ACTALiveCameraFrame(cameraID: north, cameraName: missing.uuidString,
                                             jpegData: Data("wrong camera".utf8))
        let byID = await coordinator.executeAgentTool(toolName: "live_look",
            arguments: ["camera": missing.uuidString], threadID: "test", liveFrames: [misleading],
            cameraNames: directory, broker: broker, brokerSession: scoped)
        XCTAssertTrue(byID.attachedImages.isEmpty)
        XCTAssertNil(byID.savedClipID)
        XCTAssertEqual(try store.loadACTAChatClips(threadID: "test").count, 1)
        XCTAssertEqual(audit.snapshot().filter { $0.phase == .result && $0.outcome == "failed" }.count, 3)
        await broker.closeSession(scoped, operatorKey: key)
    }

    func testAmbiguousCameraRejectionRequiresResultAudit() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ACTAAnalyticsCoordinator(
            aiClient: ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun)), trackingStore: store)
        let audit = FailingInspectionAudit(failureAt: 2)
        let created = await ACTALocalActionBroker.make(actions: [], allowedActionIDs: [],
            allowedInspectionIDs: ["live_look"], audit: { try audit.record($0) })
        let host = try XCTUnwrap(created)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "test", actionIDs: [], inspectionIDs: ["live_look"])
        let scoped = try XCTUnwrap(issued)
        let result = await coordinator.executeAgentTool(toolName: "live_look",
            arguments: ["camera": "Front"], threadID: "test",
            cameraNames: [UUID(): "Front North", UUID(): "Front South"],
            broker: host.broker, brokerSession: scoped)
        XCTAssertTrue(result.outputJSON.contains("AUDIT"))
        XCTAssertFalse(result.outputJSON.contains("AMBIGUOUS_CAMERA"))
        XCTAssertTrue(result.attachedImages.isEmpty)
        XCTAssertNil(result.savedClipID)
        await host.broker.closeSession(scoped, operatorKey: host.operatorKey)
    }

    func testHistoryRejectsAmbiguousNamesButAllowsExplicitAllCameras() throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID()
        let cameras = [first: "Front", second: "Front"]
        XCTAssertThrowsError(try UnifiedHistoryEvidence.load(store: store,
            question: "What happened at Front?", prior: [], cameras: cameras, now: Date())) {
            XCTAssertTrue($0.localizedDescription.contains("AMBIGUOUS_CAMERA"))
        }
        let all = try UnifiedHistoryEvidence.load(store: store,
            question: "What happened at Front across all cameras?", prior: [], cameras: cameras, now: Date())
        XCTAssertNil(all.cameraID)
        let unique = try UnifiedHistoryEvidence.load(store: store,
            question: "What happened at Front?", prior: [], cameras: [first: "Front"], now: Date())
        XCTAssertEqual(unique.cameraID, first)
        let byID = try UnifiedHistoryEvidence.load(store: store,
            question: "What happened at Front (\(first.uuidString))?", prior: [], cameras: cameras, now: Date())
        XCTAssertEqual(byID.cameraID, first)
    }

    func testHistoryResolvesExplicitPartialCameraNamesWithoutBroadening() throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let north = UUID(), south = UUID()
        let cameras = [north: "Front North", south: "Front South"]
        func scope(_ question: String) throws -> UUID? {
            try UnifiedHistoryEvidence.load(store: store, question: question,
                                            prior: [], cameras: cameras, now: Date()).cameraID
        }
        XCTAssertEqual(try scope("Что было на камере North вчера?"), north)
        XCTAssertEqual(try scope("What happened at camera South?"), south)
        for question in ["Что было на камере Front?", "What happened at camera unknown?",
                         "Что было на камере?", "What happened at camera \(UUID().uuidString)?",
                         "What happened at camera unknown near Front South?",
                         "What happened at camera out?",
                         "Compare camera North and camera South.",
                         "Show not all cameras.",
                         "Do not show all cameras.",
                         "Show all cameras except Front South.",
                         "Show all cameras apart from Front South.",
                         "Show no cameras.",
                         "Покажи не все камеры.",
                         "Не показывай все камеры.",
                         "Покажи все камеры кроме Front South."] {
            XCTAssertThrowsError(try scope(question), question)
        }
        XCTAssertNil(try scope("What happened across all cameras?"))
        XCTAssertNil(try scope("Покажи все камеры"))
        XCTAssertNil(try scope("Show all the cameras"))
        XCTAssertFalse(UnifiedHistoryEvidence.requestsAllCameras("Show small cameras"))
        XCTAssertNil(try scope("What happened yesterday?"))
    }

    func testAmbiguousLivePrefetchDoesNotAttachImages() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = InspectionInferenceProbe()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, images in
                await probe.record(prompt: prompt, images: images)
                return #"{"answerMarkdown":"Please clarify the camera.","confidence":0.5}"#
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let audit = InspectionAuditProbe()
        let scopes: Set<String> = [ACTAAnalyticsCoordinator.historyBootstrapInspection,
            ACTAAnalyticsCoordinator.historyOverviewInspection, "live_look"]
        let (broker, key, scoped) = try await session(threadID: "test", input: .chat,
                                                       scopes: scopes, audit: audit)
        let frames = [
            ACTALiveCameraFrame(cameraID: UUID(), cameraName: "Front", jpegData: Data("first".utf8)),
            ACTALiveCameraFrame(cameraID: UUID(), cameraName: "Front", jpegData: Data("second".utf8))
        ]
        let answer = await coordinator.askACTAChatAgent(question: "What is live at Front?", threadID: "test",
            liveFrames: frames, maxSteps: 1, broker: broker, brokerSession: scoped)
        let prompts = await probe.prompts
        let images = await probe.images
        XCTAssertTrue(answer.answerMarkdown.contains("AMBIGUOUS_CAMERA"))
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(images.allSatisfy(\.isEmpty))
        XCTAssertTrue(try store.loadACTAChatClips(threadID: "test").isEmpty)

        let first = try XCTUnwrap(frames[0].cameraID)
        let second = try XCTUnwrap(frames[1].cameraID)
        let directory = [first: "Front", second: "Front"]
        _ = await coordinator.askACTAChatAgent(question: "What is live at Front (\(first.uuidString))?",
            threadID: "test", liveFrames: frames, cameraNames: directory,
            maxSteps: 1, broker: broker, brokerSession: scoped)
        let idImages = await probe.images
        XCTAssertEqual(idImages.last, [frames[0].jpegData])

        _ = await coordinator.askACTAChatAgent(question: "What is live at Front across all cameras?",
            threadID: "test", liveFrames: frames, cameraNames: directory,
            maxSteps: 1, broker: broker, brokerSession: scoped)
        let allImages = await probe.images
        XCTAssertEqual(allImages.last, frames.map(\.jpegData))
        await broker.closeSession(scoped, operatorKey: key)
    }

    func testAmbiguousHistoryReportsAuditedErrorBeforeInference() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { _, _ in
                XCTFail("Ambiguous history must not reach inference")
                throw URLError(.cancelled)
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let audit = InspectionAuditProbe()
        let scopes: Set<String> = [ACTAAnalyticsCoordinator.historyBootstrapInspection,
                                   ACTAAnalyticsCoordinator.historyOverviewInspection]
        let (broker, key, scoped) = try await session(threadID: "test", input: .chat,
                                                       scopes: scopes, audit: audit)
        let answer = await coordinator.askACTAChatAgent(question: "What happened at Front?", threadID: "test",
            cameraNames: [UUID(): "Front", UUID(): "Front"], broker: broker, brokerSession: scoped)
        XCTAssertTrue(answer.answerMarkdown.contains("AMBIGUOUS_CAMERA"))
        let restricted = await coordinator.askACTAChatAgent(
            question: "Show all cameras except Front", threadID: "test",
            cameraNames: [UUID(): "Front"], broker: broker, brokerSession: scoped)
        XCTAssertTrue(restricted.answerMarkdown.contains("CAMERA_NOT_FOUND"))
        let events = audit.snapshot().filter { $0.actionID == "inspection.history.overview" }
        XCTAssertEqual(events.filter { $0.phase == .request }.count, 2)
        XCTAssertEqual(events.filter { $0.phase == .result && $0.outcome == "failed" }.count, 2)
        await broker.closeSession(scoped, operatorKey: key)
    }

    func testLivePrefetchUsesPartialNameFromFrameDirectory() async throws {
        let (root, store) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = InspectionInferenceProbe()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil },
            localAgentInference: { prompt, images in
                await probe.record(prompt: prompt, images: images)
                return #"{"answerMarkdown":"Synthetic answer","confidence":0.5}"#
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let audit = InspectionAuditProbe()
        let scopes: Set<String> = [ACTAAnalyticsCoordinator.historyBootstrapInspection,
                                   ACTAAnalyticsCoordinator.historyOverviewInspection, "live_look"]
        let (broker, key, scoped) = try await session(threadID: "test", input: .chat,
                                                       scopes: scopes, audit: audit)
        let frames = [
            ACTALiveCameraFrame(cameraID: UUID(), cameraName: "Front North", jpegData: Data("north".utf8)),
            ACTALiveCameraFrame(cameraID: UUID(), cameraName: "Front South", jpegData: Data("south".utf8))
        ]
        _ = await coordinator.askACTAChatAgent(question: "What is live on camera North?", threadID: "test",
            liveFrames: frames, maxSteps: 1, broker: broker, brokerSession: scoped)
        let images = await probe.images
        XCTAssertEqual(images.last, [frames[0].jpegData])
        await broker.closeSession(scoped, operatorKey: key)
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
