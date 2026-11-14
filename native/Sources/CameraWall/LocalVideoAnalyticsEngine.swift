import AppKit
import Combine
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import CameraCore

/// Primary Local Video Analytics Engine for macOS / Apple Silicon.
/// Coordinates frame scheduling, YOLO26s-Pose inference, multi-object fall detection,
/// temporal behavior analysis, unified incident management, and evidence recording in Local Mode
/// (and ingests WorkerEventSpool events in Distributed Mode).
@MainActor
final class LocalVideoAnalyticsEngine: ObservableObject {
    @Published private(set) var engineState: AnalyticsEngineState = .disabled
    @Published private(set) var stateReason: String = "Analytics engine is not started"
    @Published var settings: VideoAnalyticsSettings
    @Published private(set) var incidents: [SafetyIncident] = []
    @Published private(set) var trackedPosesByCamera: [UUID: [TrackedPersonPose]] = [:]
    @Published private(set) var telemetryByCamera: [UUID: CameraAnalyticsTelemetry] = [:]
    @Published private(set) var modelDescriptors: [AnalyticsModelID: AnalyticsModelDescriptor] = [:]
    @Published private(set) var auditEntries: [OperatorAuditEntry] = []
    @Published private(set) var activeBannerIncident: SafetyIncident?

    let settingsURL: URL
    let incidentManager: UnifiedIncidentManager
    let evidenceStore: SafetyEvidenceStore
    let auditLog: OperatorAuditLog

    private let scheduler = AnalyticsFrameScheduler<IdentityPixelBuffer>()
    private let analyticsQueue = DispatchQueue(label: "CameraWall.LocalVideoAnalyticsEngine", qos: .userInitiated)
    private let stateLock = NSLock()
    private nonisolated(unsafe) var fallDetectorsByCamera: [UUID: FallDetector] = [:]
    private nonisolated(unsafe) var behaviorEnginesByCamera: [UUID: BehaviorAnalysisEngine] = [:]
    private var poseDetector: YOLO26PoseDetector?
    private var customPoseModelURL: URL?
    private var isLoopRunning = false
    private var secondaryVLMVerifier: ((SafetyIncident, Data?) async -> (confirmed: Bool, summary: String)?)?

    init(
        settingsURL: URL = VideoAnalyticsSettingsStore.defaultURL,
        incidentsURL: URL = UnifiedIncidentManager.defaultURL,
        evidenceDirectoryURL: URL = SafetyEvidenceStore.defaultURL,
        auditLogURL: URL = OperatorAuditLog.defaultURL,
        poseModelURL: URL? = nil
    ) {
        self.settingsURL = settingsURL
        let audit = OperatorAuditLog(url: auditLogURL)
        self.auditLog = audit
        self.incidentManager = UnifiedIncidentManager(storageURL: incidentsURL, auditLog: audit)
        self.evidenceStore = SafetyEvidenceStore(baseDirectoryURL: evidenceDirectoryURL)
        self.customPoseModelURL = poseModelURL
        self.settings = (try? VideoAnalyticsSettingsStore.load(from: settingsURL)) ?? .safeDefaults
        self.incidents = incidentManager.allIncidents()
        self.auditEntries = audit.recentEntries(limit: 200)
        refreshModelDescriptors()
    }

    func configureSecondaryVLMVerifier(
        _ verifier: @escaping (SafetyIncident, Data?) async -> (confirmed: Bool, summary: String)?
    ) {
        self.secondaryVLMVerifier = verifier
    }

    // MARK: - Lifecycle Management

    func startIfEnabled(activeCameraCount: Int) {
        guard settings.globalEnabled else {
            transitionState(to: .disabled, reason: "Video analytics disabled in settings")
            return
        }
        guard engineState == .disabled || engineState == .error || engineState == .stopping else {
            updateRunningState(activeCameraCount: activeCameraCount)
            return
        }

        transitionState(to: .initializing, reason: "Initializing local Core ML analytics models…")
        let resolvedURL = customPoseModelURL ?? YOLO26PoseDetector.defaultModelURL
        guard let resolvedURL else {
            updateModelDescriptor(
                .yoloPose,
                status: .missing,
                reason: "yolo26s-pose model package not found in app bundle or .build/models"
            )
            transitionState(to: .degraded, reason: "Pose model missing; running object-level analytics only")
            return
        }

        // Verify model integrity (SHA-256) and load asynchronously off the main thread
        let detector = YOLO26PoseDetector(modelURL: resolvedURL)
        self.poseDetector = detector
        updateModelDescriptor(.yoloPose, status: .loading, filePath: resolvedURL.path, reason: "Loading Core ML Pose model…")

        Task.detached(priority: .userInitiated) { [weak self] in
            let loadStarted = ProcessInfo.processInfo.systemUptime
            let integrity = try? ModelIntegrityVerifier.computeSHA256(at: resolvedURL)
            do {
                try await detector.prepare()
                let loadMs = (ProcessInfo.processInfo.systemUptime - loadStarted) * 1000.0
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.updateModelDescriptor(
                        .yoloPose,
                        status: .ready,
                        filePath: resolvedURL.path,
                        sizeBytes: integrity?.sizeBytes ?? 0,
                        sha256: integrity?.hash,
                        loadDurationMs: loadMs,
                        reason: "Core ML CPU + Neural Engine ready"
                    )
                    if self.settings.globalEnabled {
                        self.transitionState(
                            to: activeCameraCount > 0 ? .running : .ready,
                            reason: activeCameraCount > 0
                                ? "Local analytics active on \(activeCameraCount) camera(s)"
                                : "Local analytics ready (waiting for active camera streams)"
                        )
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.updateModelDescriptor(
                        .yoloPose,
                        status: .error,
                        filePath: resolvedURL.path,
                        reason: error.localizedDescription
                    )
                    self.transitionState(
                        to: .error,
                        reason: "Failed to initialize YOLO26s-Pose: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func updateRunningState(activeCameraCount: Int) {
        guard settings.globalEnabled else {
            if engineState != .disabled {
                stopEngine()
            }
            return
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            scheduler.setThermalDegradationFactor(thermal == .critical ? 0.45 : 0.70)
            if engineState == .running || engineState == .ready {
                transitionState(to: .degraded, reason: "Host thermal pressure (\(thermal == .critical ? "critical" : "serious")) — throttling idle scan cadence")
            }
            return
        } else {
            scheduler.setThermalDegradationFactor(1.0)
        }

        if engineState == .ready && activeCameraCount > 0 {
            transitionState(to: .running, reason: "Local analytics active on \(activeCameraCount) camera(s)")
        } else if engineState == .running && activeCameraCount == 0 {
            transitionState(to: .ready, reason: "Ready — waiting for active cameras")
        } else if engineState == .degraded && poseDetector != nil && activeCameraCount > 0 {
            transitionState(to: .running, reason: "Local analytics restored on \(activeCameraCount) camera(s)")
        }
    }

    func notifyStreamReconnecting(cameraName: String) {
        guard settings.globalEnabled, engineState == .running else { return }
        transitionState(to: .recovering, reason: "Reconnecting stream for \(cameraName)…")
    }

    func stopEngine() {
        transitionState(to: .stopping, reason: "Stopping local analytics engine…")
        scheduler.reset()
        stateLock.lock()
        fallDetectorsByCamera.removeAll()
        behaviorEnginesByCamera.removeAll()
        stateLock.unlock()
        trackedPosesByCamera.removeAll()
        telemetryByCamera.removeAll()
        transitionState(to: .disabled, reason: "Analytics engine disabled")
    }

    func removeCamera(_ cameraID: UUID) {
        scheduler.removeCamera(cameraID)
        stateLock.lock()
        fallDetectorsByCamera.removeValue(forKey: cameraID)
        behaviorEnginesByCamera.removeValue(forKey: cameraID)
        stateLock.unlock()
        trackedPosesByCamera.removeValue(forKey: cameraID)
        telemetryByCamera.removeValue(forKey: cameraID)
    }

    // MARK: - Settings Persistence

    func updateSettings(_ newSettings: VideoAnalyticsSettings) throws {
        let validated = newSettings.clamped()
        try validated.validate()
        try VideoAnalyticsSettingsStore.save(validated, to: settingsURL)
        let wasEnabled = settings.globalEnabled
        settings = validated
        auditLog.record(
            action: .settingsUpdated,
            summary: "Updated video analytics settings (profile: \(validated.sensitivityProfile.rawValue), globalEnabled: \(validated.globalEnabled))"
        )
        auditEntries = auditLog.recentEntries(limit: 200)
        if !validated.globalEnabled {
            stopEngine()
        } else if !wasEnabled || engineState == .disabled {
            startIfEnabled(activeCameraCount: trackedPosesByCamera.count)
        }
    }

    func resetSettingsToSafeDefaults() {
        let defaults = VideoAnalyticsSettings.safeDefaults
        try? VideoAnalyticsSettingsStore.save(defaults, to: settingsURL)
        settings = defaults
        auditLog.record(
            action: .settingsResetToDefaults,
            summary: "Reset video analytics settings to safe defaults"
        )
        auditEntries = auditLog.recentEntries(limit: 200)
    }

    // MARK: - Frame Ingestion & Scheduling

    func offerCameraFrame(
        camera: Camera,
        pixelBuffer: CVPixelBuffer,
        monotonicTimestamp: TimeInterval
    ) {
        guard settings.globalEnabled else { return }
        if engineState == .disabled {
            startIfEnabled(activeCameraCount: 1)
        }
        let config = settings.effectiveConfiguration(for: camera.id, cameraYOLOEnabled: camera.yoloEnabled)
        guard config.analyticsEnabled, config.poseEstimationEnabled else {
            trackedPosesByCamera.removeValue(forKey: camera.id)
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let wrapped = IdentityPixelBuffer(value: pixelBuffer)

        // Sample pre-event ring buffer at 2 FPS when evidence recording is enabled
        if settings.enableEvidenceRecording && evidenceStore.shouldSampleFrame(cameraID: camera.id, monotonicNow: monotonicTimestamp) {
            Task.detached(priority: .utility) { [evidenceStore] in
                if let jpeg = try? await VLMFrameEncoder.jpegData(from: wrapped.value, maxDimension: 640, quality: 0.45) {
                    evidenceStore.recordSampledFrame(cameraID: camera.id, jpegData: jpeg, capturedAt: Date())
                }
            }
        }

        let accepted = scheduler.offerFrame(
            cameraID: camera.id,
            payload: wrapped,
            frameWidth: width,
            frameHeight: height,
            monotonicTimestamp: monotonicTimestamp,
            effectiveConfig: config
        )
        if accepted {
            drainSchedulerIfNeeded(camerasByID: [camera.id: camera])
        }
    }

    func drainSchedulerIfNeeded(camerasByID: [UUID: Camera]) {
        guard settings.globalEnabled, let poseDetector else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let currentSettings = settings
        let yoloMap = camerasByID.mapValues(\.yoloEnabled)

        while let workItem = scheduler.popNextReadyWorkItem(now: now, settings: currentSettings, cameraYOLOEnabled: yoloMap) {
            if engineState == .ready || engineState == .recovering {
                transitionState(to: .running, reason: "Processing live video analytics")
            }
            let cameraName = camerasByID[workItem.cameraID]?.name ?? "Camera \(workItem.cameraID.uuidString.prefix(6))"
            let enableEvidence = currentSettings.enableEvidenceRecording
            let postBufferSeconds = currentSettings.postEventBufferSeconds
            let maxQuotaMB = currentSettings.maxEvidenceDiskQuotaMB
            let soundEnabled = currentSettings.enableSoundAlert
            let bannerEnabled = currentSettings.enableVisualAlertBanner

            analyticsQueue.async { [weak self] in
                guard let self else { return }
                let started = ProcessInfo.processInfo.systemUptime
                let threshold = workItem.effectiveConfig.personConfidenceThreshold
                let poseResult = Result { try poseDetector.detect(pixel: workItem.payload.value, threshold: threshold) }
                let inferenceMs = (ProcessInfo.processInfo.systemUptime - started) * 1000.0

                switch poseResult {
                case .failure:
                    self.scheduler.completeWorkItem(
                        cameraID: workItem.cameraID,
                        inferenceLatencyMs: inferenceMs,
                        activePersonTracks: 0,
                        hasElevatedFallPhase: false,
                        hasActiveIncident: false
                    )
                case .success(let inference):
                    let observations = inference.people.map { person in
                        FallPoseObservation(
                            confidence: person.confidence,
                            box: FallBoundingBox(
                                x: person.box.x,
                                y: person.box.y,
                                width: person.box.width,
                                height: person.box.height
                            ),
                            keypoints: person.keypoints.map {
                                FallKeypoint(x: $0.x, y: $0.y, confidence: $0.confidence)
                            }
                        )
                    }

                    self.stateLock.lock()
                    var fallConfig = FallDetectorConfiguration()
                    fallConfig.fallPersistenceSeconds = workItem.effectiveConfig.fallConfirmationSeconds
                    fallConfig.personDownSeconds = workItem.effectiveConfig.personDownSeconds
                    fallConfig.primaryConfidence = workItem.effectiveConfig.personConfidenceThreshold
                    fallConfig.keypointConfidence = workItem.effectiveConfig.poseKeypointConfidenceThreshold

                    var fallDetector = self.fallDetectorsByCamera[workItem.cameraID] ?? FallDetector(configuration: fallConfig)
                    let fallUpdate = fallDetector.update(
                        observations,
                        frameWidth: workItem.frameWidth,
                        frameHeight: workItem.frameHeight,
                        timestamp: workItem.monotonicTimestamp
                    )
                    self.fallDetectorsByCamera[workItem.cameraID] = fallDetector

                    var behaviorEngine = self.behaviorEnginesByCamera[workItem.cameraID] ?? BehaviorAnalysisEngine()
                    let behaviorResult = behaviorEngine.evaluate(
                        cameraID: workItem.cameraID,
                        fallUpdate: fallUpdate,
                        config: workItem.effectiveConfig,
                        monotonicTimestamp: workItem.monotonicTimestamp,
                        wallClockNow: Date()
                    )
                    self.behaviorEnginesByCamera[workItem.cameraID] = behaviorEngine
                    self.stateLock.unlock()

                    let hasElevated = behaviorResult.trackedPeople.contains { $0.fallPhase.isElevated }
                    let hasIncident = !behaviorResult.candidates.isEmpty

                    self.scheduler.completeWorkItem(
                        cameraID: workItem.cameraID,
                        inferenceLatencyMs: inference.inferenceMilliseconds,
                        activePersonTracks: behaviorResult.trackedPeople.count,
                        hasElevatedFallPhase: hasElevated,
                        hasActiveIncident: hasIncident
                    )

                    let camTelemetry = self.scheduler.telemetry(for: workItem.cameraID)
                    var triggerJPEG: Data?
                    if hasIncident && enableEvidence {
                        triggerJPEG = try? Self.encodeTriggerSnapshotJPEG(from: workItem.payload.value)
                    }

                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.trackedPosesByCamera[workItem.cameraID] = behaviorResult.trackedPeople
                        self.telemetryByCamera[workItem.cameraID] = camTelemetry
                        self.updatePoseLatency(inference.inferenceMilliseconds)

                        if !behaviorResult.candidates.isEmpty {
                            self.handleSafetyCandidates(
                                behaviorResult.candidates,
                                cameraName: cameraName,
                                triggerJPEG: triggerJPEG,
                                enableEvidence: enableEvidence,
                                postBufferSeconds: postBufferSeconds,
                                maxQuotaMB: maxQuotaMB,
                                soundEnabled: soundEnabled,
                                bannerEnabled: bannerEnabled,
                                cooldownSeconds: workItem.effectiveConfig.alertCooldownSeconds
                            )
                        }
                    }
                }
            }
        }
    }

    /// Processes a pose result already computed (e.g. in Worker Mode) through the unified Fall + Behavior + Incident pipeline.
    func processExternalPoseResult(
        people: [PosePerson],
        camera: Camera,
        frameWidth: Int,
        frameHeight: Int,
        monotonicTimestamp: TimeInterval
    ) -> [FallEvent] {
        let config = settings.effectiveConfiguration(for: camera.id, cameraYOLOEnabled: camera.yoloEnabled)
        let observations = people.map { person in
            FallPoseObservation(
                confidence: person.confidence,
                box: FallBoundingBox(x: person.box.x, y: person.box.y, width: person.box.width, height: person.box.height),
                keypoints: person.keypoints.map { FallKeypoint(x: $0.x, y: $0.y, confidence: $0.confidence) }
            )
        }
        stateLock.lock()
        var fallDetector = fallDetectorsByCamera[camera.id] ?? FallDetector()
        let fallUpdate = fallDetector.update(observations, frameWidth: frameWidth, frameHeight: frameHeight, timestamp: monotonicTimestamp)
        fallDetectorsByCamera[camera.id] = fallDetector

        var behaviorEngine = behaviorEnginesByCamera[camera.id] ?? BehaviorAnalysisEngine()
        let behaviorResult = behaviorEngine.evaluate(
            cameraID: camera.id,
            fallUpdate: fallUpdate,
            config: config,
            monotonicTimestamp: monotonicTimestamp
        )
        behaviorEnginesByCamera[camera.id] = behaviorEngine
        stateLock.unlock()

        trackedPosesByCamera[camera.id] = behaviorResult.trackedPeople
        if !behaviorResult.candidates.isEmpty {
            handleSafetyCandidates(
                behaviorResult.candidates,
                cameraName: camera.name,
                triggerJPEG: nil,
                enableEvidence: settings.enableEvidenceRecording,
                postBufferSeconds: settings.postEventBufferSeconds,
                maxQuotaMB: settings.maxEvidenceDiskQuotaMB,
                soundEnabled: settings.enableSoundAlert,
                bannerEnabled: settings.enableVisualAlertBanner,
                cooldownSeconds: config.alertCooldownSeconds
            )
        }
        return fallUpdate.events
    }

    // MARK: - Incident Handling & Operator Actions

    private func handleSafetyCandidates(
        _ candidates: [BehaviorSafetyCandidate],
        cameraName: String,
        triggerJPEG: Data?,
        enableEvidence: Bool,
        postBufferSeconds: Double,
        maxQuotaMB: Int,
        soundEnabled: Bool,
        bannerEnabled: Bool,
        cooldownSeconds: Double
    ) {
        var createdCritical = false
        for candidate in candidates {
            var clipID: UUID?
            var snapshotPath: String?
            if enableEvidence {
                if let bundle = try? evidenceStore.createEvidenceBundle(
                    for: candidate,
                    cameraName: cameraName,
                    triggerSnapshotJPEG: triggerJPEG,
                    postEventBufferSeconds: postBufferSeconds,
                    maxDiskQuotaMB: maxQuotaMB,
                    now: candidate.occurredAt
                ) {
                    clipID = bundle.bundleID
                    snapshotPath = bundle.snapshotRelativePath
                }
            }

            if let incident = incidentManager.ingest(
                candidate: candidate,
                cameraName: cameraName,
                clipID: clipID,
                snapshotRelativePath: snapshotPath,
                cooldownSeconds: cooldownSeconds
            ) {
                if incident.severity == .critical {
                    createdCritical = true
                }
                if bannerEnabled && (incident.severity == .critical || incident.severity == .high) {
                    activeBannerIncident = incident
                }
                if candidate.requiresSecondaryVLMVerification, let verifier = secondaryVLMVerifier {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let verdict = await verifier(incident, triggerJPEG) {
                            _ = self.incidentManager.recordSecondaryVLMVerification(
                                incidentID: incident.id,
                                status: verdict.confirmed ? .confirmed : .rejected,
                                summary: verdict.summary
                            )
                            self.refreshIncidentsAndAudit()
                        } else {
                            _ = self.incidentManager.recordSecondaryVLMVerification(
                                incidentID: incident.id,
                                status: .unavailable,
                                summary: "Secondary VLM unavailable — primary safety detection preserved"
                            )
                            self.refreshIncidentsAndAudit()
                        }
                    }
                }
            }
        }
        refreshIncidentsAndAudit()
        if createdCritical && soundEnabled {
            NSSound.beep()
        }
    }

    func transitionIncident(
        _ incidentID: UUID,
        to status: SafetyIncidentStatus,
        note: String? = nil,
        suppressDurationSeconds: TimeInterval? = nil
    ) {
        _ = incidentManager.transitionStatus(
            incidentID: incidentID,
            to: status,
            operatorNote: note,
            suppressDurationSeconds: suppressDurationSeconds
        )
        if activeBannerIncident?.id == incidentID && !status.isOpen {
            activeBannerIncident = nil
        }
        refreshIncidentsAndAudit()
    }

    func dismissActiveBanner() {
        activeBannerIncident = nil
    }

    func deleteIncidentEvidence(_ incidentID: UUID) {
        evidenceStore.deleteEvidence(for: incidentID)
        auditLog.record(
            action: .evidenceDeleted,
            incidentID: incidentID,
            summary: "Operator deleted stored evidence bundle for incident \(incidentID.uuidString.prefix(8))"
        )
        refreshIncidentsAndAudit()
    }

    func clearResolvedIncidents() {
        incidentManager.clearResolvedAndClosed()
        refreshIncidentsAndAudit()
    }

    func ingestDistributedWorkerSpool(_ spool: WorkerEventSpool, camerasByID: [UUID: Camera]) async {
        let envelopes = await spool.pending(limit: 32)
        guard !envelopes.isEmpty else { return }
        var processedIDs: [UUID] = []
        for env in envelopes {
            let name = camerasByID[env.cameraID]?.name ?? "Camera \(env.cameraID.uuidString.prefix(6))"
            _ = incidentManager.ingestWorkerEnvelope(env, cameraName: name, cooldownSeconds: settings.alertCooldownSeconds)
            processedIDs.append(env.id)
        }
        _ = try? await spool.acknowledge(Set(processedIDs))
        refreshIncidentsAndAudit()
    }

    private func refreshIncidentsAndAudit() {
        incidents = incidentManager.allIncidents()
        auditEntries = auditLog.recentEntries(limit: 200)
    }

    // MARK: - Model Registry & Telemetry

    func refreshModelDescriptors() {
        var map: [AnalyticsModelID: AnalyticsModelDescriptor] = [:]

        // 1. YOLO26n Object Detector
        if let yoloURL = YOLO26Detector.defaultModelURL {
            let info = try? ModelIntegrityVerifier.computeSHA256(at: yoloURL)
            map[.yoloObject] = AnalyticsModelDescriptor(
                modelID: .yoloObject,
                version: "26n-coreml",
                status: .ready,
                backend: "Core ML (ANE + GPU + CPU)",
                filePath: yoloURL.path,
                sizeBytes: info?.sizeBytes ?? 0,
                sha256Checksum: info?.hash,
                statusReason: "Ready in local bundle"
            )
        } else {
            map[.yoloObject] = AnalyticsModelDescriptor(
                modelID: .yoloObject,
                version: "26n-coreml",
                status: .missing,
                backend: "Core ML",
                statusReason: "yolo26n.mlmodelc not found"
            )
        }

        // 2. YOLO26s-Pose Detector
        if let existingPose = modelDescriptors[.yoloPose], existingPose.status == .ready || existingPose.status == .loading {
            map[.yoloPose] = existingPose
        } else if let poseURL = customPoseModelURL ?? YOLO26PoseDetector.defaultModelURL {
            let info = try? ModelIntegrityVerifier.computeSHA256(at: poseURL)
            map[.yoloPose] = AnalyticsModelDescriptor(
                modelID: .yoloPose,
                version: "26s-pose-fp16",
                status: .ready,
                backend: "Core ML (CPU + Neural Engine)",
                filePath: poseURL.path,
                sizeBytes: info?.sizeBytes ?? 0,
                sha256Checksum: info?.hash,
                statusReason: "Discovered local Pose package"
            )
        } else {
            map[.yoloPose] = AnalyticsModelDescriptor(
                modelID: .yoloPose,
                version: "26s-pose-fp16",
                status: .missing,
                backend: "Core ML",
                statusReason: "yolo26s-pose model not found"
            )
        }

        // 3. YOLO26n-Seg
        if let segURL = ONNXSegmentationEncoder.modelURL {
            let info = try? ModelIntegrityVerifier.computeSHA256(at: segURL)
            map[.yoloSegmentation] = AnalyticsModelDescriptor(
                modelID: .yoloSegmentation,
                version: "26n-seg-onnx",
                status: .ready,
                backend: "ONNX Runtime (CoreML EP)",
                filePath: segURL.path,
                sizeBytes: info?.sizeBytes ?? 0,
                sha256Checksum: info?.hash,
                statusReason: "Available for instance mask extraction"
            )
        } else {
            map[.yoloSegmentation] = AnalyticsModelDescriptor(
                modelID: .yoloSegmentation,
                version: "26n-seg-onnx",
                status: .missing,
                backend: "ONNX Runtime",
                statusReason: "Optional segmentation model not installed"
            )
        }

        // 4. Person Re-ID
        if let reidURL = ONNXReIDEncoder.modelURL(for: .person) {
            let info = try? ModelIntegrityVerifier.computeSHA256(at: reidURL)
            map[.personReID] = AnalyticsModelDescriptor(
                modelID: .personReID,
                version: "26m-reid",
                status: .ready,
                backend: "ONNX Runtime (CoreML EP)",
                filePath: reidURL.path,
                sizeBytes: info?.sizeBytes ?? 0,
                sha256Checksum: info?.hash,
                statusReason: "Available for person re-identification"
            )
        } else {
            map[.personReID] = AnalyticsModelDescriptor(
                modelID: .personReID,
                status: .missing,
                backend: "ONNX Runtime",
                statusReason: "Optional Person Re-ID model not installed"
            )
        }

        // 5. Vehicle Re-ID
        if let vreidURL = ONNXReIDEncoder.modelURL(for: .vehicle) {
            let info = try? ModelIntegrityVerifier.computeSHA256(at: vreidURL)
            map[.vehicleReID] = AnalyticsModelDescriptor(
                modelID: .vehicleReID,
                version: "osnet-ain-x1.0",
                status: .ready,
                backend: "ONNX Runtime (CoreML EP)",
                filePath: vreidURL.path,
                sizeBytes: info?.sizeBytes ?? 0,
                sha256Checksum: info?.hash,
                statusReason: "Available for vehicle re-identification"
            )
        } else {
            map[.vehicleReID] = AnalyticsModelDescriptor(
                modelID: .vehicleReID,
                status: .missing,
                backend: "ONNX Runtime",
                statusReason: "Optional Vehicle Re-ID model not installed"
            )
        }

        // 6. Dedicated Fight Action Classifier (Explicitly marked MODEL_NOT_VALIDATED per Section 6.3 & R-06)
        map[.fightClassifier] = AnalyticsModelDescriptor(
            modelID: .fightClassifier,
            version: "stage-a-pose-heuristic",
            status: .modelNotValidated,
            backend: "Pose Kinematics Heuristic + Optional VLM",
            statusReason: "No licensed video fight action model bundled; using experimental Stage-A Pose Interaction Heuristic"
        )

        modelDescriptors = map
    }

    func reloadPoseModel(customPath: URL? = nil) {
        if let customPath {
            customPoseModelURL = customPath
        }
        engineState = .disabled
        startIfEnabled(activeCameraCount: trackedPosesByCamera.count)
    }

    private func updateModelDescriptor(
        _ id: AnalyticsModelID,
        status: AnalyticsModelStatus,
        filePath: String? = nil,
        sizeBytes: Int64 = 0,
        sha256: String? = nil,
        loadDurationMs: Double? = nil,
        reason: String
    ) {
        var desc = modelDescriptors[id] ?? AnalyticsModelDescriptor(
            modelID: id,
            version: "26s-pose-fp16",
            status: status,
            backend: "Core ML (CPU + Neural Engine)"
        )
        desc.status = status
        if let filePath { desc.filePath = filePath }
        if sizeBytes > 0 { desc.sizeBytes = sizeBytes }
        if let sha256 { desc.sha256Checksum = sha256 }
        if let loadDurationMs { desc.loadDurationMs = loadDurationMs }
        desc.statusReason = reason
        modelDescriptors[id] = desc
    }

    private func updatePoseLatency(_ latencyMs: Double) {
        guard var desc = modelDescriptors[.yoloPose] else { return }
        if let prev = desc.averageLatencyMs {
            desc.averageLatencyMs = 0.2 * latencyMs + 0.8 * prev
        } else {
            desc.averageLatencyMs = latencyMs
        }
        modelDescriptors[.yoloPose] = desc
    }

    private func transitionState(to newState: AnalyticsEngineState, reason: String) {
        let changed = (engineState != newState)
        engineState = newState
        stateReason = reason
        if changed {
            auditLog.record(
                action: .engineStateChanged,
                summary: "Analytics Engine -> \(newState.rawValue): \(reason)"
            )
            auditEntries = auditLog.recentEntries(limit: 200)
        }
    }

    private nonisolated static func encodeTriggerSnapshotJPEG(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let data = context.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
