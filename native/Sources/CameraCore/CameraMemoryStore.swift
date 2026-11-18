import Foundation
import Darwin

public struct CameraMemoryFrame: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: UUID
    public let cameraName: String
    public let capturedAt: Date
    public let summary: String
    public let fileName: String
    public let fileSize: Int

    public init(id: UUID = UUID(), cameraID: UUID, cameraName: String, capturedAt: Date,
                summary: String, fileName: String, fileSize: Int) {
        self.id = id
        self.cameraID = cameraID
        self.cameraName = String(cameraName.prefix(200))
        self.capturedAt = capturedAt
        self.summary = String(summary.prefix(500))
        self.fileName = fileName
        self.fileSize = fileSize
    }
}

public enum CameraMemoryStoreError: LocalizedError {
    case invalidImage
    case imageTooLarge
    case unsupportedIndex
    case storageFailure
    case snapshotChanged
    case recoveryRequired
    case recoveryConflict

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "Memory frames must contain image data and a safe file name."
        case .imageTooLarge: "A memory frame exceeds the per-image storage limit."
        case .unsupportedIndex: "The local memory index is invalid or too large."
        case .storageFailure: "The local memory frame could not be stored securely."
        case .snapshotChanged: "Memory frames changed since confirmation; review them again."
        case .recoveryRequired: "Memory deletion is incomplete. Retry recovery before modifying memory."
        case .recoveryConflict: "Memory deletion recovery conflicts with the current index; no further frames were removed."
        }
    }
}

public struct CameraMemoryDeletionSnapshot: Sendable {
    public let frames: [CameraMemoryFrame]
    public var count: Int { frames.count }
}

private struct CameraMemoryDeletionJournal: Codable {
    let frames: [CameraMemoryFrame]
}

public enum CameraMemorySamplingPolicy {
    public static func shouldSample(featureEnabled: Bool, retainFullFrames: Bool,
                                    wallRunning: Bool, connecting: Bool,
                                    frameFresh: Bool, sampleInProgress: Bool,
                                    lastSampleAt: TimeInterval?, now: TimeInterval) -> Bool {
        featureEnabled && retainFullFrames && wallRunning && !connecting && frameFresh
            && !sampleInProgress && CameraMemoryStore.isSampleDue(lastSampleAt: lastSampleAt, now: now)
    }
}

public final class CameraMemoryStore: @unchecked Sendable {
    public static let retentionDays = 7
    public static let minimumSampleInterval: TimeInterval = 15 * 60
    public static let maximumFrames = 256
    public static let maximumFrameBytes = 512 * 1024
    public static let maximumStorageBytes = 128 * 1024 * 1024
    private static let maximumIndexBytes = 2 * 1024 * 1024

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/memory-frames", isDirectory: true)
    }

    public static func isSampleDue(lastSampleAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0 else { return false }
        guard let lastSampleAt else { return true }
        return lastSampleAt.isFinite && lastSampleAt >= 0 && now >= lastSampleAt
            && now - lastSampleAt >= minimumSampleInterval
    }

    public static func summary(for detections: [DetectedObject]) -> String {
        guard !detections.isEmpty else { return "No tracked objects at sample time." }
        let counts = Dictionary(grouping: detections, by: \.label).mapValues(\.count)
        let details = counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", ")
        return "Visible detection counts: \(details)."
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let journalURL: URL
    private let lock = NSLock()
    private let deletionFault: (@Sendable (Int) throws -> Void)?

    public init(url: URL = CameraMemoryStore.defaultURL) {
        directoryURL = url
        indexURL = url.appendingPathComponent("index.json")
        journalURL = url.appendingPathComponent(".deletion-journal.json")
        deletionFault = nil
    }

    init(url: URL, deletionFault: @escaping @Sendable (Int) throws -> Void) {
        directoryURL = url
        indexURL = url.appendingPathComponent("index.json")
        journalURL = url.appendingPathComponent(".deletion-journal.json")
        self.deletionFault = deletionFault
    }

    @discardableResult
    public func save(_ imageData: Data, cameraID: UUID, cameraName: String,
                     capturedAt: Date, summary: String, now: Date = Date()) throws -> CameraMemoryFrame {
        guard !imageData.isEmpty else { throw CameraMemoryStoreError.invalidImage }
        guard imageData.count <= Self.maximumFrameBytes else { throw CameraMemoryStoreError.imageTooLarge }
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        try requireNoPendingDeletion()
        let existing = try readIndex()
        var retained = existing.filter { Self.isRetained($0, now: now) }
        let id = UUID()
        let fileName = "\(id.uuidString.lowercased()).jpg"
        let frame = CameraMemoryFrame(
            id: id, cameraID: cameraID, cameraName: cameraName, capturedAt: capturedAt,
            summary: summary, fileName: fileName, fileSize: imageData.count
        )
        guard Self.isRetained(frame, now: now) else { throw CameraMemoryStoreError.invalidImage }
        retained.append(frame)
        retained.sort { $0.capturedAt > $1.capturedAt }
        var totalBytes = retained.reduce(0) { $0 + $1.fileSize }
        while retained.count > Self.maximumFrames || totalBytes > Self.maximumStorageBytes {
            guard let removed = retained.popLast() else { break }
            totalBytes -= removed.fileSize
        }
        guard retained.contains(where: { $0.id == frame.id }) else {
            throw CameraMemoryStoreError.imageTooLarge
        }

        let imageURL = directoryURL.appendingPathComponent(fileName)
        do {
            try imageData.write(to: imageURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
            try writeIndex(retained)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw CameraMemoryStoreError.storageFailure
        }
        let retainedNames = Set(retained.map(\.fileName))
        for oldFrame in existing where !retainedNames.contains(oldFrame.fileName) {
            removeImage(named: oldFrame.fileName)
        }
        pruneOrphanImages(retaining: retainedNames)
        return frame
    }

    public func load(now: Date = Date()) throws -> [CameraMemoryFrame] {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        try requireNoPendingDeletion()
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let existing = try readIndex()
        let retained = existing.filter {
            Self.isRetained($0, now: now)
                && FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0.fileName).path)
        }
        if retained != existing {
            try writeIndex(retained)
            let retainedNames = Set(retained.map(\.fileName))
            for oldFrame in existing where !retainedNames.contains(oldFrame.fileName) {
                removeImage(named: oldFrame.fileName)
            }
        }
        pruneOrphanImages(retaining: Set(retained.map(\.fileName)))
        return retained.sorted { $0.capturedAt > $1.capturedAt }
    }

    public func imageData(for frame: CameraMemoryFrame) throws -> Data {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        guard URL(fileURLWithPath: frame.fileName).lastPathComponent == frame.fileName,
              frame.fileName.hasSuffix(".jpg"), frame.fileSize <= Self.maximumFrameBytes else {
            throw CameraMemoryStoreError.invalidImage
        }
        return try Data(contentsOf: directoryURL.appendingPathComponent(frame.fileName))
    }

    /// Checks physical deletion separately from removal of the index entry.
    public func hasStoredImage(for frame: CameraMemoryFrame) throws -> Bool {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        guard URL(fileURLWithPath: frame.fileName).lastPathComponent == frame.fileName,
              frame.fileName.hasSuffix(".jpg") else { throw CameraMemoryStoreError.invalidImage }
        return FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(frame.fileName).path)
    }

    public func delete(_ frameID: UUID) throws {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        try requireNoPendingDeletion()
        let existing = try readIndex()
        guard let removed = existing.first(where: { $0.id == frameID }) else { return }
        try beginDeletion([removed], current: existing)
    }

    /// Captures the exact indexed set, without retention or orphan cleanup.
    public func deletionSnapshot() throws -> CameraMemoryDeletionSnapshot {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        try requireNoPendingDeletion()
        return CameraMemoryDeletionSnapshot(frames: try readIndex())
    }

    public func deleteConfirmedSnapshot(_ snapshot: CameraMemoryDeletionSnapshot) throws {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        try requireNoPendingDeletion()
        let current = try readIndex()
        guard current == snapshot.frames else { throw CameraMemoryStoreError.snapshotChanged }
        guard !current.isEmpty else { return }
        try beginDeletion(current, current: current)
    }

    public func hasPendingDeletion() throws -> Bool {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        return FileManager.default.fileExists(atPath: journalURL.path)
    }

    /// Resumes only the originally authorized deletion; never expands it to newer frames.
    public func recoverPendingDeletion() throws {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumIndexBytes else {
            throw CameraMemoryStoreError.recoveryConflict
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(CameraMemoryDeletionJournal.self, from: Data(contentsOf: journalURL))
        guard validFrames(journal.frames), !journal.frames.isEmpty else {
            throw CameraMemoryStoreError.recoveryConflict
        }
        try finishDeletion(journal.frames, current: readIndex())
    }

    private func beginDeletion(_ frames: [CameraMemoryFrame], current: [CameraMemoryFrame]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(CameraMemoryDeletionJournal(frames: frames))
        guard data.count <= Self.maximumIndexBytes else { throw CameraMemoryStoreError.unsupportedIndex }
        try data.write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        try finishDeletion(frames, current: current)
    }

    private func finishDeletion(_ frames: [CameraMemoryFrame], current: [CameraMemoryFrame]) throws {
        let byID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        let names = Set(frames.map(\.fileName))
        guard current.allSatisfy({ frame in
            if let original = byID[frame.id] { return original == frame }
            return !names.contains(frame.fileName)
        }) else { throw CameraMemoryStoreError.recoveryConflict }
        for (index, frame) in frames.enumerated() {
            let url = directoryURL.appendingPathComponent(frame.fileName)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw CameraMemoryStoreError.recoveryConflict
                }
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                // Already removed before interruption.
            }
            try deletionFault?(index)
        }
        try writeIndex(current.filter { byID[$0.id] == nil })
        try FileManager.default.removeItem(at: journalURL)
    }

    private func requireNoPendingDeletion() throws {
        if FileManager.default.fileExists(atPath: journalURL.path) {
            throw CameraMemoryStoreError.recoveryRequired
        }
    }

    private func acquireLock() throws -> Int32 {
        lock.lock()
        do {
            try ensureDirectory()
            let fd = open(directoryURL.appendingPathComponent(".memory.lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CameraMemoryStoreError.storageFailure }
            guard flock(fd, LOCK_EX) == 0 else {
                close(fd)
                throw CameraMemoryStoreError.storageFailure
            }
            return fd
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func releaseLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
        lock.unlock()
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func readIndex() throws -> [CameraMemoryFrame] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumIndexBytes else {
            throw CameraMemoryStoreError.unsupportedIndex
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let frames = try decoder.decode([CameraMemoryFrame].self, from: Data(contentsOf: indexURL))
        guard validFrames(frames) else {
            throw CameraMemoryStoreError.unsupportedIndex
        }
        return frames
    }

    private func validFrames(_ frames: [CameraMemoryFrame]) -> Bool {
        frames.count <= Self.maximumFrames
              && Set(frames.map(\.id)).count == frames.count
              && Set(frames.map(\.fileName)).count == frames.count
              && frames.allSatisfy({
                  URL(fileURLWithPath: $0.fileName).lastPathComponent == $0.fileName
                    && $0.fileName.hasSuffix(".jpg")
                    && (0...Self.maximumFrameBytes).contains($0.fileSize)
              })
              && frames.reduce(0, { $0 + $1.fileSize }) <= Self.maximumStorageBytes
    }

    private func writeIndex(_ frames: [CameraMemoryFrame]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(frames)
        guard data.count <= Self.maximumIndexBytes else { throw CameraMemoryStoreError.unsupportedIndex }
        try data.write(to: indexURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func removeImage(named fileName: String) {
        guard URL(fileURLWithPath: fileName).lastPathComponent == fileName,
              fileName.hasSuffix(".jpg") else { return }
        try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(fileName))
    }

    private func pruneOrphanImages(retaining fileNames: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where file.pathExtension == "jpg" && !fileNames.contains(file.lastPathComponent) {
            removeImage(named: file.lastPathComponent)
        }
    }

    private static func isRetained(_ frame: CameraMemoryFrame, now: Date) -> Bool {
        let age = now.timeIntervalSince(frame.capturedAt)
        return age >= 0 && age <= Double(retentionDays) * 86_400
    }
}