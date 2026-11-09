import Foundation
import CoreGraphics
import SQLite3

public struct TrackedAttribute: Codable, Equatable, Sendable {
    public let value: String
    public let confidence: Double
    public let evidence: String
}

public struct VehicleTextCandidate: Codable, Identifiable, Hashable, Sendable {
    public let text: String
    public let confidence: Float

    public var id: String { text }

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }

    public static func normalize(_ candidates: [VehicleTextCandidate], limit: Int = 10) -> [VehicleTextCandidate] {
        var seen = Set<String>()
        return candidates
            .filter { $0.confidence.isFinite && (0.2...1).contains($0.confidence) }
            .map { VehicleTextCandidate(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), confidence: $0.confidence) }
            .filter { (2...64).contains($0.text.count) && !$0.text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            .sorted { $0.confidence == $1.confidence ? $0.text < $1.text : $0.confidence > $1.confidence }
            .filter { seen.insert($0.text).inserted }
            .prefix(max(1, min(20, limit)))
            .map { $0 }
    }
}

public struct VehicleTextEvidence: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let candidates: [VehicleTextCandidate]
    public let readAt: Date
    public let cropSHA256: String

    public init(trackID: UUID, candidates: [VehicleTextCandidate], readAt: Date = Date(), cropSHA256: String) {
        self.trackID = trackID
        self.candidates = VehicleTextCandidate.normalize(candidates, limit: 20)
        self.readAt = readAt
        self.cropSHA256 = cropSHA256
    }

    public var isValid: Bool {
        candidates.count <= 20 && candidates == VehicleTextCandidate.normalize(candidates, limit: 20)
            && readAt.timeIntervalSince1970.isFinite && cropSHA256.utf8.count == 64
            && cropSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct TrackedObjectDescription: Codable, Equatable, Sendable {
    public let summary: String
    public let attributes: [String: TrackedAttribute]
    public let overallConfidence: Double

    public static func parse(_ response: String) -> TrackedObjectDescription? {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            guard text.hasSuffix("```"), let start = text.firstIndex(of: "\n"),
                  let end = text.range(of: "```", options: .backwards)?.lowerBound, start < end else { return nil }
            text = String(text[text.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let description = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              description.overallConfidence.isFinite,
              (0...1).contains(description.overallConfidence),
              description.attributes.values.allSatisfy({
                  $0.confidence.isFinite && (0...1).contains($0.confidence)
              }) else { return nil }
        return description
    }
}

public struct TrackedObjectRecord: Equatable, Identifiable, Sendable {
    public let trackID: UUID
    public let cameraID: UUID
    public let cameraName: String
    public let label: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let observationCount: Int
    public let bestConfidence: Double
    public let box: CGRect
    public let cropPath: String?
    public let cutoutPath: String?
    public let operatorGroupID: UUID?
    public let description: TrackedObjectDescription?
    public let describedAt: Date?

    public var id: UUID { trackID }
}

public struct ObjectTrackAssigner {
    public static let lowConfidenceThreshold = 0.1
    private static let trackableLabels: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "bus", "train", "truck", "boat"
    ]

    private struct Track {
        let id: UUID
        let label: String
        var box: CGRect
        var lastSeen: Date
        var velocity: CGPoint?

        func predictedBox(at time: Date) -> CGRect {
            let elapsed = time.timeIntervalSince(lastSeen)
            guard let velocity, elapsed.isFinite, elapsed > 0 else { return box }
            let predicted = box.offsetBy(dx: velocity.x * elapsed, dy: velocity.y * elapsed)
            return ObjectTrackAssigner.valid(predicted) ? predicted : box
        }

        mutating func update(box newBox: CGRect, at time: Date) {
            let elapsed = time.timeIntervalSince(lastSeen)
            if elapsed.isFinite, elapsed > 0 {
                let observed = CGPoint(
                    x: (newBox.midX - box.midX) / elapsed,
                    y: (newBox.midY - box.midY) / elapsed
                )
                velocity = observed.x.isFinite && observed.y.isFinite ? observed : nil
            }
            box = newBox
            lastSeen = time
        }
    }

    public var maximumGap: TimeInterval
    public var minimumIoU: CGFloat
    public var motionPredictionEnabled: Bool
    private var tracks: [UUID: Track] = [:]

    public init(maximumGap: TimeInterval = 2.0, minimumIoU: CGFloat = 0.25,
                motionPredictionEnabled: Bool = false) {
        self.maximumGap = max(0, maximumGap)
        self.minimumIoU = min(1, max(0, minimumIoU))
        self.motionPredictionEnabled = motionPredictionEnabled
    }

    public mutating func assign(_ objects: [DetectedObject], at time: Date = Date(),
                                highConfidenceThreshold: Double = 0.35,
                                lowConfidenceThreshold: Double = ObjectTrackAssigner.lowConfidenceThreshold) -> [DetectedObject] {
                    guard time.timeIntervalSince1970.isFinite else { return objects }
        tracks = tracks.filter { _, track in
            let age = time.timeIntervalSince(track.lastSeen)
            return age >= 0 && age <= maximumGap
        }

        let highThreshold = min(1, max(0, highConfidenceThreshold))
        let lowThreshold = min(highThreshold, max(0, lowConfidenceThreshold))
        let validIndices = objects.indices.filter {
            objects[$0].confidence.isFinite && (0...1).contains(objects[$0].confidence)
        }
        let highIndices = validIndices.filter { objects[$0].confidence >= highThreshold }
        let lowIndices = validIndices.filter {
            objects[$0].confidence >= lowThreshold && objects[$0].confidence < highThreshold
        }
        var assignedObjects = Set<Int>()
        var assignedTracks = Set<UUID>()
        var assignments: [Int: UUID] = [:]

        for indices in [highIndices, lowIndices] {
            var pairs: [(objectIndex: Int, trackID: UUID, overlap: CGFloat)] = []
            for objectIndex in indices {
                let object = objects[objectIndex]
                guard Self.trackableLabels.contains(object.label), Self.valid(object.box) else { continue }
                for track in tracks.values where track.label == object.label && !assignedTracks.contains(track.id) {
                    let observedOverlap = Self.intersectionOverUnion(object.box, track.box)
                    let predictedOverlap = motionPredictionEnabled
                        ? Self.intersectionOverUnion(object.box, track.predictedBox(at: time)) : 0
                    let overlap = motionPredictionEnabled && predictedOverlap >= minimumIoU
                        ? predictedOverlap + 1 : observedOverlap
                    if overlap >= minimumIoU {
                        pairs.append((objectIndex, track.id, overlap))
                    }
                }
            }
            pairs.sort {
                if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
                if objects[$0.objectIndex].id != objects[$1.objectIndex].id {
                    return objects[$0.objectIndex].id < objects[$1.objectIndex].id
                }
                if $0.trackID != $1.trackID { return $0.trackID.uuidString < $1.trackID.uuidString }
                return $0.objectIndex < $1.objectIndex
            }
            for pair in pairs where !assignedObjects.contains(pair.objectIndex) && !assignedTracks.contains(pair.trackID) {
                assignedObjects.insert(pair.objectIndex)
                assignedTracks.insert(pair.trackID)
                assignments[pair.objectIndex] = pair.trackID
                if var track = tracks[pair.trackID] {
                    track.update(box: objects[pair.objectIndex].box, at: time)
                    tracks[pair.trackID] = track
                }
            }
        }

        return objects.enumerated().map { index, object in
            guard Self.trackableLabels.contains(object.label), Self.valid(object.box) else { return object }
            if let trackID = assignments[index] { return object.assigning(trackID: trackID) }
            guard object.confidence.isFinite, (0...1).contains(object.confidence),
                object.confidence >= highThreshold else { return object }
            let trackID = UUID()
            tracks[trackID] = Track(id: trackID, label: object.label, box: object.box, lastSeen: time)
            return object.assigning(trackID: trackID)
        }
    }

    public mutating func reset() {
        tracks.removeAll(keepingCapacity: true)
    }

    private static func valid(_ box: CGRect) -> Bool {
        box.minX.isFinite && box.minY.isFinite && box.width.isFinite && box.height.isFinite
            && box.width > 0 && box.height > 0
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersection.width * intersection.height
        guard unionArea > 0 else { return 0 }
        return intersection.width * intersection.height / unionArea
    }
}

public enum LocalTrackingStoreError: LocalizedError {
    case open(String)
    case query(String)
    case untrackedObject
    case invalidMerge
    case missingTrack(UUID)
    case incompatibleTracks
    case invalidDescription
    case invalidEmbedding
    case invalidValidationPair
    case missingValidationEmbedding
    case alreadyGroupedPair
    case invalidVehicleTextEvidence

    public var errorDescription: String? {
        switch self {
        case .open(let detail): return "Cannot open local tracking database: \(detail)"
        case .query(let detail): return "Cannot update local tracking database: \(detail)"
        case .untrackedObject: return "Cannot persist an object without a track ID."
        case .invalidMerge: return "Select at least two tracks to group."
        case .missingTrack(let trackID): return "Track \(trackID) is no longer available."
        case .incompatibleTracks: return "People and vehicles cannot be grouped together."
        case .invalidDescription: return "The local VLM returned an invalid structured description."
        case .invalidEmbedding: return "ReID embeddings must contain 512 finite values."
        case .invalidValidationPair: return "Validation labels require different cameras and matching object categories."
        case .missingValidationEmbedding: return "Both tracks need stored ReID embeddings before labeling a pair."
        case .alreadyGroupedPair: return "Detach these tracks before labeling them as different."
        case .invalidVehicleTextEvidence: return "Vehicle text evidence requires a vehicle track, bounded candidates and a valid crop digest."
        }
    }
}

public struct CameraScanRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: UUID
    public let cameraName: String
    public let observedAt: Date
    public let answer: String

    public init(id: UUID = UUID(), cameraID: UUID, cameraName: String, observedAt: Date = Date(), answer: String) {
        self.id = id
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.observedAt = observedAt
        self.answer = answer
    }
}

public final class LocalTrackingStore: @unchecked Sendable {
    public static let retentionDays = 30

    private let databaseURL: URL
    private let database: OpaquePointer
    private let cropDirectory: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/identity-history.sqlite3")
    }

    public static func defaultImageURL(for record: TrackedObjectRecord) -> URL? {
        guard let path = record.cutoutPath ?? record.cropPath,
              URL(fileURLWithPath: path).lastPathComponent == path else { return nil }
        return defaultURL.deletingLastPathComponent()
            .appendingPathComponent("identity-crops", isDirectory: true)
            .appendingPathComponent(path)
    }

    public init(url: URL = LocalTrackingStore.defaultURL, now: Date = Date()) throws {
        databaseURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        cropDirectory = url.deletingLastPathComponent().appendingPathComponent("identity-crops", isDirectory: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed (\(result))"
            if let handle { sqlite3_close(handle) }
            throw LocalTrackingStoreError.open(detail)
        }
        database = handle
        sqlite3_busy_timeout(database, 3000)
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS tracked_objects (
                    track_id TEXT PRIMARY KEY,
                    camera_id TEXT NOT NULL,
                    camera_name TEXT NOT NULL,
                    label TEXT NOT NULL,
                    first_seen REAL NOT NULL,
                    last_seen REAL NOT NULL,
                    observation_count INTEGER NOT NULL,
                    best_confidence REAL NOT NULL,
                    box_x REAL NOT NULL,
                    box_y REAL NOT NULL,
                    box_width REAL NOT NULL,
                    box_height REAL NOT NULL,
                    crop_path TEXT,
                    cutout_path TEXT,
                    reid_embedding BLOB,
                    description_json TEXT,
                    described_at REAL
                )
                """)
            try ensureColumn("crop_path", declaration: "TEXT")
            try ensureColumn("cutout_path", declaration: "TEXT")
            try ensureColumn("reid_embedding", declaration: "BLOB")
            try ensureColumn("description_json", declaration: "TEXT")
            try ensureColumn("described_at", declaration: "REAL")
            try ensureColumn("vehicle_text_json", declaration: "TEXT")
            try execute("""
                CREATE TABLE IF NOT EXISTS operator_identity_groups (
                    track_id TEXT PRIMARY KEY,
                    group_id TEXT NOT NULL,
                    confirmed_at REAL NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS operator_identity_group_id ON operator_identity_groups(group_id)")
            try execute("""
                CREATE TABLE IF NOT EXISTS operator_reid_different_pairs (
                    track_a TEXT NOT NULL,
                    track_b TEXT NOT NULL,
                    confirmed_at REAL NOT NULL,
                    PRIMARY KEY(track_a, track_b)
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS tracked_objects_last_seen ON tracked_objects(last_seen DESC)")
            try execute("""
                CREATE TABLE IF NOT EXISTS automatic_camera_scans (
                    scan_id TEXT PRIMARY KEY,
                    camera_id TEXT NOT NULL,
                    camera_name TEXT NOT NULL,
                    observed_at REAL NOT NULL,
                    answer TEXT NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS automatic_camera_scans_time ON automatic_camera_scans(observed_at DESC, scan_id)")
            _ = try purgeExpired(now: now)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    public func saveAutomaticScan(_ record: CameraScanRecord) throws {
        guard record.observedAt.timeIntervalSince1970.isFinite,
              !record.cameraName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.answer.count <= 20_000 else { throw LocalTrackingStoreError.invalidDescription }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("INSERT INTO automatic_camera_scans(scan_id,camera_id,camera_name,observed_at,answer) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        bind(record.id.uuidString, at: 1, to: statement)
        bind(record.cameraID.uuidString, at: 2, to: statement)
        bind(record.cameraName, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, record.observedAt.timeIntervalSince1970)
        bind(record.answer, at: 5, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func automaticScans(limit: Int = 30, now: Date = Date()) throws -> [CameraScanRecord] {
        try automaticScanPage(limit: limit, after: nil, maximumRowID: Int64.max, now: now)
    }

    public func forEachAutomaticScanPage(pageSize: Int = 1000, now: Date = Date(), _ visit: ([CameraScanRecord]) throws -> Void) throws {
        let maximumRowID: Int64 = try {
            lock.lock()
            defer { lock.unlock() }
            let statement = try prepare("SELECT COALESCE(MAX(rowid),0) FROM automatic_camera_scans")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
            return sqlite3_column_int64(statement, 0)
        }()
        let size = max(1, min(1000, pageSize))
        var cursor: CameraScanRecord?
        while true {
            try Task.checkCancellation()
            let page = try automaticScanPage(limit: size, after: cursor, maximumRowID: maximumRowID, now: now)
            guard !page.isEmpty else { return }
            try visit(page)
            cursor = page.last
            if page.count < size { return }
        }
    }

    private func automaticScanPage(limit: Int, after cursor: CameraScanRecord?, maximumRowID: Int64, now: Date) throws -> [CameraScanRecord] {
        lock.lock()
        defer { lock.unlock() }
        let cursorClause = cursor == nil ? "" : "AND (observed_at < ? OR (observed_at = ? AND scan_id > ?))"
        let statement = try prepare("""
            SELECT scan_id,camera_id,camera_name,observed_at,answer FROM automatic_camera_scans
            WHERE observed_at>=? AND rowid<=? \(cursorClause) ORDER BY observed_at DESC,scan_id LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-Double(Self.retentionDays) * 86_400).timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, maximumRowID)
        if let cursor {
            sqlite3_bind_double(statement, 3, cursor.observedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, cursor.observedAt.timeIntervalSince1970)
            bind(cursor.id.uuidString, at: 5, to: statement)
        }
        sqlite3_bind_int(statement, cursor == nil ? 3 : 6, Int32(max(1, min(1000, limit))))
        var records: [CameraScanRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW, let id = UUID(uuidString: text(statement, 0)),
                  let cameraID = UUID(uuidString: text(statement, 1)) else { throw databaseError() }
            records.append(CameraScanRecord(id: id, cameraID: cameraID, cameraName: text(statement, 2),
                observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), answer: text(statement, 4)))
        }
    }

    @discardableResult
    public func record(_ object: DetectedObject, cameraID: UUID, cameraName: String,
                       cropJPEG: Data? = nil, cutoutPNG: Data? = nil,
                       reidEmbedding: [Float]? = nil,
                       at time: Date = Date()) throws -> Bool {
        guard let trackID = object.trackID else { throw LocalTrackingStoreError.untrackedObject }
        if let reidEmbedding,
           (reidEmbedding.count != 512 || !reidEmbedding.allSatisfy(\.isFinite)) {
            throw LocalTrackingStoreError.invalidEmbedding
        }
        lock.lock()
        defer { lock.unlock() }

        let previousEvidence = try trackEvidence(trackID)
        let exists = previousEvidence != nil
        let replaceEvidence = cropJPEG.map { !$0.isEmpty } == true
            && (previousEvidence == nil || previousEvidence?.cropPath == nil
                || object.confidence > (previousEvidence?.bestConfidence ?? 0))
        var cropPath: String?
        var cutoutPath: String?
        do {
            if replaceEvidence, let cropJPEG { cropPath = try saveCrop(cropJPEG, for: trackID) }
            if cropPath != nil, let cutoutPNG { cutoutPath = try saveCutout(cutoutPNG, for: trackID) }
        } catch {
            if let cropPath { removeCrop(at: cropPath) }
            if let cutoutPath { removeCrop(at: cutoutPath) }
            throw error
        }
        let statement: OpaquePointer
        do {
            statement = try prepare("""
            INSERT INTO tracked_objects (
                track_id, camera_id, camera_name, label, first_seen, last_seen,
                observation_count, best_confidence, box_x, box_y, box_width, box_height,
                crop_path, cutout_path, reid_embedding
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                camera_name=excluded.camera_name,
                last_seen=excluded.last_seen,
                observation_count=tracked_objects.observation_count + 1,
                best_confidence=max(tracked_objects.best_confidence, excluded.best_confidence),
                box_x=excluded.box_x, box_y=excluded.box_y,
                box_width=excluded.box_width, box_height=excluded.box_height,
                crop_path=COALESCE(excluded.crop_path, tracked_objects.crop_path),
                cutout_path=CASE WHEN excluded.crop_path IS NOT NULL THEN excluded.cutout_path ELSE tracked_objects.cutout_path END,
                reid_embedding=CASE WHEN excluded.crop_path IS NOT NULL THEN excluded.reid_embedding ELSE tracked_objects.reid_embedding END
            """)
        } catch {
            if let cropPath { removeCrop(at: cropPath) }
            if let cutoutPath { removeCrop(at: cutoutPath) }
            throw error
        }
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        bind(cameraID.uuidString, at: 2, to: statement)
        bind(cameraName, at: 3, to: statement)
        bind(object.label, at: 4, to: statement)
        sqlite3_bind_double(statement, 5, time.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, time.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, object.confidence)
        sqlite3_bind_double(statement, 8, object.box.minX)
        sqlite3_bind_double(statement, 9, object.box.minY)
        sqlite3_bind_double(statement, 10, object.box.width)
        sqlite3_bind_double(statement, 11, object.box.height)
        if let cropPath { bind(cropPath, at: 12, to: statement) }
        else { sqlite3_bind_null(statement, 12) }
        if let cutoutPath { bind(cutoutPath, at: 13, to: statement) }
        else { sqlite3_bind_null(statement, 13) }
        if let reidEmbedding {
            _ = reidEmbedding.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 14, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(statement, 14)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            if let cropPath { removeCrop(at: cropPath) }
            if let cutoutPath { removeCrop(at: cutoutPath) }
            throw databaseError()
        }
        if cropPath != nil {
            if let oldPath = previousEvidence?.cropPath { removeCrop(at: oldPath) }
            if let oldPath = previousEvidence?.cutoutPath { removeCrop(at: oldPath) }
        }
        return !exists
    }

    public func recentTracks(limit: Int = 200) throws -> [TrackedObjectRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
                 SELECT t.track_id, t.camera_id, t.camera_name, t.label, t.first_seen, t.last_seen,
                     t.observation_count, t.best_confidence, t.box_x, t.box_y, t.box_width,
                     t.box_height, t.crop_path, t.cutout_path, t.description_json, t.described_at, g.group_id
                 FROM tracked_objects t
                 LEFT JOIN operator_identity_groups g ON g.track_id = t.track_id
                 ORDER BY t.last_seen DESC, t.track_id ASC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(10_000, max(1, limit))))
        return try readTracks(statement)
    }

    public func forEachRecentTrackPage(pageSize: Int = 1000,
                                       _ body: ([TrackedObjectRecord]) throws -> Void) throws {
        var readDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path, &readDatabase, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard openResult == SQLITE_OK, let readDatabase else {
            if let readDatabase { sqlite3_close(readDatabase) }
            throw LocalTrackingStoreError.open("Could not open a read-only track-history connection.")
        }
        defer { sqlite3_close(readDatabase) }
        sqlite3_busy_timeout(readDatabase, 3000)

        let snapshotMaxRowID: Int64
        do {
            let snapshotStatement = try prepareReadOnly(
                "SELECT COALESCE(MAX(rowid), 0) FROM tracked_objects", database: readDatabase
            )
            defer { sqlite3_finalize(snapshotStatement) }
            guard sqlite3_step(snapshotStatement) == SQLITE_ROW else { throw databaseError(readDatabase) }
            snapshotMaxRowID = sqlite3_column_int64(snapshotStatement, 0)
        }
        let boundedPageSize = Int32(min(2000, max(1, pageSize)))
        var cursor: String?
        while true {
            let statement: OpaquePointer
            if let cursor {
                statement = try prepareReadOnly("""
                    SELECT t.track_id, t.camera_id, t.camera_name, t.label, t.first_seen, t.last_seen,
                        t.observation_count, t.best_confidence, t.box_x, t.box_y, t.box_width,
                        t.box_height, t.crop_path, t.cutout_path, t.description_json, t.described_at, g.group_id
                    FROM tracked_objects t
                    LEFT JOIN operator_identity_groups g ON g.track_id = t.track_id
                    WHERE t.rowid <= ? AND t.track_id > ?
                    ORDER BY t.track_id ASC LIMIT ?
                    """, database: readDatabase)
                sqlite3_bind_int64(statement, 1, snapshotMaxRowID)
                bind(cursor, at: 2, to: statement)
                sqlite3_bind_int(statement, 3, boundedPageSize)
            } else {
                statement = try prepareReadOnly("""
                    SELECT t.track_id, t.camera_id, t.camera_name, t.label, t.first_seen, t.last_seen,
                        t.observation_count, t.best_confidence, t.box_x, t.box_y, t.box_width,
                        t.box_height, t.crop_path, t.cutout_path, t.description_json, t.described_at, g.group_id
                    FROM tracked_objects t
                    LEFT JOIN operator_identity_groups g ON g.track_id = t.track_id
                    WHERE t.rowid <= ?
                    ORDER BY t.track_id ASC LIMIT ?
                    """, database: readDatabase)
                sqlite3_bind_int64(statement, 1, snapshotMaxRowID)
                sqlite3_bind_int(statement, 2, boundedPageSize)
            }
            let page: [TrackedObjectRecord]
            do {
                page = try readTracks(statement, errorDatabase: readDatabase)
                sqlite3_finalize(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
            guard let last = page.last else { break }
            try body(page)
            try Task.checkCancellation()
            cursor = last.trackID.uuidString
        }
    }

    private func prepareReadOnly(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError(database) }
        return statement
    }

    private func readTracks(_ statement: OpaquePointer,
                            errorDatabase: OpaquePointer? = nil) throws -> [TrackedObjectRecord] {
        var records: [TrackedObjectRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw databaseError(errorDatabase) }
            guard let trackID = UUID(uuidString: text(statement, 0)),
                  let cameraID = UUID(uuidString: text(statement, 1)) else { continue }
            records.append(TrackedObjectRecord(
                trackID: trackID,
                cameraID: cameraID,
                cameraName: text(statement, 2),
                label: text(statement, 3),
                firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                observationCount: Int(sqlite3_column_int64(statement, 6)),
                bestConfidence: sqlite3_column_double(statement, 7),
                box: CGRect(
                    x: sqlite3_column_double(statement, 8),
                    y: sqlite3_column_double(statement, 9),
                    width: sqlite3_column_double(statement, 10),
                    height: sqlite3_column_double(statement, 11)
                ),
                cropPath: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : text(statement, 12),
                cutoutPath: sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil : text(statement, 13),
                operatorGroupID: sqlite3_column_type(statement, 16) == SQLITE_NULL
                    ? nil : UUID(uuidString: text(statement, 16)),
                description: sqlite3_column_type(statement, 14) == SQLITE_NULL
                    ? nil : TrackedObjectDescription.parse(text(statement, 14)),
                describedAt: sqlite3_column_type(statement, 15) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 15))
            ))
        }
        return records
    }

    public func contains(trackID: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try trackExists(trackID)
    }

    public func track(trackID: UUID) throws -> TrackedObjectRecord? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            SELECT t.track_id, t.camera_id, t.camera_name, t.label, t.first_seen, t.last_seen,
                t.observation_count, t.best_confidence, t.box_x, t.box_y, t.box_width,
                t.box_height, t.crop_path, t.cutout_path, t.description_json, t.described_at, g.group_id
            FROM tracked_objects t
            LEFT JOIN operator_identity_groups g ON g.track_id = t.track_id
            WHERE t.track_id = ? LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        let tracks = try readTracks(statement)
        return tracks.first
    }

    public func shouldCaptureCrop(for trackID: UUID, confidence: Double) throws -> Bool {
        guard confidence.isFinite, (0...1).contains(confidence) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let evidence = try trackEvidence(trackID) else { return true }
        return evidence.cropPath == nil || confidence > evidence.bestConfidence
    }

    public func trackIDs() throws -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT track_id FROM tracked_objects")
        defer { sqlite3_finalize(statement) }
        var trackIDs = Set<UUID>()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return trackIDs }
            guard result == SQLITE_ROW, let trackID = UUID(uuidString: text(statement, 0)) else {
                throw databaseError()
            }
            trackIDs.insert(trackID)
        }
    }

    public func reidEmbedding(for trackID: UUID) throws -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT reid_embedding FROM tracked_objects WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0)) / MemoryLayout<Float>.size
        guard count == 512, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let vector = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: count))
        return vector.allSatisfy(\.isFinite) ? vector : nil
    }

    public func labelDifferent(trackA: UUID, trackB: UUID, confirmedAt: Date = Date()) throws {
        guard trackA != trackB else { throw LocalTrackingStoreError.invalidValidationPair }
        let pair = [trackA.uuidString, trackB.uuidString].sorted()
        lock.lock()
        defer { lock.unlock() }
        guard let categoryA = try category(for: trackA),
              let categoryB = try category(for: trackB), categoryA == categoryB else {
            throw LocalTrackingStoreError.invalidValidationPair
        }
        let cameras = try cameraIDs(for: pair)
        guard cameras.count == 2, cameras[0] != cameras[1] else {
            throw LocalTrackingStoreError.invalidValidationPair
        }
        guard try reidEmbeddingExists(for: pair[0]), try reidEmbeddingExists(for: pair[1]) else {
            throw LocalTrackingStoreError.missingValidationEmbedding
        }
        let groupA = try operatorGroup(for: trackA)
        let groupB = try operatorGroup(for: trackB)
        guard groupA == nil || groupA != groupB else {
            throw LocalTrackingStoreError.alreadyGroupedPair
        }
        let statement = try prepare("""
            INSERT INTO operator_reid_different_pairs(track_a, track_b, confirmed_at)
            VALUES(?, ?, ?)
            ON CONFLICT(track_a, track_b) DO UPDATE SET confirmed_at=excluded.confirmed_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(pair[0], at: 1, to: statement)
        bind(pair[1], at: 2, to: statement)
        sqlite3_bind_double(statement, 3, confirmedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func removeDifferentLabel(trackA: UUID, trackB: UUID) throws {
        let pair = [trackA.uuidString, trackB.uuidString].sorted()
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("DELETE FROM operator_reid_different_pairs WHERE track_a = ? AND track_b = ?")
        defer { sqlite3_finalize(statement) }
        bind(pair[0], at: 1, to: statement)
        bind(pair[1], at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func reidValidationSamples(limit: Int = 10_000) throws -> [ReIDValidationSample] {
        lock.lock()
        defer { lock.unlock() }
        let maxRows = Int32(min(50_000, max(1, limit)))
        let query = """
            SELECT a.track_id, b.track_id, a.reid_embedding, b.reid_embedding, 1
            FROM tracked_objects a
            JOIN operator_identity_groups ga ON ga.track_id = a.track_id
            JOIN tracked_objects b ON b.track_id > a.track_id AND b.camera_id != a.camera_id
            JOIN operator_identity_groups gb ON gb.track_id = b.track_id AND gb.group_id = ga.group_id
            WHERE a.reid_embedding IS NOT NULL AND b.reid_embedding IS NOT NULL
              AND ((a.label = 'person' AND b.label = 'person') OR
                   (a.label IN ('bicycle','car','motorcycle','bus','train','truck','boat') AND
                    b.label IN ('bicycle','car','motorcycle','bus','train','truck','boat')))
            UNION ALL
            SELECT a.track_id, b.track_id, a.reid_embedding, b.reid_embedding, 0
            FROM operator_reid_different_pairs p
            JOIN tracked_objects a ON a.track_id = p.track_a
            JOIN tracked_objects b ON b.track_id = p.track_b
            LEFT JOIN operator_identity_groups ga ON ga.track_id = a.track_id
            LEFT JOIN operator_identity_groups gb ON gb.track_id = b.track_id
            WHERE a.camera_id != b.camera_id
              AND a.reid_embedding IS NOT NULL AND b.reid_embedding IS NOT NULL
              AND (ga.group_id IS NULL OR gb.group_id IS NULL OR ga.group_id != gb.group_id)
              AND ((a.label = 'person' AND b.label = 'person') OR
                   (a.label IN ('bicycle','car','motorcycle','bus','train','truck','boat') AND
                    b.label IN ('bicycle','car','motorcycle','bus','train','truck','boat')))
            LIMIT ?
            """
        let statement = try prepare(query)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, maxRows)
        var samples: [ReIDValidationSample] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw databaseError() }
            guard let trackA = UUID(uuidString: text(statement, 0)),
                  let trackB = UUID(uuidString: text(statement, 1)),
                  let vectorA = embedding(statement, column: 2),
                  let vectorB = embedding(statement, column: 3),
                  let distance = Self.cosineDistance(vectorA, vectorB) else { continue }
            samples.append(ReIDValidationSample(
                trackA: trackA, trackB: trackB,
                pair: LabeledReIDPair(distance: Double(distance), sameObject: sqlite3_column_int(statement, 4) == 1)
            ))
        }
        return samples
    }

    public func reidValidationCandidates(limit: Int = 40) throws -> [ReIDValidationCandidate] {
        let tracks = try recentTracks(limit: 1000)
        let samples = try reidValidationSamples(limit: 50_000)
        let labeled = Set(samples.map { Self.pairKey($0.trackA, $0.trackB) })
        var embeddings: [UUID: [Float]] = [:]
        for track in tracks {
            if let vector = try reidEmbedding(for: track.trackID) { embeddings[track.trackID] = vector }
        }
        var candidates: [ReIDValidationCandidate] = []
        for index in tracks.indices {
            let trackA = tracks[index]
            guard let vectorA = embeddings[trackA.trackID], let categoryA = Self.category(trackA.label) else { continue }
            for trackB in tracks.dropFirst(index + 1) {
                guard trackA.cameraID != trackB.cameraID,
                      Self.category(trackB.label) == categoryA,
                      trackA.operatorGroupID == nil || trackA.operatorGroupID != trackB.operatorGroupID,
                      !labeled.contains(Self.pairKey(trackA.trackID, trackB.trackID)),
                      let vectorB = embeddings[trackB.trackID],
                      let distance = Self.cosineDistance(vectorA, vectorB) else { continue }
                candidates.append(ReIDValidationCandidate(trackA: trackA, trackB: trackB, distance: Double(distance)))
            }
        }
        return candidates.sorted { $0.distance < $1.distance }
            .prefix(max(1, min(200, limit))).map { $0 }
    }

    public func saveDescription(_ description: TrackedObjectDescription,
                                for trackID: UUID, at time: Date = Date()) throws {
        guard let data = try? JSONEncoder().encode(description),
              let json = String(data: data, encoding: .utf8) else {
            throw LocalTrackingStoreError.invalidDescription
        }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE tracked_objects SET description_json = ?, described_at = ? WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(json, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
        bind(trackID.uuidString, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(database) > 0 else { throw LocalTrackingStoreError.missingTrack(trackID) }
    }

    public func saveVehicleTextEvidence(_ evidence: VehicleTextEvidence) throws {
        guard evidence.isValid else { throw LocalTrackingStoreError.invalidVehicleTextEvidence }
        let data = try JSONEncoder().encode(evidence)
        lock.lock()
        defer { lock.unlock() }
        guard try category(for: evidence.trackID) == "vehicle" else {
            throw LocalTrackingStoreError.invalidVehicleTextEvidence
        }
        let statement = try prepare("UPDATE tracked_objects SET vehicle_text_json=? WHERE track_id=?")
        defer { sqlite3_finalize(statement) }
        bind(String(decoding: data, as: UTF8.self), at: 1, to: statement)
        bind(evidence.trackID.uuidString, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(database) == 1 else { throw LocalTrackingStoreError.missingTrack(evidence.trackID) }
    }

    public func vehicleTextEvidence(for trackID: UUID) throws -> VehicleTextEvidence? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT vehicle_text_json FROM tracked_objects WHERE track_id=?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw databaseError() }
          guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, 0) else { return nil }
          let json = String(cString: value)
        guard json.utf8.count <= 64 * 1024,
              let evidence = try? JSONDecoder().decode(VehicleTextEvidence.self, from: Data(json.utf8)),
              evidence.trackID == trackID, evidence.isValid else {
            throw LocalTrackingStoreError.invalidVehicleTextEvidence
        }
        return evidence
    }

    public func clearVehicleTextEvidence(for trackID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE tracked_objects SET vehicle_text_json=NULL WHERE track_id=?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    @discardableResult
    public func purgeExpired(now: Date = Date()) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60).timeIntervalSince1970
        let scans = try prepare("DELETE FROM automatic_camera_scans WHERE observed_at < ?")
        sqlite3_bind_double(scans, 1, cutoff)
        guard sqlite3_step(scans) == SQLITE_DONE else {
            sqlite3_finalize(scans)
            throw databaseError()
        }
        sqlite3_finalize(scans)
        let paths = try cropPaths(olderThan: cutoff)
        let unlink = try prepare("""
            DELETE FROM operator_identity_groups
            WHERE track_id IN (SELECT track_id FROM tracked_objects WHERE last_seen < ?)
            """)
        sqlite3_bind_double(unlink, 1, cutoff)
        guard sqlite3_step(unlink) == SQLITE_DONE else {
            sqlite3_finalize(unlink)
            throw databaseError()
        }
        sqlite3_finalize(unlink)
        let unlinkValidation = try prepare("""
            DELETE FROM operator_reid_different_pairs
            WHERE track_a IN (SELECT track_id FROM tracked_objects WHERE last_seen < ?)
               OR track_b IN (SELECT track_id FROM tracked_objects WHERE last_seen < ?)
            """)
        sqlite3_bind_double(unlinkValidation, 1, cutoff)
        sqlite3_bind_double(unlinkValidation, 2, cutoff)
        guard sqlite3_step(unlinkValidation) == SQLITE_DONE else {
            sqlite3_finalize(unlinkValidation)
            throw databaseError()
        }
        sqlite3_finalize(unlinkValidation)
        let statement = try prepare("DELETE FROM tracked_objects WHERE last_seen < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        paths.forEach(removeCrop)
        return Int(sqlite3_changes(database))
    }

    public func delete(trackID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let paths = try cropPaths(for: trackID)
        let unlink = try prepare("DELETE FROM operator_identity_groups WHERE track_id = ?")
        bind(trackID.uuidString, at: 1, to: unlink)
        guard sqlite3_step(unlink) == SQLITE_DONE else {
            sqlite3_finalize(unlink)
            throw databaseError()
        }
        sqlite3_finalize(unlink)
        let unlinkValidation = try prepare("DELETE FROM operator_reid_different_pairs WHERE track_a = ? OR track_b = ?")
        bind(trackID.uuidString, at: 1, to: unlinkValidation)
        bind(trackID.uuidString, at: 2, to: unlinkValidation)
        guard sqlite3_step(unlinkValidation) == SQLITE_DONE else {
            sqlite3_finalize(unlinkValidation)
            throw databaseError()
        }
        sqlite3_finalize(unlinkValidation)
        let statement = try prepare("DELETE FROM tracked_objects WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        paths.forEach(removeCrop)
    }

    @discardableResult
    public func mergeTracks(_ trackIDs: [UUID], confirmedAt: Date = Date()) throws -> UUID {
        let uniqueIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        guard uniqueIDs.count >= 2 else { throw LocalTrackingStoreError.invalidMerge }
        lock.lock()
        defer { lock.unlock() }

        var existingGroups: [UUID] = []
        var selectedCategory: String?
        for trackID in uniqueIDs {
            guard let category = try category(for: trackID) else {
                throw LocalTrackingStoreError.missingTrack(trackID)
            }
            if let selectedCategory, selectedCategory != category {
                throw LocalTrackingStoreError.incompatibleTracks
            }
            selectedCategory = category
            if let groupID = try operatorGroup(for: trackID), !existingGroups.contains(groupID) {
                existingGroups.append(groupID)
            }
        }
        let groupID = existingGroups.first ?? UUID()

        try execute("BEGIN IMMEDIATE")
        do {
            for existingGroup in existingGroups where existingGroup != groupID {
                let update = try prepare("UPDATE operator_identity_groups SET group_id = ? WHERE group_id = ?")
                bind(groupID.uuidString, at: 1, to: update)
                bind(existingGroup.uuidString, at: 2, to: update)
                guard sqlite3_step(update) == SQLITE_DONE else {
                    sqlite3_finalize(update)
                    throw databaseError()
                }
                sqlite3_finalize(update)
            }
            for trackID in uniqueIDs {
                let link = try prepare("""
                    INSERT INTO operator_identity_groups(track_id, group_id, confirmed_at)
                    VALUES(?, ?, ?)
                    ON CONFLICT(track_id) DO UPDATE SET
                        group_id=excluded.group_id, confirmed_at=excluded.confirmed_at
                    """)
                bind(trackID.uuidString, at: 1, to: link)
                bind(groupID.uuidString, at: 2, to: link)
                sqlite3_bind_double(link, 3, confirmedAt.timeIntervalSince1970)
                guard sqlite3_step(link) == SQLITE_DONE else {
                    sqlite3_finalize(link)
                    throw databaseError()
                }
                sqlite3_finalize(link)
            }
            try execute("""
                DELETE FROM operator_reid_different_pairs
                WHERE EXISTS (
                    SELECT 1 FROM operator_identity_groups ga
                    JOIN operator_identity_groups gb ON gb.group_id = ga.group_id
                    WHERE ga.track_id = operator_reid_different_pairs.track_a
                      AND gb.track_id = operator_reid_different_pairs.track_b
                )
                """)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return groupID
    }

    public func detachTrack(_ trackID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("DELETE FROM operator_identity_groups WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func imageURL(for record: TrackedObjectRecord) -> URL? {
        guard let path = record.cropPath,
              URL(fileURLWithPath: path).lastPathComponent == path else { return nil }
        return cropDirectory.appendingPathComponent(path)
    }

    public func cutoutURL(for record: TrackedObjectRecord) -> URL? {
        guard let path = record.cutoutPath,
              URL(fileURLWithPath: path).lastPathComponent == path else { return nil }
        return cropDirectory.appendingPathComponent(path)
    }

    private func trackExists(_ trackID: UUID) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM tracked_objects WHERE track_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
        return result == SQLITE_ROW
    }

    private func trackEvidence(_ trackID: UUID) throws -> (bestConfidence: Double, cropPath: String?, cutoutPath: String?)? {
        let statement = try prepare("SELECT best_confidence, crop_path, cutout_path FROM tracked_objects WHERE track_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw databaseError() }
        guard result == SQLITE_ROW else { return nil }
        return (
            sqlite3_column_double(statement, 0),
            sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : text(statement, 1),
            sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : text(statement, 2)
        )
    }

    private func ensureColumn(_ column: String, declaration: String) throws {
        let statement = try prepare("PRAGMA table_info(tracked_objects)")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return }
        }
        try execute("ALTER TABLE tracked_objects ADD COLUMN \(column) \(declaration)")
    }

    private func saveCrop(_ data: Data, for trackID: UUID) throws -> String? {
        guard !data.isEmpty else { return nil }
        try FileManager.default.createDirectory(
            at: cropDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = "\(trackID.uuidString.lowercased())_\(UUID().uuidString.lowercased()).jpg"
        let url = cropDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return name
    }

    private func saveCutout(_ data: Data, for trackID: UUID) throws -> String? {
        guard !data.isEmpty else { return nil }
        try FileManager.default.createDirectory(
            at: cropDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = "\(trackID.uuidString.lowercased())_\(UUID().uuidString.lowercased())_cutout.png"
        let url = cropDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return name
    }

    private func cropPaths(olderThan cutoff: Double) throws -> [String] {
        let statement = try prepare("SELECT crop_path, cutout_path FROM tracked_objects WHERE last_seen < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        var paths: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return paths }
            guard result == SQLITE_ROW else { throw databaseError() }
            for column in 0..<2 where sqlite3_column_type(statement, Int32(column)) != SQLITE_NULL {
                paths.append(text(statement, Int32(column)))
            }
        }
    }

    private func cropPaths(for trackID: UUID) throws -> [String] {
        let statement = try prepare("SELECT crop_path, cutout_path FROM tracked_objects WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return [] }
        return (0..<2).compactMap { column in
            guard sqlite3_column_type(statement, Int32(column)) != SQLITE_NULL else { return nil }
            return text(statement, Int32(column))
        }
    }

    private func category(for trackID: UUID) throws -> String? {
        let statement = try prepare("SELECT label FROM tracked_objects WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.category(text(statement, 0))
    }

    private func cameraIDs(for trackIDs: [String]) throws -> [String] {
        let statement = try prepare("SELECT camera_id FROM tracked_objects WHERE track_id IN (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(trackIDs[0], at: 1, to: statement)
        bind(trackIDs[1], at: 2, to: statement)
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(text(statement, 0)) }
        return values
    }

    private func reidEmbeddingExists(for trackID: String) throws -> Bool {
        let statement = try prepare("SELECT reid_embedding FROM tracked_objects WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return embedding(statement, column: 0) != nil
    }

    private func embedding(_ statement: OpaquePointer, column: Int32) -> [Float]? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              sqlite3_column_bytes(statement, column) == 512 * MemoryLayout<Float>.size,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let vector = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: 512))
        return vector.allSatisfy(\.isFinite) ? vector : nil
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == 512, rhs.count == 512 else { return nil }
        let similarity = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        guard similarity.isFinite else { return nil }
        return max(0, min(2, 1 - similarity))
    }

    private static func category(_ label: String) -> String? {
        if label == "person" { return "person" }
        if ["bicycle", "car", "motorcycle", "bus", "train", "truck", "boat"].contains(label) {
            return "vehicle"
        }
        return nil
    }

    private static func pairKey(_ lhs: UUID, _ rhs: UUID) -> String {
        [lhs.uuidString, rhs.uuidString].sorted().joined(separator: ":")
    }

    private func operatorGroup(for trackID: UUID) throws -> UUID? {
        let statement = try prepare("SELECT group_id FROM operator_identity_groups WHERE track_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(trackID.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return UUID(uuidString: text(statement, 0))
    }

    private func removeCrop(at path: String) {
        guard URL(fileURLWithPath: path).lastPathComponent == path else { return }
        try? FileManager.default.removeItem(at: cropDirectory.appendingPathComponent(path))
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw LocalTrackingStoreError.query(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func databaseError(_ handle: OpaquePointer? = nil) -> LocalTrackingStoreError {
        LocalTrackingStoreError.query(String(cString: sqlite3_errmsg(handle ?? database)))
    }
}