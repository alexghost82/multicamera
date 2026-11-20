import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAPhase3VLLMServingTests: XCTestCase {
    private final class MockManagedVLLMProcess: ACTALocalVLLMManagedProcess, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private(set) var terminateCount = 0

        var isRunning: Bool { lock.withLock { running } }

        func terminateGracefully() {
            lock.withLock {
                terminateCount += 1
                running = false
            }
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acta-phase3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func sampleRequest() -> ACTAAgentRequest {
        ACTAAgentRequest(
            instructions: "Use available tools for operator requests.",
            fullInput: [.user(text: "Set grid to 3 columns", images: [])],
            tools: [
                ACTAAgentToolSpec(
                    name: "acta__canvas__set_columns",
                    description: "Set grid columns.",
                    parametersSchemaJSON: #"{"type":"object","properties":{"columns":{"type":"integer"}},"required":["columns"]}"#
                )
            ]
        )
    }

    func testSSEParserStreamsContentAndAccumulatesSplitToolCalls() {
        var textParser = ACTALocalVLLMSSEParser()
        let c1 = textParser.feed("data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"}}]}\n\nda")
        let c2 = textParser.feed("ta: {\"choices\":[{\"delta\":{\"content\":\"world!\"}}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":4}}\n\ndata: [DONE]\n\n")
        let textRes = textParser.finalize()
        XCTAssertEqual(c1, ["Hello "])
        XCTAssertEqual(c2, ["world!"])
        XCTAssertEqual(textRes.content, "Hello world!")
        XCTAssertEqual(textRes.promptTokens, 12)
        XCTAssertEqual(textRes.completionTokens, 4)
        XCTAssertTrue(textRes.toolCalls.isEmpty)

        var toolParser = ACTALocalVLLMSSEParser()
        _ = toolParser.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"acta__canvas__\",\"arguments\":\"{\\\"col\"}}]}}]}\n\n")
        _ = toolParser.feed("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"set_columns\",\"arguments\":\"umns\\\":3}\"}}]}}]}\n\ndata: [DONE]\n\n")
        let toolRes = toolParser.finalize()
        XCTAssertEqual(toolRes.toolCalls.count, 1)
        XCTAssertEqual(toolRes.toolCalls.first?.callID, "call_1")
        XCTAssertEqual(toolRes.toolCalls.first?.name, "acta__canvas__set_columns")
        XCTAssertEqual(toolRes.toolCalls.first?.arguments["columns"], "3")
    }

    func testLocalVLLMClientStreamsPreviewParsesNativeToolCallsAndRecordsTelemetry() async throws {
        let manager = ACTALocalVLLMServerManager(maxConcurrentRequests: 4)
        let capturedAuth = LockedBox<String?>(nil)
        let capturedPreviews = LockedBox<[String]>([])

        let client = ACTALocalVLLMClient(serverManager: manager) { request, onChunk in
            capturedAuth.set(request.value(forHTTPHeaderField: "Authorization"))
            onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"Checking \"}}]}\n\n")
            onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"cameras.\"}}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":8}}\n\n")
            onChunk("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"tc_42\",\"function\":{\"name\":\"acta__canvas__set_columns\",\"arguments\":\"{\\\"columns\\\":3}\"}}]}}]}\n\n")
            onChunk("data: [DONE]\n\n")
            return 200
        }

        // 1. Non-loopback endpoint rejected before transport
        do {
            _ = try await client.runAgentStep(
                baseURL: "https://remote.example.invalid/v1",
                modelName: "qwen3.5-9b",
                apiKey: "secret-token",
                request: sampleRequest()
            )
            XCTFail("Expected non-loopback endpoint rejection")
        } catch let err as ACTALocalVLLMError {
            XCTAssertEqual(err, .invalidLoopbackEndpoint)
        }

        // 2. Loopback request streams prose preview, parses native tool_calls, sends Bearer token, updates telemetry
        let result = try await client.runAgentStep(
            baseURL: "http://127.0.0.1:18735/v1",
            modelName: "qwen3.5-9b",
            apiKey: "ephemeral-secret-token",
            request: sampleRequest(),
            onAnswerPreview: { text, _ in
                capturedPreviews.modify { $0.append(text) }
            }
        )
        XCTAssertEqual(capturedAuth.get(), "Bearer ephemeral-secret-token")
        XCTAssertEqual(result.backend, .vllm)
        XCTAssertEqual(result.functionCalls.count, 1)
        XCTAssertEqual(result.functionCalls.first?.name, "acta__canvas__set_columns")
        XCTAssertEqual(result.functionCalls.first?.arguments["columns"], "3")
        XCTAssertEqual(capturedPreviews.get(), ["Checking", "Checking cameras."])

        let telemetry = await manager.telemetrySnapshot()
        XCTAssertNotNil(telemetry.lastTTFTMs)
        XCTAssertNotNil(telemetry.lastTokensPerSecond)
        XCTAssertNotNil(telemetry.p50LatencyMs)
        XCTAssertNotNil(telemetry.p95LatencyMs)
    }

    func testBoundedConcurrencyPrioritizesInteractiveAndShedsBackgroundBackpressure() async throws {
        // Total = 3, reservedInteractive = 1 => maxBackground = 2, maxQueueDepth = 1
        let limiter = ACTALocalVLLMLaneLimiter(maxTotalConcurrency: 3, reservedInteractiveSlots: 1, maxQueueDepth: 1)
        let gate1 = AsyncGate()
        let gate2 = AsyncGate()

        let bg1 = Task {
            try await limiter.withPermit(priority: .background) {
                await gate1.markEnteredAndWait()
                return "bg1"
            }
        }
        let bg2 = Task {
            try await limiter.withPermit(priority: .background) {
                await gate2.markEnteredAndWait()
                return "bg2"
            }
        }
        await gate1.waitUntilEntered()
        await gate2.waitUntilEntered()

        // Interactive request MUST run immediately using the reserved interactive slot while background is saturated
        let interactiveResult = try await limiter.withPermit(priority: .interactive) {
            "interactive-ok"
        }
        XCTAssertEqual(interactiveResult, "interactive-ok")

        // Queue 1 background waiter (hits maxQueueDepth == 1)
        let queuedBG = Task {
            try await limiter.withPermit(priority: .background) { "bg-queued" }
        }
        try await Task.sleep(for: .milliseconds(30))
        let countsBeforeShed = await limiter.counts()
        XCTAssertEqual(countsBeforeShed.background, 2)
        XCTAssertEqual(countsBeforeShed.queued, 1)

        // Next overflowing background request is shed immediately with .backpressureRejected
        do {
            _ = try await limiter.withPermit(priority: .background) { "should-shed" }
            XCTFail("Expected backpressure rejection")
        } catch let err as ACTALocalVLLMError {
            XCTAssertEqual(err, .backpressureRejected)
        }

        // Cancelling the queued waiter unblocks cleanly with CancellationError
        queuedBG.cancel()
        do {
            _ = try await queuedBG.value
            XCTFail("Expected queued background waiter cancellation")
        } catch is CancellationError {}

        await gate1.release()
        await gate2.release()
        let bg1Val = try await bg1.value
        let bg2Val = try await bg2.value
        XCTAssertEqual(bg1Val, "bg1")
        XCTAssertEqual(bg2Val, "bg2")
    }

    func testMidStreamCancellationAbortsAndRecoversCleanly() async throws {
        let manager = ACTALocalVLLMServerManager(maxConcurrentRequests: 2)
        let gate = AsyncGate()
        let previews = LockedBox<[String]>([])
        let callCount = LockedBox<Int>(0)

        let client = ACTALocalVLLMClient(serverManager: manager) { _, onChunk in
            let n = callCount.modifyAndReturn { $0 += 1; return $0 }
            if n == 1 {
                onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"Part 1 \"}}]}\n\n")
                await gate.markEnteredAndWait()
                try Task.checkCancellation()
                onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"Late chunk\"}}]}\n\n")
                return 200
            } else {
                onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"RECOVERED\"}}]}\n\ndata: [DONE]\n\n")
                return 200
            }
        }

        let task = Task {
            try await client.runAgentStep(
                baseURL: "http://127.0.0.1:18735/v1",
                modelName: "qwen3.5-9b",
                apiKey: nil,
                request: sampleRequest(),
                onAnswerPreview: { text, _ in previews.modify { $0.append(text) } }
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        XCTAssertFalse(previews.get().contains { $0.contains("Late chunk") })

        // Follow-up request succeeds immediately after cancellation
        let recovered = try await client.runAgentStep(
            baseURL: "http://127.0.0.1:18735/v1",
            modelName: "qwen3.5-9b",
            apiKey: nil,
            request: sampleRequest()
        )
        XCTAssertEqual(recovered.text, "RECOVERED")
    }

    func testManagedServerLifecycleHealthModelMismatchAndBearerAuth() async throws {
        let dir = try tempDir()
        let fakeModelDir = dir.appendingPathComponent("qwen3.5-9b", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeModelDir, withIntermediateDirectories: true)

        let process = MockManagedVLLMProcess()
        let loadedModels = LockedBox<[String]>(["qwen3.5-9b"])
        let seenAuthHeaders = LockedBox<[String]>([])

        let manager = ACTALocalVLLMServerManager(
            maxConcurrentRequests: 4,
            processFactory: { _, _ in process },
            httpFetch: { request in
                if let auth = request.value(forHTTPHeaderField: "Authorization") {
                    seenAuthHeaders.modify { $0.append(auth) }
                }
                let models = loadedModels.get().map { ["id": $0] }
                let data = try JSONSerialization.data(withJSONObject: ["data": models])
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            }
        )

        let launch = ACTALocalVLLMLaunchConfig(
            modelPath: fakeModelDir.path,
            servedModelName: "qwen3.5-9b",
            port: 18736,
            maxModelLen: 8192,
            maxNumSeqs: 4,
            gpuMemoryUtilization: 0.65
        )
        let started = try await manager.start(config: launch, readinessTimeoutSeconds: 5)
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.loadedModel, "qwen3.5-9b")

        let creds = await manager.managedCredentials()
        XCTAssertEqual(creds?.baseURL, "http://127.0.0.1:18736/v1")
        XCTAssertEqual(creds?.modelName, "qwen3.5-9b")
        XCTAssertTrue(creds?.apiKey.hasPrefix("acta-local-") == true)
        XCTAssertTrue(seenAuthHeaders.get().contains("Bearer \(creds?.apiKey ?? "")"))

        // Mismatched model fails health check cleanly
        loadedModels.set(["some-other-model"])
        do {
            _ = try await manager.checkHealth(baseURL: launch.loopbackBaseURL, expectedModel: "qwen3.5-9b")
            XCTFail("Expected modelMismatch")
        } catch let err as ACTALocalVLLMError {
            XCTAssertEqual(err, .modelMismatch(expected: "qwen3.5-9b", loaded: ["some-other-model"]))
        }

        // Stop terminates child gracefully and clears credentials
        await manager.stop()
        XCTAssertEqual(process.terminateCount, 1)
        let afterStopCreds = await manager.managedCredentials()
        XCTAssertNil(afterStopCreds)
        let stopped = await manager.telemetrySnapshot()
        XCTAssertEqual(stopped.state, .stopped)
    }

    func testACTAAIClientLocalVLLMRoutingFailClosedAndOptInLocalMLXFallbackNeverCloud() async throws {
        let traces = LockedBox<[String]>([])
        let cloudCalled = LockedBox<Bool>(false)
        let mlxCalled = LockedBox<Int>(0)
        let secretToken = "acta-local-secret-do-not-trace"

        let failingVLLM = ACTALocalVLLMClient { _, _ in
            throw ACTALocalVLLMError.serverUnavailable("Simulated vLLM down")
        }

        let client = ACTAAIClient(
            config: ACTAAIConfiguration(
                mode: .localVLLM,
                vllmBaseURL: "http://127.0.0.1:18735/v1",
                vllmModelName: "qwen3.5-9b",
                allowLocalVLLMAgent: false,
                allowVLLMLocalMLXFallback: false,
                vllmAPIKey: secretToken,
                allowExternalAI: true
            ),
            localVLLMClient: failingVLLM,
            transport: { request in
                cloudCalled.set(true)
                throw URLError(.notConnectedToInternet)
            },
            keyProvider: { _ in XCTFail("Agent must never access cloud Keychain"); return nil },
            agentTrace: { entry in traces.modify { $0.append(entry) } },
            localAgentInference: { _, _ in
                mlxCalled.modify { $0 += 1 }
                return #"{"answerMarkdown":"Fallback MLX local answer","confidence":0.8}"#
            }
        )

        // 1. Unverified loopback (allowLocalVLLMAgent == false) fails closed immediately
        do {
            _ = try await client.runAgentStep(request: sampleRequest())
            XCTFail("Expected noBackendAvailable when allowLocalVLLMAgent is false")
        } catch let err as ACTAAgentError {
            XCTAssertEqual(err, .noBackendAvailable)
        }
        XCTAssertEqual(mlxCalled.get(), 0)
        XCTAssertFalse(cloudCalled.get())

        // 2. Authorized loopback + fail-closed default (allowVLLMLocalMLXFallback == false) throws vLLM error, no MLX/cloud fallback
        client.updateConfiguration(ACTAAIConfiguration(
            mode: .localVLLM,
            vllmBaseURL: "http://127.0.0.1:18735/v1",
            vllmModelName: "qwen3.5-9b",
            allowLocalVLLMAgent: true,
            allowVLLMLocalMLXFallback: false,
            vllmAPIKey: secretToken,
            allowExternalAI: true
        ))
        do {
            _ = try await client.runAgentStep(request: sampleRequest())
            XCTFail("Expected fail-closed vLLM error")
        } catch let err as ACTALocalVLLMError {
            XCTAssertEqual(err, .serverUnavailable("Simulated vLLM down"))
        }
        XCTAssertEqual(mlxCalled.get(), 0)
        XCTAssertFalse(cloudCalled.get())

        // 3. Opt-in local MLX fallback succeeds ONLY locally on MLX, NEVER calling cloud
        client.updateConfiguration(ACTAAIConfiguration(
            mode: .localVLLM,
            vllmBaseURL: "http://127.0.0.1:18735/v1",
            vllmModelName: "qwen3.5-9b",
            allowLocalVLLMAgent: true,
            allowVLLMLocalMLXFallback: true,
            vllmAPIKey: secretToken,
            allowExternalAI: true
        ))
        let fallbackResult = try await client.runAgentStep(request: sampleRequest())
        XCTAssertEqual(fallbackResult.backend, .mlx)
        XCTAssertEqual(mlxCalled.get(), 1)
        XCTAssertFalse(cloudCalled.get())

        // 4. Trace never leaks ephemeral bearer token
        XCTAssertFalse(traces.get().contains { $0.contains(secretToken) })
    }

    func testVLMPreferencesBackwardCompatibleDecodingAndValidation() throws {
        let legacyJSON = """
        {
          "ghostBackendMode": "vllm",
          "ghostVLLMBaseURL": "http://127.0.0.1:8000/v1",
          "ghostVLLMModelName": "qwen3.5-9b"
        }
        """
        let decoded = try JSONDecoder().decode(VLMPreferences.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.actaBackendMode, .localVLLM)
        XCTAssertEqual(decoded.actaVLLMBaseURL, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(decoded.actaVLLMModelName, "qwen3.5-9b")
        XCTAssertFalse(decoded.actaVLLMAllowLocalMLXFallback)
        XCTAssertEqual(decoded.actaVLLMMaxConcurrentRequests, 4)
        XCTAssertEqual(decoded.actaVLLMGPUMemoryUtilization, 0.65, accuracy: 0.001)
        XCTAssertNoThrow(try decoded.validate())

        var invalid = decoded
        invalid.actaVLLMMaxConcurrentRequests = 32
        XCTAssertThrowsError(try invalid.validate())

        var invalidMem = decoded
        invalidMem.actaVLLMGPUMemoryUtilization = 0.99
        XCTAssertThrowsError(try invalidMem.validate())
    }

    // MARK: - Wave 3C Closure Tests

    @MainActor
    private func makeIsolatedWave3CModel(
        dir: URL,
        serverManager: ACTALocalVLLMServerManager,
        agentClient: ACTAAIClient? = nil
    ) throws -> WallModel {
        let cam = Camera(name: "Lobby", substream: "rtsp://127.0.0.1:8554/lobby", enabled: false)
        var config = WallConfiguration()
        config.cameras = [cam]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.chronologicalMemory, .crossCameraIdentity, .scheduledMissions, .operationalAlerts]),
            to: dir.appendingPathComponent("features.json")
        )
        var ai = VLMPreferences()
        let fakeModelDir = dir.appendingPathComponent("qwen-local-model", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeModelDir, withIntermediateDirectories: true)
        ai.model = fakeModelDir.path
        ai.actaBackendMode = .localVLLM
        ai.actaVLLMBaseURL = "http://127.0.0.1:18831/v1"
        ai.actaVLLMModelName = "qwen3.5-9b"
        ai.actaVLLMMaxConcurrentRequests = 4
        ai.actaVLLMAllowLocalMLXFallback = false
        ai.actaVLLMGPUMemoryUtilization = 0.65
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
        let model = WallModel(
            configURL: dir.appendingPathComponent("cameras.json"),
            workerMode: false,
            poseModelURL: dir.appendingPathComponent("fake-pose.mlmodel"),
            trackingStoreURL: dir.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(
                preferencesURL: dir.appendingPathComponent("features.json"),
                databaseURL: dir.appendingPathComponent("features.sqlite")
            ),
            analyticsDirectoryURL: dir.appendingPathComponent("analytics"),
            agentClient: agentClient,
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
            localVLLMServerManager: serverManager
        )
        addTeardownBlock { Task { @MainActor in model.shutdown() } }
        return model
    }

    func testRuntimeConfigPreservesManagedVLLMKeyAcrossSettingsSavesAndBrokerActions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-w3c-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeProc = MockManagedVLLMProcess()
        let manager = ACTALocalVLLMServerManager(
            maxConcurrentRequests: 4,
            processFactory: { _, _ in fakeProc },
            httpFetch: { request in
                let body = Data(#"{"data":[{"id":"qwen3.5-9b"}]}"#.utf8)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, resp)
            }
        )
        let model = try await makeIsolatedWave3CModel(dir: dir, serverManager: manager)

        let started = try await model.startManagedLocalVLLMAndWait()
        XCTAssertEqual(started.state, .running)

        let creds = await manager.managedCredentials()
        let apiKey = try XCTUnwrap(creds?.apiKey)
        let configAfterStart = await MainActor.run { model.actaAnalytics?.aiClient.configuration() }
        XCTAssertEqual(configAfterStart?.allowLocalVLLMAgent, true)
        XCTAssertEqual(configAfterStart?.vllmAPIKey, apiKey)

        // Saving VLM preferences must NOT wipe managedVLLMAPIKey or allowLocalVLLMAgent
        try await MainActor.run {
            var next = model.vlmPreferences
            next.actaVLLMMaxConcurrentRequests = 6
            try model.saveVLMPreferences(next)
        }
        let configAfterSave = await MainActor.run { model.actaAnalytics?.aiClient.configuration() }
        XCTAssertEqual(configAfterSave?.allowLocalVLLMAgent, true)
        XCTAssertEqual(configAfterSave?.vllmAPIKey, apiKey)

        // WallAIConfigAction and WallAIBudgetAction must succeed while managed vLLM is running
        let configAction = WallAIConfigAction(model: model)
        let confirmed = ACTAActionContext(initiator: "test", isConfirmed: true)
        let langResult = try await configAction.execute(parameters: ["language": "en"], context: confirmed)
        XCTAssertTrue(langResult.success, langResult.error ?? "expected success")
        let langVerified = try await configAction.verify(parameters: ["language": "en"], context: confirmed)
        XCTAssertTrue(langVerified)

        let budgetAction = WallAIBudgetAction(model: model)
        let budgetResult = try await budgetAction.execute(parameters: ["dailyBudgetUSD": "12.5"], context: confirmed)
        XCTAssertTrue(budgetResult.success, budgetResult.error ?? "expected success")
        let budgetVerified = try await budgetAction.verify(parameters: ["dailyBudgetUSD": "12.5"], context: confirmed)
        XCTAssertTrue(budgetVerified)

        let configAfterActions = await MainActor.run { model.actaAnalytics?.aiClient.configuration() }
        XCTAssertEqual(configAfterActions?.allowLocalVLLMAgent, true)
        XCTAssertEqual(configAfterActions?.vllmAPIKey, apiKey)
    }

    func testBackgroundCallLocalVLLMUsesLaneLimiterPriorityAndOptInLocalMLXFallback() async throws {
        struct SimpleAnswer: Codable, Sendable, Equatable {
            let status: String
        }

        let manager = ACTALocalVLLMServerManager(maxConcurrentRequests: 4, maxQueueDepth: 2)
        let limiter = await manager.limiter
        let vllmClient = ACTALocalVLLMClient(serverManager: manager)

        let bgGate = AsyncGate()
        let transportCalls = LockedBox<[String]>([])
        let shouldFailVLLM = LockedBox<Bool>(false)

        let client = ACTAAIClient(
            config: ACTAAIConfiguration(
                mode: .localVLLM,
                vllmBaseURL: "http://127.0.0.1:18832/v1",
                vllmModelName: "qwen3.5-9b",
                allowLocalVLLMAgent: true,
                allowVLLMLocalMLXFallback: false,
                vllmAPIKey: "ephemeral-wave3c-key",
                allowExternalAI: true
            ),
            localVLLMClient: vllmClient,
            transport: { request in
                let urlStr = request.url?.absoluteString ?? ""
                transportCalls.modify { $0.append(urlStr) }
                if urlStr.contains("openai") {
                    XCTFail("Local vLLM mode must never call OpenAI/cloud transport")
                }
                if shouldFailVLLM.get() {
                    throw URLError(.cannotConnectToHost)
                }
                let bodyText = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if bodyText.contains("HOLD_BG") {
                    await bgGate.markEnteredAndWait()
                }
                let json = #"{"choices":[{"message":{"content":"{\"status\":\"ok\"}"}}]}"#
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(json.utf8), resp)
            },
            keyProvider: { _ in XCTFail("Local vLLM must never read cloud Keychain"); return nil }
        )

        // Dynamically lower concurrency to 2 (1 background + 1 reserved interactive)
        await client.updateLocalVLLMMaxConcurrency(2)
        let updatedMax = await limiter.maxTotalConcurrency
        let updatedBgMax = await limiter.maxBackgroundConcurrency
        XCTAssertEqual(updatedMax, 2)
        XCTAssertEqual(updatedBgMax, 1)

        // Occupy the single background slot
        let bgTask = Task {
            await client.generateStructured(
                lane: .background,
                tier: .nano,
                prompt: "HOLD_BG",
                useContentCache: false,
                responseType: SimpleAnswer.self,
                fallbackFactory: { SimpleAnswer(status: "fallback") }
            )
        }
        await bgGate.waitUntilEntered()

        // Interactive chat request still succeeds immediately via reserved interactive slot
        let chatAnswer = await client.generateStructured(
            lane: .chat,
            tier: .mini,
            prompt: "FAST_CHAT",
            useContentCache: false,
            responseType: SimpleAnswer.self,
            fallbackFactory: { SimpleAnswer(status: "fallback") }
        )
        XCTAssertEqual(chatAnswer, SimpleAnswer(status: "ok"))

        await bgGate.release()
        let bgAnswer = await bgTask.value
        XCTAssertEqual(bgAnswer, SimpleAnswer(status: "ok"))

        // Fail-closed when vLLM fails (returns structured fallbackFactory, never calls OpenAI)
        shouldFailVLLM.set(true)
        let failureFlag = LockedBox<Bool>(false)
        let failed = await client.generateStructured(
            lane: .chat,
            tier: .mini,
            prompt: "FAIL_CLOSED_TEST",
            useContentCache: false,
            onFailureFallback: { failureFlag.set(true) },
            responseType: SimpleAnswer.self,
            fallbackFactory: { SimpleAnswer(status: "safe-fallback") }
        )
        XCTAssertEqual(failed, SimpleAnswer(status: "safe-fallback"))
        XCTAssertTrue(failureFlag.get())
        XCTAssertTrue(transportCalls.get().allSatisfy { $0.contains("127.0.0.1:18832") })
    }

    func testPhase3VLLMBrokerActionsParityAndControlLifecycle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-w3c-broker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeProc = MockManagedVLLMProcess()
        let manager = ACTALocalVLLMServerManager(
            maxConcurrentRequests: 4,
            processFactory: { _, _ in fakeProc },
            httpFetch: { request in
                let body = Data(#"{"data":[{"id":"qwen3.5-9b"}]}"#.utf8)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, resp)
            }
        )
        let model = try await makeIsolatedWave3CModel(dir: dir, serverManager: manager)
        let actions = await MainActor.run { model.buildProductionBrokerActions() }
        let targetIDs: Set<String> = ["settings.get_vllm_status", "settings.update_vllm_serving", "settings.control_vllm_server"]
        XCTAssertTrue(targetIDs.isSubset(of: Set(actions.map { $0.id })))

        let madeHost = await ACTALocalActionBroker.make(
            actions: actions,
            allowedActionIDs: targetIDs,
            allowedInspectionIDs: [],
            audit: { _ in }
        )
        let host = try XCTUnwrap(madeHost)
        let openedSession = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .chat,
            threadID: "w3c-broker",
            actionIDs: targetIDs,
            inspectionIDs: []
        )
        let session = try XCTUnwrap(openedSession)

        // 1. Read-only status works without confirmation
        let initialStatus = await host.broker.request(session: session, actionID: "settings.get_vllm_status", argumentsJSON: "{}")
        XCTAssertTrue(initialStatus.success, initialStatus.error ?? "expected status ok")
        XCTAssertTrue(initialStatus.outputJSON.contains(#""serverState":"stopped""#))

        // 2. Updating vLLM serving requires confirmation, then updates disk + runtime + limiter
        let unconfirmedUpdate = await host.broker.request(
            session: session,
            actionID: "settings.update_vllm_serving",
            argumentsJSON: #"{"maxConcurrentRequests":6,"allowLocalMLXFallback":true,"gpuMemoryUtilization":0.70}"#
        )
        XCTAssertTrue(unconfirmedUpdate.requiresOperatorConfirmation)
        let updateReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let updateRev = try XCTUnwrap(updateReviews.first)
        let approvedUpdate = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: updateRev, approved: true)
        XCTAssertTrue(approvedUpdate.success, approvedUpdate.error ?? "expected update success")
        let limiterMaxAfterUpdate = await manager.limiter.maxTotalConcurrency
        XCTAssertEqual(limiterMaxAfterUpdate, 6)
        let prefsAfterUpdate = await MainActor.run { model.vlmPreferences }
        XCTAssertTrue(prefsAfterUpdate.actaVLLMAllowLocalMLXFallback)
        XCTAssertEqual(prefsAfterUpdate.actaVLLMGPUMemoryUtilization, 0.70, accuracy: 0.001)

        // 3. Control server start -> check_health -> stop via broker with confirmation and zero secret leak
        let reqStart = await host.broker.request(session: session, actionID: "settings.control_vllm_server", argumentsJSON: #"{"operation":"start"}"#)
        XCTAssertTrue(reqStart.requiresOperatorConfirmation)
        let startReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let startRev = try XCTUnwrap(startReviews.first)
        let started = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: startRev, approved: true)
        XCTAssertTrue(started.success, started.error ?? "expected start success")
        XCTAssertTrue(started.outputJSON.contains(#""serverState":"running""#))

        let managedCreds = await manager.managedCredentials()
        let secretKey = try XCTUnwrap(managedCreds?.apiKey)
        XCTAssertFalse(started.outputJSON.contains(secretKey), "Broker output must never expose ephemeral API key")

        let reqHealth = await host.broker.request(session: session, actionID: "settings.control_vllm_server", argumentsJSON: #"{"operation":"check_health"}"#)
        XCTAssertTrue(reqHealth.requiresOperatorConfirmation)
        let healthReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let healthRev = try XCTUnwrap(healthReviews.first)
        let health = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: healthRev, approved: true)
        XCTAssertTrue(health.success)
        XCTAssertFalse(health.outputJSON.contains(secretKey))

        let reqStop = await host.broker.request(session: session, actionID: "settings.control_vllm_server", argumentsJSON: #"{"operation":"stop"}"#)
        XCTAssertTrue(reqStop.requiresOperatorConfirmation)
        let stopReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let stopRev = try XCTUnwrap(stopReviews.first)
        let stopped = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: stopRev, approved: true)
        XCTAssertTrue(stopped.success)
        XCTAssertTrue(stopped.outputJSON.contains(#""serverState":"stopped""#))
        XCTAssertEqual(fakeProc.terminateCount, 1)
    }

    func testConcurrentStressSpeechMemoryCameraAnalyticsAndAgentActions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-w3c-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = ACTALocalVLLMServerManager(maxConcurrentRequests: 4, maxQueueDepth: 4)
        let limiter = await manager.limiter
        let interactiveCompletions = LockedBox<Int>(0)
        let backgroundCompletions = LockedBox<Int>(0)
        let backpressureDrops = LockedBox<Int>(0)

        let vllmClient = ACTALocalVLLMClient(serverManager: manager) { request, onChunk in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let isBackground = body.contains("BG_LOAD")
            try await Task.sleep(nanoseconds: isBackground ? 40_000_000 : 12_000_000)
            try Task.checkCancellation()
            onChunk("data: {\"choices\":[{\"delta\":{\"content\":\"Stress response ok\"}}]}\n")
            onChunk("data: {\"choices\":[{\"delta\":{}}],\"usage\":{\"prompt_tokens\":32,\"completion_tokens\":8}}\n")
            onChunk("data: [DONE]\n")
            return 200
        }

        let aiClient = ACTAAIClient(
            config: ACTAAIConfiguration(
                mode: .localVLLM,
                vllmBaseURL: "http://127.0.0.1:18835/v1",
                vllmModelName: "qwen3.5-9b",
                allowLocalVLLMAgent: true,
                allowVLLMLocalMLXFallback: false,
                vllmAPIKey: "stress-ephemeral-key",
                allowExternalAI: false
            ),
            localVLLMClient: vllmClient
        )
        let model = try await makeIsolatedWave3CModel(dir: dir, serverManager: manager, agentClient: aiClient)

        // Seed memory store with sample frames for concurrent memory retrieval
        let sampleJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
        let camID = await MainActor.run { model.config.cameras[0].id }
        try await MainActor.run {
            for idx in 0..<6 {
                _ = try model.cameraMemoryStore.save(
                    sampleJPEG,
                    cameraID: camID,
                    cameraName: "Lobby",
                    capturedAt: Date().addingTimeInterval(Double(-idx * 30)),
                    summary: "Person walked through lobby #\(idx)"
                )
            }
        }

        let actions = await MainActor.run { model.buildProductionBrokerActions() }
        let readIDs: Set<String> = ["camera.list", "settings.get_vllm_status", "analytics.get_settings"]
        let madeHost = await ACTALocalActionBroker.make(
            actions: actions,
            allowedActionIDs: readIDs,
            allowedInspectionIDs: [],
            audit: { _ in }
        )
        let host = try XCTUnwrap(madeHost)
        let openedSession = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .voice,
            threadID: "stress-thread",
            actionIDs: readIDs,
            inspectionIDs: []
        )
        let session = try XCTUnwrap(openedSession)

        let memoryStore = await MainActor.run { model.cameraMemoryStore }
        let analyticsEngine = await MainActor.run { model.localAnalyticsEngine }

        // Run all 4 workloads concurrently:
        // (A) Interactive speech/chat turns + speech sanitization
        // (B) Background vLLM flood triggering bounded concurrency & backpressure + cancellations
        // (C) Concurrent memory retrieval reads
        // (D) Concurrent camera analytics state snapshots + broker agent actions
        let memoryReadsOK = LockedBox<Int>(0)
        let analyticsOpsOK = LockedBox<Int>(0)
        let brokerOpsOK = LockedBox<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            // (A) 6 interactive voice/chat agent steps
            for i in 0..<6 {
                group.addTask {
                    let req = ACTAAgentRequest(
                        instructions: "Voice operator request",
                        fullInput: [.user(text: "Voice status check \(i)", images: [])],
                        tools: [],
                        toolChoice: .auto
                    )
                    if let res = try? await aiClient.runAgentStep(lane: .chat, request: req) {
                        let spoken = LocalVoiceSpeechSanitizer.sanitize(res.text ?? "")
                        if !spoken.isEmpty {
                            interactiveCompletions.modify { $0 += 1 }
                        }
                    }
                }
            }

            // (B) 12 background vLLM requests (some overflow backpressure, 2 explicitly cancelled)
            for i in 0..<12 {
                group.addTask {
                    let req = ACTAAgentRequest(
                        instructions: "Background camera caption",
                        fullInput: [.user(text: "BG_LOAD frame \(i)", images: [])],
                        tools: [],
                        toolChoice: .auto
                    )
                    let task = Task {
                        try await aiClient.runAgentStep(lane: .background, request: req)
                    }
                    if i == 2 || i == 5 {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        task.cancel()
                    }
                    do {
                        _ = try await task.value
                        backgroundCompletions.modify { $0 += 1 }
                    } catch ACTALocalVLLMError.backpressureRejected {
                        backpressureDrops.modify { $0 += 1 }
                    } catch {
                        // Cancellation expected for i == 2, 5
                    }
                }
            }

            // (C) 10 concurrent memory retrieval reads
            for _ in 0..<10 {
                group.addTask {
                    if let frames = try? memoryStore.load(), frames.count >= 6 {
                        memoryReadsOK.modify { $0 += 1 }
                    }
                }
            }

            // (D) 8 concurrent camera analytics queries + broker actions
            for i in 0..<8 {
                group.addTask {
                    let actionID = i % 2 == 0 ? "camera.list" : "settings.get_vllm_status"
                    let res = await host.broker.request(session: session, actionID: actionID, argumentsJSON: "{}")
                    if res.success {
                        brokerOpsOK.modify { $0 += 1 }
                    }
                    let cfg = await MainActor.run { analyticsEngine.settings.effectiveConfiguration(for: camID) }
                    if cfg.samplingFPS > 0 {
                        analyticsOpsOK.modify { $0 += 1 }
                    }
                }
            }
        }

        // All interactive speech/chat requests must succeed without starvation
        XCTAssertEqual(interactiveCompletions.get(), 6)
        // Background completed or cleanly shed via backpressure without deadlocking
        XCTAssertGreaterThan(backgroundCompletions.get() + backpressureDrops.get(), 0)
        // Memory retrieval, camera analytics, and broker actions all remained 100% responsive
        XCTAssertEqual(memoryReadsOK.get(), 10)
        XCTAssertEqual(analyticsOpsOK.get(), 8)
        XCTAssertEqual(brokerOpsOK.get(), 8)

        let counts = await limiter.counts()
        XCTAssertEqual(counts.interactive, 0)
        XCTAssertEqual(counts.background, 0)
        XCTAssertEqual(counts.queued, 0)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func get() -> T { lock.withLock { value } }
    func set(_ next: T) { lock.withLock { value = next } }
    func modify(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
    func modifyAndReturn<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markEnteredAndWait() async {
        entered = true
        let w = enteredWaiters
        enteredWaiters.removeAll()
        w.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let w = releaseWaiters
        releaseWaiters.removeAll()
        w.forEach { $0.resume() }
    }
}
