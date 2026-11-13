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
        while wall.vlmBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(wall.vlmBusy, "History request timed out")
        XCTAssertEqual(wall.vlmStatus, "Local history answer received")
        let reply = try XCTUnwrap(wall.trackResearchMessages.last)
        XCTAssertTrue(reply.text.lowercased().contains("крас"), reply.text)
        XCTAssertEqual(reply.citedScanIDs, [scan.id])

        XCTAssertTrue(wall.askTrackResearch(question: "Когда это было?"))
        let followUpDeadline = Date().addingTimeInterval(60)
        while wall.vlmBusy && Date() < followUpDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(wall.vlmBusy, "History follow-up timed out")
        XCTAssertEqual(wall.vlmStatus, "Local history answer received")
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
