import Foundation
import CoreVideo
import XCTest
import CameraCore
@testable import CameraWall

final class LocalVLMClientTests: XCTestCase {
    @MainActor
    func testInstalledQwenAnswersSyntheticSavedHistory() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_VLM_MODEL"] else {
            throw XCTSkip("Set CAMERAWALL_TEST_VLM_MODEL to run the local history smoke test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trackingURL = directory.appendingPathComponent("tracking.sqlite3")
        let store = try LocalTrackingStore(url: trackingURL)
        let scan = CameraScanRecord(cameraID: UUID(), cameraName: "Вход",
            observedAt: Date().addingTimeInterval(-3600), answer: "A red car was visible.")
        try store.saveAutomaticScan(scan)
        let coordinator = CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
            databaseURL: directory.appendingPathComponent("features.sqlite3"))
        let wall = WallModel(configURL: directory.appendingPathComponent("cameras.json"),
            trackingStoreURL: trackingURL, featureCoordinator: coordinator)
        defer { wall.shutdown() }
        wall.vlmPreferences.model = model
        let question = "Какого цвета автомобиль был замечен?"
        XCTAssertFalse(wall.running)
        XCTAssertTrue(wall.askTrackResearch(question: question))
        let deadline = Date().addingTimeInterval(60)
        while wall.trackResearchBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(wall.trackResearchBusy, "History request timed out")
        XCTAssertEqual(wall.trackResearchStatus, "Local history answer received")
        let reply = try XCTUnwrap(wall.trackResearchMessages.last)
        XCTAssertTrue(reply.text.lowercased().contains("крас"), reply.text)
        XCTAssertEqual(reply.citedScanIDs, [scan.id])

        XCTAssertTrue(wall.askTrackResearch(question: "Когда это было?"))
        let followUpDeadline = Date().addingTimeInterval(60)
        while wall.trackResearchBusy && Date() < followUpDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(wall.trackResearchBusy, "History follow-up timed out")
        XCTAssertEqual(wall.trackResearchStatus, "Local history answer received")
        XCTAssertEqual(wall.trackResearchMessages.last?.citedScanIDs, [scan.id])
    }

    func testInstalledQwenRepeatedSceneAssessmentsOnLocalFixture() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_VLM_MODEL"] else {
            throw XCTSkip("Set CAMERAWALL_TEST_VLM_MODEL to run the local scene smoke test.")
        }
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = nativeRoot.appendingPathComponent(".build/models/bus.jpg")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("The existing local bus image fixture is required; this test never downloads it.")
        }
        let image = try Data(contentsOf: fixture)
        let client = LocalVLMClient(model: model)
        try await client.prepare()
        for question in ["Что ты видишь?", "Оцени обстановку", "Оцени обстановку"] {
            let prompt = await WallModel.vlmPrompt(question: question, rules: [])
            let reply = try await VLMResponseValidator.generateReply(expectedLanguage: question) { correction in
                try await client.analyze(image: image, prompt: prompt + correction)
            }
            XCTAssertFalse(reply.answer.isEmpty)
            XCTAssertTrue(reply.matchedAlerts.isEmpty)
        }
    }

    func testInstalledQwenReturnsStructuredAnswersForSyntheticImage() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_VLM_MODEL"] else {
            throw XCTSkip("Set CAMERAWALL_TEST_VLM_MODEL to a local Qwen 3.5 9B directory for this model smoke test.")
        }
        let client = LocalVLMClient(model: model)
        try await client.prepare()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 127, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let image = try await VLMFrameEncoder.jpegData(from: pixel)
        for question in [
            "Что ты видишь?",
            "Оцени обстановку", "Оцени обстановку", "Оцени обстановку",
            "Describe the image in one sentence.", "Опиши изображение одним предложением.", "תאר את התמונה במשפט אחד."
        ] {
            let prompt = await WallModel.vlmPrompt(question: question, rules: [])
            let reply = try await VLMResponseValidator.generateReply(expectedLanguage: question) { correction in
                try await client.analyze(image: image, prompt: prompt + correction)
            }
            XCTAssertFalse(reply.answer.isEmpty)
            XCTAssertTrue(reply.matchedAlerts.isEmpty)
        }
    }

    func testInstalledQwenRunsInteractiveAndBackgroundRequestsConcurrently() async throws {
        guard let model = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_VLM_MODEL"] else {
            throw XCTSkip("Set CAMERAWALL_TEST_VLM_MODEL to run the concurrent local model smoke test.")
        }
        let background = LocalVLMClient(model: model, workload: .background)
        let interactive = LocalVLMClient(model: model, workload: .interactive)
        try await background.prepare()
        let prompt = "Write five short numbered sentences about parking lots."
        let started = Date()
        async let first = background.analyze(text: prompt)
        async let second = interactive.analyze(text: prompt)
        let replies = try await [first, second]
        XCTAssertTrue(replies.allSatisfy { !$0.isEmpty })
        print("Concurrent background+interactive generation took \(Date().timeIntervalSince(started))s")
    }

    func testBackgroundWorkLeavesAnInstanceForInteractiveRequests() async throws {
        let loads = LoadCounter()
        let pool = VLMInstancePool<Int>(capacity: 2) { await loads.next() }
        let backgroundLease = try await pool.acquire(.background)
        let waitingBackground = Task { try await pool.acquire(.background) }
        try await Task.sleep(for: .milliseconds(50))
        let interactiveLease = try await pool.acquire(.interactive)
        XCTAssertNotEqual(interactiveLease.slot, backgroundLease.slot)
        let activeWithBothLeases = await pool.activeCount
        XCTAssertEqual(activeWithBothLeases, 2)

        await pool.release(interactiveLease.slot)
        try await Task.sleep(for: .milliseconds(50))
        let activeAfterInteractive = await pool.activeCount
        XCTAssertEqual(activeAfterInteractive, 1, "A second background request must not take the reserved instance")

        await pool.release(backgroundLease.slot)
        let resumed = try await waitingBackground.value
        XCTAssertEqual(resumed.slot, backgroundLease.slot)
        let loadCount = await loads.count
        XCTAssertEqual(loadCount, 2)
    }

    func testSingleInstancePoolServesInteractiveWaitersFirstAndCancelsWaiters() async throws {
        let pool = VLMInstancePool<Int>(capacity: 1) { 1 }
        let held = try await pool.acquire(.background)
        let order = OrderRecorder()
        let backgroundWaiter = Task {
            let lease = try await pool.acquire(.background)
            await order.append("background")
            await pool.release(lease.slot)
        }
        try await Task.sleep(for: .milliseconds(30))
        let cancelledWaiter = Task { try await pool.acquire(.interactive) }
        let interactiveWaiter = Task {
            let lease = try await pool.acquire(.interactive)
            await order.append("interactive")
            await pool.release(lease.slot)
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled waiter must not receive an instance")
        } catch is CancellationError {}

        await pool.release(held.slot)
        try await interactiveWaiter.value
        try await backgroundWaiter.value
        let recorded = await order.values
        XCTAssertEqual(recorded, ["interactive", "background"])
    }

    func testIdleExtraInstanceIsEvicted() async throws {
        let evictions = LoadCounter()
        let pool = VLMInstancePool<Int>(capacity: 2, idleEviction: .milliseconds(30), load: { 1 },
            evicted: { Task { _ = await evictions.next() } })
        let first = try await pool.acquire(.interactive)
        let second = try await pool.acquire(.interactive)
        await pool.release(second.slot)
        await pool.release(first.slot)
        try await Task.sleep(for: .milliseconds(200))
        let loaded = await pool.loadedCount
        XCTAssertEqual(loaded, 1, "The primary instance stays loaded; idle extras are released")
        let evictionCount = await evictions.count
        XCTAssertEqual(evictionCount, 1)
    }

    func testMissingNativeModelReportsItsPath() async {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).path
        let client = LocalVLMClient(model: missingPath)

        do {
            _ = try await client.analyze(text: "Describe the scene")
            XCTFail("Expected a missing native model error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(missingPath))
        }
    }

    func testEmptyResponseErrorIsReadable() {
        XCTAssertEqual(LocalVLMError.emptyResponse.localizedDescription,
                       "The native VLM returned an empty response.")
    }
}

private actor LoadCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private actor OrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
