import Foundation

/// Pose-based fall detection and kinematic posture state machine.
///
/// The detector is a per-camera value type: feed it every pose inference result for one camera
/// in monotonic time order. It keeps person tracks, evaluates velocity/angle/height transitions
/// against an upright/seated baseline, distinguishes falls from controlled movements (sitting,
/// bending, crouching, lying down), and emits `FallEvent` transitions (`FALL_CONFIRMED`, `PERSON_DOWN`, `RECOVERED`).
public enum FallPersonState: String, Codable, Sendable, CaseIterable {
    case standing = "STANDING"
    case walking = "WALKING"
    case sitting = "SITTING"
    case falling = "FALLING"
    case fallen = "FALLEN"

    public var isUpright: Bool { self == .standing || self == .walking }
    public var isFallPhase: Bool { self == .falling || self == .fallen }
}

public struct FallKeypoint: Codable, Equatable, Sendable {
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
public struct FallPoseObservation: Codable, Equatable, Sendable {
    public static let nose = 0
    public static let leftEye = 1
    public static let rightEye = 2
    public static let leftEar = 3
    public static let rightEar = 4
    public static let leftShoulder = 5
    public static let rightShoulder = 6
    public static let leftElbow = 7
    public static let rightElbow = 8
    public static let leftWrist = 9
    public static let rightWrist = 10
    public static let leftHip = 11
    public static let rightHip = 12
    public static let leftKnee = 13
    public static let rightKnee = 14
    public static let leftAnkle = 15
    public static let rightAnkle = 16

    public let confidence: Double
    public let box: FallBoundingBox
    public let keypoints: [FallKeypoint]

    public init(confidence: Double, box: FallBoundingBox, keypoints: [FallKeypoint]) {
        self.confidence = confidence
        self.box = box
        self.keypoints = keypoints
    }
}

public struct FallDetectorConfiguration: Codable, Equatable, Sendable {
    public var torsoAngleThresholdDegrees = 55.0
    public var aspectRatioThreshold = 1.15
    public var heightCollapseThreshold = 0.55
    public var sittingHeightThreshold = 0.75
    public var crouchingHeightThreshold = 0.68
    /// T_fall: how long a fall posture must persist before `FALLEN` (`FALL_CONFIRMED`) is confirmed.
    public var fallPersistenceSeconds = 0.8
    /// How long a confirmed fallen person remains down before `PERSON_DOWN` escalation is emitted.
    public var personDownSeconds = 10.0
    /// Streams at or below this rate use `lowFrameRatePersistenceSeconds` instead.
    public var lowFrameRateThreshold = 1.5
    public var lowFrameRatePersistenceSeconds = 2.0
    /// A fall is never confirmed from fewer samples than this.
    public var minimumConfirmingSamples = 2
    /// Below this rate centroid velocity is unreliable, so `WALKING` is never inferred.
    public var velocityFeatureMinimumFPS = 5.0
    public var walkingSpeedBodyHeightsPerSecond = 0.3
    public var runningSpeedBodyHeightsPerSecond = 1.25
    /// Controlled slow reclining after sitting for at least `controlledSitBeforeLieSeconds` with low vertical speed is classified as `Lying` rather than an acute fall.
    public var controlledSitBeforeLieSeconds = 1.5
    public var controlledLieDownMaxDropSpeedBodyHeightsPerSecond = 0.25
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
        let positives = [aspectRatioThreshold, fallPersistenceSeconds, personDownSeconds,
                         lowFrameRateThreshold, lowFrameRatePersistenceSeconds, velocityFeatureMinimumFPS,
                         walkingSpeedBodyHeightsPerSecond, runningSpeedBodyHeightsPerSecond,
                         relinkMaximumGapSeconds, relinkMaximumDiagonalRatio]
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
    public let verticalDropVelocity: Double
    public let angularVelocityDegreesPerSecond: Double
    public let visibleKeypointCount: Int
    public let isPartiallyOccluded: Bool

    public init(
        torsoAngleDegrees: Double?,
        aspectRatio: Double,
        heightRatio: Double?,
        baselineHeightPixels: Double?,
        verticalDropVelocity: Double = 0,
        angularVelocityDegreesPerSecond: Double = 0,
        visibleKeypointCount: Int = 0,
        isPartiallyOccluded: Bool = false
    ) {
        self.torsoAngleDegrees = torsoAngleDegrees
        self.aspectRatio = aspectRatio
        self.heightRatio = heightRatio
        self.baselineHeightPixels = baselineHeightPixels
        self.verticalDropVelocity = verticalDropVelocity
        self.angularVelocityDegreesPerSecond = angularVelocityDegreesPerSecond
        self.visibleKeypointCount = visibleKeypointCount
        self.isPartiallyOccluded = isPartiallyOccluded
    }
}

public struct FallTrackSnapshot: Codable, Equatable, Sendable {
    public let trackID: UUID
    public let state: FallPersonState
    public let phase: FallIncidentPhase
    public let behaviorState: HumanBehaviorState
    public let confidence: Double
    public let box: FallBoundingBox
    public let keypoints: [FallKeypoint]
    public let metrics: FallMetrics
    public let downDurationSeconds: Double
    public let speedBodyHeightsPerSecond: Double
    public let relinkCount: Int

    public init(
        trackID: UUID,
        state: FallPersonState,
        phase: FallIncidentPhase = .normal,
        behaviorState: HumanBehaviorState = .standing,
        confidence: Double,
        box: FallBoundingBox,
        keypoints: [FallKeypoint] = [],
        metrics: FallMetrics,
        downDurationSeconds: Double = 0,
        speedBodyHeightsPerSecond: Double = 0,
        relinkCount: Int
    ) {
        self.trackID = trackID
        self.state = state
        self.phase = phase
        self.behaviorState = behaviorState
        self.confidence = confidence
        self.box = box
        self.keypoints = keypoints
        self.metrics = metrics
        self.downDurationSeconds = downDurationSeconds
        self.speedBodyHeightsPerSecond = speedBodyHeightsPerSecond
        self.relinkCount = relinkCount
    }
}

public struct FallEvent: Codable, Equatable, Sendable {
    public static let eventType = "fall.detected"
    public static let personDownEventType = "person.down"
    public static let recoveredEventType = "fall.recovered"

    public let id: UUID
    public let trackID: UUID
    /// Timestamp in the same monotonic clock that was passed to `FallDetector.update`.
    public let occurredAt: TimeInterval
    public let fallStartedAt: TimeInterval
    public let event: String
    public let phase: FallIncidentPhase
    public let confidence: Double
    public let previousState: FallPersonState
    public let currentState: FallPersonState
    public let box: FallBoundingBox
    public let keypoints: [FallKeypoint]
    public let metrics: FallMetrics
    public let framesPerSecond: Double?
    public let persistenceSeconds: Double
    public let relinkCount: Int

    public init(
        id: UUID,
        trackID: UUID,
        occurredAt: TimeInterval,
        fallStartedAt: TimeInterval,
        event: String,
        phase: FallIncidentPhase = .fallConfirmed,
        confidence: Double,
        previousState: FallPersonState,
        currentState: FallPersonState,
        box: FallBoundingBox,
        keypoints: [FallKeypoint] = [],
        metrics: FallMetrics,
        framesPerSecond: Double?,
        persistenceSeconds: Double,
        relinkCount: Int
    ) {
        self.id = id
        self.trackID = trackID
        self.occurredAt = occurredAt
        self.fallStartedAt = fallStartedAt
        self.event = event
        self.phase = phase
        self.confidence = confidence
        self.previousState = previousState
        self.currentState = currentState
        self.box = box
        self.keypoints = keypoints
        self.metrics = metrics
        self.framesPerSecond = framesPerSecond
        self.persistenceSeconds = persistenceSeconds
        self.relinkCount = relinkCount
    }
}

public struct FallDetectorUpdate: Equatable, Sendable {
    public let tracks: [FallTrackSnapshot]
    public let events: [FallEvent]

    public static let empty = FallDetectorUpdate(tracks: [], events: [])

    public init(tracks: [FallTrackSnapshot], events: [FallEvent]) {
        self.tracks = tracks
        self.events = events
    }
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
        let shoulderMidY: Double?
        let hipMidY: Double?
        let kneeMidY: Double?
        let ankleMidY: Double?
        let visibleKeypoints: Int
        let touchesBorder: Bool

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
        var phase: FallIncidentPhase = .normal
        var behaviorState: HumanBehaviorState = .standing
        var hasBeenUprightOrSeated = false
        var startedInHorizontalPose = false
        var sittingStartedAt: TimeInterval?
        var baseline: Double?
        var baselineSamples = 0
        var fallStartedAt: TimeInterval?
        var fallConfirmedAt: TimeInterval?
        var fallSamples = 0
        var peakVerticalDropSpeed: Double = 0
        var peakAngularVelocity: Double = 0
        var stateBeforeFall: FallPersonState = .standing
        var recoveryCount = 0
        var alertDispatched = false
        var personDownDispatched = false
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

    public func phase(of trackID: UUID) -> FallIncidentPhase? {
        tracks.first { $0.id == trackID }?.phase
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
            if let event = result.event { events.append(event) }
        }
        return FallDetectorUpdate(tracks: snapshots, events: events)
    }

    private static func step(_ track: inout Track, detection: Geometry, at timestamp: TimeInterval,
                             isNew: Bool = false, configuration config: FallDetectorConfiguration,
                             framesPerSecond: Double?) -> (snapshot: FallTrackSnapshot, event: FallEvent?) {
        let previousGeometry = track.geometry
        let elapsedSinceSeen = max(0, timestamp - track.lastSeen)
        track.geometry = detection
        track.lastSeen = timestamp

        let aspectRatio = detection.width / detection.height
        let usableBaseline = track.baselineSamples >= config.minimumBaselineSamples ? track.baseline : nil
        let heightRatio = usableBaseline.map { detection.height / $0 }
        let referenceHeight = max(1.0, usableBaseline ?? detection.height)

        // Kinematic velocities
        let verticalDropVelocity: Double
        let angularVelocity: Double
        let centroidSpeed: Double
        if !isNew && elapsedSinceSeen > 1e-4 {
            let dy = detection.centerY - previousGeometry.centerY
            verticalDropVelocity = dy / elapsedSinceSeen / referenceHeight
            if let currAngle = detection.torsoAngle, let prevAngle = previousGeometry.torsoAngle {
                angularVelocity = abs(currAngle - prevAngle) / elapsedSinceSeen
            } else {
                angularVelocity = 0
            }
            let displacement = hypot(detection.centerX - previousGeometry.centerX,
                                     detection.centerY - previousGeometry.centerY)
            centroidSpeed = displacement / elapsedSinceSeen / referenceHeight
        } else {
            verticalDropVelocity = 0
            angularVelocity = 0
            centroidSpeed = 0
        }

        let horizontalTorso = detection.torsoAngle.map { $0 >= config.torsoAngleThresholdDegrees } ?? false
        let horizontalBox = aspectRatio >= config.aspectRatioThreshold
        let collapsed = heightRatio.map { $0 <= config.heightCollapseThreshold } ?? false

        // Partial occlusion guard: if at frame border and missing core torso keypoints without baseline
        let isPartiallyOccluded = detection.touchesBorder && detection.torsoAngle == nil && usableBaseline == nil

        // Distinguish waist bending with standing legs from actual fall posture:
        // If knees/ankles are clearly visible well below hips and box remains vertical & uncollapsed,
        // the person is bending at the waist (e.g., picking up an object / tying shoes), not lying on the floor.
        let isStandingWaistBend: Bool = {
            guard horizontalTorso, !horizontalBox, !collapsed else { return false }
            guard let hipY = detection.hipMidY, let ankleY = detection.ankleMidY else { return false }
            let legVerticalSpan = (ankleY - hipY) / max(1.0, detection.height)
            return legVerticalSpan >= 0.36 && aspectRatio < 0.90
        }()

        // Distinguish crouching (knees bent, torso upright, vertical aspect ratio, feet supporting body)
        let isCrouchingPosture: Bool = {
            guard !horizontalTorso, !horizontalBox else { return false }
            if let hipY = detection.hipMidY, let kneeY = detection.kneeMidY, let ankleY = detection.ankleMidY {
                let hipToKnee = abs(kneeY - hipY) / max(1.0, detection.height)
                let kneeToAnkle = (ankleY - kneeY) / max(1.0, detection.height)
                if hipToKnee < 0.16 && kneeToAnkle >= 0.15 {
                    return true
                }
            }
            if let heightRatio, heightRatio > config.heightCollapseThreshold, heightRatio <= config.crouchingHeightThreshold,
               detection.ankleMidY != nil {
                return true
            }
            return false
        }()

        let rawFallPosture = (horizontalTorso || horizontalBox || collapsed) && !isStandingWaistBend && !isPartiallyOccluded

        // Section 5 rule: A person who enters the scene ALREADY lying down without any prior upright/seated state
        // must NOT trigger an acute fall confirmation solely from horizontal posture.
        if isNew {
            if rawFallPosture {
                track.startedInHorizontalPose = true
                track.hasBeenUprightOrSeated = false
                track.state = .sitting
                track.phase = .normal
                track.behaviorState = .lying
            } else {
                track.startedInHorizontalPose = false
                track.hasBeenUprightOrSeated = true
                track.state = .standing
                track.phase = .normal
                track.behaviorState = isStandingWaistBend ? .bending : (isCrouchingPosture ? .crouching : .standing)
            }
        }

        // Check if this is a controlled, slow transition from prolonged sitting into lying on a bed/couch
        let isControlledLieDownFromSit: Bool = {
            guard rawFallPosture, !track.state.isFallPhase else { return false }
            guard track.state == .sitting, let satAt = track.sittingStartedAt else { return false }
            let satDuration = timestamp - satAt
            // Only treat as controlled lie-down if the person sat calmly for >= controlledSitBeforeLieSeconds
            // and reclined at seat level without height collapse or downward drop to the floor
            return satDuration >= config.controlledSitBeforeLieSeconds
                && !collapsed
                && verticalDropVelocity >= 0
                && verticalDropVelocity < config.controlledLieDownMaxDropSpeedBodyHeightsPerSecond
                && (detection.centerY - previousGeometry.centerY) / referenceHeight < 0.08
        }()

        let effectiveFallPosture = rawFallPosture && track.hasBeenUprightOrSeated && !isControlledLieDownFromSit
        var event: FallEvent?
        var downDurationSeconds: Double = 0

        if isPartiallyOccluded && !track.state.isFallPhase {
            track.phase = .undetermined
            track.behaviorState = .unknown
        } else if effectiveFallPosture {
            track.recoveryCount = 0
            track.peakVerticalDropSpeed = max(track.peakVerticalDropSpeed, verticalDropVelocity)
            track.peakAngularVelocity = max(track.peakAngularVelocity, angularVelocity)

            switch track.state {
            case .fallen:
                if let confirmedAt = track.fallConfirmedAt {
                    downDurationSeconds = max(0, timestamp - confirmedAt)
                } else if let started = track.fallStartedAt {
                    downDurationSeconds = max(0, timestamp - started)
                }
                if downDurationSeconds >= config.personDownSeconds {
                    track.phase = .personDown
                    if !track.personDownDispatched {
                        track.personDownDispatched = true
                        let persistence = config.persistenceSeconds(framesPerSecond: framesPerSecond)
                        event = FallEvent(
                            id: UUID(),
                            trackID: track.id,
                            occurredAt: timestamp,
                            fallStartedAt: track.fallStartedAt ?? timestamp,
                            event: FallIncidentPhase.personDown.rawValue,
                            phase: .personDown,
                            confidence: detection.observation.confidence,
                            previousState: .fallen,
                            currentState: .fallen,
                            box: detection.observation.box,
                            keypoints: detection.observation.keypoints,
                            metrics: FallMetrics(
                                torsoAngleDegrees: detection.torsoAngle,
                                aspectRatio: aspectRatio,
                                heightRatio: heightRatio,
                                baselineHeightPixels: usableBaseline,
                                verticalDropVelocity: track.peakVerticalDropSpeed,
                                angularVelocityDegreesPerSecond: track.peakAngularVelocity,
                                visibleKeypointCount: detection.visibleKeypoints,
                                isPartiallyOccluded: isPartiallyOccluded
                            ),
                            framesPerSecond: framesPerSecond,
                            persistenceSeconds: persistence,
                            relinkCount: track.relinkCount
                        )
                    }
                } else {
                    track.phase = .fallConfirmed
                }
                track.behaviorState = .fallen

            case .falling:
                track.fallSamples += 1
                track.behaviorState = .falling

            case .standing, .walking, .sitting:
                track.stateBeforeFall = track.state
                track.state = .falling
                track.fallStartedAt = timestamp
                track.fallSamples = 1
                track.peakVerticalDropSpeed = max(0, verticalDropVelocity)
                track.peakAngularVelocity = angularVelocity
                track.phase = .possibleFall
                track.behaviorState = .falling
            }

            if track.state == .falling, let started = track.fallStartedAt {
                let persistence = config.persistenceSeconds(framesPerSecond: framesPerSecond)
                let elapsedInFall = timestamp - started
                if track.fallSamples >= config.minimumConfirmingSamples, elapsedInFall >= persistence {
                    track.state = .fallen
                    track.phase = .fallConfirmed
                    track.behaviorState = .fallen
                    track.fallConfirmedAt = timestamp
                    if !track.alertDispatched {
                        track.alertDispatched = true
                        event = FallEvent(
                            id: UUID(),
                            trackID: track.id,
                            occurredAt: timestamp,
                            fallStartedAt: started,
                            event: FallPersonState.fallen.rawValue,
                            phase: .fallConfirmed,
                            confidence: detection.observation.confidence,
                            previousState: .falling,
                            currentState: .fallen,
                            box: detection.observation.box,
                            keypoints: detection.observation.keypoints,
                            metrics: FallMetrics(
                                torsoAngleDegrees: detection.torsoAngle,
                                aspectRatio: aspectRatio,
                                heightRatio: heightRatio,
                                baselineHeightPixels: usableBaseline,
                                verticalDropVelocity: track.peakVerticalDropSpeed,
                                angularVelocityDegreesPerSecond: track.peakAngularVelocity,
                                visibleKeypointCount: detection.visibleKeypoints,
                                isPartiallyOccluded: isPartiallyOccluded
                            ),
                            framesPerSecond: framesPerSecond,
                            persistenceSeconds: persistence,
                            relinkCount: track.relinkCount
                        )
                    }
                } else if track.fallSamples >= 2 || elapsedInFall >= persistence * 0.35 {
                    track.phase = .fallInProgress
                } else {
                    track.phase = .possibleFall
                }
            }
        } else if track.state == .fallen, track.recoveryCount + 1 < config.recoverySamples {
            track.recoveryCount += 1
            track.behaviorState = .fallen
        } else {
            let wasFallen = track.state == .fallen
            track.recoveryCount = 0
            track.fallStartedAt = nil
            track.fallConfirmedAt = nil
            track.fallSamples = 0
            track.peakVerticalDropSpeed = 0
            track.peakAngularVelocity = 0
            track.alertDispatched = false
            track.personDownDispatched = false

            if rawFallPosture && (track.startedInHorizontalPose || isControlledLieDownFromSit) {
                track.state = .sitting
                track.phase = .normal
                track.behaviorState = .lying
            } else {
                track.startedInHorizontalPose = false
                track.hasBeenUprightOrSeated = true
                track.phase = wasFallen ? .recovered : .normal

                if isStandingWaistBend {
                    track.state = .standing
                    track.behaviorState = .bending
                    track.sittingStartedAt = nil
                } else if isCrouchingPosture {
                    track.state = .sitting
                    track.behaviorState = .crouching
                    track.sittingStartedAt = nil
                } else if let heightRatio, heightRatio < config.sittingHeightThreshold {
                    if track.state != .sitting {
                        track.sittingStartedAt = timestamp
                    }
                    track.state = .sitting
                    track.behaviorState = .sitting
                } else if !isNew, elapsedSinceSeen > 0, let fps = framesPerSecond, fps >= config.velocityFeatureMinimumFPS {
                    track.sittingStartedAt = nil
                    if centroidSpeed >= config.runningSpeedBodyHeightsPerSecond {
                        track.state = .walking
                        track.behaviorState = .running
                    } else if centroidSpeed >= config.walkingSpeedBodyHeightsPerSecond {
                        track.state = .walking
                        track.behaviorState = .walking
                    } else {
                        track.state = .standing
                        track.behaviorState = .standing
                    }
                } else {
                    track.sittingStartedAt = nil
                    track.state = .standing
                    track.behaviorState = .standing
                }
            }
        }

        // The baseline is learned only from confidently upright samples (guide 2.4).
        if track.state.isUpright, !horizontalTorso, !horizontalBox, !isStandingWaistBend {
            if let baseline = track.baseline, track.baselineSamples >= config.minimumBaselineSamples {
                track.baseline = config.emaAlpha * detection.height + (1 - config.emaAlpha) * baseline
            } else {
                let samples = Double(track.baselineSamples)
                track.baseline = ((track.baseline ?? 0) * samples + detection.height) / (samples + 1)
            }
            track.baselineSamples += 1
        }

        let snapshot = FallTrackSnapshot(
            trackID: track.id,
            state: track.state,
            phase: track.phase,
            behaviorState: track.behaviorState,
            confidence: detection.observation.confidence,
            box: detection.observation.box,
            keypoints: detection.observation.keypoints,
            metrics: FallMetrics(
                torsoAngleDegrees: detection.torsoAngle,
                aspectRatio: aspectRatio,
                heightRatio: heightRatio,
                baselineHeightPixels: track.baselineSamples >= config.minimumBaselineSamples ? track.baseline : nil,
                verticalDropVelocity: verticalDropVelocity,
                angularVelocityDegreesPerSecond: angularVelocity,
                visibleKeypointCount: detection.visibleKeypoints,
                isPartiallyOccluded: isPartiallyOccluded
            ),
            downDurationSeconds: downDurationSeconds,
            speedBodyHeightsPerSecond: centroidSpeed,
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
        let visibleCount = observation.keypoints.filter {
            $0.confidence >= configuration.keypointConfidence && $0.x.isFinite && $0.y.isFinite
        }.count
        let touchesBorder = box.x <= 0.01 || box.y <= 0.01 || (box.x + box.width) >= 0.99 || (box.y + box.height) >= 0.985
        let shoulder = midpoint(observation.keypoints, FallPoseObservation.leftShoulder, FallPoseObservation.rightShoulder,
                                frameWidth: frameWidth, frameHeight: frameHeight)
        let hip = midpoint(observation.keypoints, FallPoseObservation.leftHip, FallPoseObservation.rightHip,
                           frameWidth: frameWidth, frameHeight: frameHeight)
        let knee = midpoint(observation.keypoints, FallPoseObservation.leftKnee, FallPoseObservation.rightKnee,
                            frameWidth: frameWidth, frameHeight: frameHeight)
        let ankle = midpoint(observation.keypoints, FallPoseObservation.leftAnkle, FallPoseObservation.rightAnkle,
                             frameWidth: frameWidth, frameHeight: frameHeight)
        var calculatedTorsoAngle: Double?
        if let shoulder, let hip {
            let dx = abs(shoulder.x - hip.x)
            let dy = abs(shoulder.y - hip.y)
            if dx > 0 || dy > 0 {
                calculatedTorsoAngle = atan2(dx, dy) * 180 / .pi
            }
        }
        return Geometry(
            observation: observation,
            centerX: (box.x + box.width / 2) * frameWidth,
            centerY: (box.y + box.height / 2) * frameHeight,
            width: width,
            height: height,
            torsoAngle: calculatedTorsoAngle,
            shoulderMidY: shoulder?.y,
            hipMidY: hip?.y,
            kneeMidY: knee?.y,
            ankleMidY: ankle?.y,
            visibleKeypoints: visibleCount,
            touchesBorder: touchesBorder
        )
    }

    private func midpoint(_ keypoints: [FallKeypoint], _ first: Int, _ second: Int,
                          frameWidth: Double, frameHeight: Double) -> (x: Double, y: Double)? {
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

    private static func intersectionOverUnion(_ first: Geometry, _ second: Geometry) -> Double {
        let width = min(first.right, second.right) - max(first.left, second.left)
        let height = min(first.bottom, second.bottom) - max(first.top, second.top)
        guard width > 0, height > 0 else { return 0 }
        let intersection = width * height
        let union = first.width * first.height + second.width * second.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
