@testable import CameraCore
@testable import CameraWall
import CoreGraphics
import Foundation
import SQLite3
import XCTest

private actor NarrativePromptCapture {
    private(set) var prompts: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let contents = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        prompts.append(try XCTUnwrap(contents.first?["text"] as? String))
        let result = ACTATemporalNarrativeResult(chapterTitle: "Test", summary: "Observed",
            deltaFromPrevious: "invented comparison")
        let content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class NarrativeOrderingRecoveryTests: XCTestCase {
    func testLiveRollbackUsesKnownPreviousSummary() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".narrative-ordering-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let capture = NarrativePromptCapture()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { try await capture.send($0) },
            keyProvider: { _ in XCTFail("Unexpected credential access"); return nil })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cameraID = UUID()
        for (wall, monotonic) in [(100.0, 100.0), (50.0, 110.0)] {
            await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, evaluateAlerts: false,
                now: Date(timeIntervalSince1970: wall), monotonicTimestamp: monotonic)
            let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test",
                retainCollageJPEG: false)
            XCTAssertNotNil(saved)
        }
        let prompts = await capture.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("Previous Chapter Summary (report ONLY new developments / delta): Observed"))
        XCTAssertNil(coordinator.lastStorageError)
    }

    func testRestartReportsAmbiguousLegacyOrderWithoutInventingPreviousChapter() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".narrative-ordering-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tracking.sqlite")
        let cameraID = UUID()
        do {
            let store = try LocalTrackingStore(url: url)
            try store.saveACTANarrativeChapter(cameraID: cameraID, cameraName: "test",
                startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 100),
                chapter: ACTATemporalNarrativeResult(chapterTitle: "first", summary: "first-summary"))
            try store.saveACTANarrativeChapter(cameraID: cameraID, cameraName: "test",
                startedAt: Date(timeIntervalSince1970: 50), endedAt: Date(timeIntervalSince1970: 50),
                chapter: ACTATemporalNarrativeResult(chapterTitle: "second", summary: "second-summary"))
        }

        let store = try LocalTrackingStore(url: url)
        let capture = NarrativePromptCapture()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { try await capture.send($0) },
            keyProvider: { _ in XCTFail("Unexpected credential access"); return nil })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, evaluateAlerts: false,
            now: Date(timeIntervalSince1970: 25), monotonicTimestamp: 1)
        let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test",
            retainCollageJPEG: false)
        XCTAssertNotNil(saved)
        XCTAssertNil(saved?.narrative.deltaFromPrevious)
        XCTAssertTrue(coordinator.takeNarrativeOrderWarning()?.contains("order is ambiguous") == true)
        XCTAssertNil(coordinator.takeNarrativeOrderWarning())
        XCTAssertNil(coordinator.lastStorageError)
        let prompts = await capture.prompts
        let prompt = try XCTUnwrap(prompts.first)
        XCTAssertTrue(prompt.contains("No previous chapter summary is available"))
        XCTAssertFalse(prompt.contains("first-summary"))
        XCTAssertFalse(prompt.contains("second-summary"))
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 3)
    }

    func testSingleChapterAndMalformedRowsAreNotSilentlySkipped() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".narrative-ordering-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tracking.sqlite")
        let store = try LocalTrackingStore(url: url)
        let cameraID = UUID()
        if case .none = try store.actaNarrativePreviousSummary(cameraID: cameraID) {} else { XCTFail() }
        let id = UUID()
        try store.saveACTANarrativeChapter(id: id, cameraID: cameraID, cameraName: "test",
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 10),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "one", summary: "original"))
        try store.setACTANarrativeOperatorText(chapterID: id.uuidString, operatorText: "reviewed")
        if case .only(let text) = try store.actaNarrativePreviousSummary(cameraID: cameraID) {
            XCTAssertEqual(text, "reviewed")
        } else { XCTFail() }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection,
            "UPDATE ghost_narrative_chapters SET chapter_json = 'invalid'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.actaNarrativePreviousSummary(cameraID: cameraID))
        try store.saveACTANarrativeChapter(cameraID: cameraID, cameraName: "test",
            startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 10),
            chapter: ACTATemporalNarrativeResult(chapterTitle: "two", summary: "other"))
        if case .ambiguous = try store.actaNarrativePreviousSummary(cameraID: cameraID) {} else { XCTFail() }
    }
}
