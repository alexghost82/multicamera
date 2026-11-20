import XCTest
@testable import CameraCore

final class WorkerEventSpoolTests: XCTestCase {
    func testSpoolPersistsEventsAndAcknowledgements() async throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("events.json")
        let event = try makeEvent(at: Date(timeIntervalSince1970: 100))
        let secondEvent = try makeEvent(at: Date(timeIntervalSince1970: 200))

        let spool = try WorkerEventSpool(url: url, maximumEvents: 4, maximumBytes: 16_384)
        try await spool.append(event)
        try await spool.append(secondEvent)
        let initialCount = await spool.count()
        XCTAssertEqual(initialCount, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reloaded = try WorkerEventSpool(url: url, maximumEvents: 4, maximumBytes: 16_384)
        let oldest = await reloaded.pending(limit: 1)
        XCTAssertEqual(oldest, [event])
        let acknowledged = try await reloaded.acknowledge([event.id])
        XCTAssertEqual(acknowledged, 1)
        let remaining = await reloaded.pending()
        XCTAssertEqual(remaining, [secondEvent])
    }

    func testCapacityFailureDoesNotDropAlreadySpooledEvents() async throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("events.json")
        let event = try makeEvent()
        let spool = try WorkerEventSpool(url: url, maximumEvents: 1, maximumBytes: 16_384)
        try await spool.append(event)

        do {
            try await spool.append(makeEvent())
            XCTFail("Expected full spool to reject a new event")
        } catch let error as WorkerEventSpoolError {
            XCTAssertEqual(error, .capacityExceeded)
        }
        let pending = await spool.pending()
        XCTAssertEqual(pending, [event])
    }

    func testSpoolRefusesExistingFileWithLoosePermissions() async throws {
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("events.json")
        let spool = try WorkerEventSpool(url: url, maximumEvents: 1, maximumBytes: 16_384)
        try await spool.append(makeEvent())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        XCTAssertThrowsError(try WorkerEventSpool(url: url, maximumEvents: 1, maximumBytes: 16_384)) {
            XCTAssertEqual($0 as? WorkerEventSpoolError, .insecureFilePermissions)
        }
    }

    func testEventRejectsInvalidOrOversizedJSONPayload() {
        XCTAssertThrowsError(try makeEvent(payload: "not-json"))
        XCTAssertThrowsError(try makeEvent(payload: String(repeating: "x", count: WorkerEventSpool.maximumPayloadBytes + 1)))
    }

    private func makeEvent(at date: Date = Date(), payload: String = "{\"status\":\"candidate\"}") throws -> WorkerEventEnvelope {
        try WorkerEventEnvelope(workerID: UUID(), cameraID: UUID(), leaseID: UUID(), leaseGeneration: 1,
                                eventType: "candidate", occurredAt: date, payloadJSON: payload)
    }
}