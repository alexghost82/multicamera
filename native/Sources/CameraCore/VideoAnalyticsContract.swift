import CryptoKit
import Foundation

// MARK: - Engine Lifecycle & Execution Mode

public enum AnalyticsEngineState: String, Codable, CaseIterable, Sendable {
    case disabled = "DISABLED"
    case initializing = "INITIALIZING"
    case ready = "READY"
    case running = "RUNNING"
    case degraded = "DEGRADED"
    case recovering = "RECOVERING"
    case error = "ERROR"
    case stopping = "STOPPING"

    public var isOperational: Bool {
        switch self {
        case .ready, .running, .degraded, .recovering:
            return true
        case .disabled, .initializing, .error, .stopping:
            return false
        }
    }
}

public enum AnalyticsExecutionMode: String, Codable, CaseIterable, Sendable {
    case local = "LOCAL"
    case distributed = "DISTRIBUTED"
}

public enum AnalyticsSensitivityProfile: String, Codable, CaseIterable, Sendable {
    case conservative = "Conservative"
    case balanced = "Balanced"
    case highSensitivity = "High Sensitivity"
    case custom = "Custom"
}

// MARK: - Human Behavior & Fall Incident Phases

public enum HumanBehaviorState: String, Codable, CaseIterable, Sendable {
    case standing = "Standing"
    case walking = "Walking"
    case running = "Running"
    case sitting = "Sitting"
    case lying = "Lying"
    case bending = "Bending"
    case crouching = "Crouching"
    case falling = "Falling"
    case fallen = "Fallen"
    case stationary = "Stationary"
    case unknown = "Unknown"

    public var isAlertState: Bool {
        switch self {
        case .falling, .fallen:
            return true
        default:
            return false
        }
    }
}

public enum FallIncidentPhase: String, Codable, CaseIterable, Sendable {
    case normal = "NORMAL"
    case possibleFall = "POSSIBLE_FALL"
    case fallInProgress = "FALL_IN_PROGRESS"
    case fallConfirmed = "FALL_CONFIRMED"
    case personDown = "PERSON_DOWN"
    case recovered = "RECOVERED"
    case undetermined = "UNDETERMINED"

    public var isCritical: Bool {
        self == .fallConfirmed || self == .personDown
    }

    public var isElevated: Bool {
        switch self {
        case .possibleFall, .fallInProgress, .fallConfirmed, .personDown:
            return true
        case .normal, .recovered, .undetermined:
            return false
        }
    }
}

// MARK: - Safety Incident Taxonomy & Severity

public enum SafetyIncidentSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"

    private var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: SafetyIncidentSeverity, rhs: SafetyIncidentSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum SafetyIncidentType: String, Codable, CaseIterable, Sendable {
    case fallConfirmed = "FALL_CONFIRMED"
    case personDown = "PERSON_DOWN"
    case possibleUnresponsivePerson = "POSSIBLE_UNRESPONSIVE_PERSON"
    case prolongedInactivity = "PROLONGED_INACTIVITY"
    case restrictedZoneIntrusion = "RESTRICTED_ZONE_INTRUSION"
    case loitering = "LOITERING"
    case unusualMovement = "UNUSUAL_MOVEMENT"
    case abnormalCrowdActivity = "ABNORMAL_CROWD_ACTIVITY"
    case possiblePhysicalFight = "POSSIBLE_PHYSICAL_FIGHT"
    case aggressivePhysicalInteraction = "AGGRESSIVE_PHYSICAL_INTERACTION"

    public var defaultSeverity: SafetyIncidentSeverity {
        switch self {
        case .fallConfirmed, .personDown, .possibleUnresponsivePerson:
            return .critical
        case .restrictedZoneIntrusion, .possiblePhysicalFight, .aggressivePhysicalInteraction:
            return .high
        case .prolongedInactivity, .abnormalCrowdActivity, .unusualMovement:
            return .medium
        case .loitering:
            return .low
        }
    }

    public var displayTitle: String {
        switch self {
        case .fallConfirmed: return "Fall Confirmed"
        case .personDown: return "Person Down"
        case .possibleUnresponsivePerson: return "Possible Unresponsive Person"
        case .prolongedInactivity: return "Prolonged Inactivity"
        case .restrictedZoneIntrusion: return "Restricted Zone Intrusion"
        case .loitering: return "Loitering"
        case .unusualMovement: return "Unusual Movement / Running"
        case .abnormalCrowdActivity: return "Abnormal Crowd Activity"
        case .possiblePhysicalFight: return "Possible Physical Fight"
        case .aggressivePhysicalInteraction: return "Aggressive Physical Interaction"
        }
    }
}

public enum SafetyIncidentStatus: String, Codable, CaseIterable, Sendable {
    case candidate = "CANDIDATE"
    case confirmed = "CONFIRMED"
    case active = "ACTIVE"
    case acknowledged = "ACKNOWLEDGED"
    case falsePositive = "FALSE_POSITIVE"
    case suppressed = "SUPPRESSED"
    case resolved = "RESOLVED"
    case closed = "CLOSED"

    public var isOpen: Bool {
        switch self {
        case .candidate, .confirmed, .active, .acknowledged:
            return true
        case .falsePositive, .suppressed, .resolved, .closed:
            return false
        }
    }
}

// MARK: - Overlay & Restricted Zone Configuration

public struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

public struct RestrictedZoneRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var points: [NormalizedPoint]
    public var enabled: Bool
    public var holdSeconds: Double
    public var severity: SafetyIncidentSeverity

    public init(
        id: UUID = UUID(),
        name: String,
        points: [NormalizedPoint],
        enabled: Bool = true,
        holdSeconds: Double = 1.5,
        severity: SafetyIncidentSeverity = .high
    ) {
        self.id = id
        self.name = name
        self.points = points
        self.enabled = enabled
        self.holdSeconds = max(0, holdSeconds)
        self.severity = severity
    }

    public static func rectangle(
        id: UUID = UUID(),
        name: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        enabled: Bool = true,
        holdSeconds: Double = 1.5,
        severity: SafetyIncidentSeverity = .high
    ) -> RestrictedZoneRegion {
        let minX = min(max(x, 0), 1)
        let minY = min(max(y, 0), 1)
        let maxX = min(max(x + width, minX), 1)
        let maxY = min(max(y + height, minY), 1)
        return RestrictedZoneRegion(
            id: id,
            name: name,
            points: [
                NormalizedPoint(x: minX, y: minY),
                NormalizedPoint(x: maxX, y: minY),
                NormalizedPoint(x: maxX, y: maxY),
                NormalizedPoint(x: minX, y: maxY)
            ],
            enabled: enabled,
            holdSeconds: holdSeconds,
            severity: severity
        )
    }

    /// Ray-casting point-in-polygon check in normalized [0, 1] coordinates.
    public func contains(_ point: NormalizedPoint) -> Bool {
        guard enabled, points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let pi = points[i]
            let pj = points[j]
            let intersects = ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / ((pj.y - pi.y) == 0 ? 1e-9 : (pj.y - pi.y)) + pi.x)
            if intersects {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

public struct AnalyticsOverlaySettings: Codable, Equatable, Sendable {
    public var showBoundingBoxes: Bool
    public var showPoseSkeleton: Bool
    public var showTrackID: Bool
    public var showBehaviorState: Bool
    public var showFallStatus: Bool
    public var showConfidence: Bool
    public var showCriticalAlertMarker: Bool
    public var showRestrictedZones: Bool

    public init(
        showBoundingBoxes: Bool = true,
        showPoseSkeleton: Bool = true,
        showTrackID: Bool = true,
        showBehaviorState: Bool = true,
        showFallStatus: Bool = true,
        showConfidence: Bool = true,
        showCriticalAlertMarker: Bool = true,
        showRestrictedZones: Bool = true
    ) {
        self.showBoundingBoxes = showBoundingBoxes
        self.showPoseSkeleton = showPoseSkeleton
        self.showTrackID = showTrackID
        self.showBehaviorState = showBehaviorState
        self.showFallStatus = showFallStatus
        self.showConfidence = showConfidence
        self.showCriticalAlertMarker = showCriticalAlertMarker
        self.showRestrictedZones = showRestrictedZones
    }
}

// MARK: - Per-Camera & Global Analytics Settings

public struct CameraAnalyticsOverride: Codable, Equatable, Identifiable, Sendable {
    public var cameraID: UUID
    public var inheritGlobalSettings: Bool
    public var analyticsEnabled: Bool
    public var personDetectionEnabled: Bool
    public var poseEstimationEnabled: Bool
    public var fallDetectionEnabled: Bool
    public var behaviorAnalysisEnabled: Bool
    public var inactivityDetectionEnabled: Bool
    public var loiteringDetectionEnabled: Bool
    public var zoneMonitoringEnabled: Bool
    public var fightDetectionEnabled: Bool
    public var secondaryVLMVerificationEnabled: Bool
    public var sensitivityProfile: AnalyticsSensitivityProfile
    public var customSamplingFPS: Double?
    public var customAlertCooldownSeconds: Double?
    public var restrictedZones: [RestrictedZoneRegion]

    public var id: UUID { cameraID }

    public init(
        cameraID: UUID,
        inheritGlobalSettings: Bool = true,
        analyticsEnabled: Bool = true,
        personDetectionEnabled: Bool = true,
        poseEstimationEnabled: Bool = true,
        fallDetectionEnabled: Bool = true,
        behaviorAnalysisEnabled: Bool = true,
        inactivityDetectionEnabled: Bool = true,
        loiteringDetectionEnabled: Bool = true,
        zoneMonitoringEnabled: Bool = true,
        fightDetectionEnabled: Bool = false,
        secondaryVLMVerificationEnabled: Bool = false,
        sensitivityProfile: AnalyticsSensitivityProfile = .balanced,
        customSamplingFPS: Double? = nil,
        customAlertCooldownSeconds: Double? = nil,
        restrictedZones: [RestrictedZoneRegion] = []
    ) {
        self.cameraID = cameraID
        self.inheritGlobalSettings = inheritGlobalSettings
        self.analyticsEnabled = analyticsEnabled
        self.personDetectionEnabled = personDetectionEnabled
        self.poseEstimationEnabled = poseEstimationEnabled
        self.fallDetectionEnabled = fallDetectionEnabled
        self.behaviorAnalysisEnabled = behaviorAnalysisEnabled
        self.inactivityDetectionEnabled = inactivityDetectionEnabled
        self.loiteringDetectionEnabled = loiteringDetectionEnabled
        self.zoneMonitoringEnabled = zoneMonitoringEnabled
        self.fightDetectionEnabled = fightDetectionEnabled
        self.secondaryVLMVerificationEnabled = secondaryVLMVerificationEnabled
        self.sensitivityProfile = sensitivityProfile
        self.customSamplingFPS = customSamplingFPS
        self.customAlertCooldownSeconds = customAlertCooldownSeconds
        self.restrictedZones = restrictedZones
    }
}

public struct EffectiveCameraAnalyticsConfig: Codable, Equatable, Sendable {
    public let cameraID: UUID
    public let analyticsEnabled: Bool
    public let personDetectionEnabled: Bool
    public let poseEstimationEnabled: Bool
    public let fallDetectionEnabled: Bool
    public let behaviorAnalysisEnabled: Bool
    public let inactivityDetectionEnabled: Bool
    public let loiteringDetectionEnabled: Bool
    public let zoneMonitoringEnabled: Bool
    public let unusualMovementEnabled: Bool
    public let crowdActivityEnabled: Bool
    public let fightDetectionEnabled: Bool
    public let secondaryVLMVerificationEnabled: Bool
    public let samplingFPS: Double
    public let idleSamplingFPS: Double
    public let activeFallBoostFPS: Double
    public let personConfidenceThreshold: Double
    public let poseKeypointConfidenceThreshold: Double
    public let fallConfirmationSeconds: Double
    public let personDownSeconds: Double
    public let inactivityThresholdSeconds: Double
    public let loiteringThresholdSeconds: Double
    public let minimumVisibleKeypoints: Int
    public let alertCooldownSeconds: Double
    public let restrictedZones: [RestrictedZoneRegion]
}

public enum VideoAnalyticsSettingsValidationError: LocalizedError, Equatable, Sendable {
    case invalidPersonConfidence(Double)
    case invalidPoseKeypointConfidence(Double)
    case invalidSamplingFPS(Double)
    case invalidFallConfirmationSeconds(Double)
    case invalidPersonDownSeconds(Double)
    case invalidInactivityThresholdSeconds(Double)
    case invalidLoiteringThresholdSeconds(Double)
    case invalidMinimumVisibleKeypoints(Int)
    case invalidAlertCooldownSeconds(Double)
    case invalidBufferSeconds(Double)
    case invalidEvidenceDiskQuotaMB(Int)
    case invalidMaxConcurrentInferenceTasks(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPersonConfidence(let v):
            return "Person confidence threshold (\(v)) must be between 0.15 and 0.95."
        case .invalidPoseKeypointConfidence(let v):
            return "Pose keypoint confidence threshold (\(v)) must be between 0.10 and 0.90."
        case .invalidSamplingFPS(let v):
            return "Analytics sampling FPS (\(v)) must be between 0.5 and 15.0."
        case .invalidFallConfirmationSeconds(let v):
            return "Fall confirmation duration (\(v)s) must be between 0.3 and 10.0 seconds."
        case .invalidPersonDownSeconds(let v):
            return "Person-down duration (\(v)s) must be between 2.0 and 300.0 seconds."
        case .invalidInactivityThresholdSeconds(let v):
            return "Inactivity threshold (\(v)s) must be between 5.0 and 3600.0 seconds."
        case .invalidLoiteringThresholdSeconds(let v):
            return "Loitering threshold (\(v)s) must be between 10.0 and 7200.0 seconds."
        case .invalidMinimumVisibleKeypoints(let v):
            return "Minimum visible keypoints (\(v)) must be between 4 and 17."
        case .invalidAlertCooldownSeconds(let v):
            return "Alert cooldown (\(v)s) must be between 2.0 and 3600.0 seconds."
        case .invalidBufferSeconds(let v):
            return "Evidence buffer duration (\(v)s) must be between 1.0 and 30.0 seconds."
        case .invalidEvidenceDiskQuotaMB(let v):
            return "Evidence disk quota (\(v) MB) must be between 64 and 65536 MB."
        case .invalidMaxConcurrentInferenceTasks(let v):
            return "Max concurrent inference tasks (\(v)) must be between 1 and 8."
        }
    }
}

public struct VideoAnalyticsSettings: Codable, Equatable, Sendable {
    // Level 1: Global Basic Settings
    public var globalEnabled: Bool
    public var executionMode: AnalyticsExecutionMode
    public var enablePersonDetection: Bool
    public var enablePoseEstimation: Bool
    public var enableFallDetection: Bool
    public var enableBehaviorAnalysis: Bool
    public var enableProlongedInactivity: Bool
    public var enableLoiteringDetection: Bool
    public var enableZoneMonitoring: Bool
    public var enableUnusualMovement: Bool
    public var enableCrowdActivity: Bool
    public var enableFightDetection: Bool
    public var enableSecondaryVLMVerification: Bool
    public var enableSoundAlert: Bool
    public var enableVisualAlertBanner: Bool
    public var enableEvidenceRecording: Bool
    public var sensitivityProfile: AnalyticsSensitivityProfile
    public var overlaySettings: AnalyticsOverlaySettings

    // Level 2: Per-Camera Settings
    public var cameraOverrides: [UUID: CameraAnalyticsOverride]

    // Level 3: Advanced Settings
    public var personConfidenceThreshold: Double
    public var poseKeypointConfidenceThreshold: Double
    public var analyticsSamplingFPS: Double
    public var idleCameraSamplingFPS: Double
    public var activeFallBoostFPS: Double
    public var fallConfirmationSeconds: Double
    public var personDownSeconds: Double
    public var inactivityThresholdSeconds: Double
    public var loiteringThresholdSeconds: Double
    public var minimumVisibleKeypoints: Int
    public var alertCooldownSeconds: Double
    public var preEventBufferSeconds: Double
    public var postEventBufferSeconds: Double
    public var maxEvidenceDiskQuotaMB: Int
    public var maxConcurrentInferenceTasks: Int

    public init(
        globalEnabled: Bool = true,
        executionMode: AnalyticsExecutionMode = .local,
        enablePersonDetection: Bool = true,
        enablePoseEstimation: Bool = true,
        enableFallDetection: Bool = true,
        enableBehaviorAnalysis: Bool = true,
        enableProlongedInactivity: Bool = true,
        enableLoiteringDetection: Bool = true,
        enableZoneMonitoring: Bool = true,
        enableUnusualMovement: Bool = true,
        enableCrowdActivity: Bool = true,
        enableFightDetection: Bool = false,
        enableSecondaryVLMVerification: Bool = false,
        enableSoundAlert: Bool = false,
        enableVisualAlertBanner: Bool = true,
        enableEvidenceRecording: Bool = true,
        sensitivityProfile: AnalyticsSensitivityProfile = .balanced,
        overlaySettings: AnalyticsOverlaySettings = AnalyticsOverlaySettings(),
        cameraOverrides: [UUID: CameraAnalyticsOverride] = [:],
        personConfidenceThreshold: Double = 0.35,
        poseKeypointConfidenceThreshold: Double = 0.25,
        analyticsSamplingFPS: Double = 4.0,
        idleCameraSamplingFPS: Double = 1.5,
        activeFallBoostFPS: Double = 8.0,
        fallConfirmationSeconds: Double = 0.8,
        personDownSeconds: Double = 10.0,
        inactivityThresholdSeconds: Double = 30.0,
        loiteringThresholdSeconds: Double = 120.0,
        minimumVisibleKeypoints: Int = 6,
        alertCooldownSeconds: Double = 30.0,
        preEventBufferSeconds: Double = 8.0,
        postEventBufferSeconds: Double = 6.0,
        maxEvidenceDiskQuotaMB: Int = 2048,
        maxConcurrentInferenceTasks: Int = 2
    ) {
        self.globalEnabled = globalEnabled
        self.executionMode = executionMode
        self.enablePersonDetection = enablePersonDetection
        self.enablePoseEstimation = enablePoseEstimation
        self.enableFallDetection = enableFallDetection
        self.enableBehaviorAnalysis = enableBehaviorAnalysis
        self.enableProlongedInactivity = enableProlongedInactivity
        self.enableLoiteringDetection = enableLoiteringDetection
        self.enableZoneMonitoring = enableZoneMonitoring
        self.enableUnusualMovement = enableUnusualMovement
        self.enableCrowdActivity = enableCrowdActivity
        self.enableFightDetection = enableFightDetection
        self.enableSecondaryVLMVerification = enableSecondaryVLMVerification
        self.enableSoundAlert = enableSoundAlert
        self.enableVisualAlertBanner = enableVisualAlertBanner
        self.enableEvidenceRecording = enableEvidenceRecording
        self.sensitivityProfile = sensitivityProfile
        self.overlaySettings = overlaySettings
        self.cameraOverrides = cameraOverrides
        self.personConfidenceThreshold = personConfidenceThreshold
        self.poseKeypointConfidenceThreshold = poseKeypointConfidenceThreshold
        self.analyticsSamplingFPS = analyticsSamplingFPS
        self.idleCameraSamplingFPS = idleCameraSamplingFPS
        self.activeFallBoostFPS = activeFallBoostFPS
        self.fallConfirmationSeconds = fallConfirmationSeconds
        self.personDownSeconds = personDownSeconds
        self.inactivityThresholdSeconds = inactivityThresholdSeconds
        self.loiteringThresholdSeconds = loiteringThresholdSeconds
        self.minimumVisibleKeypoints = minimumVisibleKeypoints
        self.alertCooldownSeconds = alertCooldownSeconds
        self.preEventBufferSeconds = preEventBufferSeconds
        self.postEventBufferSeconds = postEventBufferSeconds
        self.maxEvidenceDiskQuotaMB = maxEvidenceDiskQuotaMB
        self.maxConcurrentInferenceTasks = maxConcurrentInferenceTasks
    }

    public static let safeDefaults = VideoAnalyticsSettings()

    public mutating func applySensitivityProfile(_ profile: AnalyticsSensitivityProfile) {
        sensitivityProfile = profile
        switch profile {
        case .conservative:
            personConfidenceThreshold = 0.45
            poseKeypointConfidenceThreshold = 0.35
            fallConfirmationSeconds = 1.2
            personDownSeconds = 15.0
            inactivityThresholdSeconds = 45.0
            minimumVisibleKeypoints = 7
        case .balanced:
            personConfidenceThreshold = 0.35
            poseKeypointConfidenceThreshold = 0.25
            fallConfirmationSeconds = 0.8
            personDownSeconds = 10.0
            inactivityThresholdSeconds = 30.0
            minimumVisibleKeypoints = 6
        case .highSensitivity:
            personConfidenceThreshold = 0.25
            poseKeypointConfidenceThreshold = 0.20
            fallConfirmationSeconds = 0.6
            personDownSeconds = 6.0
            inactivityThresholdSeconds = 20.0
            minimumVisibleKeypoints = 5
        case .custom:
            break
        }
    }

    public func validate() throws {
        guard idleCameraSamplingFPS.isFinite, idleCameraSamplingFPS >= 0.5, idleCameraSamplingFPS <= analyticsSamplingFPS,
              activeFallBoostFPS.isFinite, activeFallBoostFPS >= analyticsSamplingFPS, activeFallBoostFPS <= 30 else {
            throw ConfigurationError.invalid("Check idle and boosted analytics sampling rates.")
        }
        for (id, override) in cameraOverrides {
            guard id == override.cameraID,
                  override.customSamplingFPS.map({ $0.isFinite && (0.5...15).contains($0) }) ?? true,
                  override.customAlertCooldownSeconds.map({ $0.isFinite && (2...3600).contains($0) }) ?? true else {
                throw ConfigurationError.invalid("Check per-camera sampling and cooldown overrides.")
            }
            for zone in override.restrictedZones {
                guard !zone.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      (3...64).contains(zone.points.count), zone.holdSeconds.isFinite, zone.holdSeconds >= 0,
                      zone.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                    throw ConfigurationError.invalid("Check zone names, polygon coordinates and hold time.")
                }
            }
        }

        guard personConfidenceThreshold.isFinite, (0.15...0.95).contains(personConfidenceThreshold) else {
            throw VideoAnalyticsSettingsValidationError.invalidPersonConfidence(personConfidenceThreshold)
        }
        guard poseKeypointConfidenceThreshold.isFinite, (0.10...0.90).contains(poseKeypointConfidenceThreshold) else {
            throw VideoAnalyticsSettingsValidationError.invalidPoseKeypointConfidence(poseKeypointConfidenceThreshold)
        }
        guard analyticsSamplingFPS.isFinite, (0.5...15.0).contains(analyticsSamplingFPS) else {
            throw VideoAnalyticsSettingsValidationError.invalidSamplingFPS(analyticsSamplingFPS)
        }
        guard fallConfirmationSeconds.isFinite, (0.3...10.0).contains(fallConfirmationSeconds) else {
            throw VideoAnalyticsSettingsValidationError.invalidFallConfirmationSeconds(fallConfirmationSeconds)
        }
        guard personDownSeconds.isFinite, (2.0...300.0).contains(personDownSeconds) else {
            throw VideoAnalyticsSettingsValidationError.invalidPersonDownSeconds(personDownSeconds)
        }
        guard inactivityThresholdSeconds.isFinite, (5.0...3600.0).contains(inactivityThresholdSeconds) else {
            throw VideoAnalyticsSettingsValidationError.invalidInactivityThresholdSeconds(inactivityThresholdSeconds)
        }
        guard loiteringThresholdSeconds.isFinite, (10.0...7200.0).contains(loiteringThresholdSeconds) else {
            throw VideoAnalyticsSettingsValidationError.invalidLoiteringThresholdSeconds(loiteringThresholdSeconds)
        }
        guard (4...17).contains(minimumVisibleKeypoints) else {
            throw VideoAnalyticsSettingsValidationError.invalidMinimumVisibleKeypoints(minimumVisibleKeypoints)
        }
        guard alertCooldownSeconds.isFinite, (2.0...3600.0).contains(alertCooldownSeconds) else {
            throw VideoAnalyticsSettingsValidationError.invalidAlertCooldownSeconds(alertCooldownSeconds)
        }
        guard preEventBufferSeconds.isFinite, (1.0...30.0).contains(preEventBufferSeconds),
              postEventBufferSeconds.isFinite, (1.0...30.0).contains(postEventBufferSeconds) else {
            throw VideoAnalyticsSettingsValidationError.invalidBufferSeconds(
                !preEventBufferSeconds.isFinite || !(1.0...30.0).contains(preEventBufferSeconds)
                    ? preEventBufferSeconds : postEventBufferSeconds
            )
        }
        guard (64...65536).contains(maxEvidenceDiskQuotaMB) else {
            throw VideoAnalyticsSettingsValidationError.invalidEvidenceDiskQuotaMB(maxEvidenceDiskQuotaMB)
        }
        guard (1...8).contains(maxConcurrentInferenceTasks) else {
            throw VideoAnalyticsSettingsValidationError.invalidMaxConcurrentInferenceTasks(maxConcurrentInferenceTasks)
        }
    }

    public func clamped() -> VideoAnalyticsSettings {
        var copy = self
        copy.personConfidenceThreshold = min(max(personConfidenceThreshold, 0.15), 0.95)
        copy.poseKeypointConfidenceThreshold = min(max(poseKeypointConfidenceThreshold, 0.10), 0.90)
        copy.analyticsSamplingFPS = min(max(analyticsSamplingFPS, 0.5), 15.0)
        copy.idleCameraSamplingFPS = min(max(idleCameraSamplingFPS, 0.5), copy.analyticsSamplingFPS)
        copy.activeFallBoostFPS = min(max(activeFallBoostFPS, copy.analyticsSamplingFPS), 15.0)
        copy.fallConfirmationSeconds = min(max(fallConfirmationSeconds, 0.3), 10.0)
        copy.personDownSeconds = min(max(personDownSeconds, 2.0), 300.0)
        copy.inactivityThresholdSeconds = min(max(inactivityThresholdSeconds, 5.0), 3600.0)
        copy.loiteringThresholdSeconds = min(max(loiteringThresholdSeconds, 10.0), 7200.0)
        copy.minimumVisibleKeypoints = min(max(minimumVisibleKeypoints, 4), 17)
        copy.alertCooldownSeconds = min(max(alertCooldownSeconds, 2.0), 3600.0)
        copy.preEventBufferSeconds = min(max(preEventBufferSeconds, 1.0), 30.0)
        copy.postEventBufferSeconds = min(max(postEventBufferSeconds, 1.0), 30.0)
        copy.maxEvidenceDiskQuotaMB = min(max(maxEvidenceDiskQuotaMB, 64), 65536)
        copy.maxConcurrentInferenceTasks = min(max(maxConcurrentInferenceTasks, 1), 8)
        return copy
    }

    public func effectiveConfiguration(for cameraID: UUID, cameraYOLOEnabled: Bool = true) -> EffectiveCameraAnalyticsConfig {
        let override = cameraOverrides[cameraID]
        let restrictedZones = override?.restrictedZones ?? []
        if let override, !override.inheritGlobalSettings {
            var profileSettings = self
            if override.sensitivityProfile != .custom && override.sensitivityProfile != self.sensitivityProfile {
                profileSettings.applySensitivityProfile(override.sensitivityProfile)
            }
            let enabled = globalEnabled && override.analyticsEnabled && cameraYOLOEnabled
            let fps = override.customSamplingFPS.map { min(max($0, 0.5), 15.0) } ?? profileSettings.analyticsSamplingFPS
            let cooldown = override.customAlertCooldownSeconds.map { min(max($0, 2.0), 3600.0) } ?? profileSettings.alertCooldownSeconds
            return EffectiveCameraAnalyticsConfig(
                cameraID: cameraID,
                analyticsEnabled: enabled,
                personDetectionEnabled: enabled && override.personDetectionEnabled,
                poseEstimationEnabled: enabled && override.poseEstimationEnabled,
                fallDetectionEnabled: enabled && override.poseEstimationEnabled && override.fallDetectionEnabled,
                behaviorAnalysisEnabled: enabled && override.behaviorAnalysisEnabled,
                inactivityDetectionEnabled: enabled && override.behaviorAnalysisEnabled && override.inactivityDetectionEnabled,
                loiteringDetectionEnabled: enabled && override.behaviorAnalysisEnabled && override.loiteringDetectionEnabled,
                zoneMonitoringEnabled: enabled && override.zoneMonitoringEnabled,
                unusualMovementEnabled: enabled && override.behaviorAnalysisEnabled && enableUnusualMovement,
                crowdActivityEnabled: enabled && enableCrowdActivity,
                fightDetectionEnabled: enabled && override.behaviorAnalysisEnabled && override.fightDetectionEnabled,
                secondaryVLMVerificationEnabled: enabled && override.secondaryVLMVerificationEnabled,
                samplingFPS: fps,
                idleSamplingFPS: min(profileSettings.idleCameraSamplingFPS, fps),
                activeFallBoostFPS: max(profileSettings.activeFallBoostFPS, fps),
                personConfidenceThreshold: profileSettings.personConfidenceThreshold,
                poseKeypointConfidenceThreshold: profileSettings.poseKeypointConfidenceThreshold,
                fallConfirmationSeconds: profileSettings.fallConfirmationSeconds,
                personDownSeconds: profileSettings.personDownSeconds,
                inactivityThresholdSeconds: profileSettings.inactivityThresholdSeconds,
                loiteringThresholdSeconds: profileSettings.loiteringThresholdSeconds,
                minimumVisibleKeypoints: profileSettings.minimumVisibleKeypoints,
                alertCooldownSeconds: cooldown,
                restrictedZones: restrictedZones
            )
        }

        let enabled = globalEnabled && cameraYOLOEnabled
        return EffectiveCameraAnalyticsConfig(
            cameraID: cameraID,
            analyticsEnabled: enabled,
            personDetectionEnabled: enabled && enablePersonDetection,
            poseEstimationEnabled: enabled && enablePoseEstimation,
            fallDetectionEnabled: enabled && enablePoseEstimation && enableFallDetection,
            behaviorAnalysisEnabled: enabled && enableBehaviorAnalysis,
            inactivityDetectionEnabled: enabled && enableBehaviorAnalysis && enableProlongedInactivity,
            loiteringDetectionEnabled: enabled && enableBehaviorAnalysis && enableLoiteringDetection,
            zoneMonitoringEnabled: enabled && enableZoneMonitoring,
            unusualMovementEnabled: enabled && enableBehaviorAnalysis && enableUnusualMovement,
            crowdActivityEnabled: enabled && enableCrowdActivity,
            fightDetectionEnabled: enabled && enableBehaviorAnalysis && enableFightDetection,
            secondaryVLMVerificationEnabled: enabled && enableSecondaryVLMVerification,
            samplingFPS: analyticsSamplingFPS,
            idleSamplingFPS: min(idleCameraSamplingFPS, analyticsSamplingFPS),
            activeFallBoostFPS: max(activeFallBoostFPS, analyticsSamplingFPS),
            personConfidenceThreshold: personConfidenceThreshold,
            poseKeypointConfidenceThreshold: poseKeypointConfidenceThreshold,
            fallConfirmationSeconds: fallConfirmationSeconds,
            personDownSeconds: personDownSeconds,
            inactivityThresholdSeconds: inactivityThresholdSeconds,
            loiteringThresholdSeconds: loiteringThresholdSeconds,
            minimumVisibleKeypoints: minimumVisibleKeypoints,
            alertCooldownSeconds: alertCooldownSeconds,
            restrictedZones: restrictedZones
        )
    }
}

public enum VideoAnalyticsSettingsStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/video-analytics-settings.json")
    }

    public static func load(from url: URL = defaultURL) throws -> VideoAnalyticsSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .safeDefaults
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(VideoAnalyticsSettings.self, from: data)
        return decoded.clamped()
    }

    public static func save(_ settings: VideoAnalyticsSettings, to url: URL = defaultURL) throws {
        try settings.validate()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Live Tracked Person Pose & Per-Camera Analytics Snapshot

public struct TrackedPersonPose: Codable, Equatable, Identifiable, Sendable {
    public let trackID: UUID
    public let cameraID: UUID
    public let box: FallBoundingBox
    public let confidence: Double
    public let keypoints: [FallKeypoint]
    public let visibleKeypointCount: Int
    public let behaviorState: HumanBehaviorState
    public let fallState: FallPersonState
    public let fallPhase: FallIncidentPhase
    public let torsoAngleDegrees: Double?
    public let aspectRatio: Double
    public let heightRatio: Double?
    public let verticalVelocity: Double
    public let angularVelocityDegreesPerSecond: Double
    public let speedBodyHeightsPerSecond: Double
    public let stationaryDurationSeconds: Double
    public let downDurationSeconds: Double
    public let dwellDurationSeconds: Double
    public let activeZoneIDs: [UUID]
    public let isPartiallyOccluded: Bool
    public let hasCriticalAlert: Bool

    public var id: UUID { trackID }

    public init(
        trackID: UUID,
        cameraID: UUID,
        box: FallBoundingBox,
        confidence: Double,
        keypoints: [FallKeypoint],
        visibleKeypointCount: Int,
        behaviorState: HumanBehaviorState,
        fallState: FallPersonState,
        fallPhase: FallIncidentPhase,
        torsoAngleDegrees: Double? = nil,
        aspectRatio: Double = 0.5,
        heightRatio: Double? = nil,
        verticalVelocity: Double = 0,
        angularVelocityDegreesPerSecond: Double = 0,
        speedBodyHeightsPerSecond: Double = 0,
        stationaryDurationSeconds: Double = 0,
        downDurationSeconds: Double = 0,
        dwellDurationSeconds: Double = 0,
        activeZoneIDs: [UUID] = [],
        isPartiallyOccluded: Bool = false,
        hasCriticalAlert: Bool = false
    ) {
        self.trackID = trackID
        self.cameraID = cameraID
        self.box = box
        self.confidence = confidence
        self.keypoints = keypoints
        self.visibleKeypointCount = visibleKeypointCount
        self.behaviorState = behaviorState
        self.fallState = fallState
        self.fallPhase = fallPhase
        self.torsoAngleDegrees = torsoAngleDegrees
        self.aspectRatio = aspectRatio
        self.heightRatio = heightRatio
        self.verticalVelocity = verticalVelocity
        self.angularVelocityDegreesPerSecond = angularVelocityDegreesPerSecond
        self.speedBodyHeightsPerSecond = speedBodyHeightsPerSecond
        self.stationaryDurationSeconds = stationaryDurationSeconds
        self.downDurationSeconds = downDurationSeconds
        self.dwellDurationSeconds = dwellDurationSeconds
        self.activeZoneIDs = activeZoneIDs
        self.isPartiallyOccluded = isPartiallyOccluded
        self.hasCriticalAlert = hasCriticalAlert
    }

    public static let skeletonConnections: [(Int, Int)] = [
        (FallPoseObservation.nose, FallPoseObservation.leftEye),
        (FallPoseObservation.nose, FallPoseObservation.rightEye),
        (FallPoseObservation.leftEye, FallPoseObservation.leftEar),
        (FallPoseObservation.rightEye, FallPoseObservation.rightEar),
        (FallPoseObservation.leftShoulder, FallPoseObservation.rightShoulder),
        (FallPoseObservation.leftShoulder, FallPoseObservation.leftElbow),
        (FallPoseObservation.leftElbow, FallPoseObservation.leftWrist),
        (FallPoseObservation.rightShoulder, FallPoseObservation.rightElbow),
        (FallPoseObservation.rightElbow, FallPoseObservation.rightWrist),
        (FallPoseObservation.leftShoulder, FallPoseObservation.leftHip),
        (FallPoseObservation.rightShoulder, FallPoseObservation.rightHip),
        (FallPoseObservation.leftHip, FallPoseObservation.rightHip),
        (FallPoseObservation.leftHip, FallPoseObservation.leftKnee),
        (FallPoseObservation.leftKnee, FallPoseObservation.leftAnkle),
        (FallPoseObservation.rightHip, FallPoseObservation.rightKnee),
        (FallPoseObservation.rightKnee, FallPoseObservation.rightAnkle)
    ]
}

public struct CameraAnalyticsTelemetry: Codable, Equatable, Sendable {
    public let cameraID: UUID
    public var analyticsFPS: Double
    public var lastInferenceLatencyMs: Double
    public var averageInferenceLatencyMs: Double
    public var processedFrames: Int
    public var droppedFrames: Int
    public var activePersonTracks: Int
    public var lastProcessedAt: Date?
    public var hasElevatedFallPhase: Bool
    public var hasActiveIncident: Bool

    public init(
        cameraID: UUID,
        analyticsFPS: Double = 0,
        lastInferenceLatencyMs: Double = 0,
        averageInferenceLatencyMs: Double = 0,
        processedFrames: Int = 0,
        droppedFrames: Int = 0,
        activePersonTracks: Int = 0,
        lastProcessedAt: Date? = nil,
        hasElevatedFallPhase: Bool = false,
        hasActiveIncident: Bool = false
    ) {
        self.cameraID = cameraID
        self.analyticsFPS = analyticsFPS
        self.lastInferenceLatencyMs = lastInferenceLatencyMs
        self.averageInferenceLatencyMs = averageInferenceLatencyMs
        self.processedFrames = processedFrames
        self.droppedFrames = droppedFrames
        self.activePersonTracks = activePersonTracks
        self.lastProcessedAt = lastProcessedAt
        self.hasElevatedFallPhase = hasElevatedFallPhase
        self.hasActiveIncident = hasActiveIncident
    }
}

// MARK: - Model Registry & Checksum Verification

public enum AnalyticsModelID: String, Codable, CaseIterable, Identifiable, Sendable {
    case yoloObject = "yolo26n"
    case yoloPose = "yolo26s-pose"
    case yoloSegmentation = "yolo26n-seg"
    case personReID = "yolo26m-reid"
    case vehicleReID = "osnet-vehicle-reid"
    case qwenVLM = "qwen3.5-9b"
    case fightClassifier = "fight-action-classifier"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yoloObject: return "YOLO26n Object Detection"
        case .yoloPose: return "YOLO26s-Pose (COCO-17 Keypoints)"
        case .yoloSegmentation: return "YOLO26n Instance Segmentation"
        case .personReID: return "YOLO26m Person Re-ID"
        case .vehicleReID: return "OSNet Vehicle Re-ID"
        case .qwenVLM: return "Qwen3.5-9B Multimodal VLM"
        case .fightClassifier: return "Dedicated Fight Action Classifier"
        }
    }

    public var isRequiredForSafetyEngine: Bool {
        switch self {
        case .yoloObject, .yoloPose:
            return true
        case .yoloSegmentation, .personReID, .vehicleReID, .qwenVLM, .fightClassifier:
            return false
        }
    }
}

public enum AnalyticsModelStatus: String, Codable, CaseIterable, Sendable {
    case ready = "READY"
    case loading = "LOADING"
    case missing = "MISSING"
    case corruptedChecksum = "CORRUPTED_CHECKSUM"
    case modelNotValidated = "MODEL_NOT_VALIDATED"
    case disabled = "DISABLED"
    case error = "ERROR"
}

public struct AnalyticsModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let modelID: AnalyticsModelID
    public var version: String
    public var status: AnalyticsModelStatus
    public var backend: String
    public var filePath: String?
    public var sizeBytes: Int64
    public var sha256Checksum: String?
    public var expectedSHA256Checksum: String?
    public var loadDurationMs: Double?
    public var averageLatencyMs: Double?
    public var statusReason: String

    public var id: AnalyticsModelID { modelID }

    public init(
        modelID: AnalyticsModelID,
        version: String = "1.0",
        status: AnalyticsModelStatus,
        backend: String,
        filePath: String? = nil,
        sizeBytes: Int64 = 0,
        sha256Checksum: String? = nil,
        expectedSHA256Checksum: String? = nil,
        loadDurationMs: Double? = nil,
        averageLatencyMs: Double? = nil,
        statusReason: String = ""
    ) {
        self.modelID = modelID
        self.version = version
        self.status = status
        self.backend = backend
        self.filePath = filePath
        self.sizeBytes = sizeBytes
        self.sha256Checksum = sha256Checksum
        self.expectedSHA256Checksum = expectedSHA256Checksum
        self.loadDurationMs = loadDurationMs
        self.averageLatencyMs = averageLatencyMs
        self.statusReason = statusReason
    }
}

public enum ModelIntegrityVerifier {
    /// Computes SHA-256 of a file or, for a directory bundle (`.mlmodelc` / `.mlpackage`), the primary weight file inside.
    public static func computeSHA256(at url: URL) throws -> (hash: String, sizeBytes: Int64) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !isDirectory.boolValue {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return (hex, Int64(data.count))
        }

        // For .mlmodelc / .mlpackage directory bundles, hash the deterministic weight/coremldata files
        let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var regularFiles: [URL] = []
        var totalSize: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                regularFiles.append(fileURL)
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        guard !regularFiles.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        regularFiles.sort { $0.path < $1.path }
        var hasher = SHA256()
        for fileURL in regularFiles {
            let relPath = fileURL.path.replacingOccurrences(of: url.path, with: "")
            hasher.update(data: Data(relPath.utf8))
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, totalSize)
    }
}
