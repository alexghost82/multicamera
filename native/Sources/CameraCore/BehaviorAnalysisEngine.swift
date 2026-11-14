import Foundation

public struct BehaviorSafetyCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let cameraID: UUID
    public let trackIDs: [UUID]
    public let zoneID: UUID?
    public let zoneName: String?
    public let type: SafetyIncidentType
    public let severity: SafetyIncidentSeverity
    public let confidence: Double
    public let monotonicTimestamp: TimeInterval
    public let occurredAt: Date
    public let primaryBox: FallBoundingBox?
    public let keypoints: [FallKeypoint]
    public let title: String
    public let explanation: String
    public let detectorSource: String
    public let requiresSecondaryVLMVerification: Bool
    public let metrics: [String: Double]

    public init(
        id: UUID = UUID(),
        cameraID: UUID,
        trackIDs: [UUID],
        zoneID: UUID? = nil,
        zoneName: String? = nil,
        type: SafetyIncidentType,
        severity: SafetyIncidentSeverity? = nil,
        confidence: Double,
        monotonicTimestamp: TimeInterval,
        occurredAt: Date = Date(),
        primaryBox: FallBoundingBox? = nil,
        keypoints: [FallKeypoint] = [],
        title: String? = nil,
        explanation: String,
        detectorSource: String,
        requiresSecondaryVLMVerification: Bool = false,
        metrics: [String: Double] = [:]
    ) {
        self.id = id
        self.cameraID = cameraID
        self.trackIDs = trackIDs
        self.zoneID = zoneID
        self.zoneName = zoneName
        self.type = type
        self.severity = severity ?? type.defaultSeverity
        self.confidence = min(max(confidence, 0), 1)
        self.monotonicTimestamp = monotonicTimestamp
        self.occurredAt = occurredAt
        self.primaryBox = primaryBox
        self.keypoints = keypoints
        self.title = title ?? type.displayTitle
        self.explanation = explanation
        self.detectorSource = detectorSource
        self.requiresSecondaryVLMVerification = requiresSecondaryVLMVerification
        self.metrics = metrics
    }
}

public struct BehaviorAnalysisResult: Equatable, Sendable {
    public let cameraID: UUID
    public let trackedPeople: [TrackedPersonPose]
    public let candidates: [BehaviorSafetyCandidate]

    public init(cameraID: UUID, trackedPeople: [TrackedPersonPose], candidates: [BehaviorSafetyCandidate]) {
        self.cameraID = cameraID
        self.trackedPeople = trackedPeople
        self.candidates = candidates
    }
}

/// Modular per-camera temporal behavior analysis engine.
/// Evaluates posture states, prolonged inactivity / unresponsive person, loitering,
/// restricted zone intrusion, unusual movement/running, crowd activity, and Stage-A pose interaction heuristics.
public struct BehaviorAnalysisEngine: Sendable {
    private struct TrackTemporalState {
        let trackID: UUID
        var firstSeenAt: TimeInterval
        var lastSeenAt: TimeInterval
        var anchorCenter: NormalizedPoint
        var lastCenter: NormalizedPoint
        var lastWristLeft: NormalizedPoint?
        var lastWristRight: NormalizedPoint?
        var stationarySince: TimeInterval
        var runningSince: TimeInterval?
        var zoneEnteredAt: [UUID: TimeInterval] = [:]
        var smoothedWristSpeed: Double = 0
        var hasCriticalAlert: Bool = false
    }

    private struct PairInteractionState {
        var startedAt: TimeInterval
        var activeSamples: Int
        var peakAgitationScore: Double
    }

    public var stillnessDisplacementThreshold: Double = 0.018
    public var loiteringRadiusNormalized: Double = 0.18
    public var runningHoldSeconds: Double = 1.2
    public var runningSpeedThreshold: Double = 1.25
    public var crowdPersonThreshold: Int = 5
    public var crowdHoldSeconds: Double = 3.0
    public var fightProximityMaxDistanceNormalized: Double = 0.22
    public var fightHoldSeconds: Double = 1.2
    public var fightWristSpeedThreshold: Double = 0.85

    private var trackStates: [UUID: TrackTemporalState] = [:]
    private var pairStates: [String: PairInteractionState] = [:]
    private var crowdAboveThresholdSince: TimeInterval?
    private var lastAlertByKey: [String: TimeInterval] = [:]
    private var lastTimestamp: TimeInterval?

    public init() {}

    public mutating func reset() {
        trackStates.removeAll()
        pairStates.removeAll()
        crowdAboveThresholdSince = nil
        lastAlertByKey.removeAll()
        lastTimestamp = nil
    }

    public mutating func evaluate(
        cameraID: UUID,
        fallUpdate: FallDetectorUpdate,
        config: EffectiveCameraAnalyticsConfig,
        monotonicTimestamp: TimeInterval,
        wallClockNow: Date = Date()
    ) -> BehaviorAnalysisResult {
        guard monotonicTimestamp.isFinite else {
            return BehaviorAnalysisResult(cameraID: cameraID, trackedPeople: [], candidates: [])
        }
        if let lastTimestamp, monotonicTimestamp < lastTimestamp {
            return BehaviorAnalysisResult(cameraID: cameraID, trackedPeople: [], candidates: [])
        }
        lastTimestamp = monotonicTimestamp

        // Expire stale tracks (> 5s unseen)
        trackStates = trackStates.filter { monotonicTimestamp - $0.value.lastSeenAt <= 5.0 }

        var candidates: [BehaviorSafetyCandidate] = []
        var criticalTrackIDs = Set<UUID>()

        // 1. Convert FallDetector events into primary safety candidates
        if config.fallDetectionEnabled {
            for fallEvent in fallUpdate.events {
                criticalTrackIDs.insert(fallEvent.trackID)
                let incidentType: SafetyIncidentType = (fallEvent.phase == .personDown) ? .personDown : .fallConfirmed
                let key = "\(incidentType.rawValue):\(fallEvent.trackID.uuidString)"
                if canFireAlert(key: key, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                    markAlertFired(key: key, now: monotonicTimestamp)
                    var metricDict: [String: Double] = [
                        "aspectRatio": fallEvent.metrics.aspectRatio,
                        "persistenceSeconds": fallEvent.persistenceSeconds,
                        "verticalDropVelocity": fallEvent.metrics.verticalDropVelocity,
                        "angularVelocityDegPerSec": fallEvent.metrics.angularVelocityDegreesPerSecond,
                        "visibleKeypoints": Double(fallEvent.metrics.visibleKeypointCount)
                    ]
                    if let angle = fallEvent.metrics.torsoAngleDegrees {
                        metricDict["torsoAngleDegrees"] = angle
                    }
                    if let hRatio = fallEvent.metrics.heightRatio {
                        metricDict["heightRatio"] = hRatio
                    }

                    let angleText = fallEvent.metrics.torsoAngleDegrees.map { String(format: "torso angle %.0f°", $0) } ?? "horizontal posture"
                    let heightText = fallEvent.metrics.heightRatio.map { String(format: ", height %.0f%% of upright baseline", $0 * 100) } ?? ""
                    let explanation: String
                    if incidentType == .personDown {
                        explanation = String(
                            format: "Person remained down on floor for %.1f s after confirmed fall (%@%@).",
                            monotonicTimestamp - fallEvent.fallStartedAt,
                            angleText,
                            heightText
                        )
                    } else {
                        explanation = String(
                            format: "Fall confirmed after %.1f s transition (%@%@, aspect ratio %.2f).",
                             monotonicTimestamp - fallEvent.fallStartedAt,
                            angleText,
                            heightText,
                            fallEvent.metrics.aspectRatio
                        )
                    }

                    candidates.append(
                        BehaviorSafetyCandidate(
                            id: fallEvent.id,
                            cameraID: cameraID,
                            trackIDs: [fallEvent.trackID],
                            type: incidentType,
                            severity: .critical,
                            confidence: fallEvent.confidence,
                            monotonicTimestamp: monotonicTimestamp,
                            occurredAt: wallClockNow,
                            primaryBox: fallEvent.box,
                            keypoints: fallEvent.keypoints,
                            explanation: explanation,
                            detectorSource: "FallDetectorV2",
                            requiresSecondaryVLMVerification: config.secondaryVLMVerificationEnabled,
                            metrics: metricDict
                        )
                    )
                }
            }
        }

        // 2. Per-track temporal behavior evaluation
        var enrichedPoses: [TrackedPersonPose] = []
        enrichedPoses.reserveCapacity(fallUpdate.tracks.count)

        for snapshot in fallUpdate.tracks {
            let center = NormalizedPoint(
                x: snapshot.box.x + snapshot.box.width * 0.5,
                y: snapshot.box.y + snapshot.box.height * 0.5
            )
            let footPoint = NormalizedPoint(
                x: snapshot.box.x + snapshot.box.width * 0.5,
                y: min(1.0, snapshot.box.y + snapshot.box.height)
            )
            let leftWrist = keypointNormalized(snapshot.keypoints, index: FallPoseObservation.leftWrist, minConfidence: config.poseKeypointConfidenceThreshold)
            let rightWrist = keypointNormalized(snapshot.keypoints, index: FallPoseObservation.rightWrist, minConfidence: config.poseKeypointConfidenceThreshold)

            var state = trackStates[snapshot.trackID] ?? TrackTemporalState(
                trackID: snapshot.trackID,
                firstSeenAt: monotonicTimestamp,
                lastSeenAt: monotonicTimestamp,
                anchorCenter: center,
                lastCenter: center,
                lastWristLeft: leftWrist,
                lastWristRight: rightWrist,
                stationarySince: monotonicTimestamp
            )

            let dt = max(0, monotonicTimestamp - state.lastSeenAt)
            let stepDisplacement = hypot(center.x - state.lastCenter.x, center.y - state.lastCenter.y)
            let anchorDisplacement = hypot(center.x - state.anchorCenter.x, center.y - state.anchorCenter.y)

            // Wrist movement velocity for interaction heuristics
            if dt > 1e-3 {
                var wristSpeed: Double = 0
                if let lw = leftWrist, let prevLW = state.lastWristLeft {
                    wristSpeed = max(wristSpeed, hypot(lw.x - prevLW.x, lw.y - prevLW.y) / dt / max(0.05, snapshot.box.height))
                }
                if let rw = rightWrist, let prevRW = state.lastWristRight {
                    wristSpeed = max(wristSpeed, hypot(rw.x - prevRW.x, rw.y - prevRW.y) / dt / max(0.05, snapshot.box.height))
                }
                state.smoothedWristSpeed = 0.4 * wristSpeed + 0.6 * state.smoothedWristSpeed
            }
            state.lastWristLeft = leftWrist
            state.lastWristRight = rightWrist
            state.lastCenter = center
            state.lastSeenAt = monotonicTimestamp

            if stepDisplacement > stillnessDisplacementThreshold {
                state.stationarySince = monotonicTimestamp
            }
            if anchorDisplacement > loiteringRadiusNormalized {
                state.anchorCenter = center
                state.firstSeenAt = monotonicTimestamp
            }

            let stationaryDuration = max(0, monotonicTimestamp - state.stationarySince)
            let dwellDuration = max(0, monotonicTimestamp - state.firstSeenAt)

            // 2a. Prolonged Inactivity / Possible Unresponsive Person
            if config.inactivityDetectionEnabled {
                let isLyingOrFallen = snapshot.behaviorState == .lying || snapshot.behaviorState == .fallen
                let unresponsiveThreshold = isLyingOrFallen
                    ? config.inactivityThresholdSeconds
                    : config.inactivityThresholdSeconds * 1.5
                if stationaryDuration >= unresponsiveThreshold && (isLyingOrFallen || snapshot.behaviorState == .sitting) {
                    let incidentType: SafetyIncidentType = isLyingOrFallen ? .possibleUnresponsivePerson : .prolongedInactivity
                    let key = "\(incidentType.rawValue):\(snapshot.trackID.uuidString)"
                    if canFireAlert(key: key, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                        markAlertFired(key: key, now: monotonicTimestamp)
                        criticalTrackIDs.insert(snapshot.trackID)
                        candidates.append(
                            BehaviorSafetyCandidate(
                                cameraID: cameraID,
                                trackIDs: [snapshot.trackID],
                                type: incidentType,
                                severity: isLyingOrFallen ? .critical : .medium,
                                confidence: snapshot.confidence,
                                monotonicTimestamp: monotonicTimestamp,
                                occurredAt: wallClockNow,
                                primaryBox: snapshot.box,
                                keypoints: snapshot.keypoints,
                                explanation: String(
                                    format: "Person in %@ posture showed no significant movement for %.1f s (threshold %.1f s).",
                                    snapshot.behaviorState.rawValue,
                                    stationaryDuration,
                                    unresponsiveThreshold
                                ),
                                detectorSource: "ProlongedInactivityDetector",
                                requiresSecondaryVLMVerification: config.secondaryVLMVerificationEnabled,
                                metrics: [
                                    "stationaryDurationSeconds": stationaryDuration,
                                    "thresholdSeconds": unresponsiveThreshold
                                ]
                            )
                        )
                    }
                }
            }

            // 2b. Loitering Detection
            if config.loiteringDetectionEnabled && dwellDuration >= config.loiteringThresholdSeconds {
                let key = "\(SafetyIncidentType.loitering.rawValue):\(snapshot.trackID.uuidString)"
                if canFireAlert(key: key, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                    markAlertFired(key: key, now: monotonicTimestamp)
                    candidates.append(
                        BehaviorSafetyCandidate(
                            cameraID: cameraID,
                            trackIDs: [snapshot.trackID],
                            type: .loitering,
                            severity: .low,
                            confidence: snapshot.confidence,
                            monotonicTimestamp: monotonicTimestamp,
                            occurredAt: wallClockNow,
                            primaryBox: snapshot.box,
                            keypoints: snapshot.keypoints,
                            explanation: String(
                                format: "Person remained within monitored area for %.0f s (threshold %.0f s).",
                                dwellDuration,
                                config.loiteringThresholdSeconds
                            ),
                            detectorSource: "LoiteringDetector",
                            requiresSecondaryVLMVerification: false,
                            metrics: [
                                "dwellDurationSeconds": dwellDuration,
                                "thresholdSeconds": config.loiteringThresholdSeconds
                            ]
                        )
                    )
                }
            }

            // 2c. Restricted Zone Intrusion
            var activeZoneIDs: [UUID] = []
            if config.zoneMonitoringEnabled && !config.restrictedZones.isEmpty {
                for zone in config.restrictedZones where zone.enabled {
                    let inside = zone.contains(footPoint) || zone.contains(center)
                    if inside {
                        activeZoneIDs.append(zone.id)
                        let enteredAt = state.zoneEnteredAt[zone.id] ?? monotonicTimestamp
                        state.zoneEnteredAt[zone.id] = enteredAt
                        let holdElapsed = monotonicTimestamp - enteredAt
                        if holdElapsed >= zone.holdSeconds {
                            let key = "\(SafetyIncidentType.restrictedZoneIntrusion.rawValue):\(zone.id.uuidString):\(snapshot.trackID.uuidString)"
                            if canFireAlert(key: key, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                                markAlertFired(key: key, now: monotonicTimestamp)
                                criticalTrackIDs.insert(snapshot.trackID)
                                candidates.append(
                                    BehaviorSafetyCandidate(
                                        cameraID: cameraID,
                                        trackIDs: [snapshot.trackID],
                                        zoneID: zone.id,
                                        zoneName: zone.name,
                                        type: .restrictedZoneIntrusion,
                                        severity: zone.severity,
                                        confidence: snapshot.confidence,
                                        monotonicTimestamp: monotonicTimestamp,
                                        occurredAt: wallClockNow,
                                        primaryBox: snapshot.box,
                                        keypoints: snapshot.keypoints,
                                        explanation: String(
                                            format: "Person entered restricted zone '%@' for %.1f s (hold threshold %.1f s).",
                                            zone.name,
                                            holdElapsed,
                                            zone.holdSeconds
                                        ),
                                        detectorSource: "RestrictedZoneDetector",
                                        requiresSecondaryVLMVerification: config.secondaryVLMVerificationEnabled,
                                        metrics: [
                                            "zoneHoldSeconds": holdElapsed,
                                            "thresholdSeconds": zone.holdSeconds
                                        ]
                                    )
                                )
                            }
                        }
                    } else {
                        state.zoneEnteredAt.removeValue(forKey: zone.id)
                    }
                }
            }

            // 2d. Unusual Movement / Sustained Running
            if config.unusualMovementEnabled {
                if snapshot.speedBodyHeightsPerSecond >= runningSpeedThreshold {
                    let startedRunning = state.runningSince ?? monotonicTimestamp
                    state.runningSince = startedRunning
                    let runningDuration = monotonicTimestamp - startedRunning
                    if runningDuration >= runningHoldSeconds {
                        let key = "\(SafetyIncidentType.unusualMovement.rawValue):\(snapshot.trackID.uuidString)"
                        if canFireAlert(key: key, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                            markAlertFired(key: key, now: monotonicTimestamp)
                            candidates.append(
                                BehaviorSafetyCandidate(
                                    cameraID: cameraID,
                                    trackIDs: [snapshot.trackID],
                                    type: .unusualMovement,
                                    severity: .medium,
                                    confidence: snapshot.confidence,
                                    monotonicTimestamp: monotonicTimestamp,
                                    occurredAt: wallClockNow,
                                    primaryBox: snapshot.box,
                                    keypoints: snapshot.keypoints,
                                    explanation: String(
                                        format: "Sustained rapid movement / running detected (%.2f body-heights/s for %.1f s).",
                                        snapshot.speedBodyHeightsPerSecond,
                                        runningDuration
                                    ),
                                    detectorSource: "UnusualMovementDetector",
                                    requiresSecondaryVLMVerification: false,
                                    metrics: [
                                        "speedBodyHeightsPerSecond": snapshot.speedBodyHeightsPerSecond,
                                        "durationSeconds": runningDuration
                                    ]
                                )
                            )
                        }
                    }
                } else {
                    state.runningSince = nil
                }
            }

            // Refine behaviorState if stationary for a long period
            let effectiveBehaviorState: HumanBehaviorState
            if snapshot.behaviorState == .standing && stationaryDuration >= 5.0 {
                effectiveBehaviorState = .stationary
            } else {
                effectiveBehaviorState = snapshot.behaviorState
            }

            let isCritical = criticalTrackIDs.contains(snapshot.trackID) || snapshot.phase.isCritical
            state.hasCriticalAlert = isCritical
            trackStates[snapshot.trackID] = state

            enrichedPoses.append(
                TrackedPersonPose(
                    trackID: snapshot.trackID,
                    cameraID: cameraID,
                    box: snapshot.box,
                    confidence: snapshot.confidence,
                    keypoints: snapshot.keypoints,
                    visibleKeypointCount: snapshot.metrics.visibleKeypointCount,
                    behaviorState: effectiveBehaviorState,
                    fallState: snapshot.state,
                    fallPhase: snapshot.phase,
                    torsoAngleDegrees: snapshot.metrics.torsoAngleDegrees,
                    aspectRatio: snapshot.metrics.aspectRatio,
                    heightRatio: snapshot.metrics.heightRatio,
                    verticalVelocity: snapshot.metrics.verticalDropVelocity,
                    angularVelocityDegreesPerSecond: snapshot.metrics.angularVelocityDegreesPerSecond,
                    speedBodyHeightsPerSecond: snapshot.speedBodyHeightsPerSecond,
                    stationaryDurationSeconds: stationaryDuration,
                    downDurationSeconds: snapshot.downDurationSeconds,
                    dwellDurationSeconds: dwellDuration,
                    activeZoneIDs: activeZoneIDs,
                    isPartiallyOccluded: snapshot.metrics.isPartiallyOccluded,
                    hasCriticalAlert: isCritical
                )
            )
        }

        // 3. Abnormal Crowd Activity
        if config.crowdActivityEnabled {
            let personCount = enrichedPoses.count
            if personCount >= crowdPersonThreshold {
                let since = crowdAboveThresholdSince ?? monotonicTimestamp
                crowdAboveThresholdSince = since
                let held = monotonicTimestamp - since
                if held >= crowdHoldSeconds {
                    let key = "\(SafetyIncidentType.abnormalCrowdActivity.rawValue):\(cameraID.uuidString)"
                    if canFireAlert(key: key, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                        markAlertFired(key: key, now: monotonicTimestamp)
                        let avgSpeed = enrichedPoses.map(\.speedBodyHeightsPerSecond).reduce(0, +) / Double(max(1, personCount))
                        candidates.append(
                            BehaviorSafetyCandidate(
                                cameraID: cameraID,
                                trackIDs: enrichedPoses.map(\.trackID),
                                type: .abnormalCrowdActivity,
                                severity: avgSpeed >= 0.8 ? .high : .medium,
                                confidence: 0.85,
                                monotonicTimestamp: monotonicTimestamp,
                                occurredAt: wallClockNow,
                                primaryBox: enrichedPoses.first?.box,
                                explanation: String(
                                    format: "Crowd threshold reached (%d people visible for %.1f s, average motion %.2f body-heights/s).",
                                    personCount,
                                    held,
                                    avgSpeed
                                ),
                                detectorSource: "AbnormalCrowdActivityDetector",
                                requiresSecondaryVLMVerification: config.secondaryVLMVerificationEnabled,
                                metrics: [
                                    "personCount": Double(personCount),
                                    "holdSeconds": held,
                                    "averageMotionSpeed": avgSpeed
                                ]
                            )
                        )
                    }
                }
            } else {
                crowdAboveThresholdSince = nil
            }
        }

        // 4. Stage-A Aggressive Physical Interaction / Possible Fight Heuristic
        if config.fightDetectionEnabled && enrichedPoses.count >= 2 {
            var activePairKeys = Set<String>()
            for i in 0..<(enrichedPoses.count - 1) {
                for j in (i + 1)..<enrichedPoses.count {
                    let first = enrichedPoses[i]
                    let second = enrichedPoses[j]
                    let pairKey = [first.trackID.uuidString, second.trackID.uuidString].sorted().joined(separator: ":")

                    let c1 = NormalizedPoint(x: first.box.x + first.box.width * 0.5, y: first.box.y + first.box.height * 0.5)
                    let c2 = NormalizedPoint(x: second.box.x + second.box.width * 0.5, y: second.box.y + second.box.height * 0.5)
                    let centerDistance = hypot(c1.x - c2.x, c1.y - c2.y)
                    let iou = boxIoU(first.box, second.box)
                    let inCloseProximity = centerDistance <= fightProximityMaxDistanceNormalized || iou >= 0.08

                    guard inCloseProximity else { continue }
                    let w1 = trackStates[first.trackID]?.smoothedWristSpeed ?? 0
                    let w2 = trackStates[second.trackID]?.smoothedWristSpeed ?? 0
                    let maxWristSpeed = max(w1, w2)
                    let combinedBodySpeed = first.speedBodyHeightsPerSecond + second.speedBodyHeightsPerSecond
                    let combinedAngularSpeed = first.angularVelocityDegreesPerSecond + second.angularVelocityDegreesPerSecond

                    let isAgitated = maxWristSpeed >= fightWristSpeedThreshold
                        || (combinedBodySpeed >= 1.2 && combinedAngularSpeed >= 65.0)
                    guard isAgitated else { continue }

                    activePairKeys.insert(pairKey)
                    let agitationScore = min(1.0, 0.5 * (maxWristSpeed / max(0.1, fightWristSpeedThreshold)) + 0.5 * (combinedBodySpeed / 2.0))
                    var pairState = pairStates[pairKey] ?? PairInteractionState(
                        startedAt: monotonicTimestamp,
                        activeSamples: 0,
                        peakAgitationScore: agitationScore
                    )
                    pairState.activeSamples += 1
                    pairState.peakAgitationScore = max(pairState.peakAgitationScore, agitationScore)
                    pairStates[pairKey] = pairState

                    let interactionDuration = monotonicTimestamp - pairState.startedAt
                    if pairState.activeSamples >= 2 && interactionDuration >= fightHoldSeconds {
                        let alertKey = "\(SafetyIncidentType.possiblePhysicalFight.rawValue):\(pairKey)"
                        if canFireAlert(key: alertKey, now: monotonicTimestamp, cooldown: config.alertCooldownSeconds) {
                            markAlertFired(key: alertKey, now: monotonicTimestamp)
                            let unionX = min(first.box.x, second.box.x)
                            let unionY = min(first.box.y, second.box.y)
                            let unionRight = max(first.box.x + first.box.width, second.box.x + second.box.width)
                            let unionBottom = max(first.box.y + first.box.height, second.box.y + second.box.height)
                            let unionBox = FallBoundingBox(
                                x: unionX,
                                y: unionY,
                                width: max(0.01, unionRight - unionX),
                                height: max(0.01, unionBottom - unionY)
                            )
                            candidates.append(
                                BehaviorSafetyCandidate(
                                    cameraID: cameraID,
                                    trackIDs: [first.trackID, second.trackID],
                                    type: .possiblePhysicalFight,
                                    severity: .high,
                                    confidence: min(0.92, max(0.55, pairState.peakAgitationScore)),
                                    monotonicTimestamp: monotonicTimestamp,
                                    occurredAt: wallClockNow,
                                    primaryBox: unionBox,
                                    keypoints: first.keypoints,
                                    explanation: String(
                                        format: "Stage-A Pose Interaction Heuristic: 2 tracks in close proximity (d=%.2f, IoU=%.2f) with rapid limb/body kinematics (wrist speed %.2f, duration %.1f s). Experimental heuristic — review or verify via VLM.",
                                        centerDistance,
                                        iou,
                                        maxWristSpeed,
                                        interactionDuration
                                    ),
                                    detectorSource: "PoseInteractionHeuristicStageA",
                                    requiresSecondaryVLMVerification: true,
                                    metrics: [
                                        "centerDistance": centerDistance,
                                        "boxIoU": iou,
                                        "maxWristSpeed": maxWristSpeed,
                                        "interactionDurationSeconds": interactionDuration
                                    ]
                                )
                            )
                        }
                    }
                }
            }
            pairStates = pairStates.filter { activePairKeys.contains($0.key) }
        } else {
            pairStates.removeAll()
        }

        return BehaviorAnalysisResult(
            cameraID: cameraID,
            trackedPeople: enrichedPoses,
            candidates: candidates
        )
    }

    private func canFireAlert(key: String, now: TimeInterval, cooldown: Double) -> Bool {
        guard let last = lastAlertByKey[key] else { return true }
        return (now - last) >= max(1.0, cooldown)
    }

    private mutating func markAlertFired(key: String, now: TimeInterval) {
        lastAlertByKey[key] = now
    }

    private func keypointNormalized(_ keypoints: [FallKeypoint], index: Int, minConfidence: Double) -> NormalizedPoint? {
        guard keypoints.indices.contains(index) else { return nil }
        let kp = keypoints[index]
        guard kp.confidence >= minConfidence, kp.x.isFinite, kp.y.isFinite else { return nil }
        return NormalizedPoint(x: kp.x, y: kp.y)
    }

    private func boxIoU(_ a: FallBoundingBox, _ b: FallBoundingBox) -> Double {
        let left = max(a.x, b.x)
        let top = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        guard right > left, bottom > top else { return 0 }
        let inter = (right - left) * (bottom - top)
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
