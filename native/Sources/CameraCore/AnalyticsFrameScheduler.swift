import Foundation

public enum CameraSchedulingActivityTier: Int, Codable, Comparable, Sendable {
    case idle = 0
    case activePerson = 1
    case elevatedSafety = 2

    public static func < (lhs: CameraSchedulingActivityTier, rhs: CameraSchedulingActivityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ScheduledCameraWorkItem<FramePayload: Sendable>: Sendable {
    public let cameraID: UUID
    public let payload: FramePayload
    public let frameWidth: Int
    public let frameHeight: Int
    public let monotonicTimestamp: TimeInterval
    public let activityTier: CameraSchedulingActivityTier
    public let effectiveConfig: EffectiveCameraAnalyticsConfig

    public init(
        cameraID: UUID,
        payload: FramePayload,
        frameWidth: Int,
        frameHeight: Int,
        monotonicTimestamp: TimeInterval,
        activityTier: CameraSchedulingActivityTier,
        effectiveConfig: EffectiveCameraAnalyticsConfig
    ) {
        self.cameraID = cameraID
        self.payload = payload
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.monotonicTimestamp = monotonicTimestamp
        self.activityTier = activityTier
        self.effectiveConfig = effectiveConfig
    }
}

/// Bounded (1-slot-per-camera), starvation-free scheduler for up to 64 video streams.
public final class AnalyticsFrameScheduler<FramePayload: Sendable>: @unchecked Sendable {
    private struct PendingSlot {
        var payload: FramePayload
        var frameWidth: Int
        var frameHeight: Int
        var enqueuedAt: TimeInterval
    }

    private struct CameraScheduleState {
        var activityTier: CameraSchedulingActivityTier = .idle
        var lastDispatchedAt: TimeInterval?
        var lastCompletedAt: TimeInterval?
        var smoothedFPS: Double = 0
        var lastLatencyMs: Double = 0
        var smoothedLatencyMs: Double = 0
        var processedFrames: Int = 0
        var droppedFrames: Int = 0
        var activePersonTracks: Int = 0
        var hasElevatedFallPhase: Bool = false
        var hasActiveIncident: Bool = false
        var isInFlight: Bool = false
    }

    private let lock = NSLock()
    private var pendingByCamera: [UUID: PendingSlot] = [:]
    private var stateByCamera: [UUID: CameraScheduleState] = [:]
    private var cameraOrder: [UUID] = []
    private var roundRobinCursor: Int = 0
    private var inFlightTasks: Int = 0
    private var thermalDegradationFactor: Double = 1.0

    public init() {}

    /// Sets a thermal/load throttling factor in `(0.25 ... 1.0]`.
    /// When `< 1.0`, idle and normal camera FPS budgets are scaled down while preserving elevated safety priority.
    public func setThermalDegradationFactor(_ factor: Double) {
        lock.lock()
        defer { lock.unlock() }
        thermalDegradationFactor = min(max(factor, 0.25), 1.0)
    }

    public var currentThermalDegradationFactor: Double {
        lock.lock()
        defer { lock.unlock() }
        return thermalDegradationFactor
    }

    /// Enqueues or replaces the single latest frame for `cameraID`.
    /// Returns `true` if accepted into the 1-frame slot, or `false` if analytics is disabled for this camera.
    @discardableResult
    public func offerFrame(
        cameraID: UUID,
        payload: FramePayload,
        frameWidth: Int,
        frameHeight: Int,
        monotonicTimestamp: TimeInterval,
        effectiveConfig: EffectiveCameraAnalyticsConfig
    ) -> Bool {
        guard effectiveConfig.analyticsEnabled, frameWidth > 0, frameHeight > 0, monotonicTimestamp.isFinite else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }

        if stateByCamera[cameraID] == nil {
            stateByCamera[cameraID] = CameraScheduleState()
            cameraOrder.append(cameraID)
        }

        if pendingByCamera[cameraID] != nil {
            // Bounded 1-frame buffer per camera: drop the older unconsumed frame
            stateByCamera[cameraID]?.droppedFrames += 1
        }
        pendingByCamera[cameraID] = PendingSlot(
            payload: payload,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            enqueuedAt: monotonicTimestamp
        )
        return true
    }

    /// Selects the next camera ready for inference using priority-boosted fair round-robin.
    public func popNextReadyWorkItem(
        now: TimeInterval,
        settings: VideoAnalyticsSettings,
        cameraYOLOEnabled: [UUID: Bool] = [:]
    ) -> ScheduledCameraWorkItem<FramePayload>? {
        lock.lock()
        defer { lock.unlock() }

        guard settings.globalEnabled,
              inFlightTasks < max(1, settings.maxConcurrentInferenceTasks),
              !pendingByCamera.isEmpty,
              !cameraOrder.isEmpty else {
            return nil
        }

        let count = cameraOrder.count
        var bestIndex: Int?
        var bestScore: Double = -Double.infinity
        var bestEffectiveConfig: EffectiveCameraAnalyticsConfig?

        for offset in 0..<count {
            let idx = (roundRobinCursor + offset) % count
            let cameraID = cameraOrder[idx]
            guard let slot = pendingByCamera[cameraID],
                  let state = stateByCamera[cameraID],
                  !state.isInFlight else {
                continue
            }
            let yoloOn = cameraYOLOEnabled[cameraID] ?? true
            let config = settings.effectiveConfiguration(for: cameraID, cameraYOLOEnabled: yoloOn)
            guard config.analyticsEnabled else {
                pendingByCamera.removeValue(forKey: cameraID)
                continue
            }

            let targetFPS = targetSamplingFPS(for: state.activityTier, config: config)
            let minInterval = 1.0 / max(0.25, targetFPS)
            let elapsedSinceDispatch = state.lastDispatchedAt.map { max(0, slot.enqueuedAt - $0) } ?? Double.greatestFiniteMagnitude
            let elapsedNow = state.lastDispatchedAt.map { max(0, now - $0) } ?? Double.greatestFiniteMagnitude
            let effectiveElapsed = max(elapsedSinceDispatch, elapsedNow)

            guard effectiveElapsed >= minInterval else {
                continue
            }

            // Starvation-free score: overdue ratio + tier priority bonus + round-robin tie-breaker
            let overdueRatio = min(effectiveElapsed / max(minInterval, 1e-3), 20.0)
            let tierBonus: Double
            switch state.activityTier {
            case .elevatedSafety:
                tierBonus = 50.0
            case .activePerson:
                tierBonus = 5.0
            case .idle:
                // Guarantee idle cameras are never starved beyond 1.5x their idle interval
                tierBonus = overdueRatio >= 1.5 ? 10.0 : 0.0
            }
            let fairnessBonus = Double(count - offset) * 0.01
            let score = overdueRatio + tierBonus + fairnessBonus

            if score > bestScore {
                bestScore = score
                bestIndex = idx
                bestEffectiveConfig = config
            }
        }

        guard let chosenIndex = bestIndex,
              let chosenConfig = bestEffectiveConfig else {
            return nil
        }

        let chosenCameraID = cameraOrder[chosenIndex]
        guard let slot = pendingByCamera.removeValue(forKey: chosenCameraID) else {
            return nil
        }

        roundRobinCursor = (chosenIndex + 1) % max(1, count)
        inFlightTasks += 1

        if var state = stateByCamera[chosenCameraID] {
            if let prevDispatch = state.lastDispatchedAt, now > prevDispatch {
                let instFPS = 1.0 / max(0.01, now - prevDispatch)
                state.smoothedFPS = state.smoothedFPS == 0 ? instFPS : (0.25 * instFPS + 0.75 * state.smoothedFPS)
            }
            state.lastDispatchedAt = max(now, slot.enqueuedAt)
            state.isInFlight = true
            stateByCamera[chosenCameraID] = state
        }

        let tier = stateByCamera[chosenCameraID]?.activityTier ?? .idle
        return ScheduledCameraWorkItem(
            cameraID: chosenCameraID,
            payload: slot.payload,
            frameWidth: slot.frameWidth,
            frameHeight: slot.frameHeight,
            monotonicTimestamp: slot.enqueuedAt,
            activityTier: tier,
            effectiveConfig: chosenConfig
        )
    }

    /// Marks an inference task for `cameraID` as complete and updates telemetry and dynamic cadence tier.
    public func completeWorkItem(
        cameraID: UUID,
        inferenceLatencyMs: Double,
        activePersonTracks: Int,
        hasElevatedFallPhase: Bool,
        hasActiveIncident: Bool,
        completedAt: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }

        inFlightTasks = max(0, inFlightTasks - 1)
        guard var state = stateByCamera[cameraID] else { return }
        state.isInFlight = false
        state.processedFrames += 1
        state.lastLatencyMs = max(0, inferenceLatencyMs)
        state.smoothedLatencyMs = state.smoothedLatencyMs == 0
            ? state.lastLatencyMs
            : (0.2 * state.lastLatencyMs + 0.8 * state.smoothedLatencyMs)
        state.activePersonTracks = max(0, activePersonTracks)
        state.hasElevatedFallPhase = hasElevatedFallPhase
        state.hasActiveIncident = hasActiveIncident
        state.lastCompletedAt = completedAt.timeIntervalSince1970

        if hasElevatedFallPhase || hasActiveIncident {
            state.activityTier = .elevatedSafety
        } else if activePersonTracks > 0 {
            state.activityTier = .activePerson
        } else {
            state.activityTier = .idle
        }
        stateByCamera[cameraID] = state
    }

    public func removeCamera(_ cameraID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if stateByCamera[cameraID]?.isInFlight == true {
            inFlightTasks = max(0, inFlightTasks - 1)
        }
        pendingByCamera.removeValue(forKey: cameraID)
        stateByCamera.removeValue(forKey: cameraID)
        cameraOrder.removeAll { $0 == cameraID }
        if !cameraOrder.isEmpty {
            roundRobinCursor %= cameraOrder.count
        } else {
            roundRobinCursor = 0
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pendingByCamera.removeAll()
        stateByCamera.removeAll()
        cameraOrder.removeAll()
        roundRobinCursor = 0
        inFlightTasks = 0
    }

    public var pendingQueueDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingByCamera.count
    }

    public var currentInFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlightTasks
    }

    public func telemetry(for cameraID: UUID) -> CameraAnalyticsTelemetry {
        lock.lock()
        defer { lock.unlock() }
        guard let state = stateByCamera[cameraID] else {
            return CameraAnalyticsTelemetry(cameraID: cameraID)
        }
        return CameraAnalyticsTelemetry(
            cameraID: cameraID,
            analyticsFPS: state.smoothedFPS,
            lastInferenceLatencyMs: state.lastLatencyMs,
            averageInferenceLatencyMs: state.smoothedLatencyMs,
            processedFrames: state.processedFrames,
            droppedFrames: state.droppedFrames,
            activePersonTracks: state.activePersonTracks,
            lastProcessedAt: state.lastCompletedAt.map(Date.init(timeIntervalSince1970:)),
            hasElevatedFallPhase: state.hasElevatedFallPhase,
            hasActiveIncident: state.hasActiveIncident
        )
    }

    public func allTelemetry() -> [UUID: CameraAnalyticsTelemetry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [UUID: CameraAnalyticsTelemetry] = [:]
        for (cameraID, state) in stateByCamera {
            result[cameraID] = CameraAnalyticsTelemetry(
                cameraID: cameraID,
                analyticsFPS: state.smoothedFPS,
                lastInferenceLatencyMs: state.lastLatencyMs,
                averageInferenceLatencyMs: state.smoothedLatencyMs,
                processedFrames: state.processedFrames,
                droppedFrames: state.droppedFrames,
                activePersonTracks: state.activePersonTracks,
                lastProcessedAt: state.lastCompletedAt.map(Date.init(timeIntervalSince1970:)),
                hasElevatedFallPhase: state.hasElevatedFallPhase,
                hasActiveIncident: state.hasActiveIncident
            )
        }
        return result
    }

    private func targetSamplingFPS(
        for tier: CameraSchedulingActivityTier,
        config: EffectiveCameraAnalyticsConfig
    ) -> Double {
        switch tier {
        case .elevatedSafety:
            // Never throttle elevated safety phases unless extreme thermal state
            return config.activeFallBoostFPS * max(0.75, thermalDegradationFactor)
        case .activePerson:
            return config.samplingFPS * thermalDegradationFactor
        case .idle:
            return config.idleSamplingFPS * thermalDegradationFactor
        }
    }
}
