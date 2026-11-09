import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import CameraWall

private actor ModelLoadRecorder {
    private(set) var calls: [LocalModelService] = []
    var failingService: LocalModelService?

    init(failingService: LocalModelService? = nil) {
        self.failingService = failingService
    }

    func load(_ service: LocalModelService) throws {
        calls.append(service)
        if service == failingService { throw LocalVLMError.invalidResponse }
    }

    func clearFailure() { failingService = nil }
}

@MainActor
final class ModelRuntimeTests: XCTestCase {
    func testHostMemoryTelemetryIsAvailableAndBounded() throws {
        let usage = try XCTUnwrap(HostTelemetry.readMemoryUsage())
        XCTAssertGreaterThan(usage.totalBytes, 0)
        XCTAssertLessThanOrEqual(usage.usedBytes, usage.totalBytes)
        XCTAssertTrue((0...100).contains(usage.percentage))
    }

    func testStatusStripRendersNonblankAtNarrowAndWideWidths() async throws {
        let runtime = LocalModelRuntime { service, _ in
            if service == .segmentation { throw LocalVLMError.modelNotFound("synthetic-segmentation.onnx") }
        }
        await runtime.start(modelPath: "/synthetic/qwen3.5-9b").value
        for width in [360, 720, 1280] {
            let content = ModelRuntimeView(runtime: runtime, vlmBusy: false, retry: {})
                .environment(\.locale, Locale(identifier: "en"))
                .preferredColorScheme(.dark)
                .frame(width: CGFloat(width))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, width)
            XCTAssertGreaterThan(image.height, 30)
            XCTAssertLessThan(image.height, 220)
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 32, "Status strip must contain rendered text and symbols")
            if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("models-\(width).png"))
            }
        }
    }

    func testInstalledDetectionSegmentationAndReIDModelsPrepare() async throws {
        guard YOLO26Detector.defaultModelURL != nil, ONNXSegmentationEncoder.modelURL != nil,
              ReIDModelKind.allCases.allSatisfy({ ONNXReIDEncoder.modelURL(for: $0) != nil }) else {
            throw XCTSkip("Local YOLO, segmentation and ReID model files are required for preparation smoke testing.")
        }
        let detector = YOLO26Detector()
        try await detector.prepare()
        try await Task.detached(priority: .utility) {
            try ONNXSegmentationEncoder.prepare()
            let encoder = try XCTUnwrap(ONNXReIDEncoder.shared)
            for kind in ReIDModelKind.allCases { try encoder.prepare(kind) }
        }.value
    }

    func testConcurrentStartsSharePreparation() async {
        let recorder = ModelLoadRecorder()
        let runtime = LocalModelRuntime { service, _ in try await recorder.load(service) }
        let first = runtime.start(modelPath: "/synthetic/qwen3.5-9b")
        let second = runtime.start(modelPath: "/synthetic/qwen3.5-9b")
        await first.value
        await second.value
        let calls = await recorder.calls
        XCTAssertEqual(calls, LocalModelService.allCases)
    }

    func testCancellationLeavesModelsWaitingWithoutCallingLoader() async {
        let recorder = ModelLoadRecorder()
        let runtime = LocalModelRuntime { service, _ in try await recorder.load(service) }
        let preparation = runtime.start(modelPath: "/synthetic/qwen3.5-9b")
        runtime.cancel()
        await preparation.value
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(runtime.states.values.allSatisfy { $0 == .waiting })
    }

    func testLoadsEveryServiceOnceAndReusesReadyModels() async {
        let recorder = ModelLoadRecorder()
        let runtime = LocalModelRuntime { service, _ in try await recorder.load(service) }
        await runtime.start(modelPath: "/synthetic/qwen3.5-9b").value
        XCTAssertTrue(runtime.states.values.allSatisfy { $0 == .ready })
        await runtime.start(modelPath: "/synthetic/qwen3.5-9b").value
        let calls = await recorder.calls
        XCTAssertEqual(calls, LocalModelService.allCases)
    }

    func testFailureDoesNotBlockOtherModelsAndRetryOnlyLoadsFailure() async {
        let recorder = ModelLoadRecorder(failingService: .segmentation)
        let runtime = LocalModelRuntime { service, _ in try await recorder.load(service) }
        await runtime.start(modelPath: "/synthetic/qwen3.5-9b").value
        guard case .failed = runtime.states[.segmentation] else { return XCTFail("Expected model failure") }
        XCTAssertEqual(runtime.states[.qwen], .ready)
        await recorder.clearFailure()
        await runtime.start(modelPath: "/synthetic/qwen3.5-9b").value
        let calls = await recorder.calls
        XCTAssertEqual(calls, LocalModelService.allCases + [.segmentation])
        XCTAssertTrue(runtime.states.values.allSatisfy { $0 == .ready })
    }

    func testChangingModelPathReloadsOnlyQwen() async {
        let recorder = ModelLoadRecorder()
        let runtime = LocalModelRuntime { service, _ in try await recorder.load(service) }
        await runtime.start(modelPath: "/synthetic/first").value
        await runtime.start(modelPath: "/synthetic/second").value
        let calls = await recorder.calls
        XCTAssertEqual(calls, LocalModelService.allCases + [.qwen])
        XCTAssertEqual(runtime.qwenModelPath, "/synthetic/second")
    }
}