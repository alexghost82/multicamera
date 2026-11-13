import Foundation

/// Pose-based fall detection (see human-fall-detection-guide.md, sections 2 and 4).
///
/// The detector is a per-camera value type: feed it every pose inference result for one camera
/// in monotonic time order. It keeps lightweight person tracks, runs a debounced state machine per
/// track and emits a single `FallEvent` when a track is confirmed `FALLEN`.
public enum FallPersonState: String, Codable, Sendable, CaseIterable {
    case standing = "STANDING"
    case walking = "WALKING"
    case sitting = "SITTING"
    case falling = "FALLING"
    case fallen = "FALLEN"

    public var isUpright: Bool { self == .standing || self == .walking }
    public var isFallPhase: Bool { self == .falling || self == .fallen }
}

public struct FallKeypoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let confidence: Double

    public init(x: Double, y: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

/// Normalized (0...1) top-left anchored box.
public struct FallBoundingBox: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One person from a COCO-17 pose detector, in normalized frame coordinates.
public struct FallPoseObservation: Equatable, Sendable {
    public static let leftShoulder = 5
    public static let rightShoulder = 6
    public static let leftHip = 11
    public static let rightHip = 12

    public let confidence: Double
    public let box: FallBoundingBox
    public let keypoints: [FallKeypoint]

    public init(confidence: Double, box: FallBoundingBox, keypoints: [FallKeypoint]) {
        self.confidence = confidence
        self.box = box
        self.keypoints = keypoints
    }
}

public struct FallDetectorConfiguration: Equatable, Sendable {
    public var torsoAngleThresholdDegrees = 55.0
    public var aspectRatioThreshold = 1.15
    public var heightCollapseThreshold = 0.55
    public var sittingHeightThreshold = 0.75
    /// T_fall: how long a fall posture must persist before `FALLEN` is confirmed.
    public var fallPersistenceSeconds = 0.8
    /// Streams at or below this rate use `lowFrameRatePersistenceSeconds` instead.
    public var lowFrameRateThreshold = 1.5
    public var lowFrameRatePersistenceSeconds = 2.0
    /// A fall is never confirmed from fewer samples than this.
    public var minimumConfirmingSamples = 2
    /// Below this rate centroid velocity is unreliable, so `WALKING` is never inferred.
    public var velocityFeatureMinimumFPS = 5.0
    public var walkingSpeedBodyHeightsPerSecond = 0.3
    public var emaAlpha = 0.05
    /// The height-collapse rule is ignored until the baseline has this many upright samples.
    public var minimumBaselineSamples = 3
    public var primaryConfidence = 0.4
    /// Secondary floor used only to keep `FALLING`/`FALLEN` tracks attached under occlusion.
    public var lowConfidenceFloor = 0.15
    public var keypointConfidence = 0.3
    public var matchIoUThreshold = 0.2
    public var relinkMaximumGapSeconds = 3.0
    public var relinkMaximumDiagonalRatio = 2.0
    /// Consecutive upright samples needed to leave `FALLEN`.
    public var recoverySamples = 2
    public var frameIntervalSmoothing = 0.2
    public var maximumTracks = 64

    public init() {}

    public var isValid: Bool {
        let positives = [aspectRatioThreshold, fallPersistenceSeconds, lowFrameRateThreshold,
                         lowFrameRatePersistenceSeconds, velocityFeatureMinimumFPS,
                         walkingSpeedBodyHeightsPerSecond, relinkMaximumGapSeconds, relinkMaximumDiagonalRatio]
        let unitIntervals = [emaAlpha, primaryConfidence, lowConfidenceFloor, keypointConfidence,
                             matchIoUThreshold, frameIntervalSmoothing]
        return positives.allSatisfy { $0.isFinite && $0 > 0 }
            && unitIntervals.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1 }
            && torsoAngleThresholdDegrees > 0 && torsoAngleThresholdDegrees < 90
            && heightCollapseThreshold > 0 && heightCollapseThreshold < sittingHeightThreshold
            && sittingHeightThreshold < 1
            && lowConfidenceFloor <= primaryConfidence
            && minimumConfirmingSamples >= 2 && minimumBaselineSamples >= 1
            && recoverySamples >= 1 && maximumTracks >= 1
    }

    /// Persistence window adapted to the observed pose cadence (guide section 4.2).
    public func persistenceSeconds(framesPerSecond: Double?) -> Double {
        guard let framesPerSecond, framesPerSecond <= lowFrameRateThreshold else { return fallPersistenceSeconds }
        return max(fallPersistenceSeconds, lowFrameRatePersistenceSeconds)
    }
}

public struct FallMetrics: Codable, Equatable, Sendable {
    public let torsoAngleDegrees: Double?
    public let aspectRatio: Double
    public let heightRatio: Double?
    public let baselineHeightPixels: Double?
}

public struct FallTrackSnapshot: Equatable, Sendable {
    public let trackID: UUID
    public let state: FallPersonState
    public let confidence: Double
    public let box: FallBoundingBox
    public let metrics: FallMetrics
    public let relinkCount: Int
}

public struct FallEvent: Codable, Equatable, Sendable {
    public static let eventType = "fall.detected"

    public let id: UUID
    public let trackID: UUID
    /// Timestamp in the same monotonic clock that was passed to `FallDetector.update`.
    public let occurredAt: TimeInterval
    public let fallStartedAt: TimeInterval
    public let event: String
    public let confidence: Double
    public let previousState: FallPersonState
    public let currentState: FallPersonState
    public let box: FallBoundingBox
    public let metrics: FallMetrics
    public let framesPerSecond: Double?
    public let persistenceSeconds: Double
    public let relinkCount: Int
}

public struct FallDetectorUpdate: Equatable, Sendable {
    public let tracks: [FallTrackSnapshot]
    public let events: [FallEvent]

    public static let empty = FallDetectorUpdate(tracks: [], events: [])
}

public struct FallDetector: Sendable {
    public let configuration: FallDetectorConfiguration

    private struct Geometry {
        let observation: FallPoseObservation
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
        let torsoAngle: Double?

        var diagonal: Double { (width * width + height * height).squareRoot() }
        var left: Double { centerX - width / 2 }
        var right: Double { centerX + width / 2 }
        var top: Double { centerY - height / 2 }
        var bottom: Double { centerY + height / 2 }
    }

    private struct Track {
        let id: UUID
        var geometry: Geometry
        var lastSeen: TimeInterval
        var state: FallPersonState = .standing
        var baseline: Double?
        var baselineSamples = 0
        var fallStartedAt: TimeInterval?
        var fallSamples = 0
        var stateBeforeFall: FallPersonState = .standing
        var recoveryCount = 0
        var alertDispatched = false
        var relinkCount = 0
    }

    private var tracks: [Track] = []
    private var lastTimestamp: TimeInterval?
    private var frameInterval: Double?

    public init(configuration: FallDetectorConfiguration = FallDetectorConfiguration()) {
        precondition(configuration.isValid, "Invalid fall detector configuration")
        self.configuration = configuration
    }

    /// Smoothed pose cadence for this camera, or nil before the second frame.
    public var framesPerSecond: Double? { frameInterval.map { 1 / $0 } }
    public var trackCount: Int { tracks.count }

    public func state(of trackID: UUID) -> FallPersonState? {
        tracks.first { $0.id == trackID }?.state
    }

    public mutating func reset() {
        tracks.removeAll()
        lastTimestamp = nil
        frameInterval = nil
    }

    public mutating func update(_ observations: [FallPoseObservation], frameWidth: Int, frameHeight: Int,
                                timestamp: TimeInterval) -> FallDetectorUpdate {
        guard frameWidth > 0, frameHeight > 0, timestamp.isFinite else { return .empty }
        if let lastTimestamp {
            guard timestamp > lastTimestamp else { return .empty }
            let delta = min(timestamp - lastTimestamp, configuration.relinkMaximumGapSeconds)
            let smoothing = configuration.frameIntervalSmoothing
            frameInterval = frameInterval.map { smoothing * delta + (1 - smoothing) * $0 } ?? delta
        }
        lastTimestamp = timestamp
        tracks.removeAll { timestamp - $0.lastSeen > configuration.relinkMaximumGapSeconds }

        let detections = observations.compactMap {
            geometry(for: $0, frameWidth: Double(frameWidth), frameHeight: Double(frameHeight))
        }
        let high = detections.indices.filter { detections[$0].observation.confidence >= configuration.primaryConfidence }
        let low = detections.indices.filter { detections[$0].observation.confidence < configuration.primaryConfidence }

        var unmatchedTracks = Set(tracks.indices)
        var unmatchedHigh = Set(high)
        var unmatchedLow = Set(low)
        var assignments: [(track: Int, detection: Int, relinked: Bool)] = []

        func matchByIoU(_ detectionIndices: inout Set<Int>, trackFilter: (Track) -> Bool) {
            var candidates: [(score: Double, track: Int, detection: Int)] = []
            for trackIndex in unmatchedTracks where trackFilter(tracks[trackIndex]) {
                for detectionIndex in detectionIndices {
                    let score = Self.intersectionOverUnion(tracks[trackIndex].geometry, detections[detectionIndex])
                    if score >= configuration.matchIoUThreshold { candidates.append((score, trackIndex, detectionIndex)) }
                }
            }
            for candidate in candidates.sorted(by: { $0.score > $1.score })
            where unmatchedTracks.contains(candidate.track) && detectionIndices.contains(candidate.detection) {
                unmatchedTracks.remove(candidate.track)
                detectionIndices.remove(candidate.detection)
                assignments.append((candidate.track, candidate.detection, false))
            }
        }

        // Proximity re-linking (guide 4.3): a fall changes the box shape so much that IoU fails.
        func relinkByProximity(_ detectionIndices: inout Set<Int>, trackFilter: (Track) -> Bool) {
            var candidates: [(ratio: Double, track: Int, detection: Int)] = []
            for trackIndex in unmatchedTracks where trackFilter(tracks[trackIndex]) {
                let track = tracks[trackIndex]
                guard timestamp - track.lastSeen <= configuration.relinkMaximumGapSeconds,
                      track.geometry.diagonal > 0 else { continue }
                for detectionIndex in detectionIndices {
                    let detection = detections[detectionIndex]
                    let distance = hypot(detection.centerX - track.geometry.centerX,
                                         detection.centerY - track.geometry.centerY)
                    let ratio = distance / track.geometry.diagonal
                    if ratio <= configuration.relinkMaximumDiagonalRatio {
                        candidates.append((ratio, trackIndex, detectionIndex))
                    }
                }
            }
            for candidate in candidates.sorted(by: { $0.ratio < $1.ratio })
            where unmatchedTracks.contains(candidate.track) && detectionIndices.contains(candidate.detection) {
                unmatchedTracks.remove(candidate.track)
                detectionIndices.remove(candidate.detection)
                assignments.append((candidate.track, candidate.detection, true))
            }
        }

        matchByIoU(&unmatchedHigh) { _ in true }
        matchByIoU(&unmatchedLow) { $0.state.isFallPhase }
        relinkByProximity(&unmatchedHigh) { _ in true }
        relinkByProximity(&unmatchedLow) { $0.state.isFallPhase }

        var snapshots: [FallTrackSnapshot] = []
        var events: [FallEvent] = []
        let fps = framesPerSecond
        for assignment in assignments {
            if assignment.relinked { tracks[assignment.track].relinkCount += 1 }
            let result = Self.step(&tracks[assignment.track], detection: detections[assignment.detection],
                                   at: timestamp, configuration: configuration, framesPerSecond: fps)
            snapshots.append(result.snapshot)
            if let event = result.event { events.append(event) }
        }
        for detectionIndex in high.filter(unmatchedHigh.contains) where tracks.count < configuration.maximumTracks {
            var track = Track(id: UUID(), geometry: detections[detectionIndex], lastSeen: timestamp)
            let result = Self.step(&track, detection: detections[detectionIndex], at: timestamp, isNew: true,
                                   configuration: configuration, framesPerSecond: fps)
            tracks.append(track)
            snapshots.append(result.snapshot)
        }
        return FallDetectorUpdate(tracks: snapshots, events: events)
    }

    private static func step(_ track: inout Track, detection: Geometry, at timestamp: TimeInterval,
                             isNew: Bool = false, configuration config: FallDetectorConfiguration,
                             framesPerSecond: Double?) -> (snapshot: FallTrackSnapshot, event: FallEvent?) {
        let previousGeometry = track.geometry
        let elapsedSinceSeen = timestamp - track.lastSeen
        track.geometry = detection
        track.lastSeen = timestamp

        let aspectRatio = detection.width / detection.height
        let usableBaseline = track.baselineSamples >= config.minimumBaselineSamples ? track.baseline : nil
        let heightRatio = usableBaseline.map { detection.height / $0 }
        let horizontalTorso = detection.torsoAngle.map { $0 >= config.torsoAngleThresholdDegrees } ?? false
        let horizontalBox = aspectRatio >= config.aspectRatioThreshold
        let collapsed = heightRatio.map { $0 <= config.heightCollapseThreshold } ?? false
        let fallPosture = horizontalTorso || horizontalBox || collapsed
        var event: FallEvent?

        if fallPosture {
            track.recoveryCount = 0
            switch track.state {
            case .fallen:
                break
            case .falling:
                track.fallSamples += 1
            case .standing, .walking, .sitting:
                track.stateBeforeFall = track.state
                track.state = .falling
                track.fallStartedAt = timestamp
                track.fallSamples = 1
            }
            if track.state == .falling, let started = track.fallStartedAt {
                let persistence = config.persistenceSeconds(framesPerSecond: framesPerSecond)
                if track.fallSamples >= config.minimumConfirmingSamples, timestamp - started >= persistence {
                    track.state = .fallen
                    if !track.alertDispatched {
                        track.alertDispatched = true
                        event = FallEvent(
                            id: UUID(), trackID: track.id, occurredAt: timestamp, fallStartedAt: started,
                            event: FallPersonState.fallen.rawValue, confidence: detection.observation.confidence,
                            previousState: .falling, currentState: .fallen, box: detection.observation.box,
                            metrics: FallMetrics(torsoAngleDegrees: detection.torsoAngle, aspectRatio: aspectRatio,
                                                 heightRatio: heightRatio, baselineHeightPixels: usableBaseline),
                            framesPerSecond: framesPerSecond, persistenceSeconds: persistence,
                            relinkCount: track.relinkCount
                        )
                    }
                }
            }
        } else if track.state == .fallen, track.recoveryCount + 1 < config.recoverySamples {
            track.recoveryCount += 1
        } else {
            track.recoveryCount = 0
            track.fallStartedAt = nil
            track.fallSamples = 0
            track.alertDispatched = false
            if let heightRatio, heightRatio < config.sittingHeightThreshold {
                track.state = .sitting
            } else if !isNew, elapsedSinceSeen > 0, let fps = framesPerSecond, fps >= config.velocityFeatureMinimumFPS {
                let displacement = hypot(detection.centerX - previousGeometry.centerX,
                                         detection.centerY - previousGeometry.centerY)
                let speed = displacement / elapsedSinceSeen / max(1, usableBaseline ?? detection.height)
                track.state = speed >= config.walkingSpeedBodyHeightsPerSecond ? .walking : .standing
            } else {
                track.state = .standing
            }
        }

        // The baseline is learned only from confidently upright samples (guide 2.4).
        if track.state.isUpright, !horizontalTorso, !horizontalBox {
            if let baseline = track.baseline, track.baselineSamples >= config.minimumBaselineSamples {
                track.baseline = config.emaAlpha * detection.height + (1 - config.emaAlpha) * baseline
            } else {
                let samples = Double(track.baselineSamples)
                track.baseline = ((track.baseline ?? 0) * samples + detection.height) / (samples + 1)
            }
            track.baselineSamples += 1
        }

        let snapshot = FallTrackSnapshot(
            trackID: track.id, state: track.state, confidence: detection.observation.confidence,
            box: detection.observation.box,
            metrics: FallMetrics(torsoAngleDegrees: detection.torsoAngle, aspectRatio: aspectRatio,
                                 heightRatio: heightRatio,
                                 baselineHeightPixels: track.baselineSamples >= config.minimumBaselineSamples ? track.baseline : nil),
            relinkCount: track.relinkCount
        )
        return (snapshot, event)
    }

    private func geometry(for observation: FallPoseObservation, frameWidth: Double,
                          frameHeight: Double) -> Geometry? {
        let box = observation.box
        guard observation.confidence.isFinite, observation.confidence >= configuration.lowConfidenceFloor,
              observation.confidence <= 1,
              [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0 else { return nil }
        let width = box.width * frameWidth
        let height = box.height * frameHeight
        return Geometry(observation: observation,
                        centerX: (box.x + box.width / 2) * frameWidth,
                        centerY: (box.y + box.height / 2) * frameHeight,
                        width: width, height: height,
                        torsoAngle: torsoAngle(observation.keypoints, frameWidth: frameWidth, frameHeight: frameHeight))
    }

    private func torsoAngle(_ keypoints: [FallKeypoint], frameWidth: Double, frameHeight: Double) -> Double? {
        func midpoint(_ first: Int, _ second: Int) -> (x: Double, y: Double)? {
            let points = [first, second].compactMap { index -> FallKeypoint? in
                guard keypoints.indices.contains(index) else { return nil }
                let point = keypoints[index]
                guard point.confidence >= configuration.keypointConfidence,
                      point.x.isFinite, point.y.isFinite else { return nil }
                return point
            }
            guard !points.isEmpty else { return nil }
            return (points.map(\.x).reduce(0, +) / Double(points.count) * frameWidth,
                    points.map(\.y).reduce(0, +) / Double(points.count) * frameHeight)
        }
        guard let shoulder = midpoint(FallPoseObservation.leftShoulder, FallPoseObservation.rightShoulder),
              let hip = midpoint(FallPoseObservation.leftHip, FallPoseObservation.rightHip) else { return nil }
        let dx = abs(shoulder.x - hip.x)
        let dy = abs(shoulder.y - hip.y)
        guard dx > 0 || dy > 0 else { return nil }
        return atan2(dx, dy) * 180 / .pi
    }

    private static func intersectionOverUnion(_ first: Geometry, _ second: Geometry) -> Double {
        let width = min(first.right, second.right) - max(first.left, second.left)
        let height = min(first.bottom, second.bottom) - max(first.top, second.top)
        guard width > 0, height > 0 else { return 0 }
        let intersection = width * height
        let union = first.width * first.height + second.width * second.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
