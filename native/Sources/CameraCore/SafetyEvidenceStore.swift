import Foundation

public struct SafetyEvidenceBundleManifest: Codable, Equatable, Sendable {
    public let incidentID: UUID
    public let cameraID: UUID
    public let cameraName: String
    public let incidentType: SafetyIncidentType
    public let severity: SafetyIncidentSeverity
    public let createdAt: Date
    public var preEventFrameCount: Int
    public var postEventFrameCount: Int
    public var totalBytes: Int
    public let primaryBox: FallBoundingBox?
    public let keypoints: [FallKeypoint]
    public let trackIDs: [UUID]
    public let metrics: [String: Double]
    public let explanation: String

    public init(
        incidentID: UUID,
        cameraID: UUID,
        cameraName: String,
        incidentType: SafetyIncidentType,
        severity: SafetyIncidentSeverity,
        createdAt: Date = Date(),
        preEventFrameCount: Int,
        postEventFrameCount: Int = 0,
        totalBytes: Int,
        primaryBox: FallBoundingBox? = nil,
        keypoints: [FallKeypoint] = [],
        trackIDs: [UUID] = [],
        metrics: [String: Double] = [:],
        explanation: String
    ) {
        self.incidentID = incidentID
        self.cameraID = cameraID
        self.cameraName = cameraName
        self.incidentType = incidentType
        self.severity = severity
        self.createdAt = createdAt
        self.preEventFrameCount = preEventFrameCount
        self.postEventFrameCount = postEventFrameCount
        self.totalBytes = totalBytes
        self.primaryBox = primaryBox
        self.keypoints = keypoints
        self.trackIDs = trackIDs
        self.metrics = metrics
        self.explanation = explanation
    }
}

/// Manages pre-event ring buffering, post-event frame collection, snapshot persistence,
/// and disk quota enforcement (`0o700` dirs, `0o600` files) for safety incidents in Local & Distributed modes.
public final class SafetyEvidenceStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/safety-evidence", isDirectory: true)
    }

    private struct PendingPostEventCapture {
        let incidentID: UUID
        let cameraID: UUID
        let startedAt: Date
        let durationSeconds: TimeInterval
        var lastCapturedAt: Date
        var capturedCount: Int
        let maxPostFrames: Int
    }

    public let baseDirectoryURL: URL
    private let lock = NSLock()
    private var persistenceError: String?
    public var lastPersistenceError: String? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceError
    }
    private var preEventBuffer = AlertLookbackBuffer()
    private var lastSampledUptimeByCamera: [UUID: TimeInterval] = [:]
    private var frameSerialCounter: UInt64 = 1
    private var pendingPostCaptures: [UUID: PendingPostEventCapture] = [:]

    public init(baseDirectoryURL: URL = SafetyEvidenceStore.defaultURL) {
        self.baseDirectoryURL = baseDirectoryURL
    }

    /// Checks whether the ring buffer needs a new sample for `cameraID` at `monotonicNow` (default 2 FPS = 0.5s).
    public func shouldSampleFrame(
        cameraID: UUID,
        monotonicNow: TimeInterval,
        sampleInterval: TimeInterval = 0.5
    ) -> Bool {
        guard monotonicNow.isFinite else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let last = lastSampledUptimeByCamera[cameraID], monotonicNow - last < sampleInterval {
            return false
        }
        lastSampledUptimeByCamera[cameraID] = monotonicNow
        return true
    }

    /// Appends a JPEG frame into the pre-event ring buffer and feeds any active post-event capture for `cameraID`.
    public func recordSampledFrame(
        cameraID: UUID,
        jpegData: Data,
        capturedAt: Date = Date()
    ) {
        guard !jpegData.isEmpty, jpegData.count <= AlertLookbackBuffer.maximumFrameBytes else { return }
        lock.lock()
        let serial = frameSerialCounter
        frameSerialCounter &+= 1
        _ = preEventBuffer.append(
            AlertLookbackFrame(serial: serial, capturedAt: capturedAt, jpegData: jpegData),
            cameraID: cameraID,
            now: capturedAt
        )

        // Check active post-event captures for this camera
        var completedIncidentIDs: [UUID] = []
        for (incidentID, var capture) in pendingPostCaptures where capture.cameraID == cameraID {
            let elapsed = capturedAt.timeIntervalSince(capture.startedAt)
            if elapsed > capture.durationSeconds || capture.capturedCount >= capture.maxPostFrames {
                completedIncidentIDs.append(incidentID)
                continue
            }
            if capturedAt.timeIntervalSince(capture.lastCapturedAt) >= 0.45 {
                do {
                    try writePostEventFrameUnlocked(incidentID: incidentID, postIndex: capture.capturedCount + 1, jpegData: jpegData)
                    capture.capturedCount += 1
                    capture.lastCapturedAt = capturedAt
                    pendingPostCaptures[incidentID] = capture
                } catch {
                    persistenceError = "Cannot save incident evidence: \(error.localizedDescription)"
                }
                if capture.capturedCount >= capture.maxPostFrames {
                    completedIncidentIDs.append(incidentID)
                }
            }
        }
        for id in completedIncidentIDs {
            pendingPostCaptures.removeValue(forKey: id)
        }
        lock.unlock()
    }

    /// Creates an evidence bundle on disk for `candidate` with snapshot, pre-event frames, and manifest,
    /// and schedules post-event frame collection.
    @discardableResult
    public func createEvidenceBundle(
        for candidate: BehaviorSafetyCandidate,
        incidentID: UUID? = nil,
        cameraName: String,
        triggerSnapshotJPEG: Data?,
        postEventBufferSeconds: Double = 6.0,
        maxDiskQuotaMB: Int = 2048,
        now: Date = Date()
    ) throws -> (bundleID: UUID, snapshotRelativePath: String?) {
        lock.lock()
        defer { lock.unlock() }

        do {
        try ensureDirectoryUnlocked(baseDirectoryURL)
        let bundleID = incidentID ?? candidate.id
        let destination = bundleDirectoryURL(for: bundleID)
        if FileManager.default.fileExists(atPath: destination.path) {
            let manifest = try readManifestUnlocked(in: destination)
            guard manifest.incidentID == bundleID, manifest.cameraID == candidate.cameraID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let snapshot = destination.appendingPathComponent("snapshot.jpg")
            return (bundleID, FileManager.default.fileExists(atPath: snapshot.path)
                ? "\(bundleID.uuidString.lowercased())/snapshot.jpg" : nil)
        }
        // Publish a complete bundle in one rename, never a half-written visible directory.
        let bundleDir = baseDirectoryURL.appendingPathComponent(".\(UUID().uuidString).pending", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try FileManager.default.createDirectory(
            at: bundleDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundleDir.path)

        var preFrames = preEventBuffer.snapshot(cameraID: candidate.cameraID, now: now)
        if let triggerSnapshotJPEG, !triggerSnapshotJPEG.isEmpty {
            let serial = frameSerialCounter
            frameSerialCounter &+= 1
            preFrames.append(AlertLookbackFrame(serial: serial, capturedAt: now, jpegData: triggerSnapshotJPEG))
        }

        var totalBytes = 0
        var snapshotRelPath: String?
        let primarySnapshotData = triggerSnapshotJPEG ?? preFrames.last?.jpegData
        if let primarySnapshotData, !primarySnapshotData.isEmpty {
            let snapshotFile = bundleDir.appendingPathComponent("snapshot.jpg")
            try primarySnapshotData.write(to: snapshotFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotFile.path)
            totalBytes += primarySnapshotData.count
            snapshotRelPath = "\(bundleID.uuidString.lowercased())/snapshot.jpg"
        }

        for (idx, frame) in preFrames.enumerated() {
            let frameFile = bundleDir.appendingPathComponent(String(format: "pre-%02d.jpg", idx + 1))
            try frame.jpegData.write(to: frameFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: frameFile.path)
            totalBytes += frame.jpegData.count
        }

        let manifest = SafetyEvidenceBundleManifest(
            incidentID: bundleID,
            cameraID: candidate.cameraID,
            cameraName: cameraName,
            incidentType: candidate.type,
            severity: candidate.severity,
            createdAt: now,
            preEventFrameCount: preFrames.count,
            postEventFrameCount: 0,
            totalBytes: totalBytes,
            primaryBox: candidate.primaryBox,
            keypoints: candidate.keypoints,
            trackIDs: candidate.trackIDs,
            metrics: candidate.metrics,
            explanation: candidate.explanation
        )
        try writeManifestUnlocked(manifest, in: bundleDir)
        try FileManager.default.moveItem(at: bundleDir, to: destination)

        if postEventBufferSeconds > 0 {
            let maxPost = max(1, min(30, Int((postEventBufferSeconds * 2.0).rounded())))
            pendingPostCaptures[bundleID] = PendingPostEventCapture(
                incidentID: bundleID,
                cameraID: candidate.cameraID,
                startedAt: now,
                durationSeconds: postEventBufferSeconds,
                lastCapturedAt: now,
                capturedCount: 0,
                maxPostFrames: maxPost
            )
        }

        enforceQuotaUnlocked(maxBytes: Int64(max(64, maxDiskQuotaMB)) * 1024 * 1024, protecting: bundleID)
        return (bundleID, snapshotRelPath)
        } catch {
            persistenceError = "Cannot save incident evidence: \(error.localizedDescription)"
            throw error
        }
    }

    public func loadSnapshot(for incidentID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let file = bundleDirectoryURL(for: incidentID).appendingPathComponent("snapshot.jpg")
        return try? Data(contentsOf: file)
    }

    public func loadClipFrames(for incidentID: UUID) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let dir = bundleDirectoryURL(for: incidentID)
        guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let preFiles = children
            .filter { $0.lastPathComponent.hasPrefix("pre-") && $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let postFiles = children
            .filter { $0.lastPathComponent.hasPrefix("post-") && $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (preFiles + postFiles).compactMap { try? Data(contentsOf: $0) }
    }

    public func loadManifest(for incidentID: UUID) -> SafetyEvidenceBundleManifest? {
        lock.lock()
        defer { lock.unlock() }
        let file = bundleDirectoryURL(for: incidentID).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SafetyEvidenceBundleManifest.self, from: data)
    }

    public func hasEvidenceBundle(for incidentID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: bundleDirectoryURL(for: incidentID).path)
    }

    public func deleteEvidence(for incidentID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let dir = bundleDirectoryURL(for: incidentID)
        do {
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            pendingPostCaptures.removeValue(forKey: incidentID)
        } catch {
            persistenceError = "Cannot delete incident evidence: \(error.localizedDescription)"
            throw error
        }
    }

    public func currentDiskUsageBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return directorySizeUnlocked(baseDirectoryURL)
    }

    private func bundleDirectoryURL(for incidentID: UUID) -> URL {
        baseDirectoryURL.appendingPathComponent(incidentID.uuidString.lowercased(), isDirectory: true)
    }

    private func ensureDirectoryUnlocked(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writePostEventFrameUnlocked(incidentID: UUID, postIndex: Int, jpegData: Data) throws {
        let dir = bundleDirectoryURL(for: incidentID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let file = dir.appendingPathComponent(String(format: "post-%02d.jpg", postIndex))
        try jpegData.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        var manifest = try readManifestUnlocked(in: dir)
        manifest.postEventFrameCount = max(manifest.postEventFrameCount, postIndex)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        manifest.totalBytes = try files.filter { $0.pathExtension == "jpg" }.reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        try writeManifestUnlocked(manifest, in: dir)
    }

    private func readManifestUnlocked(in dir: URL) throws -> SafetyEvidenceBundleManifest {
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SafetyEvidenceBundleManifest.self, from: data)
    }

    private func writeManifestUnlocked(_ manifest: SafetyEvidenceBundleManifest, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let url = dir.appendingPathComponent("manifest.json")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func enforceQuotaUnlocked(maxBytes: Int64, protecting protectedID: UUID) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var bundles: [(url: URL, createdAt: Date, size: Int64)] = []
        var total: Int64 = 0
        for dir in children where dir.hasDirectoryPath {
            let size = directorySizeUnlocked(dir)
            total += size
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            bundles.append((dir, created, size))
        }
        guard total > maxBytes else { return }
        let protectedName = protectedID.uuidString.lowercased()
        for bundle in bundles.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard total > maxBytes else { break }
            if bundle.url.lastPathComponent == protectedName { continue }
            do {
                try FileManager.default.removeItem(at: bundle.url)
                if let id = UUID(uuidString: bundle.url.lastPathComponent) { pendingPostCaptures.removeValue(forKey: id) }
                total -= bundle.size
            } catch {
                persistenceError = "Cannot delete incident evidence: \(error.localizedDescription)"
            }
        }
    }

    private func directorySizeUnlocked(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
