import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAClearISAPIEventsActionTests: XCTestCase {
    private final class Memory: ACTAISAPIEventMemory {
        var isAvailable = true
        var events: [ISAPIEventRecord]
        var onClear: (() -> Void)?
        init(_ events: [ISAPIEventRecord]) { self.events = events }
        func clearEvents() -> Bool {
            onClear?()
            events = []
            return true
        }
    }

    private func event() -> ISAPIEventRecord {
        ISAPIEventRecord(cameraID: UUID(), cameraName: "fixture",
                         payload: ISAPIEventPayload(eventType: "VMD", eventState: "active",
                                                    channelID: nil, eventDescription: nil, occurredAt: nil))
    }

    private func fixture() throws -> (URL, URL, Memory) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".isapi-clear-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("events.json")
        let memory = Memory([event()])
        try ISAPIEventStore.save(memory.events, to: url)
        return (root, url, memory)
    }

    func testRegistryConfirmationRejectionAndVerifiedSuccess() async throws {
        let (root, url, memory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ACTAClearISAPIEventsService(memory: memory, url: url)
        let action = ACTAClearISAPIEventsAction(service: service)
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let bytes = try Data(contentsOf: url)
        let first = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(first.requiresOperatorConfirmation)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let rejected = try await registry.confirmAndExecute(token: try XCTUnwrap(first.confirmationToken), confirmed: false)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(memory.events.count, 1)

        let second = try await registry.execute(actionID: action.id, parameters: [:])
        memory.onClear = {
            XCTAssertEqual(try? JSONDecoder().decode([ISAPIEventRecord].self, from: Data(contentsOf: url)), [])
        }
        let result = try await registry.confirmAndExecute(token: try XCTUnwrap(second.confirmationToken), confirmed: true)
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(memory.events.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode([ISAPIEventRecord].self, from: Data(contentsOf: url)), [])
        let replay = try await registry.confirmAndExecute(token: try XCTUnwrap(second.confirmationToken), confirmed: true)
        XCTAssertFalse(replay.success)
    }

    func testDirectCallNeedsConfirmationAndRejectsUnknownParameters() async throws {
        let (root, url, memory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let action = ACTAClearISAPIEventsAction(service: ACTAClearISAPIEventsService(memory: memory, url: url))
        let bytes = try Data(contentsOf: url)
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.error?.contains("CONFIRMATION_REQUIRED") == true)
        XCTAssertThrowsError(try action.validate(parameters: ["x": "y"]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(memory.events.count, 1)
    }

    func testMissingCorruptAndChangedStoresAreNeverOverwritten() throws {
        let (root, url, memory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ACTAClearISAPIEventsService(memory: memory, url: url)
        let missing = root.appendingPathComponent("missing.json")
        let missingService = ACTAClearISAPIEventsService(memory: memory, url: missing)
        XCTAssertThrowsError(try missingService.clear(confirmed: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try service.clear(confirmed: true)) {
            guard case ACTAClearISAPIEventsError.invalidData = $0 else { return XCTFail("Expected invalid data") }
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        let changed = try JSONEncoder().encode([event()])
        try changed.write(to: url)
        XCTAssertThrowsError(try service.clear(confirmed: true)) {
            guard case ACTAClearISAPIEventsError.changed = $0 else { return XCTFail("Expected conflict") }
        }
        XCTAssertEqual(try Data(contentsOf: url), changed)
        XCTAssertEqual(memory.events.count, 1)
    }

    func testChangeBetweenReadsDoesNotWrite() throws {
        let (root, url, memory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: url)
        let changed = try JSONEncoder().encode([event()])
        var reads = 0
        var writes = 0
        let service = ACTAClearISAPIEventsService(memory: memory, read: {
            reads += 1
            return reads == 1 ? original : changed
        }, writeEmpty: { writes += 1 })
        XCTAssertThrowsError(try service.clear(confirmed: true)) {
            guard case ACTAClearISAPIEventsError.changed = $0 else { return XCTFail("Expected conflict") }
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(memory.events.count, 1)
    }

    func testWriteOrReadbackFailureReportsPartialAndPreservesMemory() async throws {
        for mode in 0..<3 {
            let (root, url, memory) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var reads = 0
            let service = ACTAClearISAPIEventsService(memory: memory, read: {
                reads += 1
                if mode == 1 && reads == 3 { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            }, writeEmpty: {
                if mode != 2 { try ISAPIEventStore.save([], to: url) }
                if mode == 0 { throw CocoaError(.fileWriteNoPermission) }
            })
            let action = ACTAClearISAPIEventsAction(service: service)
            let result = try await action.execute(parameters: [:], context: ACTAActionContext(isConfirmed: true))
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.contains("PARTIAL_FAILURE") == true)
            XCTAssertEqual(memory.events.count, 1)
            XCTAssertEqual(try JSONDecoder().decode([ISAPIEventRecord].self, from: Data(contentsOf: url)).count,
                           mode == 2 ? 1 : 0)
        }
    }
}
