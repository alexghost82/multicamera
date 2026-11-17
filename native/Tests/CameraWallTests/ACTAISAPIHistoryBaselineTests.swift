import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAISAPIHistoryBaselineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func event(at date: Date) -> ISAPIEventRecord {
        ISAPIEventRecord(cameraID: UUID(), cameraName: "fixture",
                         payload: ISAPIEventPayload(eventType: "VMD", eventState: nil,
                                                    channelID: nil, eventDescription: nil, occurredAt: nil),
                         receivedAt: date)
    }

    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".isapi-baseline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return (root, root.appendingPathComponent("events.json"))
    }

    func testLoadIsReadOnlyAndSaveRefreshesVerifiedBaseline() throws {
        let (root, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recent = event(at: now)
        let expired = event(at: now.addingTimeInterval(-Double(ISAPIEventStore.retentionDays + 1) * 86_400))
        let original = try JSONEncoder().encode([expired, recent])
        try original.write(to: url)
        let baseline = ACTAISAPIHistoryBaseline(url: url)
        let loaded = try baseline.load(now: now)
        XCTAssertEqual(loaded, [recent])
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(baseline.bytes, original)
        let added = event(at: now.addingTimeInterval(1))
        let saved = try baseline.save([added] + loaded, replacing: loaded, now: now)
        XCTAssertEqual(saved, [added, recent])
        XCTAssertEqual(try JSONDecoder().decode([ISAPIEventRecord].self, from: Data(contentsOf: url)), saved)
        XCTAssertEqual(baseline.bytes, try Data(contentsOf: url))
        XCTAssertEqual(baseline.events, saved)
    }

    func testMissingCorruptAndChangedFileFailWithoutOverwrite() throws {
        let (root, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = ACTAISAPIHistoryBaseline(url: url)
        XCTAssertThrowsError(try baseline.load(now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try baseline.load(now: now))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let stored = [event(at: now)]
        try ISAPIEventStore.save(stored, to: url, now: now)
        let memory = try baseline.load(now: now)
        let changed = try JSONEncoder().encode(stored)
        try changed.write(to: url)
        XCTAssertThrowsError(try baseline.save([event(at: now)] + memory, replacing: memory, now: now)) {
            guard case ACTAClearISAPIEventsError.changed = $0 else { return XCTFail("Expected conflict") }
        }
        XCTAssertEqual(try Data(contentsOf: url), changed)
        XCTAssertNil(baseline.bytes)
    }

    func testFailedSaveOrReadbackInvalidatesBaseline() throws {
        for mode in 0..<2 {
            let (root, url) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let original = [event(at: now)]
            try ISAPIEventStore.save(original, to: url, now: now)
            var reads = 0
            let baseline = ACTAISAPIHistoryBaseline(read: {
                reads += 1
                if mode == 1 && reads == 5 { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            }, save: { events, time in
                try ISAPIEventStore.save(events, to: url, now: time)
                if mode == 0 { throw CocoaError(.fileWriteNoPermission) }
            })
            let current = try baseline.load(now: now)
            XCTAssertThrowsError(try baseline.save([event(at: now)] + current, replacing: current, now: now)) {
                guard case ACTAClearISAPIEventsError.partialFailure = $0 else { return XCTFail("Expected partial failure") }
            }
            XCTAssertNil(baseline.bytes)
            XCTAssertNil(baseline.events)
            XCTAssertEqual(current, original)
        }
    }

    func testChangedMemoryAndChangedDuringPreflightFailClosed() throws {
        let (root, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let records = [event(at: now)]
        try ISAPIEventStore.save(records, to: url, now: now)
        let original = try Data(contentsOf: url)
        let baseline = ACTAISAPIHistoryBaseline(url: url)
        _ = try baseline.load(now: now)
        XCTAssertThrowsError(try baseline.save([], replacing: [], now: now))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(baseline.bytes)

        var reads = 0
        var writes = 0
        let racing = ACTAISAPIHistoryBaseline(read: {
            reads += 1
            return reads == 4 ? Data("[]".utf8) : original
        }, save: { _, _ in writes += 1 })
        let current = try racing.load(now: now)
        XCTAssertThrowsError(try racing.save([], replacing: current, now: now))
        XCTAssertEqual(writes, 0)
        XCTAssertNil(racing.bytes)
    }

    func testAcceptVerifiedClearRejectsNonemptyOrChangedDisk() throws {
        let (root, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try ISAPIEventStore.save([event(at: now)], to: url, now: now)
        let baseline = ACTAISAPIHistoryBaseline(url: url)
        _ = try baseline.load(now: now)
        XCTAssertThrowsError(try baseline.acceptVerifiedClear(Data("[]".utf8)))
        XCTAssertNil(baseline.bytes)
        try Data("[]".utf8).write(to: url)
        try baseline.acceptVerifiedClear(Data("[]".utf8))
        XCTAssertEqual(baseline.events, [])
        XCTAssertEqual(baseline.bytes, Data("[]".utf8))
    }
}
