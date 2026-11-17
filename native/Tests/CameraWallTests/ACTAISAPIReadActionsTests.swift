import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAISAPIReadActionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private struct FixtureProvider: ACTAISAPIReadProvider {
        let records: [ISAPIEventRecord]
        var status: ACTAISAPIHistoryStatus = .available

        func snapshot(now: Date) async throws -> ACTAISAPISnapshot {
            ACTAISAPISnapshot(records: records, source: .liveMemory, status: status, capturedAt: now)
        }
    }

    private struct FailingProvider: ACTAISAPIReadProvider {
        let error: ACTAISAPIProviderError
        func snapshot(now: Date) async throws -> ACTAISAPISnapshot { throw error }
    }

    private struct UnexpectedFailure: LocalizedError {
        var errorDescription: String? { "private-provider-detail" }
    }

    private struct UnexpectedFailureProvider: ACTAISAPIReadProvider {
        func snapshot(now: Date) async throws -> ACTAISAPISnapshot { throw UnexpectedFailure() }
    }

    private func record(camera: UUID, receivedAt: Date) -> ISAPIEventRecord {
        ISAPIEventRecord(cameraID: camera, cameraName: "private-name",
            payload: ISAPIEventPayload(eventType: "VMD", eventState: "active", channelID: "private-channel",
                                       eventDescription: "private-description", occurredAt: nil),
            receivedAt: receivedAt)
    }

    private func registry(_ provider: any ACTAISAPIReadProvider) async -> ACTAActionRegistry {
        let registry = ACTAActionRegistry()
        await registry.register(ACTAISAPIReadAction(provider: provider))
        return registry
    }

    private func object(_ result: ACTAActionResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
    }

    func testFilterOrderingLimitAndMinimalOutput() async throws {
        let camera = UUID()
        let other = UUID()
        let records = (0..<105).map { record(camera: camera, receivedAt: now.addingTimeInterval(Double($0))) }
        let foreign = record(camera: other, receivedAt: now.addingTimeInterval(1_000))
        let registry = await registry(FixtureProvider(records: [foreign] + records))
        let result = try await registry.execute(actionID: "monitor.get_isapi_events",
            parameters: ["camera_id": camera.uuidString, "limit": "100"], context: ACTAActionContext(now: now))
        XCTAssertTrue(result.success, result.summary)
        let output = try object(result)
        XCTAssertEqual(output["source"] as? String, "live_memory")
        XCTAssertEqual(output["status"] as? String, "available")
        XCTAssertNotNil(output["captured_at"])
        let events = try XCTUnwrap(output["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?["id"] as? String, records[104].id.uuidString)
        XCTAssertEqual(events.last?["id"] as? String, records[5].id.uuidString)
        XCTAssertTrue(events.allSatisfy { $0["camera_id"] as? String == camera.uuidString })
        XCTAssertEqual(events.first?["event_type"] as? String, "VMD")
        XCTAssertEqual(events.first?["event_state"] as? String, "active")
        XCTAssertFalse(result.outputJSON.contains("private-name"))
        XCTAssertFalse(result.outputJSON.contains("private-description"))
        XCTAssertFalse(result.outputJSON.contains("private-channel"))

        let defaultResult = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertEqual((try object(defaultResult)["events"] as? [Any])?.count, 50)
        let one = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: ["limit": "1"])
        XCTAssertEqual((try object(one)["events"] as? [Any])?.count, 1)
        let none = try await registry.execute(actionID: "monitor.get_isapi_events",
                                              parameters: ["camera_id": UUID().uuidString])
        XCTAssertTrue(none.success)
        XCTAssertEqual((try object(none)["events"] as? [Any])?.count, 0)
    }

    func testInvalidArgumentsAndUnavailableDifferFromEmpty() async throws {
        let registry = await registry(FixtureProvider(records: []))
        for parameters in [["limit": "0"], ["limit": "101"], ["limit": "-1"], ["limit": "1.5"],
                           ["limit": ""], ["camera_id": ""], ["camera_id": "invalid"], ["extra": "x"]] {
            let result = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: parameters)
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.contains("INVALID_ARGUMENT") == true)
        }
        let empty = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertTrue(empty.success)
        XCTAssertEqual((try object(empty)["events"] as? [Any])?.count, 0)

        for (error, code) in [(ACTAISAPIProviderError.unavailable, "UNAVAILABLE"),
                              (.invalidData, "INVALID_DATA")] {
            let failing = await self.registry(FailingProvider(error: error))
            let result = try await failing.execute(actionID: "monitor.get_isapi_events", parameters: [:])
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.verified)
            XCTAssertTrue(result.error?.contains(code) == true)
            XCTAssertNil(try object(result)["events"])
        }
        let unexpected = await self.registry(UnexpectedFailureProvider())
        let sanitized = try await unexpected.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(sanitized.success)
        XCTAssertTrue(sanitized.error?.contains("UNAVAILABLE") == true)
        XCTAssertFalse(sanitized.outputJSON.contains("private-provider-detail"))
        let firstLaunch = await self.registry(FixtureProvider(records: [], status: .verifiedFirstLaunch))
        let verified = try await firstLaunch.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertTrue(verified.success)
        XCTAssertEqual(try object(verified)["status"] as? String, "verified_first_launch")
        let inconsistent = await self.registry(FixtureProvider(
            records: [record(camera: UUID(), receivedAt: now)], status: .verifiedFirstLaunch))
        let invalid = try await inconsistent.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(invalid.success)
        XCTAssertTrue(invalid.error?.contains("INVALID_DATA") == true)
    }

    func testSnapshotRetentionMatchesLoadWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotURL = root.appendingPathComponent("snapshot.json")
        let loadURL = root.appendingPathComponent("load.json")
        let camera = UUID()
        let cutoff = now.addingTimeInterval(-Double(ISAPIEventStore.retentionDays) * 24 * 60 * 60)
        let records = (0..<ISAPIEventStore.maximumRecords + 1).map {
            record(camera: camera, receivedAt: cutoff.addingTimeInterval(Double($0)))
        } + [record(camera: camera, receivedAt: cutoff.addingTimeInterval(-1))]
        let bytes = try JSONEncoder().encode(records)
        try bytes.write(to: snapshotURL)
        try bytes.write(to: loadURL)
        let before = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let snapshot = try ISAPIEventStore.readSnapshot(from: snapshotURL, now: now)
        let after = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), bytes)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(snapshot.count, ISAPIEventStore.maximumRecords)
        XCTAssertEqual(snapshot, try ISAPIEventStore.load(from: loadURL, now: now))
        XCTAssertFalse(snapshot.contains { $0.receivedAt < cutoff })
        XCTAssertEqual(snapshot.first?.receivedAt, cutoff.addingTimeInterval(1_000))

        let boundary = [record(camera: camera, receivedAt: cutoff),
                        record(camera: camera, receivedAt: cutoff.addingTimeInterval(-1))]
        try JSONEncoder().encode(boundary).write(to: snapshotURL)
        XCTAssertEqual(try ISAPIEventStore.readSnapshot(from: snapshotURL, now: now), [boundary[0]])
    }

    func testStoreProviderMissingCorruptAndEmptyAreDistinctWithoutCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("events.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = await registry(ACTAISAPIStoreReadProvider(url: url))
        let missing = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(missing.success)
        XCTAssertTrue(missing.error?.contains("UNAVAILABLE") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try ISAPIEventStore.readSnapshot(from: url, now: now))
        XCTAssertTrue(try ISAPIEventStore.load(from: url, now: now).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: url)
        let invalid = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertFalse(invalid.success)
        XCTAssertTrue(invalid.error?.contains("INVALID_DATA") == true)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertFalse(invalid.outputJSON.contains(root.path))

        try Data("[]".utf8).write(to: url)
        let empty = try await registry.execute(actionID: "monitor.get_isapi_events", parameters: [:])
        XCTAssertTrue(empty.success)
        XCTAssertEqual(try object(empty)["source"] as? String, "local_store")
        XCTAssertEqual((try object(empty)["events"] as? [Any])?.count, 0)
        XCTAssertEqual(try Data(contentsOf: url), Data("[]".utf8))
    }
}
