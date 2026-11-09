import Foundation

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

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "Memory frames must contain image data and a safe file name."
        case .imageTooLarge: "A memory frame exceeds the per-image storage limit."
        case .unsupportedIndex: "The local memory index is invalid or too large."
        case .storageFailure: "The local memory frame could not be stored securely."
        }
    }
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
    private let lock = NSLock()

    public init(url: URL = CameraMemoryStore.defaultURL) {
        directoryURL = url
        indexURL = url.appendingPathComponent("index.json")
    }

    @discardableResult
    public func save(_ imageData: Data, cameraID: UUID, cameraName: String,
                     capturedAt: Date, summary: String, now: Date = Date()) throws -> CameraMemoryFrame {
        guard !imageData.isEmpty else { throw CameraMemoryStoreError.invalidImage }
        guard imageData.count <= Self.maximumFrameBytes else { throw CameraMemoryStoreError.imageTooLarge }
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectory()
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
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        try ensureDirectory()
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
        lock.lock()
        defer { lock.unlock() }
        guard URL(fileURLWithPath: frame.fileName).lastPathComponent == frame.fileName,
              frame.fileName.hasSuffix(".jpg"), frame.fileSize <= Self.maximumFrameBytes else {
            throw CameraMemoryStoreError.invalidImage
        }
        return try Data(contentsOf: directoryURL.appendingPathComponent(frame.fileName))
    }

    public func delete(_ frameID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = try readIndex()
        guard let removed = existing.first(where: { $0.id == frameID }) else { return }
        let retained = existing.filter { $0.id != frameID }
        try writeIndex(retained)
        removeImage(named: removed.fileName)
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
        guard frames.count <= Self.maximumFrames,
              Set(frames.map(\.id)).count == frames.count,
              Set(frames.map(\.fileName)).count == frames.count,
              frames.allSatisfy({
                  URL(fileURLWithPath: $0.fileName).lastPathComponent == $0.fileName
                    && $0.fileName.hasSuffix(".jpg")
                    && (0...Self.maximumFrameBytes).contains($0.fileSize)
              }),
              frames.reduce(0, { $0 + $1.fileSize }) <= Self.maximumStorageBytes else {
            throw CameraMemoryStoreError.unsupportedIndex
        }
        return frames
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