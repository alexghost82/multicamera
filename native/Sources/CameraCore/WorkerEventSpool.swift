import Foundation

public struct WorkerEventEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let workerID: UUID
    public let cameraID: UUID
    public let leaseID: UUID
    public let leaseGeneration: UInt64
    public let eventType: String
    public let occurredAt: Date
    public let payloadJSON: String

    public init(id: UUID = UUID(), workerID: UUID, cameraID: UUID, leaseID: UUID,
                leaseGeneration: UInt64, eventType: String, occurredAt: Date = Date(), payloadJSON: String) throws {
        guard !eventType.isEmpty, eventType.utf8.count <= 128,
              payloadJSON.utf8.count <= WorkerEventSpool.maximumPayloadBytes,
              let data = payloadJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw WorkerEventSpoolError.invalidEvent
        }
        self.id = id
        self.workerID = workerID
        self.cameraID = cameraID
        self.leaseID = leaseID
        self.leaseGeneration = leaseGeneration
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.payloadJSON = payloadJSON
    }
}

public enum WorkerEventSpoolError: Error, Equatable {
    case invalidEvent
    case capacityExceeded
    case insecureFilePermissions
}

public actor WorkerEventSpool {
    public static let maximumPayloadBytes = 64 * 1024
    public static let defaultMaximumEvents = 10_000
    public static let defaultMaximumBytes = 16 * 1024 * 1024

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/worker-events.json")
    }

    private let url: URL
    private let maximumEvents: Int
    private let maximumBytes: Int
    private var events: [WorkerEventEnvelope]

    public init(url: URL = WorkerEventSpool.defaultURL,
                maximumEvents: Int = WorkerEventSpool.defaultMaximumEvents,
                maximumBytes: Int = WorkerEventSpool.defaultMaximumBytes) throws {
        precondition(maximumEvents > 0 && maximumBytes > 0)
        self.url = url
        self.maximumEvents = maximumEvents
        self.maximumBytes = maximumBytes
        events = try Self.load(url: url, maximumEvents: maximumEvents, maximumBytes: maximumBytes)
    }

    public func append(_ event: WorkerEventEnvelope) throws {
        if let existing = events.first(where: { $0.id == event.id }) {
            guard existing == event else { throw WorkerEventSpoolError.invalidEvent }
            return
        }
        var next = events
        next.append(event)
        guard next.count <= maximumEvents, try Self.encode(next).count <= maximumBytes else {
            throw WorkerEventSpoolError.capacityExceeded
        }
        try persist(next)
        events = next
    }

    @discardableResult
    public func acknowledge(_ eventIDs: Set<UUID>) throws -> Int {
        guard !eventIDs.isEmpty else { return 0 }
        let next = events.filter { !eventIDs.contains($0.id) }
        let removed = events.count - next.count
        guard removed > 0 else { return 0 }
        try persist(next)
        events = next
        return removed
    }

    public func pending(limit: Int = 100) -> [WorkerEventEnvelope] {
        guard limit > 0 else { return [] }
        return Array(events.sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.occurredAt < $1.occurredAt
        }.prefix(limit))
    }

    public func count() -> Int { events.count }

    private func persist(_ next: [WorkerEventEnvelope]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try Self.encode(next).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func load(url: URL, maximumEvents: Int, maximumBytes: Int) throws -> [WorkerEventEnvelope] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard permissions & 0o077 == 0 else { throw WorkerEventSpoolError.insecureFilePermissions }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw WorkerEventSpoolError.capacityExceeded }
        let events = try JSONDecoder().decode([WorkerEventEnvelope].self, from: data)
        guard events.count <= maximumEvents else { throw WorkerEventSpoolError.capacityExceeded }
        for event in events {
            _ = try WorkerEventEnvelope(id: event.id, workerID: event.workerID, cameraID: event.cameraID,
                                        leaseID: event.leaseID, leaseGeneration: event.leaseGeneration,
                                        eventType: event.eventType, occurredAt: event.occurredAt,
                                        payloadJSON: event.payloadJSON)
        }
        return events
    }

    private static func encode(_ events: [WorkerEventEnvelope]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(events)
    }
}