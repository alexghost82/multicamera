import XCTest
import CameraCore
@testable import CameraWall

final class UnifiedAgentHistoryTests: XCTestCase {
    func testScanReferencesAndAliasesPreserveProvenance() throws {
        let id = UUID(), camera = UUID()
        var ledger = AgentEvidenceLedger()
        ledger.record(outputJSON: "{\"automatic_scans\":[{\"scan_id\":\"\(id)\",\"camera_id\":\"\(camera)\",\"camera_name\":\"Entrance\",\"observed_at\":\"2026-11-14T08:00:00Z\"}]}", tool: "history_overview")
        XCTAssertEqual(ledger.references.first?.recordID, id.uuidString)
        XCTAssertEqual(ledger.references.first?.occurredAt, "2026-11-14T08:00:00Z")
        let resolved = ledger.validated(ledger.resolvingAliases(ACTAChatPresentAnswer(answerMarkdown: "Observation", citedRecordIDs: ["S1", "S999"])))
        XCTAssertEqual(resolved.evidenceReferences.count, 1)
        XCTAssertEqual(resolved.evidenceReferences.first?.cameraID, camera.uuidString)
    }

    func testRetrievalIncludesOldAndRemovedCamerasAndExactDayScope() throws {
        let (directory, store, scans) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let overview = try UnifiedHistoryEvidence.load(store: store, question: "Что происходило за всё время на всех камерах?", prior: [], cameras: [scans[0].cameraID: scans[0].cameraName], now: Date())
        for scan in scans { XCTAssertTrue(overview.json.contains(scan.id.uuidString), overview.json) }
        XCTAssertNil(overview.since)
        let yesterday = try UnifiedHistoryEvidence.load(store: store, question: "Что было вчера?", prior: [], cameras: [:], now: Date())
        XCTAssertNotNil(yesterday.since)
        XCTAssertFalse(yesterday.json.contains(scans[0].id.uuidString))
        XCTAssertTrue(yesterday.json.contains(scans[1].id.uuidString))
    }

    @MainActor
    func testFrameQuestionEntryUsesOneHistoryAgentEvenWithNoLiveCameras() async throws {
        let (directory, store, scans) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wall = WallModel(configURL: directory.appendingPathComponent("cameras.json"),
            trackingStoreURL: directory.appendingPathComponent("history.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"), databaseURL: directory.appendingPathComponent("features.sqlite")), analyticsDirectoryURL: directory)
        defer { wall.shutdown() }
        var prefs = wall.vlmPreferences; prefs.actaBackendMode = .dryRun
        try wall.saveVLMPreferences(prefs)
        XCTAssertFalse(wall.running)
        XCTAssertTrue(wall.askVLM(question: "Что происходило за всё время на всех камерах?", cameraIDs: []))
        XCTAssertEqual(wall.actaChatMessages.last?.role, "user")
        let deadline = Date().addingTimeInterval(10)
        while wall.actaAgentBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(wall.actaAgentBusy)
        let answer = try XCTUnwrap(wall.actaChatMessages.last)
        XCTAssertEqual(answer.role, "assistant")
        let cameras = Set(answer.structuredAnswer?.evidenceReferences.compactMap(\.cameraID) ?? [])
        for scan in scans { XCTAssertTrue(cameras.contains(scan.cameraID.uuidString)) }
        XCTAssertTrue(wall.vlmMessages.isEmpty, "Manual requests must not go to the frame-only chat")
    }

    func testRealQwenAnswersAllCameraHistoryAndFollowUp() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_AGENT_MODEL"] else {
            throw XCTSkip("Set CAMERAWALL_TEST_AGENT_MODEL for real local-model end-to-end verification")
        }
        let (directory, store, scans) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess, preferredLanguage: .ru), localVLM: LocalVLMClient(model: model, workload: .interactive), agentTrace: { FileHandle.standardError.write(Data(("AGENT_TRACE " + $0 + "\n").utf8)) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let started = Date()
        let answer = await coordinator.askACTAChatAgent(question: "Проверь историю за всё время и расскажи, что происходило на всех камерах. Отдельно по каждой камере.", cameraNames: Dictionary(uniqueKeysWithValues: scans.map { ($0.cameraID, $0.cameraName) }))
        print("REAL_AGENT_QA elapsed=\(Date().timeIntervalSince(started)) sources=\(answer.evidenceReferences.count) answer=\(answer.answerMarkdown)")
        XCTAssertGreaterThan(answer.confidence, 0, answer.answerMarkdown)
        for scan in scans { XCTAssertTrue(answer.answerMarkdown.contains(scan.cameraName), answer.answerMarkdown) }
        XCTAssertTrue(answer.answerMarkdown.lowercased().contains("крас"), answer.answerMarkdown)
        XCTAssertTrue(answer.answerMarkdown.lowercased().contains("велосип"), answer.answerMarkdown)
        XCTAssertFalse(answer.evidenceReferences.isEmpty)
        XCTAssertEqual(try store.loadACTAChatMessages(threadID: "default").count, 2)
        let followUp = await coordinator.askACTAChatAgent(question: "Какого цвета был автомобиль у входа и когда его заметили?", cameraNames: Dictionary(uniqueKeysWithValues: scans.map { ($0.cameraID, $0.cameraName) }))
        print("REAL_AGENT_FOLLOWUP sources=\(followUp.evidenceReferences.count) answer=\(followUp.answerMarkdown)")
        XCTAssertTrue(followUp.answerMarkdown.lowercased().contains("крас"), followUp.answerMarkdown)
        XCTAssertFalse(followUp.evidenceReferences.isEmpty)
    }

    private func fixture() throws -> (URL, LocalTrackingStore, [CameraScanRecord]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unified-agent-\(UUID())")
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(36000)
        let scans = [
            CameraScanRecord(cameraID: UUID(), cameraName: "Вход", observedAt: now.addingTimeInterval(-3 * 86400), answer: "A red car arrived at the entrance. The driver unloaded two boxes."),
            CameraScanRecord(cameraID: UUID(), cameraName: "Склад", observedAt: yesterday, answer: "A worker carried three cardboard boxes into the warehouse."),
            CameraScanRecord(cameraID: UUID(), cameraName: "Парковка", observedAt: now.addingTimeInterval(-1800), answer: "A cyclist parked a bicycle next to the fence.")]
        for scan in scans { try store.saveAutomaticScan(scan) }
        return (directory, store, scans)
    }
}
