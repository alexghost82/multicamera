import XCTest
@testable import CameraCore

final class ISAPIEventTests: XCTestCase {
    func testStreamDecoderHandlesMultipartBoundariesAndSplitXML() throws {
        var decoder = ISAPIEventStreamDecoder()
        let first = Data("--boundary\r\nContent-Type: application/xml\r\n\r\n<EventNotificationAlert><eventType>VMD</eventType><eventState>active</eventState><channelID>1</channelID>".utf8)
        let second = Data("<dateTime>2026-10-29T12:34:56Z</dateTime><eventDescription>Motion detected</eventDescription></EventNotificationAlert>\r\n--boundary--\r\n".utf8)

        XCTAssertTrue(try decoder.append(first).isEmpty)
        let events = try decoder.append(second)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, "VMD")
        XCTAssertEqual(events[0].eventState, "active")
        XCTAssertEqual(events[0].channelID, "1")
        XCTAssertEqual(events[0].eventDescription, "Motion detected")
        XCTAssertEqual(events[0].occurredAt, ISO8601DateFormatter().date(from: "2026-10-29T12:34:56Z"))
    }

    func testXMLParserRejectsMalformedEventsAndMissingEventType() {
        XCTAssertThrowsError(try ISAPIEventXMLParser.parse(Data("<EventNotificationAlert>".utf8)))
        XCTAssertThrowsError(try ISAPIEventXMLParser.parse(Data("<EventNotificationAlert><eventState>active</eventState></EventNotificationAlert>".utf8)))
    }

    func testXMLParserEnforcesEventSizeLimit() {
        let oversized = Data(repeating: 65, count: ISAPIEventXMLParser.maximumEventBytes + 1)
        XCTAssertThrowsError(try ISAPIEventXMLParser.parse(oversized))
    }

    func testEventStoreUsesPrivateFilesAndKeepsBoundedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let now = Date()
        let cameraID = UUID()
        let payload = ISAPIEventPayload(eventType: "VMD", eventState: "active", channelID: "1",
                                        eventDescription: "Motion", occurredAt: nil)
        let records = (0..<ISAPIEventStore.maximumRecords + 1).map { index in
            ISAPIEventRecord(cameraID: cameraID, cameraName: "Gate", payload: payload,
                             receivedAt: now.addingTimeInterval(TimeInterval(index)))
        }

        try ISAPIEventStore.save(records, to: url, now: now)

        XCTAssertEqual(try ISAPIEventStore.load(from: url, now: now).count, ISAPIEventStore.maximumRecords)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    }

    func testEventStorePurgesRecordsOlderThanThirtyDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.json")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let payload = ISAPIEventPayload(eventType: "VMD", eventState: "active", channelID: nil,
                                        eventDescription: nil, occurredAt: nil)
        let old = ISAPIEventRecord(cameraID: UUID(), cameraName: "Gate", payload: payload,
                                   receivedAt: now.addingTimeInterval(-31 * 24 * 60 * 60))
        let recent = ISAPIEventRecord(cameraID: UUID(), cameraName: "Door", payload: payload,
                                      receivedAt: now)

        try ISAPIEventStore.save([old, recent], to: url, now: now)

        XCTAssertEqual(try ISAPIEventStore.load(from: url, now: now), [recent])
    }
}