import Foundation

public struct AlertLookbackFrame: Equatable, Sendable {
    public let serial: UInt64
    public let capturedAt: Date
    public let jpegData: Data

    public init(serial: UInt64, capturedAt: Date, jpegData: Data) {
        self.serial = serial
        self.capturedAt = capturedAt
        self.jpegData = jpegData
    }
}

public struct CriticalAlertClip: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let frameCount: Int
    public let byteCount: Int
    public let frameRate: Double
}

public enum CriticalAlertClipError: LocalizedError {
    case invalidFrames
    case storageFull
    case invalidClip

    public var errorDescription: String? {
        switch self {
        case .invalidFrames: "The alert lookback sequence is empty, oversized or out of order."
        case .storageFull: "Local alert clip storage is full; existing clips were preserved."
        case .invalidClip: "The local alert clip is invalid or expired."
        }
    }
}

public struct AlertLookbackBuffer: Sendable {
    public static let lookbackSeconds: TimeInterval = 8
    public static let sampleInterval: TimeInterval = 0.5
    public static let framesPerCamera = 16
    public static let maximumTotalFrames = 256
    public static let maximumFrameBytes = 512 * 1024
    public static let maximumTotalBytes = 128 * 1024 * 1024

    private var framesByCamera: [UUID: [AlertLookbackFrame]] = [:]

    public init() {}

    public var frameCount: Int { framesByCamera.values.reduce(0) { $0 + $1.count } }
    public var byteCount: Int { framesByCamera.values.flatMap { $0 }.reduce(0) { $0 + $1.jpegData.count } }

    @discardableResult
    public mutating func append(_ frame: AlertLookbackFrame, cameraID: UUID, now: Date) -> Bool {
        guard now.timeIntervalSince1970.isFinite, frame.capturedAt.timeIntervalSince1970.isFinite,
              frame.capturedAt <= now, now.timeIntervalSince(frame.capturedAt) <= Self.lookbackSeconds,
              !frame.jpegData.isEmpty, frame.jpegData.count <= Self.maximumFrameBytes else { return false }
        prune(now: now)
        var frames = framesByCamera[cameraID, default: []]
        if let latest = frames.last {
            guard frame.serial != latest.serial,
                  frame.capturedAt.timeIntervalSince(latest.capturedAt) >= Self.sampleInterval,
                  frame.capturedAt >= latest.capturedAt else { return false }
        }
        frames.append(frame)
        if frames.count > Self.framesPerCamera { frames.removeFirst(frames.count - Self.framesPerCamera) }
        framesByCamera[cameraID] = frames
        evictOldestUntilBounded()
        return framesByCamera[cameraID]?.contains(where: { $0.serial == frame.serial }) == true
    }

    public mutating func snapshot(cameraID: UUID, now: Date) -> [AlertLookbackFrame] {
        prune(now: now)
        return framesByCamera[cameraID] ?? []
    }

    public mutating func removeAll(cameraID: UUID? = nil) {
        if let cameraID { framesByCamera.removeValue(forKey: cameraID) }
        else { framesByCamera.removeAll(keepingCapacity: false) }
    }

    public mutating func prune(now: Date) {
        guard now.timeIntervalSince1970.isFinite else { return }
        for cameraID in Array(framesByCamera.keys) {
            framesByCamera[cameraID]?.removeAll {
                $0.capturedAt > now || now.timeIntervalSince($0.capturedAt) > Self.lookbackSeconds
            }
            if framesByCamera[cameraID]?.isEmpty == true { framesByCamera.removeValue(forKey: cameraID) }
        }
        evictOldestUntilBounded()
    }

    private mutating func evictOldestUntilBounded() {
        while frameCount > Self.maximumTotalFrames || byteCount > Self.maximumTotalBytes {
            let oldest = framesByCamera.compactMap { cameraID, frames in
                frames.first.map { (cameraID, $0.capturedAt, $0.serial) }
            }.min {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.0 != $1.0 { return $0.0.uuidString < $1.0.uuidString }
                return $0.2 < $1.2
            }
            guard let oldest, var frames = framesByCamera[oldest.0], !frames.isEmpty else { return }
            frames.removeFirst()
            if frames.isEmpty { framesByCamera.removeValue(forKey: oldest.0) }
            else { framesByCamera[oldest.0] = frames }
        }
    }
}

public enum AlertLookbackSamplingPolicy {
    public static let sampleInterval: TimeInterval = 0.5
    public static let maximumConcurrentEncodes = 4

    public static func shouldSample(
        operationsEnabled: Bool, retainFullFrames: Bool, scheduledAnalysisEnabled: Bool, hasEnabledRules: Bool,
        wallRunning: Bool, connecting: Bool, cameraEnabled: Bool, cameraInScope: Bool,
        frameFresh: Bool, frameAvailable: Bool, inFlightCount: Int,
        lastSubmittedAt: TimeInterval?, now: TimeInterval
    ) -> Bool {
        guard operationsEnabled, retainFullFrames, scheduledAnalysisEnabled, hasEnabledRules, wallRunning, !connecting,
              cameraEnabled, cameraInScope, frameFresh, frameAvailable,
              inFlightCount < maximumConcurrentEncodes, now.isFinite, now >= 0 else { return false }
        guard let lastSubmittedAt else { return true }
        return lastSubmittedAt.isFinite && lastSubmittedAt >= 0 && now >= lastSubmittedAt
            && now - lastSubmittedAt >= sampleInterval
    }
}

public final class CriticalAlertClipStore: @unchecked Sendable {
    public static let retentionDays = 7
    public static let maximumClips = 100
    public static let maximumFramesPerClip = AlertLookbackBuffer.framesPerCamera
    public static let maximumClipBytes = 8 * 1024 * 1024
    public static let maximumStorageBytes = 128 * 1024 * 1024
    private static let maximumIndexBytes = 256 * 1024

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/alert-clips", isDirectory: true)
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let lock = NSLock()

    public init(url: URL = CriticalAlertClipStore.defaultURL) {
        directoryURL = url
        indexURL = url.appendingPathComponent("index.json")
    }

    @discardableResult
    public func save(
        alertID: UUID, cameraID: UUID, frames: [AlertLookbackFrame], frameRate: Double = 2,
        now: Date = Date()
    ) throws -> CriticalAlertClip {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count >= 2, frames.count <= Self.maximumFramesPerClip,
              frameRate.isFinite, (1...8).contains(frameRate), now.timeIntervalSince1970.isFinite,
              frames.allSatisfy({ !$0.jpegData.isEmpty && $0.jpegData.count <= AlertLookbackBuffer.maximumFrameBytes }),
              Set(frames.map(\.serial)).count == frames.count,
              zip(frames, frames.dropFirst()).allSatisfy({ pair in pair.0.capturedAt <= pair.1.capturedAt }),
              frames.allSatisfy({
                  $0.capturedAt <= now && now.timeIntervalSince($0.capturedAt) <= AlertLookbackBuffer.lookbackSeconds
              }) else {
            throw CriticalAlertClipError.invalidFrames
        }
        let totalBytes = frames.reduce(0) { $0 + $1.jpegData.count }
        guard totalBytes <= Self.maximumClipBytes else { throw CriticalAlertClipError.invalidFrames }
        try ensureDirectory()
        let existing = try readIndex()
        let retained = existing.filter { Self.isRetained($0, now: now) }
        removeClipDirectories(for: existing.filter { !Self.isRetained($0, now: now) })
        let retainedBytes = retained.reduce(0) { $0 + $1.byteCount }
        guard !retained.contains(where: { $0.id == alertID }),
              retained.count < Self.maximumClips,
              retainedBytes + totalBytes <= Self.maximumStorageBytes else { throw CriticalAlertClipError.storageFull }
        let clip = CriticalAlertClip(
            id: alertID, cameraID: cameraID, createdAt: now,
            expiresAt: now.addingTimeInterval(Double(Self.retentionDays) * 86_400),
            frameCount: frames.count, byteCount: totalBytes, frameRate: frameRate
        )
        let clipDirectory = directoryURL.appendingPathComponent(alertID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: clipDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            for (index, frame) in frames.enumerated() {
                let file = clipDirectory.appendingPathComponent(String(format: "frame-%02d.jpg", index + 1))
                try frame.jpegData.write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try writeIndex(retained + [clip])
        } catch {
            try? FileManager.default.removeItem(at: clipDirectory)
            throw error
        }
        return clip
    }

    public func clips(now: Date = Date()) throws -> [CriticalAlertClip] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        try ensureDirectory()
        let existing = try readIndex()
        let retained = existing.filter { Self.isRetained($0, now: now) && clipExistsAndMatches($0) }
        if retained != existing {
            try writeIndex(retained)
            let retainedIDs = Set(retained.map { $0.id.uuidString.lowercased() })
            for item in existing where !retainedIDs.contains(item.id.uuidString.lowercased()) {
                try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(item.id.uuidString.lowercased(), isDirectory: true))
            }
        }
        pruneOrphanDirectories(retaining: Set(retained.map { $0.id.uuidString.lowercased() }))
        return retained.sorted { $0.createdAt > $1.createdAt }
    }

    public func frames(for alertID: UUID, now: Date = Date()) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard let clip = try readIndex().first(where: { $0.id == alertID }), Self.isRetained(clip, now: now),
              clipExistsAndMatches(clip) else { throw CriticalAlertClipError.invalidClip }
        let folder = directoryURL.appendingPathComponent(alertID.uuidString.lowercased(), isDirectory: true)
        return try (1...clip.frameCount).map { index in
            let file = folder.appendingPathComponent(String(format: "frame-%02d.jpg", index))
            let data = try Data(contentsOf: file)
            guard data.count <= AlertLookbackBuffer.maximumFrameBytes else { throw CriticalAlertClipError.invalidClip }
            return data
        }
    }

    public func delete(_ alertID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = try readIndex()
        try writeIndex(existing.filter { $0.id != alertID })
        let clipURL = directoryURL.appendingPathComponent(alertID.uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.removeItem(at: clipURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Deleting an already-absent clip is idempotent.
        }
    }

    @discardableResult
    public func pruneExpired(now: Date = Date()) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let existing = try readIndex()
        let retained = existing.filter { Self.isRetained($0, now: now) && clipExistsAndMatches($0) }
        try writeIndex(retained)
        let expired = existing.filter { !retained.contains($0) }
        removeClipDirectories(for: expired)
        pruneOrphanDirectories(retaining: Set(retained.map { $0.id.uuidString.lowercased() }))
        return expired.count
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func readIndex() throws -> [CriticalAlertClip] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumIndexBytes else {
            throw CriticalAlertClipError.invalidClip
        }
        let clips = try JSONDecoder().decode([CriticalAlertClip].self, from: Data(contentsOf: indexURL))
        guard clips.count <= Self.maximumClips, Set(clips.map(\.id)).count == clips.count,
              clips.allSatisfy({
                  (2...Self.maximumFramesPerClip).contains($0.frameCount)
                      && (0...Self.maximumClipBytes).contains($0.byteCount)
                      && $0.createdAt.timeIntervalSince1970.isFinite && $0.expiresAt > $0.createdAt
                      && $0.frameRate.isFinite && (1...8).contains($0.frameRate)
              }), clips.reduce(0, { $0 + $1.byteCount }) <= Self.maximumStorageBytes else {
            throw CriticalAlertClipError.invalidClip
        }
        return clips
    }

    private func writeIndex(_ clips: [CriticalAlertClip]) throws {
        let data = try JSONEncoder().encode(clips)
        guard data.count <= Self.maximumIndexBytes else { throw CriticalAlertClipError.invalidClip }
        try data.write(to: indexURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func clipExistsAndMatches(_ clip: CriticalAlertClip) -> Bool {
        let folder = directoryURL.appendingPathComponent(clip.id.uuidString.lowercased(), isDirectory: true)
        var total = 0
        for index in 1...clip.frameCount {
            let file = folder.appendingPathComponent(String(format: "frame-%02d.jpg", index))
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= AlertLookbackBuffer.maximumFrameBytes else { return false }
            total += size
        }
        return total == clip.byteCount
    }

    private func pruneOrphanDirectories(retaining names: Set<String>) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directoryURL,
                                                                          includingPropertiesForKeys: nil) else { return }
        for child in children where child.hasDirectoryPath && !names.contains(child.lastPathComponent) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func removeClipDirectories(for clips: [CriticalAlertClip]) {
        for clip in clips {
            try? FileManager.default.removeItem(
                at: directoryURL.appendingPathComponent(clip.id.uuidString.lowercased(), isDirectory: true)
            )
        }
    }

    private static func isRetained(_ clip: CriticalAlertClip, now: Date) -> Bool {
        clip.createdAt <= now && clip.expiresAt > now
            && now.timeIntervalSince(clip.createdAt) <= Double(retentionDays) * 86_400
    }
}