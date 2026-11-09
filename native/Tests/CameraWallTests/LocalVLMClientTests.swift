import Foundation
import CoreVideo
import XCTest
@testable import CameraWall

final class LocalVLMClientTests: XCTestCase {
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
