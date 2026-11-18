import Foundation
import CoreGraphics
import SQLite3
import Darwin

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
    private let failureLock = NSLock()
    private var persistenceFailure: String?
    /// Sticky diagnostic, including errors from background writers whose callers cannot throw.
    public var lastPersistenceError: String? { failureLock.withLock { persistenceFailure } }
    private let database: OpaquePointer
    private let cropDirectory: URL
    private let lock = NSRecursiveLock()
#if DEBUG
    var narrativeJPEGWriteTestHook: ((FileHandle, URL, Data) throws -> Void)?
    var durableAuditRestoreTestHook: (() throws -> Void)?
#endif

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
            try? execute("PRAGMA journal_mode=WAL")
            try? execute("PRAGMA synchronous=NORMAL")
            try? execute("PRAGMA wal_autocheckpoint=1000")
            try? execute("PRAGMA journal_size_limit=67108864")
            try? execute("PRAGMA cache_size=-16000")
            try? execute("PRAGMA temp_store=MEMORY")
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
            try ensureColumn("crop_quality", declaration: "REAL")
            try ensureColumn("chroma_blob", declaration: "BLOB")
            try ensureColumn("chroma_code", declaration: "TEXT")
            try ensureColumn("chroma_bucket", declaration: "INTEGER")
            try ensureColumn("hsv_blob", declaration: "BLOB")
            try ensureColumn("upper_color", declaration: "TEXT")
            try ensureColumn("lower_color", declaration: "TEXT")
            try ensureColumn("vehicle_color", declaration: "TEXT")
            try ensureColumn("resolved_sex", declaration: "TEXT")
            try ensureColumn("identity_state", declaration: "TEXT")
            try ensureColumn("identity_score", declaration: "REAL")
            try ensureColumn("ghost_identity_id", declaration: "TEXT")
            try ensureColumn("is_best", declaration: "INTEGER DEFAULT 0")
            try ensureACTATables()
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

    // Reserve against writers in other connections while the sidecar commits.
    // This does not make the two databases crash-atomic.
    func withIdentityReadReservation<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        defer { try? execute("ROLLBACK") }
        return try operation()
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
        do {
            let statement = try prepare("UPDATE tracked_objects SET description_json = ?, described_at = ? WHERE track_id = ?")
            defer { sqlite3_finalize(statement) }
            bind(json, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, time.timeIntervalSince1970)
            bind(trackID.uuidString, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(database) > 0 else { throw LocalTrackingStoreError.missingTrack(trackID) }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        try? syncLocalTrackToACTAKnowledge(trackID: trackID, now: time)
    }

    public func saveVehicleTextEvidence(_ evidence: VehicleTextEvidence) throws {
        guard evidence.isValid else { throw LocalTrackingStoreError.invalidVehicleTextEvidence }
        let data = try JSONEncoder().encode(evidence)
        lock.lock()
        do {
            guard try category(for: evidence.trackID) == "vehicle" else {
                throw LocalTrackingStoreError.invalidVehicleTextEvidence
            }
            let statement = try prepare("UPDATE tracked_objects SET vehicle_text_json=? WHERE track_id=?")
            defer { sqlite3_finalize(statement) }
            bind(String(decoding: data, as: UTF8.self), at: 1, to: statement)
            bind(evidence.trackID.uuidString, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            guard sqlite3_changes(database) == 1 else { throw LocalTrackingStoreError.missingTrack(evidence.trackID) }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        try? syncLocalTrackToACTAKnowledge(trackID: evidence.trackID, now: evidence.readAt)
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
        guard sqlite3_changes(database) == 1 else { throw LocalTrackingStoreError.missingTrack(trackID) }
    }

    @discardableResult
    public func clearVehicleTextEvidence(matching expected: VehicleTextEvidence) throws -> Bool {
        guard expected.isValid else { throw LocalTrackingStoreError.invalidVehicleTextEvidence }
        lock.lock()
        defer { lock.unlock() }
        let query = try prepare("SELECT vehicle_text_json FROM tracked_objects WHERE track_id=?")
        defer { sqlite3_finalize(query) }
        bind(expected.trackID.uuidString, at: 1, to: query)
        let step = sqlite3_step(query)
        if step == SQLITE_DONE { throw LocalTrackingStoreError.missingTrack(expected.trackID) }
        guard step == SQLITE_ROW else { throw databaseError() }
        guard sqlite3_column_type(query, 0) != SQLITE_NULL,
              let value = sqlite3_column_text(query, 0) else { return false }
        let json = String(cString: value)
        guard json.utf8.count <= 64 * 1024,
              let current = try? JSONDecoder().decode(VehicleTextEvidence.self, from: Data(json.utf8)),
              current.isValid, current.trackID == expected.trackID else {
            throw LocalTrackingStoreError.invalidVehicleTextEvidence
        }
        guard current == expected else { return false }
        let statement = try prepare("UPDATE tracked_objects SET vehicle_text_json=NULL WHERE track_id=? AND vehicle_text_json=?")
        defer { sqlite3_finalize(statement) }
        bind(expected.trackID.uuidString, at: 1, to: statement)
        bind(json, at: 2, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        return sqlite3_changes(database) == 1
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
        let error = LocalTrackingStoreError.query(String(cString: sqlite3_errmsg(handle ?? database)))
        failureLock.withLock { persistenceFailure = error.localizedDescription }
        return error
    }

    // MARK: - Ghost Analytics SQLite Persistence

    private func ensureTableColumn(table: String, column: String, declaration: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return }
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
    }

    private func ensureACTATables() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_identities (
                identity_id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                display_code TEXT NOT NULL,
                profile_json TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_camera_links (
                link_key TEXT PRIMARY KEY,
                from_camera_id TEXT NOT NULL,
                to_camera_id TEXT NOT NULL,
                transition_count INTEGER NOT NULL,
                mean_transit_sec REAL NOT NULL,
                min_transit_sec REAL NOT NULL,
                max_transit_sec REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_dedup_decisions (
                pair_key TEXT PRIMARY KEY,
                id_a TEXT NOT NULL,
                id_b TEXT NOT NULL,
                layer TEXT NOT NULL,
                should_merge INTEGER NOT NULL,
                record_cannot_link INTEGER NOT NULL,
                confidence REAL NOT NULL,
                reason TEXT NOT NULL,
                decided_at REAL NOT NULL,
                evidence_hash TEXT
            )
            """)
        try ensureTableColumn(table: "ghost_dedup_decisions", column: "evidence_hash", declaration: "TEXT")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_narrative_chapters (
                chapter_id TEXT PRIMARY KEY,
                camera_id TEXT NOT NULL,
                camera_name TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                chapter_json TEXT NOT NULL,
                ai_summary TEXT,
                operator_text TEXT,
                operator_marked INTEGER NOT NULL DEFAULT 0,
                pinned INTEGER NOT NULL DEFAULT 0,
                frame_count INTEGER NOT NULL DEFAULT 0,
                sighting_count INTEGER NOT NULL DEFAULT 0,
                identity_count INTEGER NOT NULL DEFAULT 0,
                collage_path TEXT
            )
            """)
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "ai_summary", declaration: "TEXT")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "operator_text", declaration: "TEXT")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "operator_marked", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "pinned", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "frame_count", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "sighting_count", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "identity_count", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_narrative_chapters", column: "collage_path", declaration: "TEXT")
        try execute("CREATE INDEX IF NOT EXISTS ghost_narrative_chapters_time ON ghost_narrative_chapters(ended_at DESC)")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_vehicle_registry_cache (
                plate_number TEXT PRIMARY KEY,
                record_json TEXT NOT NULL,
                fetched_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_alert_mentor_briefs (
                alert_id TEXT PRIMARY KEY,
                camera_id TEXT NOT NULL,
                brief_json TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_camera_roles (
                camera_id TEXT PRIMARY KEY,
                role_json TEXT NOT NULL,
                intel_json TEXT,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_ai_cache (
                request_hash TEXT PRIMARY KEY,
                task_type TEXT NOT NULL,
                prompt_version TEXT NOT NULL,
                response_json TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_ai_cache_time ON ghost_ai_cache(created_at DESC)")

        // Semantic Knowledge Layer tables
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_attribute_index (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                track_id TEXT NOT NULL,
                identity_id TEXT NOT NULL,
                camera_id TEXT NOT NULL,
                captured_at REAL NOT NULL,
                facet TEXT NOT NULL,
                value TEXT NOT NULL,
                confidence REAL NOT NULL,
                crop_quality REAL NOT NULL,
                source TEXT NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_attr_facet_val ON ghost_attribute_index(facet, value)")
        try execute("CREATE INDEX IF NOT EXISTS ghost_attr_identity ON ghost_attribute_index(identity_id)")
        try execute("CREATE INDEX IF NOT EXISTS ghost_attr_track ON ghost_attribute_index(track_id)")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_identity_dossiers (
                identity_id TEXT PRIMARY KEY,
                display_name TEXT,
                kind TEXT NOT NULL,
                facets_json TEXT NOT NULL,
                alternatives_json TEXT NOT NULL,
                summary_line TEXT NOT NULL,
                text_blob TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_visits (
                visit_id TEXT PRIMARY KEY,
                identity_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                camera_ids_json TEXT NOT NULL,
                track_ids_json TEXT NOT NULL,
                sighting_count INTEGER NOT NULL,
                best_track_id TEXT NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_visits_identity_time ON ghost_visits(identity_id, started_at DESC)")

        try? execute("CREATE VIRTUAL TABLE IF NOT EXISTS ghost_identity_fts USING fts5(identity_id UNINDEXED, summary_line, text_blob)")
        try? execute("CREATE VIRTUAL TABLE IF NOT EXISTS ghost_crop_fts USING fts5(track_id UNINDEXED, identity_id UNINDEXED, description_text)")

        // Agent Conversation History, Focus Memory, Chain Debt & Actions
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_chat_threads (
                thread_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                focus_json TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                operator_name TEXT NOT NULL DEFAULT 'operator',
                kind TEXT NOT NULL DEFAULT 'general',
                severity TEXT NOT NULL DEFAULT 'normal',
                pinned INTEGER NOT NULL DEFAULT 0,
                last_response_id TEXT,
                pending_outputs_json TEXT
            )
            """)
        try ensureTableColumn(table: "ghost_chat_threads", column: "operator_name", declaration: "TEXT NOT NULL DEFAULT 'operator'")
        try ensureTableColumn(table: "ghost_chat_threads", column: "kind", declaration: "TEXT NOT NULL DEFAULT 'general'")
        try ensureTableColumn(table: "ghost_chat_threads", column: "severity", declaration: "TEXT NOT NULL DEFAULT 'normal'")
        try ensureTableColumn(table: "ghost_chat_threads", column: "pinned", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_chat_threads", column: "last_response_id", declaration: "TEXT")
        try ensureTableColumn(table: "ghost_chat_threads", column: "pending_outputs_json", declaration: "TEXT")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_chat_messages (
                message_id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                structured_json TEXT,
                created_at REAL NOT NULL,
                clip_id TEXT,
                call_id TEXT
            )
            """)
        try ensureTableColumn(table: "ghost_chat_messages", column: "clip_id", declaration: "TEXT")
        try ensureTableColumn(table: "ghost_chat_messages", column: "call_id", declaration: "TEXT")
        try ensureTableColumn(table: "ghost_chat_messages", column: "review_safe_context", declaration: "INTEGER NOT NULL DEFAULT 0")
        try ensureTableColumn(table: "ghost_chat_messages", column: "safe_offline_chain_id", declaration: "TEXT")
        try ensureTableColumn(table: "ghost_chat_messages", column: "safe_offline_debt_json", declaration: "TEXT")
        try execute("""
            CREATE TRIGGER IF NOT EXISTS ghost_chat_context_invalidate
            AFTER UPDATE OF content, role, structured_json ON ghost_chat_messages
            BEGIN
                UPDATE ghost_chat_messages SET review_safe_context = 0,
                    safe_offline_chain_id = NULL, safe_offline_debt_json = NULL
                    WHERE message_id = NEW.message_id;
            END
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_chat_messages_thread ON ghost_chat_messages(thread_id, created_at ASC)")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_thread_focus (
                thread_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                ref_id TEXT NOT NULL,
                label TEXT,
                pinned INTEGER NOT NULL DEFAULT 0,
                last_used_at REAL NOT NULL,
                PRIMARY KEY(thread_id, kind, ref_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_thread_cameras (
                thread_id TEXT NOT NULL,
                camera_id TEXT NOT NULL,
                bound_at REAL NOT NULL,
                PRIMARY KEY(thread_id, camera_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_thread_links (
                thread_a TEXT NOT NULL,
                thread_b TEXT NOT NULL,
                linked_at REAL NOT NULL,
                PRIMARY KEY(thread_a, thread_b)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_chat_tool_calls (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                args_json TEXT NOT NULL,
                result_rows INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                ok INTEGER NOT NULL,
                error TEXT,
                created_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_chat_tool_calls_thread ON ghost_chat_tool_calls(thread_id, created_at ASC)")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_chat_actions (
                action_id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                action_type TEXT NOT NULL,
                title TEXT NOT NULL,
                params_json TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                reviewed_at REAL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_chat_actions_thread ON ghost_chat_actions(thread_id, created_at DESC)")

        try execute("""
            CREATE TABLE IF NOT EXISTS ghost_chat_clips (
                clip_id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                camera_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS ghost_chat_clips_expires ON ghost_chat_clips(expires_at ASC)")
    }

    public func saveACTATrackVisualMetadata(
        trackID: UUID,
        cropQuality: Double,
        chromaPrint: ACTAChromaSignature?,
        hsvHistogram: [Float] = [],
        resolvedSex: ACTAResolvedSex = .unknown,
        identityState: ACTAIdentityMatchState? = nil,
        identityScore: Double? = nil,
        actaIdentityID: String? = nil,
        isBest: Bool? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            UPDATE tracked_objects
            SET crop_quality = ?,
                chroma_blob = ?,
                chroma_code = ?,
                chroma_bucket = ?,
                hsv_blob = ?,
                upper_color = ?,
                lower_color = ?,
                vehicle_color = ?,
                resolved_sex = ?,
                identity_state = COALESCE(?, identity_state),
                identity_score = COALESCE(?, identity_score),
                ghost_identity_id = COALESCE(?, ghost_identity_id),
                is_best = COALESCE(?, is_best)
            WHERE track_id = ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cropQuality)
        if let chromaPrint {
            _ = chromaPrint.blob.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(statement, 2, rawBuffer.baseAddress, Int32(chromaPrint.blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            bind(chromaPrint.code, at: 3, to: statement)
            sqlite3_bind_int(statement, 4, Int32(chromaPrint.bucket))
            if let upper = chromaPrint.upperColorHex { bind(upper, at: 6, to: statement) } else { sqlite3_bind_null(statement, 6) }
            if let lower = chromaPrint.lowerColorHex { bind(lower, at: 7, to: statement) } else { sqlite3_bind_null(statement, 7) }
            if let veh = chromaPrint.vehicleColorHex { bind(veh, at: 8, to: statement) } else { sqlite3_bind_null(statement, 8) }
        } else {
            sqlite3_bind_null(statement, 2)
            sqlite3_bind_null(statement, 3)
            sqlite3_bind_null(statement, 4)
            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 8)
        }
        if !hsvHistogram.isEmpty {
            let data = hsvHistogram.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(statement, 5, rawBuffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bind(resolvedSex.rawValue, at: 9, to: statement)
        if let identityState { bind(identityState.rawValue, at: 10, to: statement) } else { sqlite3_bind_null(statement, 10) }
        if let identityScore { sqlite3_bind_double(statement, 11, identityScore) } else { sqlite3_bind_null(statement, 11) }
        if let actaIdentityID { bind(actaIdentityID, at: 12, to: statement) } else { sqlite3_bind_null(statement, 12) }
        if let isBest { sqlite3_bind_int(statement, 13, isBest ? 1 : 0) } else { sqlite3_bind_null(statement, 13) }
        bind(trackID.uuidString, at: 14, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    // MARK: - AI Request Content-Hash Cache

    public func cachedACTAAIResponse(requestHash: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT response_json FROM ghost_ai_cache WHERE request_hash = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        bind(requestHash, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    public func saveACTAAICacheResponse(
        requestHash: String,
        taskType: String,
        promptVersion: String = "v1",
        responseJSON: String,
        now: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_ai_cache(request_hash, task_type, prompt_version, response_json, created_at)
            VALUES(?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(requestHash, at: 1, to: stmt)
        bind(taskType, at: 2, to: stmt)
        bind(promptVersion, at: 3, to: stmt)
        bind(responseJSON, at: 4, to: stmt)
        sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    // MARK: - Identity Profiles, Topology & Dedup Decisions

    public func upsertACTAIdentityProfile(_ profile: ACTAIdentityGalleryProfile) throws {
        let data = try JSONEncoder().encode(profile)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            INSERT INTO ghost_identities(identity_id, kind, display_code, profile_json, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(identity_id) DO UPDATE SET
                kind = excluded.kind,
                display_code = excluded.display_code,
                profile_json = excluded.profile_json,
                updated_at = excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(profile.identityID, at: 1, to: statement)
        bind(profile.kind, at: 2, to: statement)
        bind(profile.displayCode, at: 3, to: statement)
        bind(json, at: 4, to: statement)
        sqlite3_bind_double(statement, 5, profile.lastSeenAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func deleteACTAIdentityProfile(identityID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM ghost_identities WHERE identity_id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(identityID, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    public func loadACTAIdentityProfiles(limit: Int = 500) throws -> [ACTAIdentityGalleryProfile] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT profile_json FROM ghost_identities ORDER BY updated_at DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(5000, limit))))
        var profiles: [ACTAIdentityGalleryProfile] = []
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            let json = text(statement, 0)
            if let data = json.data(using: .utf8),
               let profile = try? decoder.decode(ACTAIdentityGalleryProfile.self, from: data) {
                profiles.append(profile)
            }
        }
        return profiles
    }

    public func saveACTACameraLinks(_ links: [ACTACameraTransitionLink]) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_camera_links(
                link_key, from_camera_id, to_camera_id, transition_count,
                mean_transit_sec, min_transit_sec, max_transit_sec, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        for link in links {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            let key = "\(link.fromCameraID)->\(link.toCameraID)"
            bind(key, at: 1, to: stmt)
            bind(link.fromCameraID, at: 2, to: stmt)
            bind(link.toCameraID, at: 3, to: stmt)
            sqlite3_bind_int(stmt, 4, Int32(link.transitionCount))
            sqlite3_bind_double(stmt, 5, link.meanTransitSec)
            sqlite3_bind_double(stmt, 6, link.minTransitSec)
            sqlite3_bind_double(stmt, 7, link.maxTransitSec)
            sqlite3_bind_double(stmt, 8, link.updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        }
    }

    public func loadACTACameraLinks() throws -> [ACTACameraTransitionLink] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT from_camera_id, to_camera_id, transition_count, mean_transit_sec, min_transit_sec, max_transit_sec, updated_at
            FROM ghost_camera_links
            """)
        defer { sqlite3_finalize(stmt) }
        var links: [ACTACameraTransitionLink] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            links.append(
                ACTACameraTransitionLink(
                    fromCameraID: text(stmt, 0),
                    toCameraID: text(stmt, 1),
                    transitionCount: Int(sqlite3_column_int(stmt, 2)),
                    meanTransitSec: sqlite3_column_double(stmt, 3),
                    minTransitSec: sqlite3_column_double(stmt, 4),
                    maxTransitSec: sqlite3_column_double(stmt, 5),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                )
            )
        }
        return links
    }

    public func saveACTADedupDecision(
        _ decision: ACTASweeperPairDecision,
        evidenceHash: String? = nil,
        decidedAt: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let pairKey = decision.idA < decision.idB ? "\(decision.idA)|\(decision.idB)" : "\(decision.idB)|\(decision.idA)"
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_dedup_decisions(
                pair_key, id_a, id_b, layer, should_merge, record_cannot_link, confidence, reason, decided_at, evidence_hash
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(pairKey, at: 1, to: stmt)
        bind(decision.idA, at: 2, to: stmt)
        bind(decision.idB, at: 3, to: stmt)
        bind(decision.layer.rawValue, at: 4, to: stmt)
        sqlite3_bind_int(stmt, 5, decision.shouldMerge ? 1 : 0)
        sqlite3_bind_int(stmt, 6, decision.recordCannotLink ? 1 : 0)
        sqlite3_bind_double(stmt, 7, decision.confidence)
        bind(decision.reason, at: 8, to: stmt)
        sqlite3_bind_double(stmt, 9, decidedAt.timeIntervalSince1970)
        if let evidenceHash { bind(evidenceHash, at: 10, to: stmt) } else { sqlite3_bind_null(stmt, 10) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    public func loadACTACannotLinkPairs() throws -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT id_a, id_b FROM ghost_dedup_decisions WHERE record_cannot_link = 1")
        defer { sqlite3_finalize(stmt) }
        var pairs: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            pairs.append((text(stmt, 0), text(stmt, 1)))
        }
        return pairs
    }

    // MARK: - Narrative Chapters ("ACTA Memory") & Operator Controls

    public func saveACTANarrativeChapter(
        id: UUID = UUID(),
        cameraID: UUID,
        cameraName: String,
        startedAt: Date,
        endedAt: Date,
        chapter: ACTATemporalNarrativeResult,
        frameCount: Int = 0,
        sightingCount: Int = 0,
        identityCount: Int = 0,
        collageJPEG: Data? = nil
    ) throws {
        let record = ACTANarrativeChapterRecord(
            chapterID: id.uuidString,
            cameraID: cameraID,
            cameraName: cameraName,
            startedAt: startedAt,
            endedAt: endedAt,
            narrative: chapter,
            aiSummary: chapter.summary,
            operatorText: nil,
            operatorMarked: false,
            pinned: false,
            frameCount: frameCount,
            sightingCount: sightingCount,
            identityCount: identityCount,
            collagePath: nil
        )
        try saveACTANarrativeChapterRecord(record, collageJPEG: collageJPEG)
    }

    public func saveACTANarrativeChapterRecord(
        _ record: ACTANarrativeChapterRecord,
        collageJPEG: Data? = nil
    ) throws {
        try writeACTANarrativeChapterRecord(record, collageJPEG: collageJPEG, insertOnly: false)
    }

    public func insertACTANarrativeChapterRecord(
        _ record: ACTANarrativeChapterRecord,
        collageJPEG: Data? = nil
    ) throws {
        guard UUID(uuidString: record.chapterID) != nil, record.collagePath == nil else {
            throw LocalTrackingStoreError.query("Invalid narrative chapter identifier")
        }
        try writeACTANarrativeChapterRecord(record, collageJPEG: collageJPEG, insertOnly: true)
    }

    private func writeACTANarrativeChapterRecord(
        _ record: ACTANarrativeChapterRecord,
        collageJPEG: Data?,
        insertOnly: Bool
    ) throws {
        let data = try JSONEncoder().encode(record.narrative)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        var transactionOpen = false
        if insertOnly {
            try execute("BEGIN IMMEDIATE")
            transactionOpen = true
        }
        defer { if transactionOpen { try? execute("ROLLBACK") } }
        if insertOnly {
            let existing = try prepare("SELECT 1 FROM ghost_narrative_chapters WHERE chapter_id = ?")
            defer { sqlite3_finalize(existing) }
            bind(record.chapterID, at: 1, to: existing)
            let result = sqlite3_step(existing)
            if result == SQLITE_ROW { throw LocalTrackingStoreError.query("Narrative chapter already exists") }
            guard result == SQLITE_DONE else { throw databaseError() }
        }

        var savedCollagePath = record.collagePath
        if let collageJPEG, !collageJPEG.isEmpty {
            try FileManager.default.createDirectory(
                at: cropDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let name = "narrative_\(record.chapterID.lowercased()).jpg"
            let url = cropDirectory.appendingPathComponent(name)
            if insertOnly {
                let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                if descriptor >= 0 {
                    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? file.close() }
                    var created = stat()
                    let hasIdentity = fstat(descriptor, &created) == 0
                    do {
#if DEBUG
                        if let hook = narrativeJPEGWriteTestHook {
                            try hook(file, url, collageJPEG)
                        } else {
                            try file.write(contentsOf: collageJPEG)
                        }
#else
                        try file.write(contentsOf: collageJPEG)
#endif
                        try file.close()
                    } catch {
                        var current = stat()
                        if hasIdentity, lstat(url.path, &current) == 0,
                           (current.st_mode & S_IFMT) == S_IFREG,
                           current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                            _ = unlink(url.path)
                        }
                        throw error
                    }
                } else if errno == EEXIST {
                    let existingDescriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
                    guard existingDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let file = FileHandle(fileDescriptor: existingDescriptor, closeOnDealloc: true)
                    defer { try? file.close() }
                    var attributes = stat()
                    guard fstat(existingDescriptor, &attributes) == 0,
                          (attributes.st_mode & S_IFMT) == S_IFREG,
                          attributes.st_size == collageJPEG.count,
                          try file.readToEnd() == collageJPEG else {
                        throw LocalTrackingStoreError.query("Narrative collage conflict")
                    }
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try collageJPEG.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            savedCollagePath = name
        }

        let conflictClause = insertOnly ? "ON CONFLICT(chapter_id) DO NOTHING" : """
            ON CONFLICT(chapter_id) DO UPDATE SET
                camera_id = excluded.camera_id,
                camera_name = excluded.camera_name,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                chapter_json = excluded.chapter_json,
                ai_summary = COALESCE(ghost_narrative_chapters.ai_summary, excluded.ai_summary),
                operator_text = COALESCE(excluded.operator_text, ghost_narrative_chapters.operator_text),
                operator_marked = MAX(ghost_narrative_chapters.operator_marked, excluded.operator_marked),
                pinned = MAX(ghost_narrative_chapters.pinned, excluded.pinned),
                frame_count = MAX(ghost_narrative_chapters.frame_count, excluded.frame_count),
                sighting_count = MAX(ghost_narrative_chapters.sighting_count, excluded.sighting_count),
                identity_count = MAX(ghost_narrative_chapters.identity_count, excluded.identity_count),
                collage_path = COALESCE(excluded.collage_path, ghost_narrative_chapters.collage_path)
            """
        let statement = try prepare("""
            INSERT INTO ghost_narrative_chapters(
                chapter_id, camera_id, camera_name, started_at, ended_at, chapter_json,
                ai_summary, operator_text, operator_marked, pinned, frame_count, sighting_count, identity_count, collage_path
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \(conflictClause)
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.chapterID, at: 1, to: statement)
        bind(record.cameraID.uuidString, at: 2, to: statement)
        bind(record.cameraName, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, record.endedAt.timeIntervalSince1970)
        bind(json, at: 6, to: statement)
        bind(record.aiSummary, at: 7, to: statement)
        if let opText = record.operatorText { bind(opText, at: 8, to: statement) } else { sqlite3_bind_null(statement, 8) }
        sqlite3_bind_int(statement, 9, record.operatorMarked ? 1 : 0)
        sqlite3_bind_int(statement, 10, record.pinned ? 1 : 0)
        sqlite3_bind_int(statement, 11, Int32(record.frameCount))
        sqlite3_bind_int(statement, 12, Int32(record.sightingCount))
        sqlite3_bind_int(statement, 13, Int32(record.identityCount))
        if let savedCollagePath { bind(savedCollagePath, at: 14, to: statement) } else { sqlite3_bind_null(statement, 14) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        if insertOnly {
            try execute("COMMIT")
            transactionOpen = false
        }
    }

    public func setACTANarrativePinned(chapterID: String, pinned: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            UPDATE ghost_narrative_chapters
            SET pinned = ?,
                operator_marked = CASE WHEN ? = 1 THEN 1 ELSE operator_marked END
            WHERE chapter_id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_int(stmt, 2, pinned ? 1 : 0)
        bind(chapterID, at: 3, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    /// Saves or clears operator custom text on a narrative chapter while preserving `ai_summary` and keeping `operator_marked = 1`.
    public func setACTANarrativeOperatorText(chapterID: String, operatorText: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = operatorText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stmt = try prepare("""
            UPDATE ghost_narrative_chapters
            SET operator_text = ?,
                operator_marked = 1
            WHERE chapter_id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        if let trimmed, !trimmed.isEmpty {
            bind(trimmed, at: 1, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        bind(chapterID, at: 2, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    public func loadACTANarrativeChapterRecord(chapterID: String) throws -> ACTANarrativeChapterRecord? {
        try loadACTANarrativeChapterRecords(chapterID: chapterID, limit: 1).first
    }

    public func actaNarrativeChapterExists(chapterID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT 1 FROM ghost_narrative_chapters WHERE chapter_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(chapterID, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }

    /// Reads the JPEG collage persisted next to a narrative chapter, if any.
    public func actaNarrativeCollageData(for record: ACTANarrativeChapterRecord) -> Data? {
        guard let name = record.collagePath,
              URL(fileURLWithPath: name).lastPathComponent == name,
              name.hasSuffix(".jpg") else { return nil }
        return try? Data(contentsOf: cropDirectory.appendingPathComponent(name))
    }

    public func loadACTANarrativeChapterRecords(
        chapterID: String? = nil,
        cameraID: UUID? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 50
    ) throws -> [ACTANarrativeChapterRecord] {
        lock.lock()
        defer { lock.unlock() }
        var clauses: [String] = []
        if chapterID != nil { clauses.append("chapter_id = ?") }
        if cameraID != nil { clauses.append("camera_id = ?") }
        if since != nil { clauses.append("ended_at >= ?") }
        if until != nil { clauses.append("started_at <= ?") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT chapter_id, camera_id, camera_name, started_at, ended_at, chapter_json,
                   ai_summary, operator_text, operator_marked, pinned,
                   frame_count, sighting_count, identity_count, collage_path
            FROM ghost_narrative_chapters
            \(whereSQL)
            ORDER BY ended_at DESC
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bindIdx: Int32 = 1
        if let chapterID {
            bind(chapterID, at: bindIdx, to: stmt)
            bindIdx += 1
        }
        if let cameraID {
            bind(cameraID.uuidString, at: bindIdx, to: stmt)
            bindIdx += 1
        }
        if let since {
            sqlite3_bind_double(stmt, bindIdx, since.timeIntervalSince1970)
            bindIdx += 1
        }
        if let until {
            sqlite3_bind_double(stmt, bindIdx, until.timeIntervalSince1970)
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(max(1, min(500, limit))))

        var records: [ACTANarrativeChapterRecord] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = text(stmt, 0)
            let camIDStr = text(stmt, 1)
            let camUUID = UUID(uuidString: camIDStr) ?? UUID()
            let camName = text(stmt, 2)
            let sAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let eAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let json = text(stmt, 5)
            guard let data = json.data(using: .utf8),
                  let chapter = try? decoder.decode(ACTATemporalNarrativeResult.self, from: data) else { continue }
            let aiSum = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? chapter.summary : text(stmt, 6)
            let opText = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : text(stmt, 7)
            let opMarked = sqlite3_column_int(stmt, 8) != 0
            let pinned = sqlite3_column_int(stmt, 9) != 0
            let frameCount = Int(sqlite3_column_int(stmt, 10))
            let sightingCount = Int(sqlite3_column_int(stmt, 11))
            let identityCount = Int(sqlite3_column_int(stmt, 12))
            let collagePath = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : text(stmt, 13)
            records.append(
                ACTANarrativeChapterRecord(
                    chapterID: cid,
                    cameraID: camUUID,
                    cameraName: camName,
                    startedAt: sAt,
                    endedAt: eAt,
                    narrative: chapter,
                    aiSummary: aiSum,
                    operatorText: opText,
                    operatorMarked: opMarked,
                    pinned: pinned,
                    frameCount: frameCount,
                    sightingCount: sightingCount,
                    identityCount: identityCount,
                    collagePath: collagePath
                )
            )
        }
        return records
    }

    public func loadACTANarrativeChapters(cameraID: UUID? = nil, limit: Int = 50) throws -> [(id: String, cameraID: String, cameraName: String, startedAt: Date, endedAt: Date, chapter: ACTATemporalNarrativeResult)] {
        let records = try loadACTANarrativeChapterRecords(cameraID: cameraID, limit: limit)
        return records.map {
            var chap = $0.narrative
            chap.summary = $0.effectiveSummary
            return ($0.chapterID, $0.cameraID.uuidString, $0.cameraName, $0.startedAt, $0.endedAt, chap)
        }
    }

    // MARK: - Semantic Knowledge Layer (Attribute Index, Dossiers, Visits, Routes, FTS5)

    public func indexACTATrackKnowledge(
        trackID: String,
        identityID: String,
        cameraID: String,
        capturedAt: Date,
        cropQuality: Double,
        description: ACTACropDescription?,
        chromaSignature: ACTAChromaSignature?,
        displayName: String? = nil,
        kind: String = "person"
    ) throws {
        let entries = ACTAAttributeIndexEntry.extractEntries(
            trackID: trackID,
            identityID: identityID,
            cameraID: cameraID,
            capturedAt: capturedAt,
            cropQuality: cropQuality,
            description: description,
            chromaSignature: chromaSignature
        )

        lock.lock()
        do {
            // Update tracked_objects.ghost_identity_id if row exists
            let upd = try prepare("UPDATE tracked_objects SET ghost_identity_id = ? WHERE track_id = ?")
            defer { sqlite3_finalize(upd) }
            bind(identityID, at: 1, to: upd)
            bind(trackID, at: 2, to: upd)
            _ = sqlite3_step(upd)

            // Replace existing attribute entries for this trackID
            let del = try prepare("DELETE FROM ghost_attribute_index WHERE track_id = ?")
            defer { sqlite3_finalize(del) }
            bind(trackID, at: 1, to: del)
            guard sqlite3_step(del) == SQLITE_DONE else { throw databaseError() }

            let ins = try prepare("""
                INSERT INTO ghost_attribute_index(
                    track_id, identity_id, camera_id, captured_at, facet, value, confidence, crop_quality, source
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(ins) }
            for entry in entries {
                sqlite3_reset(ins)
                sqlite3_clear_bindings(ins)
                bind(entry.trackID, at: 1, to: ins)
                bind(entry.identityID, at: 2, to: ins)
                bind(entry.cameraID, at: 3, to: ins)
                sqlite3_bind_double(ins, 4, entry.capturedAt.timeIntervalSince1970)
                bind(entry.facet, at: 5, to: ins)
                bind(entry.value, at: 6, to: ins)
                sqlite3_bind_double(ins, 7, entry.confidence)
                sqlite3_bind_double(ins, 8, entry.cropQuality)
                bind(entry.source, at: 9, to: ins)
                guard sqlite3_step(ins) == SQLITE_DONE else { throw databaseError() }
            }

            if let summaryText = description?.summary, !summaryText.isEmpty {
                if let delCropFTS = try? prepare("DELETE FROM ghost_crop_fts WHERE track_id = ?") {
                    defer { sqlite3_finalize(delCropFTS) }
                    bind(trackID, at: 1, to: delCropFTS)
                    _ = sqlite3_step(delCropFTS)
                }
                if let insCropFTS = try? prepare("INSERT INTO ghost_crop_fts(track_id, identity_id, description_text) VALUES(?, ?, ?)") {
                    defer { sqlite3_finalize(insCropFTS) }
                    bind(trackID, at: 1, to: insCropFTS)
                    bind(identityID, at: 2, to: insCropFTS)
                    bind(summaryText, at: 3, to: insCropFTS)
                    _ = sqlite3_step(insCropFTS)
                }
            }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        _ = try rebuildACTAIdentityDossier(
            identityID: identityID,
            displayName: displayName,
            kind: description?.kind ?? kind,
            now: capturedAt
        )
        _ = try rebuildACTAVisits(identityID: identityID)
    }

    @discardableResult
    public func rebuildACTAIdentityDossier(
        identityID: String,
        displayName: String? = nil,
        kind: String = "person",
        now: Date = Date()
    ) throws -> ACTAIdentityDossier {
        lock.lock()
        defer { lock.unlock() }

        let stmt = try prepare("""
            SELECT track_id, identity_id, camera_id, captured_at, facet, value, confidence, crop_quality, source
            FROM ghost_attribute_index
            WHERE identity_id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        bind(identityID, at: 1, to: stmt)
        var entries: [ACTAAttributeIndexEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(
                ACTAAttributeIndexEntry(
                    trackID: text(stmt, 0),
                    identityID: text(stmt, 1),
                    cameraID: text(stmt, 2),
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    facet: text(stmt, 4),
                    value: text(stmt, 5),
                    confidence: sqlite3_column_double(stmt, 6),
                    cropQuality: sqlite3_column_double(stmt, 7),
                    source: text(stmt, 8)
                )
            )
        }

        // Pull free-text descriptions from ghost_crop_fts or tracked_objects
        var descriptions: [String] = []
        if let ftsStmt = try? prepare("SELECT description_text FROM ghost_crop_fts WHERE identity_id = ?") {
            defer { sqlite3_finalize(ftsStmt) }
            bind(identityID, at: 1, to: ftsStmt)
            while sqlite3_step(ftsStmt) == SQLITE_ROW {
                descriptions.append(text(ftsStmt, 0))
            }
        }

        var resolvedDisplayName = displayName
        var resolvedKind = kind
        if resolvedDisplayName == nil {
            let profStmt = try prepare("SELECT kind, display_code, profile_json FROM ghost_identities WHERE identity_id = ? LIMIT 1")
            defer { sqlite3_finalize(profStmt) }
            bind(identityID, at: 1, to: profStmt)
            if sqlite3_step(profStmt) == SQLITE_ROW {
                resolvedKind = text(profStmt, 0)
                let code = text(profStmt, 1)
                if let pData = text(profStmt, 2).data(using: .utf8),
                   let prof = try? JSONDecoder().decode(ACTAIdentityGalleryProfile.self, from: pData) {
                    resolvedDisplayName = prof.displayName ?? code
                } else {
                    resolvedDisplayName = code
                }
            }
        }

        let dossier = ACTAIdentityDossierBuilder.build(
            identityID: identityID,
            displayName: resolvedDisplayName,
            kind: resolvedKind,
            entries: entries,
            descriptions: descriptions,
            now: now
        )

        let facetsJSON = (try? String(data: JSONEncoder().encode(dossier.facets), encoding: .utf8)) ?? "{}"
        let altsJSON = (try? String(data: JSONEncoder().encode(dossier.alternatives), encoding: .utf8)) ?? "{}"

        let upsert = try prepare("""
            INSERT OR REPLACE INTO ghost_identity_dossiers(
                identity_id, display_name, kind, facets_json, alternatives_json, summary_line, text_blob, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(upsert) }
        bind(dossier.identityID, at: 1, to: upsert)
        if let dn = dossier.displayName { bind(dn, at: 2, to: upsert) } else { sqlite3_bind_null(upsert, 2) }
        bind(dossier.kind, at: 3, to: upsert)
        bind(facetsJSON, at: 4, to: upsert)
        bind(altsJSON, at: 5, to: upsert)
        bind(dossier.summaryLine, at: 6, to: upsert)
        bind(dossier.textBlob, at: 7, to: upsert)
        sqlite3_bind_double(upsert, 8, dossier.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(upsert) == SQLITE_DONE else { throw databaseError() }

        if let delFTS = try? prepare("DELETE FROM ghost_identity_fts WHERE identity_id = ?") {
            defer { sqlite3_finalize(delFTS) }
            bind(dossier.identityID, at: 1, to: delFTS)
            _ = sqlite3_step(delFTS)
        }
        if let insFTS = try? prepare("INSERT INTO ghost_identity_fts(identity_id, summary_line, text_blob) VALUES(?, ?, ?)") {
            defer { sqlite3_finalize(insFTS) }
            bind(dossier.identityID, at: 1, to: insFTS)
            bind(dossier.summaryLine, at: 2, to: insFTS)
            bind(dossier.textBlob, at: 3, to: insFTS)
            _ = sqlite3_step(insFTS)
        }

        return dossier
    }

    public func getACTAIdentityDossier(identityID: String) throws -> ACTAIdentityDossier? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT identity_id, display_name, kind, facets_json, alternatives_json, summary_line, text_blob, updated_at
            FROM ghost_identity_dossiers
            WHERE identity_id = ? OR display_name = ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(stmt) }
        bind(identityID, at: 1, to: stmt)
        bind(identityID, at: 2, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = text(stmt, 0)
        let dn = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : text(stmt, 1)
        let kind = text(stmt, 2)
        let facets = (try? JSONDecoder().decode([String: String].self, from: Data(text(stmt, 3).utf8))) ?? [:]
        let alts = (try? JSONDecoder().decode([String: [String]].self, from: Data(text(stmt, 4).utf8))) ?? [:]
        let summary = text(stmt, 5)
        let blob = text(stmt, 6)
        let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        return ACTAIdentityDossier(
            identityID: id,
            displayName: dn,
            kind: kind,
            facets: facets,
            alternatives: alts,
            summaryLine: summary,
            textBlob: blob,
            updatedAt: uAt
        )
    }

    public func loadAllACTAIdentityDossiers() throws -> [ACTAIdentityDossier] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT identity_id, display_name, kind, facets_json, alternatives_json, summary_line, text_blob, updated_at
            FROM ghost_identity_dossiers
            ORDER BY updated_at DESC
            """)
        defer { sqlite3_finalize(stmt) }
        var list: [ACTAIdentityDossier] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            let dn = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : text(stmt, 1)
            let kind = text(stmt, 2)
            let facets = (try? JSONDecoder().decode([String: String].self, from: Data(text(stmt, 3).utf8))) ?? [:]
            let alts = (try? JSONDecoder().decode([String: [String]].self, from: Data(text(stmt, 4).utf8))) ?? [:]
            let summary = text(stmt, 5)
            let blob = text(stmt, 6)
            let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            list.append(
                ACTAIdentityDossier(
                    identityID: id,
                    displayName: dn,
                    kind: kind,
                    facets: facets,
                    alternatives: alts,
                    summaryLine: summary,
                    textBlob: blob,
                    updatedAt: uAt
                )
            )
        }
        return list
    }

    @discardableResult
    public func rebuildACTAVisits(
        identityID: String? = nil,
        visitGapSeconds: TimeInterval = 120.0
    ) throws -> [ACTAVisitSession] {
        let sightings = try loadSightingsForKnowledge(identityID: identityID)
        let visits = ACTAVisitBuilder.buildVisits(sightings: sightings, visitGapSeconds: visitGapSeconds)

        lock.lock()
        defer { lock.unlock() }
        if let identityID {
            let del = try prepare("DELETE FROM ghost_visits WHERE identity_id = ?")
            defer { sqlite3_finalize(del) }
            bind(identityID, at: 1, to: del)
            guard sqlite3_step(del) == SQLITE_DONE else { throw databaseError() }
        } else {
            try execute("DELETE FROM ghost_visits")
        }

        let ins = try prepare("""
            INSERT OR REPLACE INTO ghost_visits(
                visit_id, identity_id, started_at, ended_at, camera_ids_json, track_ids_json, sighting_count, best_track_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(ins) }
        let encoder = JSONEncoder()
        for v in visits {
            sqlite3_reset(ins)
            sqlite3_clear_bindings(ins)
            let camsJSON = (try? String(data: encoder.encode(v.cameraIDs), encoding: .utf8)) ?? "[]"
            let trksJSON = (try? String(data: encoder.encode(v.trackIDs), encoding: .utf8)) ?? "[]"
            bind(v.visitID, at: 1, to: ins)
            bind(v.identityID, at: 2, to: ins)
            sqlite3_bind_double(ins, 3, v.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(ins, 4, v.endedAt.timeIntervalSince1970)
            bind(camsJSON, at: 5, to: ins)
            bind(trksJSON, at: 6, to: ins)
            sqlite3_bind_int(ins, 7, Int32(v.sightingCount))
            bind(v.bestTrackID, at: 8, to: ins)
            guard sqlite3_step(ins) == SQLITE_DONE else { throw databaseError() }
        }
        return visits
    }

    private func loadSightingsForKnowledge(identityID: String? = nil) throws -> [ACTASightingForVisit] {
        lock.lock()
        defer { lock.unlock() }
        var results: [ACTASightingForVisit] = []
        var seenTracks = Set<String>()

        let sql: String
        if identityID != nil {
            sql = """
                SELECT track_id, ghost_identity_id, camera_id, camera_name, first_seen, last_seen, COALESCE(crop_quality, best_confidence, 0.75)
                FROM tracked_objects
                WHERE ghost_identity_id = ?
                ORDER BY first_seen ASC
                """
        } else {
            sql = """
                SELECT track_id, ghost_identity_id, camera_id, camera_name, first_seen, last_seen, COALESCE(crop_quality, best_confidence, 0.75)
                FROM tracked_objects
                WHERE ghost_identity_id IS NOT NULL AND ghost_identity_id != ''
                ORDER BY first_seen ASC
                """
        }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let identityID { bind(identityID, at: 1, to: stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid = text(stmt, 0)
            let gid = text(stmt, 1)
            seenTracks.insert(tid)
            results.append(
                ACTASightingForVisit(
                    trackID: tid,
                    identityID: gid,
                    cameraID: text(stmt, 2),
                    cameraName: text(stmt, 3),
                    firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    quality: sqlite3_column_double(stmt, 6)
                )
            )
        }

        // Also include tracks present in ghost_attribute_index in case synthetic tests indexed attributes directly
        let attrSQL = identityID != nil
            ? "SELECT track_id, identity_id, camera_id, MIN(captured_at), MAX(captured_at), MAX(crop_quality) FROM ghost_attribute_index WHERE identity_id = ? GROUP BY track_id, identity_id, camera_id"
            : "SELECT track_id, identity_id, camera_id, MIN(captured_at), MAX(captured_at), MAX(crop_quality) FROM ghost_attribute_index GROUP BY track_id, identity_id, camera_id"
        let attrStmt = try prepare(attrSQL)
        defer { sqlite3_finalize(attrStmt) }
        if let identityID { bind(identityID, at: 1, to: attrStmt) }
        while sqlite3_step(attrStmt) == SQLITE_ROW {
            let tid = text(attrStmt, 0)
            guard !seenTracks.contains(tid) else { continue }
            seenTracks.insert(tid)
            results.append(
                ACTASightingForVisit(
                    trackID: tid,
                    identityID: text(attrStmt, 1),
                    cameraID: text(attrStmt, 2),
                    cameraName: text(attrStmt, 2),
                    firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(attrStmt, 3)),
                    lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(attrStmt, 4)),
                    quality: sqlite3_column_double(attrStmt, 5)
                )
            )
        }
        return results
    }

    /// Deterministically rebuilds `ghost_Identity_dossiers`, `ghost_visits`, and FTS5 indices from stored attribute entries and tracks.
    /// Never wipes `ghost_narrative_chapters` or `ghost_chat_threads`.
    public func rebuildAllACTAKnowledge(
        visitGapSeconds: TimeInterval = 120.0,
        now: Date = Date()
    ) throws {
        var identityIDs = Set<String>()
        lock.lock()
        do {
            let s1 = try prepare("SELECT DISTINCT identity_id FROM ghost_attribute_index")
            defer { sqlite3_finalize(s1) }
            while sqlite3_step(s1) == SQLITE_ROW { identityIDs.insert(text(s1, 0)) }

            let s2 = try prepare("SELECT identity_id FROM ghost_identities")
            defer { sqlite3_finalize(s2) }
            while sqlite3_step(s2) == SQLITE_ROW { identityIDs.insert(text(s2, 0)) }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        for id in identityIDs {
            _ = try rebuildACTAIdentityDossier(identityID: id, now: now)
        }
        _ = try rebuildACTAVisits(identityID: nil, visitGapSeconds: visitGapSeconds)
    }

    /// Conjunctive facet + FTS5/LIKE search across `ghost_attribute_index` and `ghost_identity_dossiers`.
    public func searchACTAIdentitiesByAttributes(
        kind: String? = nil,
        facets: [String: String] = [:],
        freeTextQuery: String? = nil,
        cameraID: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 25
    ) throws -> [ACTAIdentityDossier] {
        let allDossiers = try loadAllACTAIdentityDossiers()
        var candidateIDs = Set(allDossiers.map(\.identityID))

        if let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !kind.isEmpty {
            candidateIDs = candidateIDs.filter { id in
                guard let d = allDossiers.first(where: { $0.identityID == id }) else { return false }
                return d.kind.lowercased() == kind || d.facets["kind"]?.lowercased() == kind
            }
        }

        // Conjunctive facet filter via ghost_attribute_index + dossier facets
        for (rawFacet, rawVal) in facets {
            let facet = rawFacet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normVal = (facet.contains("color") ? ACTAColorNormalizer.normalizeColorToken(rawVal) : nil)
                ?? rawVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !facet.isEmpty, !normVal.isEmpty else { continue }

            var matchingForFacet = Set<String>()
            lock.lock()
            if let stmt = try? prepare("SELECT DISTINCT identity_id FROM ghost_attribute_index WHERE facet = ? AND (value = ? OR value LIKE ?)") {
                defer { sqlite3_finalize(stmt) }
                bind(facet, at: 1, to: stmt)
                bind(normVal, at: 2, to: stmt)
                bind("%\(normVal)%", at: 3, to: stmt)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    matchingForFacet.insert(text(stmt, 0))
                }
            }
            lock.unlock()

            for d in allDossiers {
                if let fVal = d.facets[facet]?.lowercased(), fVal.contains(normVal) {
                    matchingForFacet.insert(d.identityID)
                }
                if let alts = d.alternatives[facet], alts.contains(where: { $0.lowercased().contains(normVal) }) {
                    matchingForFacet.insert(d.identityID)
                }
            }
            candidateIDs.formIntersection(matchingForFacet)
        }

        if cameraID != nil || since != nil || until != nil {
            let sightings = try loadSightingsForKnowledge()
            let matchingSightingIDs = Set(
                sightings.filter { s in
                    if let cameraID, !cameraID.isEmpty, s.cameraID != cameraID && s.cameraName != cameraID { return false }
                    if let since, s.lastSeenAt < since { return false }
                    if let until, s.firstSeenAt > until { return false }
                    return true
                }.map(\.identityID)
            )
            candidateIDs.formIntersection(matchingSightingIDs)
        }

        var ftsRankOrder: [String] = []
        if let q = freeTextQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            var textMatches = Set<String>()
            let tokens = q.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }

            // 1. Try FTS5 BM25 query
            if !tokens.isEmpty {
                let ftsExpr = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
                lock.lock()
                if let ftsStmt = try? prepare("SELECT identity_id FROM ghost_identity_fts WHERE ghost_identity_fts MATCH ? ORDER BY bm25(ghost_identity_fts) LIMIT 100") {
                    defer { sqlite3_finalize(ftsStmt) }
                    bind(ftsExpr, at: 1, to: ftsStmt)
                    while sqlite3_step(ftsStmt) == SQLITE_ROW {
                        let id = text(ftsStmt, 0)
                        textMatches.insert(id)
                        ftsRankOrder.append(id)
                    }
                }
                lock.unlock()
            }

            // 2. Fallback / supplement via normalized tokens & substring check
            for d in allDossiers {
                let hay = (d.summaryLine + " " + d.textBlob).lowercased()
                let matchedAll = tokens.allSatisfy { tok in
                    if hay.contains(tok) { return true }
                    if let normColor = ACTAColorNormalizer.normalizeColorToken(tok), hay.contains(normColor) {
                        return true
                    }
                    return false
                }
                if matchedAll {
                    textMatches.insert(d.identityID)
                }
            }
            candidateIDs.formIntersection(textMatches)
        }

        let dossierMap = Dictionary(uniqueKeysWithValues: allDossiers.map { ($0.identityID, $0) })
        var orderedResults: [ACTAIdentityDossier] = []
        for id in ftsRankOrder where candidateIDs.contains(id) {
            if let d = dossierMap[id] {
                orderedResults.append(d)
                candidateIDs.remove(id)
            }
        }
        let remaining = candidateIDs.compactMap { dossierMap[$0] }.sorted { $0.updatedAt > $1.updatedAt }
        orderedResults.append(contentsOf: remaining)
        return Array(orderedResults.prefix(max(1, limit)))
    }

    public func getACTAIdentityRoute(
        identityID: String,
        topology: ACTACameraTopology? = nil
    ) throws -> ACTAIdentityRoute {
        let sightings = try loadSightingsForKnowledge(identityID: identityID)
        let topo: ACTACameraTopology
        if let topology {
            topo = topology
        } else {
            topo = ACTACameraTopology(links: (try? loadACTACameraLinks()) ?? [])
        }
        return ACTARouteBuilder.buildRoute(identityID: identityID, sightings: sightings, topology: topo)
    }

    public func whoWasPresent(
        cameraID: String? = nil,
        since: Date,
        until: Date,
        kind: String? = nil
    ) throws -> [ACTAIdentityDossier] {
        let sightings = try loadSightingsForKnowledge()
        let activeIDs = Set(
            sightings.filter { s in
                if let cameraID, !cameraID.isEmpty, s.cameraID != cameraID && s.cameraName != cameraID {
                    return false
                }
                return s.lastSeenAt >= since && s.firstSeenAt <= until
            }.map(\.identityID)
        )
        let dossiers = try loadAllACTAIdentityDossiers()
        return dossiers.filter { d in
            guard activeIDs.contains(d.identityID) else { return false }
            if let kind = kind?.lowercased(), !kind.isEmpty {
                return d.kind.lowercased() == kind
            }
            return true
        }
    }

    public func listACTAVisits(
        identityID: String? = nil,
        cameraID: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 50
    ) throws -> [ACTAVisitSession] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT visit_id, identity_id, started_at, ended_at, camera_ids_json, track_ids_json, sighting_count, best_track_id
            FROM ghost_visits
            ORDER BY started_at DESC
            LIMIT 500
            """)
        defer { sqlite3_finalize(stmt) }
        var visits: [ACTAVisitSession] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let vid = text(stmt, 0)
            let iid = text(stmt, 1)
            let sAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let eAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let cams = (try? decoder.decode([String].self, from: Data(text(stmt, 4).utf8))) ?? []
            let trks = (try? decoder.decode([String].self, from: Data(text(stmt, 5).utf8))) ?? []
            let cnt = Int(sqlite3_column_int(stmt, 6))
            let best = text(stmt, 7)

            if let identityID, !identityID.isEmpty, iid != identityID { continue }
            if let cameraID, !cameraID.isEmpty, !cams.contains(cameraID) { continue }
            if let since, eAt < since { continue }
            if let until, sAt > until { continue }

            visits.append(
                ACTAVisitSession(
                    visitID: vid,
                    identityID: iid,
                    startedAt: sAt,
                    endedAt: eAt,
                    cameraIDs: cams,
                    trackIDs: trks,
                    sightingCount: cnt,
                    bestTrackID: best
                )
            )
            if visits.count >= limit { break }
        }
        return visits
    }

    public func findACTACompanions(
        identityID: String,
        maxGapSeconds: TimeInterval = 15.0
    ) throws -> [ACTACompanionRecord] {
        let sightings = try loadSightingsForKnowledge()
        return ACTACompanionFinder.findCompanions(
            for: identityID,
            allSightings: sightings,
            maxGapSeconds: maxGapSeconds
        )
    }

    public func executeReadOnlyACTASQL(_ rawSQL: String, maxLimit: Int = 200) throws -> [[String: String]] {
        let safeMaxLimit = max(1, min(maxLimit, 1000))
        let safeSQL = try ACTAReadOnlySQLGuard.validateAndCap(rawSQL, maxLimit: safeMaxLimit)
        lock.lock()
        defer { lock.unlock() }
        let deadline = UnsafeMutablePointer<TimeInterval>.allocate(capacity: 1)
        deadline.initialize(to: ProcessInfo.processInfo.systemUptime + 0.5)
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
        }, deadline)
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            deadline.deinitialize(count: 1)
            deadline.deallocate()
        }
        let stmt = try prepare(safeSQL)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_stmt_readonly(stmt) != 0 else {
            throw NSError(domain: "ACTAReadOnlySQLGuard", code: 5, userInfo: [NSLocalizedDescriptionKey: "SQLite statement is not read-only"])
        }
        let colCount = sqlite3_column_count(stmt)
        var rows: [[String: String]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw databaseError() }
            var row: [String: String] = [:]
            for c in 0..<colCount {
                let colName = sqlite3_column_name(stmt, c).map { String(cString: $0) } ?? "col_\(c)"
                row[colName] = sqlite3_column_type(stmt, c) == SQLITE_NULL ? "null" : text(stmt, c)
            }
            rows.append(row)
            if rows.count >= safeMaxLimit { break }
        }
        return rows
    }

    // MARK: - Agent Conversation History, Focus Memory, Chain Debt & Merge

    @discardableResult
    public func ensureACTAChatThread(
        threadID: String = UUID().uuidString,
        title: String = "Investigation",
        operatorName: String = "operator",
        kind: String = "general",
        severity: String = "normal",
        now: Date = Date()
    ) throws -> ACTAChatThreadRecord {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT INTO ghost_chat_threads(thread_id, title, operator_name, kind, severity, pinned, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, 0, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                updated_at = MAX(ghost_chat_threads.updated_at, excluded.updated_at)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        bind(title, at: 2, to: stmt)
        bind(operatorName, at: 3, to: stmt)
        bind(kind, at: 4, to: stmt)
        bind(severity, at: 5, to: stmt)
        sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        return try loadACTAChatThreadUnlocked(threadID: threadID) ?? ACTAChatThreadRecord(
            threadID: threadID,
            title: title,
            operatorName: operatorName,
            kind: kind,
            severity: severity,
            createdAt: now,
            updatedAt: now
        )
    }

    private func loadACTAChatThreadUnlocked(threadID: String) throws -> ACTAChatThreadRecord? {
        let stmt = try prepare("""
            SELECT thread_id, title, operator_name, kind, severity, pinned, last_response_id, pending_outputs_json, created_at, updated_at
            FROM ghost_chat_threads
            WHERE thread_id = ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let tid = text(stmt, 0)
        let title = text(stmt, 1)
        let opName = text(stmt, 2)
        let kind = text(stmt, 3)
        let sev = text(stmt, 4)
        let pinned = sqlite3_column_int(stmt, 5) != 0
        let lastResp = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : text(stmt, 6)
        let pendingJSON = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : text(stmt, 7)
        let pending = pendingJSON.flatMap { try? JSONDecoder().decode([ACTAPendingOutputDebt].self, from: Data($0.utf8)) } ?? []
        let cAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

        var cameras: [String] = []
        let camStmt = try prepare("SELECT camera_id FROM ghost_thread_cameras WHERE thread_id = ? ORDER BY bound_at ASC")
        defer { sqlite3_finalize(camStmt) }
        bind(tid, at: 1, to: camStmt)
        while sqlite3_step(camStmt) == SQLITE_ROW { cameras.append(text(camStmt, 0)) }

        var linked: [String] = []
        let linkStmt = try prepare("SELECT thread_b FROM ghost_thread_links WHERE thread_a = ? ORDER BY linked_at ASC")
        defer { sqlite3_finalize(linkStmt) }
        bind(tid, at: 1, to: linkStmt)
        while sqlite3_step(linkStmt) == SQLITE_ROW { linked.append(text(linkStmt, 0)) }

        return ACTAChatThreadRecord(
            threadID: tid,
            title: title,
            operatorName: opName,
            kind: kind,
            severity: sev,
            pinned: pinned,
            lastResponseID: lastResp,
            pendingOutputs: pending,
            boundCameraIDs: cameras,
            linkedThreadIDs: linked,
            createdAt: cAt,
            updatedAt: uAt
        )
    }

    public func loadACTAChatThread(threadID: String) throws -> ACTAChatThreadRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try loadACTAChatThreadUnlocked(threadID: threadID)
    }

    public func listACTAChatThreads(limit: Int = 50) throws -> [ACTAChatThreadRecord] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("SELECT thread_id FROM ghost_chat_threads ORDER BY pinned DESC, updated_at DESC LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(1, min(500, limit))))
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(text(stmt, 0)) }
        return try ids.compactMap { try loadACTAChatThreadUnlocked(threadID: $0) }
    }

    /// Appends a message to `ghost_chat_messages`. Automatically applies `ACTAOpSec.stripPersona` to user prompts and `ACTAOpSec.sanitizeText` to assistant outputs.
    @discardableResult
    public func appendACTAChatMessage(
        _ message: ACTAChatMessageRecord,
        terminalResponseID: String? = nil,
        pendingOutputs: [ACTAPendingOutputDebt]? = nil,
        reviewSafeContext: Bool = false,
        trustedOfflineChain: Bool = false
    ) throws -> ACTAChatMessageRecord {
        _ = try ensureACTAChatThread(threadID: message.threadID, now: message.createdAt)
        var sanitized = message
        if sanitized.role == "user" {
            sanitized.text = ACTAOpSec.stripPersona(sanitized.text)
        } else if sanitized.role == "assistant" {
            sanitized.text = ACTAOpSec.sanitizeText(sanitized.text)
            if let ans = sanitized.structuredAnswer {
                sanitized.structuredAnswer = ACTAOpSec.sanitizeAnswer(ans)
            }
        }
        let structuredJSON = try sanitized.structuredAnswer.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let pendingJSON = try pendingOutputs.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }

        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_chat_messages(
                message_id, thread_id, role, content, structured_json, created_at, clip_id, call_id, review_safe_context,
                safe_offline_chain_id, safe_offline_debt_json
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(sanitized.messageID, at: 1, to: stmt)
        bind(sanitized.threadID, at: 2, to: stmt)
        bind(sanitized.role, at: 3, to: stmt)
        bind(sanitized.text, at: 4, to: stmt)
        if let structuredJSON { bind(structuredJSON, at: 5, to: stmt) } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_double(stmt, 6, sanitized.createdAt.timeIntervalSince1970)
        if let clipID = sanitized.clipID { bind(clipID, at: 7, to: stmt) } else { sqlite3_bind_null(stmt, 7) }
        if let callID = sanitized.callID { bind(callID, at: 8, to: stmt) } else { sqlite3_bind_null(stmt, 8) }
        let safe = reviewSafeContext && sanitized.role == "assistant"
            && sanitized.structuredAnswer.map { $0.proposedActions.isEmpty } == true
        sqlite3_bind_int(stmt, 9, safe ? 1 : 0)
        let safeDebt = pendingOutputs.map { !$0.isEmpty && $0.allSatisfy {
            !$0.callID.isEmpty && $0.callID.utf8.count <= 256
                && $0.callID.utf8.allSatisfy { (0x21...0x7E).contains($0) }
                && ($0.outputJSON == #"{"status":"presented"}"# || $0.outputJSON == #"{"status":"skipped"}"#)
        } } == true
        if safe && trustedOfflineChain && safeDebt,
           let terminalResponseID, terminalResponseID.hasPrefix("resp_offline_"),
           terminalResponseID.utf8.count <= 256,
           terminalResponseID.utf8.allSatisfy({ (0x21...0x7E).contains($0) }), let pendingJSON {
            bind(terminalResponseID, at: 10, to: stmt)
            bind(pendingJSON, at: 11, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 10)
            sqlite3_bind_null(stmt, 11)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }

        let upd = try prepare("UPDATE ghost_chat_threads SET updated_at = MAX(updated_at, ?) WHERE thread_id = ?")
        defer { sqlite3_finalize(upd) }
        sqlite3_bind_double(upd, 1, sanitized.createdAt.timeIntervalSince1970)
        bind(sanitized.threadID, at: 2, to: upd)
        guard sqlite3_step(upd) == SQLITE_DONE else { throw databaseError() }
        if let pendingJSON {
            let chain = try prepare("UPDATE ghost_chat_threads SET last_response_id = ?, pending_outputs_json = ? WHERE thread_id = ?")
            defer { sqlite3_finalize(chain) }
            if let terminalResponseID { bind(terminalResponseID, at: 1, to: chain) } else { sqlite3_bind_null(chain, 1) }
            bind(pendingJSON, at: 2, to: chain)
            bind(sanitized.threadID, at: 3, to: chain)
            guard sqlite3_step(chain) == SQLITE_DONE else { throw databaseError() }
        }
        try execute("COMMIT")
        return sanitized
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Opaque legacy server chains have no trustworthy provenance; only locally recorded offline chains qualify.
    public func loadACTASafeOfflineChain(threadID: String) throws -> (String, [ACTAPendingOutputDebt])? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT m.safe_offline_chain_id, m.safe_offline_debt_json, t.last_response_id, t.pending_outputs_json
            FROM ghost_chat_messages m JOIN ghost_chat_threads t ON t.thread_id = m.thread_id
            WHERE m.thread_id = ? AND m.role = 'assistant' AND m.review_safe_context = 1
                AND m.safe_offline_chain_id IS NOT NULL
            ORDER BY m.rowid DESC LIMIT 1
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw databaseError() }
        guard sqlite3_column_type(stmt, 1) != SQLITE_NULL, sqlite3_column_type(stmt, 2) != SQLITE_NULL,
              sqlite3_column_type(stmt, 3) != SQLITE_NULL, text(stmt, 0) == text(stmt, 2) else { return nil }
        let debt: [ACTAPendingOutputDebt]
        let current: [ACTAPendingOutputDebt]
        do {
            debt = try JSONDecoder().decode([ACTAPendingOutputDebt].self, from: Data(text(stmt, 1).utf8))
            current = try JSONDecoder().decode([ACTAPendingOutputDebt].self, from: Data(text(stmt, 3).utf8))
        } catch {
            throw LocalTrackingStoreError.query("Stored offline chain data is invalid.")
        }
        guard debt == current else { return nil }
        return (text(stmt, 0), debt)
    }

    public func loadACTAChatMessages(
        threadID: String, limit: Int = 200, reviewSafeContextOnly: Bool = false
    ) throws -> [ACTAChatMessageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT message_id, thread_id, role, content, structured_json, created_at, clip_id, call_id
            FROM ghost_chat_messages
            WHERE thread_id = ? AND (? = 0 OR role = 'user' OR (role = 'assistant' AND review_safe_context = 1))
            ORDER BY created_at ASC
            LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        sqlite3_bind_int(stmt, 2, reviewSafeContextOnly ? 1 : 0)
        sqlite3_bind_int(stmt, 3, Int32(max(1, min(1000, limit))))
        var messages: [ACTAChatMessageRecord] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mid = text(stmt, 0)
            let tid = text(stmt, 1)
            let role = text(stmt, 2)
            let content = text(stmt, 3)
            let structJSON = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : text(stmt, 4)
            let ans = structJSON.flatMap { try? decoder.decode(ACTAChatFinalAnswer.self, from: Data($0.utf8)) }
            let cAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let clipID = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : text(stmt, 6)
            let callID = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : text(stmt, 7)
            messages.append(
                ACTAChatMessageRecord(
                    messageID: mid,
                    threadID: tid,
                    role: role,
                    text: content,
                    structuredAnswer: ans,
                    clipID: clipID,
                    callID: callID,
                    createdAt: cAt
                )
            )
        }
        return messages
    }

    public func setACTAThreadChainHead(
        threadID: String,
        lastResponseID: String?,
        pendingOutputs: [ACTAPendingOutputDebt] = [],
        now: Date = Date()
    ) throws {
        _ = try ensureACTAChatThread(threadID: threadID, now: now)
        let pendingJSON = pendingOutputs.isEmpty ? nil : (try? String(data: JSONEncoder().encode(pendingOutputs), encoding: .utf8))
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            UPDATE ghost_chat_threads
            SET last_response_id = ?,
                pending_outputs_json = ?,
                updated_at = MAX(updated_at, ?)
            WHERE thread_id = ?
            """)
        defer { sqlite3_finalize(stmt) }
        if let lastResponseID { bind(lastResponseID, at: 1, to: stmt) } else { sqlite3_bind_null(stmt, 1) }
        if let pendingJSON { bind(pendingJSON, at: 2, to: stmt) } else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
        bind(threadID, at: 4, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    /// Reads and atomically clears `pending_outputs_json` for a thread when settling OpenAI Responses API `function_call_output` debt.
    public func consumeACTAThreadPendingOutputs(threadID: String) throws -> (lastResponseID: String?, owedOutputs: [ACTAPendingOutputDebt]) {
        lock.lock()
        defer { lock.unlock() }
        guard let thread = try loadACTAChatThreadUnlocked(threadID: threadID) else {
            return (nil, [])
        }
        if !thread.pendingOutputs.isEmpty {
            let clr = try prepare("UPDATE ghost_chat_threads SET pending_outputs_json = NULL WHERE thread_id = ?")
            defer { sqlite3_finalize(clr) }
            bind(threadID, at: 1, to: clr)
            _ = sqlite3_step(clr)
        }
        return (thread.lastResponseID, thread.pendingOutputs)
    }

    public func pushACTAThreadFocus(
        threadID: String,
        kind: String = "identity",
        refID: String,
        label: String? = nil,
        pinned: Bool = false,
        now: Date = Date()
    ) throws {
        guard !refID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try ensureACTAChatThread(threadID: threadID, now: now)
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT INTO ghost_thread_focus(thread_id, kind, ref_id, label, pinned, last_used_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, kind, ref_id) DO UPDATE SET
                label = COALESCE(excluded.label, ghost_thread_focus.label),
                pinned = MAX(ghost_thread_focus.pinned, excluded.pinned),
                last_used_at = MAX(ghost_thread_focus.last_used_at, excluded.last_used_at)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        bind(kind, at: 2, to: stmt)
        bind(refID, at: 3, to: stmt)
        if let label { bind(label, at: 4, to: stmt) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_int(stmt, 5, pinned ? 1 : 0)
        sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    public func loadACTAThreadFocusEntries(threadID: String, limit: Int = 6) throws -> [ACTAThreadFocusEntry] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT thread_id, kind, ref_id, label, pinned, last_used_at
            FROM ghost_thread_focus
            WHERE thread_id = ?
            ORDER BY pinned DESC, last_used_at DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        sqlite3_bind_int(stmt, 2, Int32(max(1, min(50, limit))))
        var entries: [ACTAThreadFocusEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(
                ACTAThreadFocusEntry(
                    threadID: text(stmt, 0),
                    kind: text(stmt, 1),
                    refID: text(stmt, 2),
                    label: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : text(stmt, 3),
                    pinned: sqlite3_column_int(stmt, 4) != 0,
                    lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                )
            )
        }
        return entries
    }

    /// Builds the system-prompt focus block (`Active Entity Focus`) for pronoun resolution ("he", "she", "that car", "он", "она", "эта машина").
    public func loadACTAThreadFocusBlock(threadID: String, limit: Int = 6) throws -> String {
        let entries = try loadACTAThreadFocusEntries(threadID: threadID, limit: limit)
        guard !entries.isEmpty else { return "" }
        var lines: [String] = ["Active Entity Focus (use to resolve pronouns like he/she/they/that vehicle):"]
        for entry in entries {
            let pinTag = entry.pinned ? " [PINNED]" : ""
            if entry.kind == "identity", let dossier = try? getACTAIdentityDossier(identityID: entry.refID) {
                lines.append("- \(dossier.summaryLine)\(pinTag)")
            } else {
                let lbl = entry.label.map { " (\($0))" } ?? ""
                lines.append("- [\(entry.kind)] \(entry.refID)\(lbl)\(pinTag)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func bindACTAThreadCameras(threadID: String, cameraIDs: [String], now: Date = Date()) throws {
        guard !cameraIDs.isEmpty else { return }
        _ = try ensureACTAChatThread(threadID: threadID, now: now)
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR IGNORE INTO ghost_thread_cameras(thread_id, camera_id, bound_at)
            VALUES(?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        for camID in cameraIDs where !camID.isEmpty {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(threadID, at: 1, to: stmt)
            bind(camID, at: 2, to: stmt)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        }
    }

    public func linkACTAThreads(threadA: String, threadB: String, now: Date = Date()) throws {
        guard threadA != threadB else { return }
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR IGNORE INTO ghost_thread_links(thread_a, thread_b, linked_at)
            VALUES(?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        for (a, b) in [(threadA, threadB), (threadB, threadA)] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(a, at: 1, to: stmt)
            bind(b, at: 2, to: stmt)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        }
    }

    /// Transactionally merges `sourceThreadID` into `targetThreadID`, re-parenting all messages, tool calls, clips, actions, focus entries, cameras, and links, and resetting `last_response_id = NULL` and `pending_outputs_json = NULL` so the next turn rebuilds a full history transcript.
    public func mergeACTAThreads(
        sourceThreadID: String,
        intoTargetThreadID targetThreadID: String,
        now: Date = Date()
    ) throws {
        guard sourceThreadID != targetThreadID else { return }
        _ = try ensureACTAChatThread(threadID: targetThreadID, now: now)

        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for table in ["ghost_chat_messages", "ghost_chat_tool_calls", "ghost_chat_clips", "ghost_chat_actions"] {
                let stmt = try prepare("UPDATE \(table) SET thread_id = ? WHERE thread_id = ?")
                defer { sqlite3_finalize(stmt) }
                bind(targetThreadID, at: 1, to: stmt)
                bind(sourceThreadID, at: 2, to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
            }

            // Merge focus with MAX(last_used_at) and MAX(pinned)
            let focusStmt = try prepare("""
                INSERT INTO ghost_thread_focus(thread_id, kind, ref_id, label, pinned, last_used_at)
                SELECT ?, kind, ref_id, label, pinned, last_used_at FROM ghost_thread_focus WHERE thread_id = ?
                ON CONFLICT(thread_id, kind, ref_id) DO UPDATE SET
                    label = COALESCE(ghost_thread_focus.label, excluded.label),
                    pinned = MAX(ghost_thread_focus.pinned, excluded.pinned),
                    last_used_at = MAX(ghost_thread_focus.last_used_at, excluded.last_used_at)
                """)
            defer { sqlite3_finalize(focusStmt) }
            bind(targetThreadID, at: 1, to: focusStmt)
            bind(sourceThreadID, at: 2, to: focusStmt)
            guard sqlite3_step(focusStmt) == SQLITE_DONE else { throw databaseError() }

            let delFocus = try prepare("DELETE FROM ghost_thread_focus WHERE thread_id = ?")
            defer { sqlite3_finalize(delFocus) }
            bind(sourceThreadID, at: 1, to: delFocus)
            guard sqlite3_step(delFocus) == SQLITE_DONE else { throw databaseError() }

            // Merge bound cameras
            let camStmt = try prepare("""
                INSERT OR IGNORE INTO ghost_thread_cameras(thread_id, camera_id, bound_at)
                SELECT ?, camera_id, bound_at FROM ghost_thread_cameras WHERE thread_id = ?
                """)
            defer { sqlite3_finalize(camStmt) }
            bind(targetThreadID, at: 1, to: camStmt)
            bind(sourceThreadID, at: 2, to: camStmt)
            guard sqlite3_step(camStmt) == SQLITE_DONE else { throw databaseError() }

            let delCam = try prepare("DELETE FROM ghost_thread_cameras WHERE thread_id = ?")
            defer { sqlite3_finalize(delCam) }
            bind(sourceThreadID, at: 1, to: delCam)
            guard sqlite3_step(delCam) == SQLITE_DONE else { throw databaseError() }

            // Re-parent thread links and remove self-links
            let linkA = try prepare("UPDATE OR IGNORE ghost_thread_links SET thread_a = ? WHERE thread_a = ?")
            defer { sqlite3_finalize(linkA) }
            bind(targetThreadID, at: 1, to: linkA)
            bind(sourceThreadID, at: 2, to: linkA)
            _ = sqlite3_step(linkA)

            let linkB = try prepare("UPDATE OR IGNORE ghost_thread_links SET thread_b = ? WHERE thread_b = ?")
            defer { sqlite3_finalize(linkB) }
            bind(targetThreadID, at: 1, to: linkB)
            bind(sourceThreadID, at: 2, to: linkB)
            _ = sqlite3_step(linkB)

            let cleanLinks = try prepare("DELETE FROM ghost_thread_links WHERE thread_a = ? OR thread_b = ? OR thread_a = thread_b")
            defer { sqlite3_finalize(cleanLinks) }
            bind(sourceThreadID, at: 1, to: cleanLinks)
            bind(sourceThreadID, at: 2, to: cleanLinks)
            _ = sqlite3_step(cleanLinks)

            // Reset chain head on target thread so next turn sends full merged history
            let resetTarget = try prepare("""
                UPDATE ghost_chat_threads
                SET last_response_id = NULL,
                    pending_outputs_json = NULL,
                    updated_at = ?
                WHERE thread_id = ?
                """)
            defer { sqlite3_finalize(resetTarget) }
            sqlite3_bind_double(resetTarget, 1, now.timeIntervalSince1970)
            bind(targetThreadID, at: 2, to: resetTarget)
            guard sqlite3_step(resetTarget) == SQLITE_DONE else { throw databaseError() }

            // Delete source thread
            let delSrc = try prepare("DELETE FROM ghost_chat_threads WHERE thread_id = ?")
            defer { sqlite3_finalize(delSrc) }
            bind(sourceThreadID, at: 1, to: delSrc)
            guard sqlite3_step(delSrc) == SQLITE_DONE else { throw databaseError() }

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func recordACTAToolCallAudit(_ record: ACTAToolCallAuditRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_chat_tool_calls(
                id, thread_id, tool_name, args_json, result_rows, duration_ms, ok, error, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(record.id, at: 1, to: stmt)
        bind(record.threadID, at: 2, to: stmt)
        bind(record.toolName, at: 3, to: stmt)
        bind(record.argsJSON, at: 4, to: stmt)
        sqlite3_bind_int(stmt, 5, Int32(record.resultRows))
        sqlite3_bind_int(stmt, 6, Int32(record.durationMs))
        sqlite3_bind_int(stmt, 7, record.ok ? 1 : 0)
        if let err = record.error { bind(err, at: 8, to: stmt) } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_bind_double(stmt, 9, record.createdAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    /// Commits the audit independently with SQLite's full-sync durability before returning.
    public func recordDurableACTAToolCallAudit(_ record: ACTAToolCallAuditRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_get_autocommit(database) != 0 else {
            throw LocalTrackingStoreError.query("A durable audit cannot join an existing transaction.")
        }
        let journal = try prepare("PRAGMA journal_mode")
        let validJournal = sqlite3_step(journal) == SQLITE_ROW
            && sqlite3_column_text(journal, 0).map { !["off", "memory"].contains(String(cString: $0).lowercased()) } == true
        sqlite3_finalize(journal)
        guard validJournal else {
            throw LocalTrackingStoreError.query("A durable audit requires an on-disk journal.")
        }
        let sync = try prepare("PRAGMA synchronous")
        let previousSync = sqlite3_step(sync) == SQLITE_ROW ? sqlite3_column_int(sync, 0) : -1
        sqlite3_finalize(sync)
        guard (0...3).contains(previousSync) else {
            throw LocalTrackingStoreError.query("Cannot determine the SQLite synchronization mode.")
        }
        try execute("PRAGMA synchronous=FULL")
        var writeError: Error?
        do {
            try recordACTAToolCallAudit(record)
        } catch {
            writeError = error
        }
        do {
#if DEBUG
            try durableAuditRestoreTestHook?()
#endif
            try execute("PRAGMA synchronous=\(previousSync)")
        } catch {
            throw LocalTrackingStoreError.query(writeError == nil
                ? "The audit was committed, but SQLite synchronization mode restoration failed."
                : "The audit write and SQLite synchronization mode restoration both failed.")
        }
        if let writeError { throw writeError }
    }

    public func saveACTAChatAction(_ action: ACTAChatActionRecord) throws {
        let paramsJSON = (try? String(data: JSONEncoder().encode(action.parameters), encoding: .utf8)) ?? "{}"
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_chat_actions(
                action_id, thread_id, action_type, title, params_json, status, created_at, reviewed_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(action.actionID, at: 1, to: stmt)
        bind(action.threadID, at: 2, to: stmt)
        bind(action.actionType, at: 3, to: stmt)
        bind(action.title, at: 4, to: stmt)
        bind(paramsJSON, at: 5, to: stmt)
        bind(action.status, at: 6, to: stmt)
        sqlite3_bind_double(stmt, 7, action.createdAt.timeIntervalSince1970)
        if let rev = action.reviewedAt { sqlite3_bind_double(stmt, 8, rev.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 8) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
    }

    public func listACTAChatActions(threadID: String? = nil, status: String? = nil) throws -> [ACTAChatActionRecord] {
        lock.lock()
        defer { lock.unlock() }
        var clauses: [String] = []
        if threadID != nil { clauses.append("thread_id = ?") }
        if status != nil { clauses.append("status = ?") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let stmt = try prepare("""
            SELECT action_id, thread_id, action_type, title, params_json, status, created_at, reviewed_at
            FROM ghost_chat_actions
            \(whereSQL)
            ORDER BY created_at DESC
            LIMIT 100
            """)
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if let threadID { bind(threadID, at: idx, to: stmt); idx += 1 }
        if let status { bind(status, at: idx, to: stmt); idx += 1 }
        var list: [ACTAChatActionRecord] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let aid = text(stmt, 0)
            let tid = text(stmt, 1)
            let atype = text(stmt, 2)
            let title = text(stmt, 3)
            let params = (try? decoder.decode([String: String].self, from: Data(text(stmt, 4).utf8))) ?? [:]
            let st = text(stmt, 5)
            let cAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let rAt = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            list.append(
                ACTAChatActionRecord(
                    actionID: aid,
                    threadID: tid,
                    actionType: atype,
                    title: title,
                    parameters: params,
                    status: st,
                    createdAt: cAt,
                    reviewedAt: rAt
                )
            )
        }
        return list
    }

    /// The reviewed decision and its database effects form one durable unit.
    /// Nested store methods use the recursive lock on this same connection.
    public func applyACTAChatAction(
        _ proposal: ACTAChatActionRecord, confirmed: Bool, now: Date = Date(),
        changes: (LocalTrackingStore) throws -> Void
    ) throws -> ACTAChatActionRecord? {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            guard let updated = try resolveACTAChatAction(actionID: proposal.actionID, confirmed: confirmed,
                expectedAction: proposal, now: now) else {
                try execute("ROLLBACK")
                return nil
            }
            if confirmed { try changes(self) }
            try execute("COMMIT")
            return updated
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func loadACTAChatActionUnlocked(actionID: String) throws -> ACTAChatActionRecord? {
        let stmt = try prepare("SELECT action_id, thread_id, action_type, title, params_json, status, created_at, reviewed_at FROM ghost_chat_actions WHERE action_id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(actionID, at: 1, to: stmt)
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw databaseError() }
        return ACTAChatActionRecord(actionID: text(stmt, 0), threadID: text(stmt, 1), actionType: text(stmt, 2),
            title: text(stmt, 3), parameters: try JSONDecoder().decode([String: String].self, from: Data(text(stmt, 4).utf8)),
            status: text(stmt, 5), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            reviewedAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)))
    }

    public func loadACTAChatAction(actionID: String) throws -> ACTAChatActionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try loadACTAChatActionUnlocked(actionID: actionID)
    }

    /// Compare the reviewed proposal under the same lock as the one-shot state transition.
    public func resolveACTAChatAction(actionID: String, confirmed: Bool,
                                     expectedAction: ACTAChatActionRecord? = nil,
                                     now: Date = Date()) throws -> ACTAChatActionRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard var action = try loadACTAChatActionUnlocked(actionID: actionID), action.status == "proposed" else { return nil }
        if let expected = expectedAction {
            // Compare the reviewed intent, not Date round-tripping through SQLite REAL.
            guard expected.actionID == action.actionID, expected.threadID == action.threadID,
                  expected.actionType == action.actionType, expected.title == action.title,
                  expected.parameters == action.parameters, expected.status == action.status else { return nil }
        }
        let resolvedStatus = confirmed ? "confirmed" : "rejected"
        let upd = try prepare("UPDATE ghost_chat_actions SET status = ?, reviewed_at = ? WHERE action_id = ? AND status = 'proposed'")
        defer { sqlite3_finalize(upd) }
        bind(resolvedStatus, at: 1, to: upd)
        sqlite3_bind_double(upd, 2, now.timeIntervalSince1970)
        bind(actionID, at: 3, to: upd)
        guard sqlite3_step(upd) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(database) == 1 else { return nil }
        action.status = resolvedStatus
        action.reviewedAt = now
        return action
    }

    @discardableResult
    public func saveACTAChatClip(
        clipID: String = UUID().uuidString,
        threadID: String,
        cameraID: String,
        clipData: Data,
        fileExtension: String = "jpg",
        createdAt: Date = Date()
    ) throws -> ACTAChatClipRecord {
        try FileManager.default.createDirectory(
            at: cropDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fileName = "chatclip_\(clipID.lowercased()).\(fileExtension)"
        let fileURL = cropDirectory.appendingPathComponent(fileName)
        try clipData.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let record = ACTAChatClipRecord(
            clipID: clipID,
            threadID: threadID,
            cameraID: cameraID,
            filePath: fileName,
            createdAt: createdAt
        )

        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            INSERT OR REPLACE INTO ghost_chat_clips(clip_id, thread_id, camera_id, file_path, created_at, expires_at)
            VALUES(?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        bind(record.clipID, at: 1, to: stmt)
        bind(record.threadID, at: 2, to: stmt)
        bind(record.cameraID, at: 3, to: stmt)
        bind(record.filePath, at: 4, to: stmt)
        sqlite3_bind_double(stmt, 5, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, record.expiresAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw databaseError() }
        return record
    }

    public func loadACTAChatClips(threadID: String) throws -> [ACTAChatClipRecord] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT clip_id, thread_id, camera_id, file_path, created_at, expires_at
            FROM ghost_chat_clips
            WHERE thread_id = ?
            ORDER BY created_at DESC
            """)
        defer { sqlite3_finalize(stmt) }
        bind(threadID, at: 1, to: stmt)
        var list: [ACTAChatClipRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            list.append(
                ACTAChatClipRecord(
                    clipID: text(stmt, 0),
                    threadID: text(stmt, 1),
                    cameraID: text(stmt, 2),
                    filePath: text(stmt, 3),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                )
            )
        }
        return list
    }

    // MARK: - Storage Janitor (Degrade-Before-Delete Ladder & Protected Evidence)

    /// Executes the Ghost Storage Janitor pass:
    /// 1. Prunes expired 44-minute `ghost_chat_clips` (deleting file on disk + SQLite row).
    /// 2. Identifies protected tracks: `is_best = 1`, the highest-quality crop of every identity, and tracks belonging to operator-named identities.
    /// 3. Enforces per-identity crop cap (`maxCropsPerIdentity = 48`, or `1` when `dataSaverEnabled`) and age/disk pressure by degrading `cutout_path -> NULL` and `crop_path -> NULL` on disk while **preserving** the SQLite row, `reid_embedding` (512D), and `chroma_blob`.
    /// 4. Prunes old `ghost_chat_tool_calls` and `ghost_ai_cache` older than `logRetentionDays`, while never touching `ghost_narrative_chapters` or `ghost_chat_threads`.
    public func runACTAStorageJanitorPass(
        policy: ACTAStorageJanitorPolicy = ACTAStorageJanitorPolicy(),
        now: Date = Date()
    ) throws -> ACTAStorageJanitorReport {
        var report = ACTAStorageJanitorReport()

        // Check free disk space
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: cropDirectory.deletingLastPathComponent().path),
           let freeBytes = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue {
            let freeGB = freeBytes / (1024.0 * 1024.0 * 1024.0)
            if freeGB < policy.minFreeDiskGB {
                report.lowDiskSpaceTriggered = true
            }
        }

        let Profiles = (try? loadACTAIdentityProfiles(limit: 5000)) ?? []
        let namedIdentityIDs = Set(Profiles.compactMap { prof -> String? in
            guard let name = prof.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            return prof.identityID
        })

        lock.lock()
        defer { lock.unlock() }

        // 1. Prune expired chat clips (44-min TTL)
        let expStmt = try prepare("SELECT clip_id, file_path FROM ghost_chat_clips WHERE expires_at <= ?")
        defer { sqlite3_finalize(expStmt) }
        sqlite3_bind_double(expStmt, 1, now.timeIntervalSince1970)
        var expiredClips: [(String, String)] = []
        while sqlite3_step(expStmt) == SQLITE_ROW {
            expiredClips.append((text(expStmt, 0), text(expStmt, 1)))
        }
        for (cid, path) in expiredClips {
            removeCrop(at: path)
            let del = try prepare("DELETE FROM ghost_chat_clips WHERE clip_id = ?")
            defer { sqlite3_finalize(del) }
            bind(cid, at: 1, to: del)
            if sqlite3_step(del) == SQLITE_DONE {
                report.expiredClipsRemovedCount += 1
            }
        }

        // 2. Inspect all tracked_objects to determine best crop per identity & overflow / aging candidates
        struct TrackMediaRow {
            let trackID: String
            let identityID: String?
            let lastSeen: Double
            let quality: Double
            let isBest: Bool
            let cropPath: String?
            let cutoutPath: String?
        }

        let trkStmt = try prepare("""
            SELECT track_id, ghost_identity_id, last_seen, COALESCE(crop_quality, best_confidence, 0.5), COALESCE(is_best, 0), crop_path, cutout_path
            FROM tracked_objects
            ORDER BY COALESCE(crop_quality, best_confidence, 0.5) DESC, last_seen DESC
            """)
        defer { sqlite3_finalize(trkStmt) }
        var allTracks: [TrackMediaRow] = []
        while sqlite3_step(trkStmt) == SQLITE_ROW {
            allTracks.append(
                TrackMediaRow(
                    trackID: text(trkStmt, 0),
                    identityID: sqlite3_column_type(trkStmt, 1) == SQLITE_NULL ? nil : text(trkStmt, 1),
                    lastSeen: sqlite3_column_double(trkStmt, 2),
                    quality: sqlite3_column_double(trkStmt, 3),
                    isBest: sqlite3_column_int(trkStmt, 4) != 0,
                    cropPath: sqlite3_column_type(trkStmt, 5) == SQLITE_NULL ? nil : text(trkStmt, 5),
                    cutoutPath: sqlite3_column_type(trkStmt, 6) == SQLITE_NULL ? nil : text(trkStmt, 6)
                )
            )
        }

        var protectedTrackIDs = Set<String>()
        var tracksPerIdentity: [String: [TrackMediaRow]] = [:]
        for row in allTracks {
            if row.isBest {
                protectedTrackIDs.insert(row.trackID)
            }
            if let gid = row.identityID, !gid.isEmpty {
                tracksPerIdentity[gid, default: []].append(row)
                if namedIdentityIDs.contains(gid) {
                    protectedTrackIDs.insert(row.trackID)
                }
            }
        }
        // Always protect the #1 highest-quality crop per identity
        for (_, rows) in tracksPerIdentity {
            if let bestRow = rows.first {
                protectedTrackIDs.insert(bestRow.trackID)
            }
        }

        let effectiveCap = policy.dataSaverEnabled ? 1 : max(1, policy.maxCropsPerIdentity)
        var overflowTrackIDs = Set<String>()
        for (_, rows) in tracksPerIdentity where rows.count > effectiveCap {
            for overflow in rows.dropFirst(effectiveCap) where !protectedTrackIDs.contains(overflow.trackID) {
                overflowTrackIDs.insert(overflow.trackID)
            }
        }

        let retentionCutoff = now.addingTimeInterval(-Double(max(1, policy.trackImageRetentionDays)) * 86_400).timeIntervalSince1970

        for row in allTracks where !protectedTrackIDs.contains(row.trackID) {
            let isOverflow = overflowTrackIDs.contains(row.trackID)
            let isAged = row.lastSeen < retentionCutoff
            guard isOverflow || isAged || report.lowDiskSpaceTriggered else { continue }

            // Step 1 of Degrade Ladder: remove cutout PNG first
            if let cutout = row.cutoutPath {
                removeCrop(at: cutout)
                let u = try prepare("UPDATE tracked_objects SET cutout_path = NULL WHERE track_id = ?")
                defer { sqlite3_finalize(u) }
                bind(row.trackID, at: 1, to: u)
                if sqlite3_step(u) == SQLITE_DONE {
                    report.degradedCutoutCount += 1
                }
            }
            // Step 2 of Degrade Ladder: remove crop JPEG while keeping SQLite row + 512D reid_embedding + chroma_blob
            if let crop = row.cropPath {
                removeCrop(at: crop)
                let u = try prepare("UPDATE tracked_objects SET crop_path = NULL WHERE track_id = ?")
                defer { sqlite3_finalize(u) }
                bind(row.trackID, at: 1, to: u)
                if sqlite3_step(u) == SQLITE_DONE {
                    report.degradedCropCount += 1
                    if isOverflow {
                        report.overflowCropsDegradedCount += 1
                    }
                }
            }
        }

        // 3. Prune old AI logs & cache older than logRetentionDays
        let logCutoff = now.addingTimeInterval(-Double(max(1, policy.logRetentionDays)) * 86_400).timeIntervalSince1970
        for table in ["ghost_chat_tool_calls", "ghost_ai_cache"] {
            let del = try prepare("DELETE FROM \(table) WHERE created_at < ?")
            defer { sqlite3_finalize(del) }
            sqlite3_bind_double(del, 1, logCutoff)
            if sqlite3_step(del) == SQLITE_DONE {
                report.oldLogsPrunedCount += Int(sqlite3_changes(database))
            }
        }

        return report
    }

    public func cacheVehicleRegistryRecord(_ record: ACTAVehicleRegistryRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            INSERT OR REPLACE INTO ghost_vehicle_registry_cache(plate_number, record_json, fetched_at)
            VALUES(?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.plateNumber, at: 1, to: statement)
        bind(json, at: 2, to: statement)
        sqlite3_bind_double(statement, 3, record.fetchedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func cachedVehicleRegistryRecord(plateNumber: String) throws -> ACTAVehicleRegistryRecord? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT record_json FROM ghost_vehicle_registry_cache WHERE plate_number = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(plateNumber, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let json = text(statement, 0)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ACTAVehicleRegistryRecord.self, from: data)
    }

    public func saveACTAAlertMentorBrief(cameraID: UUID, brief: ACTAAlertMentorBrief, createdAt: Date = Date()) throws {
        let data = try JSONEncoder().encode(brief)
        guard let json = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            INSERT OR REPLACE INTO ghost_alert_mentor_briefs(alert_id, camera_id, brief_json, created_at)
            VALUES(?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bind(brief.alertID, at: 1, to: statement)
        bind(cameraID.uuidString, at: 2, to: statement)
        bind(json, at: 3, to: statement)
        sqlite3_bind_double(statement, 4, createdAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    public func loadACTAAlertMentorBrief(alertID: String) throws -> ACTAAlertMentorBrief? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT brief_json FROM ghost_alert_mentor_briefs WHERE alert_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(alertID, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let data = text(statement, 0).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ACTAAlertMentorBrief.self, from: data)
    }

    public func loadACTAAlertMentorBriefs(
        cameraID: UUID? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 50
    ) throws -> [(alertID: String, cameraID: String, brief: ACTAAlertMentorBrief, createdAt: Date)] {
        lock.lock()
        defer { lock.unlock() }
        var clauses: [String] = []
        if cameraID != nil { clauses.append("camera_id = ?") }
        if since != nil { clauses.append("created_at >= ?") }
        if until != nil { clauses.append("created_at <= ?") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let statement = try prepare("""
            SELECT alert_id, camera_id, brief_json, created_at
            FROM ghost_alert_mentor_briefs
            \(whereSQL)
            ORDER BY created_at DESC
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        var idx: Int32 = 1
        if let cameraID {
            bind(cameraID.uuidString, at: idx, to: statement)
            idx += 1
        }
        if let since {
            sqlite3_bind_double(statement, idx, since.timeIntervalSince1970)
            idx += 1
        }
        if let until {
            sqlite3_bind_double(statement, idx, until.timeIntervalSince1970)
            idx += 1
        }
        sqlite3_bind_int(statement, idx, Int32(max(1, min(500, limit))))
        var rows: [(alertID: String, cameraID: String, brief: ACTAAlertMentorBrief, createdAt: Date)] = []
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            let aid = text(statement, 0)
            let cid = text(statement, 1)
            let json = text(statement, 2)
            let cAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            if let data = json.data(using: .utf8),
               let brief = try? decoder.decode(ACTAAlertMentorBrief.self, from: data) {
                rows.append((alertID: aid, cameraID: cid, brief: brief, createdAt: cAt))
            }
        }
        return rows
    }

    /// Synchronizes a track's local VLM `description_json` and OCR `vehicle_text_json` into the ACTA knowledge tables
    /// (`ghost_attribute_index`, `ghost_crop_fts`, `ghost_identity_dossiers`, `ghost_visits`) so that all saved track
    /// descriptions and vehicle texts are immediately searchable by the Ghost agent tools.
    public func syncLocalTrackToACTAKnowledge(trackID: UUID, now: Date = Date()) throws {
        let trackIDStr = trackID.uuidString
        var cameraIDStr = ""
        var labelStr = "person"
        var lastSeenDate = now
        var cropQuality = 0.75
        var description: TrackedObjectDescription?
        var vehicleEvidence: VehicleTextEvidence?
        var resolvedIdentityID = ""

        lock.lock()
        do {
            let stmt = try prepare("""
                SELECT t.camera_id, t.label, t.last_seen, COALESCE(t.crop_quality, t.best_confidence, 0.75),
                       t.description_json, t.vehicle_text_json, t.ghost_identity_id, g.group_id
                FROM tracked_objects t
                LEFT JOIN operator_identity_groups g ON g.track_id = t.track_id
                WHERE t.track_id = ?
                LIMIT 1
                """)
            defer { sqlite3_finalize(stmt) }
            bind(trackIDStr, at: 1, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                lock.unlock()
                return
            }
            cameraIDStr = text(stmt, 0)
            labelStr = text(stmt, 1)
            lastSeenDate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            cropQuality = sqlite3_column_double(stmt, 3)
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                description = TrackedObjectDescription.parse(text(stmt, 4))
            }
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                let vJSON = text(stmt, 5)
                vehicleEvidence = try? JSONDecoder().decode(VehicleTextEvidence.self, from: Data(vJSON.utf8))
            }
            let actaID = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? "" : text(stmt, 6)
            let groupID = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? "" : text(stmt, 7)
            if !actaID.isEmpty {
                resolvedIdentityID = actaID
            } else if !groupID.isEmpty {
                resolvedIdentityID = groupID
            } else {
                resolvedIdentityID = trackIDStr
            }

            if actaID.isEmpty {
                let upd = try prepare("UPDATE tracked_objects SET ghost_identity_id = ? WHERE track_id = ?")
                defer { sqlite3_finalize(upd) }
                bind(resolvedIdentityID, at: 1, to: upd)
                bind(trackIDStr, at: 2, to: upd)
                _ = sqlite3_step(upd)
            }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        let kind = (Self.category(labelStr) == "vehicle") ? "vehicle" : "person"
        var entries: [ACTAAttributeIndexEntry] = [
            ACTAAttributeIndexEntry(
                trackID: trackIDStr,
                identityID: resolvedIdentityID,
                cameraID: cameraIDStr,
                capturedAt: lastSeenDate,
                facet: "kind",
                value: kind,
                confidence: 0.90,
                cropQuality: cropQuality,
                source: "local_track"
            )
        ]

        func appendFacet(_ facet: String, _ rawValue: String?, confidence: Double) {
            guard let cleaned = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !cleaned.isEmpty, cleaned != "none", cleaned != "null", cleaned != "unknown" else { return }
            entries.append(
                ACTAAttributeIndexEntry(
                    trackID: trackIDStr,
                    identityID: resolvedIdentityID,
                    cameraID: cameraIDStr,
                    capturedAt: lastSeenDate,
                    facet: facet,
                    value: cleaned,
                    confidence: max(0.35, min(1.0, confidence)),
                    cropQuality: cropQuality,
                    source: "local_track"
                )
            )
        }

        if let description {
            for (rawKey, attr) in description.attributes {
                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = attr.value
                switch key {
                case "upper_color", "top_color", "shirt_color", "jacket_color":
                    let norm = ACTAColorNormalizer.normalizeColorToken(val) ?? val
                    appendFacet("upper_color", norm, confidence: attr.confidence)
                    appendFacet("color", norm, confidence: attr.confidence * 0.9)
                case "lower_color", "bottom_color", "pants_color":
                    let norm = ACTAColorNormalizer.normalizeColorToken(val) ?? val
                    appendFacet("lower_color", norm, confidence: attr.confidence)
                    appendFacet("color", norm, confidence: attr.confidence * 0.85)
                case "vehicle_color", "car_color", "primary_color":
                    let norm = ACTAColorNormalizer.normalizeColorToken(val) ?? val
                    appendFacet("vehicle_color", norm, confidence: attr.confidence)
                    appendFacet("color", norm, confidence: attr.confidence)
                case "color":
                    let norm = ACTAColorNormalizer.normalizeColorToken(val) ?? val
                    appendFacet(kind == "vehicle" ? "vehicle_color" : "upper_color", norm, confidence: attr.confidence)
                    appendFacet("color", norm, confidence: attr.confidence)
                case "gender", "sex", "apparent_sex":
                    appendFacet("sex", val, confidence: attr.confidence)
                case "age", "age_group":
                    appendFacet("age_group", val, confidence: attr.confidence)
                case "clothing", "upper_clothing", "upper_wear", "top":
                    appendFacet("upper_wear", val, confidence: attr.confidence)
                    if let norm = ACTAColorNormalizer.normalizeColorToken(val), norm != val.lowercased() {
                        appendFacet("upper_color", norm, confidence: attr.confidence * 0.85)
                        appendFacet("color", norm, confidence: attr.confidence * 0.8)
                    }
                case "lower_clothing", "lower_wear", "bottom", "pants":
                    appendFacet("lower_wear", val, confidence: attr.confidence)
                case "bag", "bags", "carried_item", "accessory", "accessories":
                    appendFacet("bag", val, confidence: attr.confidence)
                case "hat", "headwear":
                    appendFacet("headwear", val, confidence: attr.confidence)
                case "make", "brand":
                    appendFacet("make", val, confidence: attr.confidence)
                case "model":
                    appendFacet("model", val, confidence: attr.confidence)
                case "vehicle_type", "body_type", "type":
                    appendFacet(kind == "vehicle" ? "vehicle_category" : key, val, confidence: attr.confidence)
                case "plate", "plate_number", "license_plate":
                    appendFacet("plate_number", ACTAVehicleRegistryRecord.normalizeIsraeliPlate(val) ?? val, confidence: attr.confidence)
                default:
                    appendFacet(key, val, confidence: attr.confidence)
                }
            }
        }

        if let vehicleEvidence {
            for candidate in vehicleEvidence.candidates.prefix(5) {
                let conf = Double(candidate.confidence)
                appendFacet("vehicle_text", candidate.text, confidence: conf)
                if let normPlate = ACTAVehicleRegistryRecord.normalizeIsraeliPlate(candidate.text) {
                    appendFacet("plate_number", normPlate, confidence: conf)
                } else if candidate.text.count >= 5, candidate.text.count <= 10 {
                    appendFacet("plate_number", candidate.text, confidence: conf * 0.9)
                }
            }
        }

        var summaryPieces: [String] = []
        if let descSummary = description?.summary, !descSummary.isEmpty {
            summaryPieces.append(descSummary)
        }
        if let vehicleEvidence, !vehicleEvidence.candidates.isEmpty {
            let ocrLine = vehicleEvidence.candidates.prefix(5).map(\.text).joined(separator: " ")
            summaryPieces.append("OCR: \(ocrLine)")
        }
        let combinedSummary = summaryPieces.joined(separator: " | ")

        lock.lock()
        do {
            let del = try prepare("DELETE FROM ghost_attribute_index WHERE track_id = ? AND source = 'local_track'")
            defer { sqlite3_finalize(del) }
            bind(trackIDStr, at: 1, to: del)
            _ = sqlite3_step(del)

            let ins = try prepare("""
                INSERT INTO ghost_attribute_index(
                    track_id, identity_id, camera_id, captured_at, facet, value, confidence, crop_quality, source
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(ins) }
            for entry in entries {
                sqlite3_reset(ins)
                sqlite3_clear_bindings(ins)
                bind(entry.trackID, at: 1, to: ins)
                bind(entry.identityID, at: 2, to: ins)
                bind(entry.cameraID, at: 3, to: ins)
                sqlite3_bind_double(ins, 4, entry.capturedAt.timeIntervalSince1970)
                bind(entry.facet, at: 5, to: ins)
                bind(entry.value, at: 6, to: ins)
                sqlite3_bind_double(ins, 7, entry.confidence)
                sqlite3_bind_double(ins, 8, entry.cropQuality)
                bind(entry.source, at: 9, to: ins)
                _ = sqlite3_step(ins)
            }

            if !combinedSummary.isEmpty {
                if let delCropFTS = try? prepare("DELETE FROM ghost_crop_fts WHERE track_id = ?") {
                    defer { sqlite3_finalize(delCropFTS) }
                    bind(trackIDStr, at: 1, to: delCropFTS)
                    _ = sqlite3_step(delCropFTS)
                }
                if let insCropFTS = try? prepare("INSERT INTO ghost_crop_fts(track_id, identity_id, description_text) VALUES(?, ?, ?)") {
                    defer { sqlite3_finalize(insCropFTS) }
                    bind(trackIDStr, at: 1, to: insCropFTS)
                    bind(resolvedIdentityID, at: 2, to: insCropFTS)
                    bind(combinedSummary, at: 3, to: insCropFTS)
                    _ = sqlite3_step(insCropFTS)
                }
            }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        _ = try rebuildACTAIdentityDossier(identityID: resolvedIdentityID, kind: kind, now: lastSeenDate)
        _ = try rebuildACTAVisits(identityID: resolvedIdentityID)
    }
}