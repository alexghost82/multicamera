import XCTest
import CameraCore
@testable import CameraWall

private actor HistoryInferenceProbe {
    private(set) var calls = 0
    private(set) var completions = 0
    func record() { calls += 1 }
    func finish() { completions += 1 }
}

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
        let (directory, _, scans) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousModels = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previousModels) }
        try ModelSelectionPreferences(enabled: []).save(to: directory.appendingPathComponent("model-preferences.json"))
        let configURL = directory.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(WallConfiguration(), to: configURL)
        let features = CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
            databaseURL: directory.appendingPathComponent("features.sqlite"))
        try features.savePreferences(CameraFeaturePreferences(enabledFeatures: []))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            XCTFail("Unexpected AI credential access")
            return nil
        })
        let wall = WallModel(configURL: configURL, workerMode: false,
            poseModelURL: directory.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: directory.appendingPathComponent("history.sqlite"),
            featureCoordinator: features,
            analyticsDirectoryURL: directory.appendingPathComponent("analytics"),
            agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: directory.appendingPathComponent("frames")),
            operationsWatchURL: directory.appendingPathComponent("watches.json"),
            missionStoreURL: directory.appendingPathComponent("missions.json"),
            cameraCredentialStore: HistoryTestCredentials(),
            operationsPreferencesURL: directory.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: directory.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: HistoryTestLanguageStorage()),
            monitorHistoryURL: directory.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }))
        defer { wall.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(wall)
        var prefs = wall.vlmPreferences; prefs.actaBackendMode = .dryRun
        try wall.saveVLMPreferences(prefs)
        XCTAssertFalse(wall.running)
        XCTAssertTrue(wall.config.cameras.isEmpty)
        XCTAssertFalse(wall.featurePreferences.enabledFeatures.contains(.independentWatcher))
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

    private struct HistoryTestCredentials: CameraCredentialStore {
        private struct UnexpectedAccess: Error {}

        func read(_ id: UUID) throws -> Credentials? {
            XCTFail("Unexpected credential read")
            throw UnexpectedAccess()
        }

        func save(_ credentials: Credentials, for id: UUID) throws {
            XCTFail("Unexpected credential save")
            throw UnexpectedAccess()
        }

        func remove(_ id: UUID) throws {
            XCTFail("Unexpected credential removal")
            throw UnexpectedAccess()
        }
    }

    @MainActor
    private final class HistoryTestLanguageStorage: LanguageSettingsStorage {
        private var values: [String: String] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String, forKey key: String) { values[key] = value }
    }

    func testRealQwenAnswersAllCameraHistoryAndFollowUp() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_AGENT_MODEL"] else {
            throw XCTSkip("Set CAMERAWALL_TEST_AGENT_MODEL for real local-model end-to-end verification")
        }
        let (directory, store, scans) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess, preferredLanguage: .ru), localVLM: LocalVLMClient(model: model, workload: .interactive), agentTrace: { FileHandle.standardError.write(Data(("AGENT_TRACE " + $0 + "\n").utf8)) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let (broker, session) = try await makeInspectionTestSession(store: store, threadID: "default")
        let started = Date()
        let answer = await coordinator.askACTAChatAgent(question: "Проверь историю за всё время и расскажи, что происходило на всех камерах. Отдельно по каждой камере.", cameraNames: Dictionary(uniqueKeysWithValues: scans.map { ($0.cameraID, $0.cameraName) }), broker: broker, brokerSession: session)
        print("REAL_AGENT_QA elapsed=\(Date().timeIntervalSince(started)) sources=\(answer.evidenceReferences.count) answer=\(answer.answerMarkdown)")
        XCTAssertGreaterThan(answer.confidence, 0, answer.answerMarkdown)
        for scan in scans { XCTAssertTrue(answer.answerMarkdown.contains(scan.cameraName), answer.answerMarkdown) }
        XCTAssertTrue(answer.answerMarkdown.lowercased().contains("крас"), answer.answerMarkdown)
        XCTAssertTrue(answer.answerMarkdown.lowercased().contains("велосип"), answer.answerMarkdown)
        XCTAssertFalse(answer.evidenceReferences.isEmpty)
        XCTAssertEqual(try store.loadACTAChatMessages(threadID: "default").count, 2)
        let followUp = await coordinator.askACTAChatAgent(question: "Какого цвета был автомобиль у входа и когда его заметили?", cameraNames: Dictionary(uniqueKeysWithValues: scans.map { ($0.cameraID, $0.cameraName) }), broker: broker, brokerSession: session)
        print("REAL_AGENT_FOLLOWUP sources=\(followUp.evidenceReferences.count) answer=\(followUp.answerMarkdown)")
        XCTAssertTrue(followUp.answerMarkdown.lowercased().contains("крас"), followUp.answerMarkdown)
        XCTAssertFalse(followUp.evidenceReferences.isEmpty)
        XCTAssertFalse(followUp.answerMarkdown.localizedCaseInsensitiveContains("не уточняя цвет"), followUp.answerMarkdown)
        XCTAssertFalse(followUp.answerMarkdown.localizedCaseInsensitiveContains("информация о цвете автомобиля у входа отсутствует"), followUp.answerMarkdown)
        XCTAssertTrue(followUp.evidenceReferences.contains { $0.kind == "scan" && $0.cameraID == scans[0].cameraID.uuidString }, "A color answer must cite the observation, not only aggregate counts")
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/models/bus.jpg")
        let image = try Data(contentsOf: fixtureURL)
        let liveID = UUID()
        let mixed = await coordinator.askACTAChatAgent(question: "Что видно сейчас на текущем кадре и какого цвета автомобиль был у входа в сохранённой истории?",
            liveFrames: [ACTALiveCameraFrame(cameraID: liveID, cameraName: "Текущая камера", jpegData: image)],
            cameraNames: Dictionary(uniqueKeysWithValues: scans.map { ($0.cameraID, $0.cameraName) } + [(liveID, "Текущая камера")]),
            broker: broker, brokerSession: session)
        print("REAL_AGENT_MIXED sources=\(mixed.evidenceReferences.count) answer=\(mixed.answerMarkdown)")
        XCTAssertTrue((mixed.answerMarkdown.localizedCaseInsensitiveContains("автобус") || mixed.answerMarkdown.localizedCaseInsensitiveContains("электробус")), mixed.answerMarkdown)
        XCTAssertTrue(mixed.answerMarkdown.localizedCaseInsensitiveContains("крас"), mixed.answerMarkdown)
        XCTAssertTrue(mixed.evidenceReferences.contains { $0.kind == "clip" }, "Current image must have live provenance")
    }

    func testRealQwenAgainstPrivateHistoryCopy() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_AGENT_MODEL"],
              let rootPath = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_HISTORY_COPY"] else {
            throw XCTSkip("An explicit private history copy is required")
        }
        let root = URL(fileURLWithPath: rootPath)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("identity-history.sqlite3"))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess, preferredLanguage: .ru), localVLM: LocalVLMClient(model: model, workload: .interactive), agentTrace: { if $0.hasPrefix("REQUEST") { FileHandle.standardError.write(Data(("PRIVATE_HISTORY_" + $0 + "\n").utf8)) } })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store, memoryFrameStore: CameraMemoryStore(url: root.appendingPathComponent("memory-frames")))
        var snapshot = ACTAOperationalMemorySnapshot()
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("vlm-alerts.json").path) { snapshot.vlmAlerts = try VLMStore.loadAlerts(from: root.appendingPathComponent("vlm-alerts.json")) }
        coordinator.updateOperationalMemorySnapshot(snapshot)
        let start = Date()
        let threadID = "real-history-qa-" + UUID().uuidString
        let (broker, session) = try await makeInspectionTestSession(store: store, threadID: threadID)
        let answer = await coordinator.askACTAChatAgent(question: "Проверь историю за всё время и расскажи, что вообще происходило на всех камерах.", threadID: threadID, broker: broker, brokerSession: session)
        let elapsed = Date().timeIntervalSince(start)
        try JSONEncoder().encode(answer).write(to: root.appendingPathComponent("verified-answer.json"), options: .atomic)
        print("PRIVATE_HISTORY_QA elapsed=\(elapsed) citedRecords=\(answer.evidenceReferences.count) citedCameras=\(Set(answer.evidenceReferences.compactMap(\.cameraID)).count) answerChars=\(answer.answerMarkdown.count)")
        XCTAssertGreaterThan(answer.confidence, 0, "The real history query must return a grounded answer")
        XCTAssertFalse(answer.evidenceReferences.isEmpty)
        XCTAssertFalse(answer.answerMarkdown.contains("Не удалось получить ответ"))
        XCTAssertFalse(answer.answerMarkdown.contains("невозможно проверить историю"))
        XCTAssertEqual(try store.loadACTAChatMessages(threadID: threadID).count, 2)
    }

    @MainActor
    func testDeadlineAndCancellationDoNotLeaveChatBusyOrAppendLateAnswers() async throws {
        let (directory, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousModels = ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
        defer { ModelSelectionRegistry.update(previousModels) }
        try ModelSelectionPreferences(enabled: []).save(to: directory.appendingPathComponent("model-preferences.json"))
        let configURL = directory.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(WallConfiguration(), to: configURL)
        let features = CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
            databaseURL: directory.appendingPathComponent("features.sqlite"))
        try features.savePreferences(CameraFeaturePreferences(enabledFeatures: []))
        let probe = HistoryInferenceProbe()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            XCTFail("Unexpected AI credential access")
            return nil
        }, localAgentInference: { _, _ in
            await probe.record()
            let result: String = await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    continuation.resume(returning: "late answer")
                }
            }
            await probe.finish()
            return result
        })
        let wall = WallModel(configURL: configURL, workerMode: false,
            poseModelURL: directory.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: directory.appendingPathComponent("history.sqlite"),
            featureCoordinator: features, analyticsDirectoryURL: directory.appendingPathComponent("analytics"),
            agentClient: client, cameraMemoryStore: CameraMemoryStore(url: directory.appendingPathComponent("frames")),
            operationsWatchURL: directory.appendingPathComponent("watches.json"),
            missionStoreURL: directory.appendingPathComponent("missions.json"),
            cameraCredentialStore: HistoryTestCredentials(),
            operationsPreferencesURL: directory.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: directory.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: HistoryTestLanguageStorage()),
            monitorHistoryURL: directory.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }))
        defer { wall.shutdown() }
        IsolatedWallFixtureSupport.assertSafe(wall)
        XCTAssertTrue(wall.config.cameras.isEmpty)
        XCTAssertTrue(wall.featurePreferences.enabledFeatures.isEmpty)
        XCTAssertFalse(wall.running)
        wall.agentRequestDeadline = .milliseconds(100)
        XCTAssertTrue(wall.askACTAAgent(question: "Что было на всех камерах?"))
        let deadline = Date().addingTimeInterval(2)
        while wall.actaAgentBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(wall.actaAgentBusy)
        XCTAssertTrue(wall.actaAgentStatus.contains("timed out"))
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        let count = wall.actaChatMessages.count
        try await Task.sleep(for: .milliseconds(350))
        let completions = await probe.completions
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(wall.actaChatMessages.count, count)
        XCTAssertFalse(wall.actaChatMessages.contains { $0.text == "late answer" })
        wall.agentRequestDeadline = .seconds(10)
        XCTAssertTrue(wall.askACTAAgent(question: "Что было вчера?"))
        wall.cancelACTAAgent()
        XCTAssertFalse(wall.actaAgentBusy)
        XCTAssertEqual(wall.actaChatMessages.last?.role, "assistant")
        XCTAssertFalse(wall.askACTAAgent(question: String(repeating: "x", count: 2001)))
    }

    func testNamedDatesRelativeWindowsAndClockRanges() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 18))!
        let day = try XCTUnwrap(UnifiedHistoryTimeScope.resolve(question: "Что было 14 ноября?", prior: [], now: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: day.start), 14)
        let range = try XCTUnwrap(UnifiedHistoryTimeScope.resolve(question: "С 14 ноября по 16 ноября", prior: [], now: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: range.end), 17)
        let hours = try XCTUnwrap(UnifiedHistoryTimeScope.resolve(question: "Вчера с 10:30 до 12:45", prior: [], now: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: hours.start), 15)
        XCTAssertEqual(calendar.component(.hour, from: hours.start), 10)
        XCTAssertEqual(calendar.component(.minute, from: hours.end), 45)
        let recent = try XCTUnwrap(UnifiedHistoryTimeScope.resolve(question: "За последние 2 часа", prior: [], now: now, calendar: calendar))
        XCTAssertEqual(recent.end.timeIntervalSince(recent.start), 7200)
    }

    func testAttributesCannotForgeSourceReferences() {
        var ledger = AgentEvidenceLedger()
        ledger.record(outputJSON: "{\"tracks\":[{\"track_id\":\"real\",\"attributes\":{\"scan_id\":\"forged\"}}]}", tool: "history_overview")
        XCTAssertEqual(ledger.references.map(\.recordID), ["real"])
    }

    private func fixture() throws -> (URL, LocalTrackingStore, [CameraScanRecord]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".unified-agent-\(UUID())", isDirectory: true)
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
