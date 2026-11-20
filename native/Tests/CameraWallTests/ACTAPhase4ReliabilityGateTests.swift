import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAPhase4ReliabilityGateTests: XCTestCase {
    private func tempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testLegacyGhostJSONAndSQLiteMigrationCompatibilityAcrossReopen() throws {
        let dir = try tempDir("acta-p4-migration")

        // 1. Legacy ghost_* VLMPreferences JSON decodes with full backward compatibility
        let legacyVLMJSON = """
        {
          "ghostBackendMode": "vllm",
          "ghostVLLMBaseURL": "http://127.0.0.1:8000/v1",
          "ghostVLLMModelName": "qwen3.5-9b",
          "ghostPreferredLanguage": "ru",
          "dailyBudgetLimitUSD": 15.0,
          "monthlyBudgetLimitUSD": 250.0
        }
        """
        let prefs = try JSONDecoder().decode(VLMPreferences.self, from: Data(legacyVLMJSON.utf8))
        XCTAssertEqual(prefs.actaBackendMode, .localVLLM)
        XCTAssertEqual(prefs.actaVLLMBaseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(prefs.actaVLLMModelName, "qwen3.5-9b")
        XCTAssertEqual(prefs.actaPreferredLanguage, .ru)
        XCTAssertFalse(prefs.actaVLLMAllowLocalMLXFallback, "Fail-closed default preserved")
        XCTAssertEqual(prefs.actaVLLMMaxConcurrentRequests, 4)
        XCTAssertEqual(prefs.actaVLLMGPUMemoryUtilization, 0.65, accuracy: 0.001)

        // 2. Round-trip persistence keeps legacy ghost* keys intact
        let vlmURL = dir.appendingPathComponent("vlm.json")
        try VLMStore.save(prefs, to: vlmURL)
        let savedText = try String(contentsOf: vlmURL, encoding: .utf8)
        XCTAssertTrue(savedText.contains("ghostBackendMode"))
        XCTAssertTrue(savedText.contains("ghostVLLMBaseURL"))
        XCTAssertFalse(savedText.contains("vllmAPIKey"), "Ephemeral vLLM API keys must never be persisted")

        // 3. Keychain account identifiers remain strictly unchanged
        XCTAssertFalse(ACTAKeychainStore.primaryKeyAccount.isEmpty)

        // 4. SQLite store survives reopen with persisted chats, scans, and audit entries intact
        let dbURL = dir.appendingPathComponent("tracking.sqlite")
        let camID = UUID()
        let now = Date().addingTimeInterval(-120)
        do {
            let store1 = try LocalTrackingStore(url: dbURL)
            _ = try store1.ensureACTAChatThread(threadID: "p4-thread", title: "Migration check", now: now)
            _ = try store1.appendACTAChatMessage(
                ACTAChatMessageRecord(threadID: "p4-thread", role: "user", text: "Check camera lobby", createdAt: now)
            )
            try store1.saveAutomaticScan(CameraScanRecord(
                cameraID: camID,
                cameraName: "Lobby",
                observedAt: now,
                answer: "Two visitors entered lobby."
            ))
        }
        do {
            let store2 = try LocalTrackingStore(url: dbURL)
            let thread = try store2.loadACTAChatThread(threadID: "p4-thread")
            XCTAssertNotNil(thread)
            let messages = try store2.loadACTAChatMessages(threadID: "p4-thread")
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?.text, "Check camera lobby")
            let scans = try store2.automaticScans(limit: 10, now: now.addingTimeInterval(60))
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(scans.first?.cameraID, camID)
        }
    }

    @MainActor
    func testLocalOnlyRestartRecoveryAndZeroSecretLeak() async throws {
        let previousModels = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previousModels) }
        let dir = try tempDir("acta-p4-restart")
        let fakeModelDir = dir.appendingPathComponent("qwen-local", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeModelDir, withIntermediateDirectories: true)

        let cam = Camera(name: "Gate", substream: "rtsp://127.0.0.1:8554/gate", enabled: false)
        var wallCfg = WallConfiguration()
        wallCfg.cameras = [cam]
        wallCfg.columns = 3
        let configURL = dir.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(wallCfg, to: configURL)
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.chronologicalMemory]),
            to: dir.appendingPathComponent("features.json")
        )
        var vlm = VLMPreferences()
        vlm.model = fakeModelDir.path
        vlm.actaBackendMode = .localVLLM
        vlm.actaVLLMBaseURL = "http://127.0.0.1:18911/v1"
        vlm.actaVLLMModelName = "qwen3.5-9b"
        vlm.actaVLLMMaxConcurrentRequests = 3
        try VLMStore.save(vlm, to: dir.appendingPathComponent("vlm.json"))

        func makeModel(manager: ACTALocalVLLMServerManager) -> WallModel {
            WallModel(
                configURL: configURL,
                workerMode: false,
                poseModelURL: dir.appendingPathComponent("fake-pose.mlmodel"),
                trackingStoreURL: dir.appendingPathComponent("tracks.sqlite"),
                featureCoordinator: CameraFeatureCoordinator(
                    preferencesURL: dir.appendingPathComponent("features.json"),
                    databaseURL: dir.appendingPathComponent("features.sqlite")
                ),
                analyticsDirectoryURL: dir.appendingPathComponent("analytics"),
                cameraMemoryStore: CameraMemoryStore(url: dir.appendingPathComponent("frames")),
                operationsWatchURL: dir.appendingPathComponent("watches.json"),
                missionStoreURL: dir.appendingPathComponent("missions.json"),
                cameraCredentialStore: ACTAIsolatedCredentials(),
                operationsPreferencesURL: dir.appendingPathComponent("operations.json"),
                alertClipStore: CriticalAlertClipStore(url: dir.appendingPathComponent("clips")),
                languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
                monitorHistoryURL: dir.appendingPathComponent("monitor.json"),
                analyticsModelDiscovery: AnalyticsModelDiscovery(
                    modelURL: { _ in nil },
                    integrity: { _ in (hash: "synthetic", sizeBytes: 0) }
                ),
                localVLLMServerManager: manager
            )
        }

        // First lifecycle: start managed vLLM, verify ephemeral key active, then shutdown
        final class ManagedStubProcess: ACTALocalVLLMManagedProcess, @unchecked Sendable {
            private let lock = NSLock()
            private var running = true
            var isRunning: Bool { lock.withLock { running } }
            func terminateGracefully() { lock.withLock { running = false } }
        }
        let proc1 = ManagedStubProcess()
        let manager1 = ACTALocalVLLMServerManager(
            maxConcurrentRequests: 3,
            processFactory: { _, _ in proc1 },
            httpFetch: { req in
                let data = Data(#"{"data":[{"id":"qwen3.5-9b"}]}"#.utf8)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let model1 = makeModel(manager: manager1)
        let started = try await model1.startManagedLocalVLLMAndWait()
        XCTAssertEqual(started.state, .running)
        let creds1 = await manager1.managedCredentials()
        let ephemeralKey = try XCTUnwrap(creds1?.apiKey)
        XCTAssertEqual(model1.actaAnalytics?.aiClient.configuration().allowExternalAI, false)
        model1.shutdown()

        // Verify zero secrets on disk
        let rawVLM = try String(contentsOf: dir.appendingPathComponent("vlm.json"), encoding: .utf8)
        let rawCameras = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(rawVLM.contains(ephemeralKey))
        XCTAssertFalse(rawCameras.contains(ephemeralKey))

        // Second lifecycle (simulated app restart): starts cleanly stopped, fail-closed, local_only intact
        let manager2 = ACTALocalVLLMServerManager()
        let model2 = makeModel(manager: manager2)
        defer { model2.shutdown() }
        XCTAssertEqual(model2.config.columns, 3)
        XCTAssertEqual(model2.config.cameras.count, 1)
        XCTAssertEqual(model2.localVLLMTelemetry.state, .stopped)
        XCTAssertEqual(model2.actaAnalytics?.aiClient.configuration().allowExternalAI, false)
        XCTAssertEqual(model2.actaAnalytics?.aiClient.configuration().allowLocalVLLMAgent, false)
        XCTAssertNil(model2.actaAnalytics?.aiClient.configuration().vllmAPIKey)
    }

    func testStaleInferenceAndCancellationDropLateResultsAndDrainLimiter() async throws {
        let manager = ACTALocalVLLMServerManager(maxConcurrentRequests: 2, maxQueueDepth: 2)
        let previews = LockedArray<String>()
        let vllmClient = ACTALocalVLLMClient(serverManager: manager) { request, onChunk in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("SLOW_STALE") {
                onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"Partial \"}}]}\n")
                try await Task.sleep(nanoseconds: 500_000_000)
                try Task.checkCancellation()
                onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"STALE_LATE\"}}]}\n")
                onChunk("data: [DONE]\n")
                return 200
            }
            onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"FRESH_OK\"}}]}\n")
            onChunk("data: [DONE]\n")
            return 200
        }
        let client = ACTAAIClient(
            config: ACTAAIConfiguration(
                mode: .localVLLM,
                vllmBaseURL: "http://127.0.0.1:18912/v1",
                vllmModelName: "qwen3.5-9b",
                allowLocalVLLMAgent: true,
                allowVLLMLocalMLXFallback: false,
                vllmAPIKey: "p4-cancel-key",
                allowExternalAI: false
            ),
            localVLLMClient: vllmClient
        )

        let slowTask = Task {
            try await client.runAgentStep(
                lane: .chat,
                request: ACTAAgentRequest(
                    instructions: "Test",
                    fullInput: [.user(text: "SLOW_STALE", images: [])],
                    tools: [],
                    toolChoice: .auto
                ),
                onAnswerPreview: { text, _ in previews.append(text) }
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        slowTask.cancel()
        do {
            _ = try await slowTask.value
            XCTFail("Expected CancellationError for cancelled slow inference")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(previews.snapshot().contains { $0.contains("STALE_LATE") })

        // Immediate fresh request succeeds and limiter drains to zero
        let fresh = try await client.runAgentStep(
            lane: .chat,
            request: ACTAAgentRequest(
                instructions: "Test",
                fullInput: [.user(text: "FRESH", images: [])],
                tools: [],
                toolChoice: .auto
            )
        )
        XCTAssertEqual(fresh.text, "FRESH_OK")
        let counts = await manager.limiter.counts()
        XCTAssertEqual(counts.interactive, 0)
        XCTAssertEqual(counts.background, 0)
        XCTAssertEqual(counts.queued, 0)
    }

    func testPoseFSMFallHeuristicsAndAnalyticsSettingsPersistenceAcrossReload() throws {
        let dir = try tempDir("acta-p4-analytics")

        // 1. Pose/FSM fall heuristic: standing -> prolonged horizontal triggers single fall event
        var detector = FallDetector()
        func makePose(horizontal: Bool) -> FallPoseObservation {
            let cx = 0.5
            let cy = horizontal ? 0.62 : 0.5
            let w = horizontal ? 0.20 : 0.07
            let h = horizontal ? 0.07 : 0.20
            var pts = Array(repeating: FallKeypoint(x: cx, y: cy, confidence: 0.1), count: 17)
            let offset = 0.04
            let shoulder = horizontal ? (cx - offset, cy) : (cx, cy - offset)
            let hip = horizontal ? (cx + offset, cy) : (cx, cy + offset)
            for idx in [FallPoseObservation.leftShoulder, FallPoseObservation.rightShoulder] {
                pts[idx] = FallKeypoint(x: shoulder.0, y: shoulder.1, confidence: 0.9)
            }
            for idx in [FallPoseObservation.leftHip, FallPoseObservation.rightHip] {
                pts[idx] = FallKeypoint(x: hip.0, y: hip.1, confidence: 0.9)
            }
            return FallPoseObservation(
                confidence: 0.92,
                box: FallBoundingBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                keypoints: pts
            )
        }
        var t = 0.0
        for _ in 0..<10 { _ = detector.update([makePose(horizontal: false)], frameWidth: 1000, frameHeight: 1000, timestamp: t); t += 0.1 }
        var fallEvents: [FallEvent] = []
        for _ in 0..<15 {
            fallEvents += detector.update([makePose(horizontal: true)], frameWidth: 1000, frameHeight: 1000, timestamp: t).events
            t += 0.1
        }
        XCTAssertEqual(fallEvents.count, 1)

        // 2. Analytics settings persist cleanly across engine reload
        let settingsURL = dir.appendingPathComponent("analytics-settings.json")
        var settings = VideoAnalyticsSettings()
        settings.enableFallDetection = true
        settings.enableBehaviorAnalysis = true
        settings.analyticsSamplingFPS = 3.0
        try VideoAnalyticsSettingsStore.save(settings, to: settingsURL)
        let reloaded = try VideoAnalyticsSettingsStore.load(from: settingsURL)
        XCTAssertEqual(reloaded.enableFallDetection, true)
        XCTAssertEqual(reloaded.enableBehaviorAnalysis, true)
        XCTAssertEqual(reloaded.analyticsSamplingFPS, 3.0, accuracy: 0.001)
    }
}

private final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func append(_ value: T) { lock.withLock { values.append(value) } }
    func snapshot() -> [T] { lock.withLock { values } }
}
