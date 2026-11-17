import Foundation

public struct ISAPIEventPayload: Equatable, Sendable {
    public let eventType: String
    public let eventState: String?
    public let channelID: String?
    public let eventDescription: String?
    public let occurredAt: Date?

    public init(eventType: String, eventState: String?, channelID: String?,
                eventDescription: String?, occurredAt: Date?) {
        self.eventType = eventType
        self.eventState = eventState
        self.channelID = channelID
        self.eventDescription = eventDescription
        self.occurredAt = occurredAt
    }
}

public struct ISAPIEventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: UUID
    public let cameraName: String
    public let eventType: String
    public let eventState: String?
    public let channelID: String?
    public let eventDescription: String?
    public let occurredAt: Date?
    public let receivedAt: Date

    public init(id: UUID = UUID(), cameraID: UUID, cameraName: String,
                payload: ISAPIEventPayload, receivedAt: Date = Date()) {
        self.id = id
        self.cameraID = cameraID
        self.cameraName = cameraName
        eventType = payload.eventType
        eventState = payload.eventState
        channelID = payload.channelID
        eventDescription = payload.eventDescription
        occurredAt = payload.occurredAt
        self.receivedAt = receivedAt
    }
}

public enum ISAPIEventParseError: LocalizedError {
    case invalidXML
    case oversizedEvent
    case missingEventType

    public var errorDescription: String? {
        switch self {
        case .invalidXML: return "The camera returned an invalid ISAPI event."
        case .oversizedEvent: return "The camera returned an ISAPI event that exceeds the size limit."
        case .missingEventType: return "The camera event does not include an event type."
        }
    }
}

public enum ISAPIEventXMLParser {
    public static let maximumEventBytes = 256 * 1024
    private static let fields: Set<String> = ["eventType", "eventState", "channelID", "eventDescription", "dateTime"]

    public static func parse(_ data: Data) throws -> ISAPIEventPayload {
        guard data.count <= maximumEventBytes else { throw ISAPIEventParseError.oversizedEvent }
        let collector = EventXMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ISAPIEventParseError.invalidXML }
        guard let eventType = collector.values["eventType"], !eventType.isEmpty else {
            throw ISAPIEventParseError.missingEventType
        }
        return ISAPIEventPayload(
            eventType: eventType,
            eventState: collector.values["eventState"],
            channelID: collector.values["channelID"],
            eventDescription: collector.values["eventDescription"],
            occurredAt: parseDate(collector.values["dateTime"])
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }

    private final class EventXMLCollector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var currentField: String?
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard fields.contains(elementName) else { return }
            currentField = elementName
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentField != nil else { return }
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard currentField == elementName else { return }
            values[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            currentField = nil
            currentText = ""
        }
    }
}

public struct ISAPIEventStreamDecoder {
    private static let closingTag = Data("</EventNotificationAlert>".utf8)
    private static let openingTag = Data("<EventNotificationAlert".utf8)
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [ISAPIEventPayload] {
        buffer.append(data)
        var events: [ISAPIEventPayload] = []

        while let closingRange = buffer.range(of: Self.closingTag) {
            let eventEnd = closingRange.upperBound
            let frame = buffer.subdata(in: 0..<eventEnd)
            buffer.removeSubrange(0..<eventEnd)
            guard let openingRange = frame.range(of: Self.openingTag) else { continue }
            let xml = frame.subdata(in: openingRange.lowerBound..<frame.endIndex)
            events.append(try ISAPIEventXMLParser.parse(xml))
        }

        guard buffer.count <= ISAPIEventXMLParser.maximumEventBytes else {
            buffer.removeAll(keepingCapacity: true)
            throw ISAPIEventParseError.oversizedEvent
        }
        return events
    }
}

public enum ISAPIEventStore {
    public static let maximumRecords = 1000
    public static let retentionDays = 30

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/isapi-events.json")
    }

    public static func load(from url: URL = defaultURL, now: Date = Date()) throws -> [ISAPIEventRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoded = try JSONDecoder().decode([ISAPIEventRecord].self, from: Data(contentsOf: url))
        let retained = retainedRecords(decoded, now: now)
        if retained.count != decoded.count { try save(retained, to: url, now: now) }
        return retained
    }

    /// Reads an existing history without pruning or creating files. A missing file throws.
    public static func readSnapshot(from url: URL = defaultURL, now: Date = Date()) throws -> [ISAPIEventRecord] {
        let decoded = try JSONDecoder().decode([ISAPIEventRecord].self, from: Data(contentsOf: url))
        return retainedRecords(decoded, now: now)
    }

    public static func retainedRecords(_ events: [ISAPIEventRecord], now: Date) -> [ISAPIEventRecord] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        return Array(events
            .filter { $0.receivedAt >= cutoff }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(maximumRecords))
    }

    public static func save(_ events: [ISAPIEventRecord], to url: URL = defaultURL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let retained = events.filter { $0.receivedAt >= cutoff }
            .sorted { $0.receivedAt > $1.receivedAt }
        try encoder.encode(Array(retained.prefix(maximumRecords))).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}