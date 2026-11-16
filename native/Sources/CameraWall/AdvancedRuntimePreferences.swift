import Foundation
import CameraCore

struct AdvancedRuntimePreferences: Codable, Equatable, Sendable {
    var fall = FallDetectorConfiguration()
    var storage = ACTAStorageJanitorPolicy()
    var capture = ACTACaptureScheduler.Config()
    var cropWindowSeconds = 15.0
    var cropTopK = 4
    var cropImprovementRatio = 1.03
    func validate() throws {
        guard fall.isValid, fall.crouchingHeightThreshold.isFinite,
              fall.crouchingHeightThreshold > 0, fall.crouchingHeightThreshold < fall.sittingHeightThreshold,
              fall.controlledSitBeforeLieSeconds.isFinite, fall.controlledSitBeforeLieSeconds >= 0,
              fall.controlledLieDownMaxDropSpeedBodyHeightsPerSecond.isFinite, fall.controlledLieDownMaxDropSpeedBodyHeightsPerSecond > 0,
              fall.maximumTracks <= 4096, storage.maxMediaDiskMB.isFinite, storage.maxMediaDiskMB >= 64,
              storage.minFreeDiskGB.isFinite, storage.minFreeDiskGB >= 0,
              (1...1000).contains(storage.maxCropsPerIdentity),
              (1...365).contains(storage.trackImageRetentionDays), (1...365).contains(storage.logRetentionDays),
              capture.bootstrapSeconds.isFinite, capture.bootstrapSeconds >= 0,
              capture.intervalSeconds.isFinite, capture.intervalSeconds > 0,
              capture.movementFraction.isFinite, (0...1).contains(capture.movementFraction),
              capture.inheritMaxAge.isFinite, capture.inheritMaxAge >= 0,
              capture.inheritMinIoU.isFinite, (0...1).contains(capture.inheritMinIoU),
              capture.staleTrackTTL.isFinite, capture.staleTrackTTL > 0,
              cropWindowSeconds.isFinite, cropWindowSeconds > 0, (1...64).contains(cropTopK),
              cropImprovementRatio.isFinite, cropImprovementRatio >= 1 else {
            throw ConfigurationError.invalid("Check advanced runtime thresholds and storage limits.")
        }
    }
    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)); try value.validate(); return value
    }
    func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
