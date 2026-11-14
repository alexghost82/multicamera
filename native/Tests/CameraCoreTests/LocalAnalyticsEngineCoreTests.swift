import Foundation
import XCTest
@testable import CameraCore

final class LocalAnalyticsEngineCoreTests: XCTestCase {
    func testSettingsValidationProfilesAndPerCameraInheritance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics-settings-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("settings.json")

        var settings = VideoAnalyticsSettings.safeDefaults
        XCTAssertNoThrow(try settings.validate())

        let cameraA = UUID()
        let cameraB = UUID()
        let zone = RestrictedZoneRegion.rectangle(name: "Server Rack", x: 0.2, y: 0.2, width: 0.4, height: 0.4, holdSeconds: 1.0)
        settings.cameraOverrides[cameraB] = CameraAnalyticsOverride(
            cameraID: cameraB,
            inheritGlobalSettings: false,
            analyticsEnabled: true,
            personDetectionEnabled: true,
            poseEstimationEnabled: true,
            fallDetectionEnabled: false,
            behaviorAnalysisEnabled: true,
            inactivityDetectionEnabled: true,
            loiteringDetectionEnabled: false,
            zoneMonitoringEnabled: true,
            fightDetectionEnabled: true,
            secondaryVLMVerificationEnabled: true,
            sensitivityProfile: .highSensitivity,
            customSamplingFPS: 6.0,
            customAlertCooldownSeconds: 15.0,
            restrictedZones: [zone]
        )

        let configA = settings.effectiveConfiguration(for: cameraA)
        XCTAssertTrue(configA.fallDetectionEnabled)
        XCTAssertEqual(configA.samplingFPS, 4.0, accuracy: 1e-6)
        XCTAssertFalse(configA.fightDetectionEnabled)

        let configB = settings.effectiveConfiguration(for: cameraB)
        XCTAssertFalse(configB.fallDetectionEnabled)
        XCTAssertTrue(configB.fightDetectionEnabled)
        XCTAssertTrue(configB.secondaryVLMVerificationEnabled)
        XCTAssertEqual(configB.samplingFPS, 6.0, accuracy: 1e-6)
        XCTAssertEqual(configB.alertCooldownSeconds, 15.0, accuracy: 1e-6)
        XCTAssertEqual(configB.restrictedZones.count, 1)

        try VideoAnalyticsSettingsStore.save(settings, to: fileURL)
        let loaded = try VideoAnalyticsSettingsStore.load(from: fileURL)
        XCTAssertEqual(loaded, settings)

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(filePerms & 0o777, 0o600)

        var invalid = settings
        invalid.personConfidenceThreshold = 1.5
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(invalid.clamped().personConfidenceThreshold, 0.95, accuracy: 1e-6)
    }

    func testBoundedSchedulerPreventsQueueExplosionAndStarvationAcross64Cameras() {
        let scheduler = AnalyticsFrameScheduler<Int>()
        var settings = VideoAnalyticsSettings.safeDefaults
        settings.maxConcurrentInferenceTasks = 4
        settings.analyticsSamplingFPS = 4.0
        settings.idleCameraSamplingFPS = 2.0

        let cameraIDs = (0..<64).map { _ in UUID() }
        var now = 100.0

        // Offer 5 frames in a burst to each of 64 cameras: queue depth must never exceed 64 (1 slot per camera)
        for burst in 0..<5 {
            for cameraID in cameraIDs {
                let cfg = settings.effectiveConfiguration(for: cameraID)
                _ = scheduler.offerFrame(
                    cameraID: cameraID,
                    payload: burst,
                    frameWidth: 1920,
                    frameHeight: 1080,
                    monotonicTimestamp: now + Double(burst) * 0.01,
                    effectiveConfig: cfg
                )
            }
        }
        XCTAssertEqual(scheduler.pendingQueueDepth, 64)
        let telemetrySample = scheduler.telemetry(for: cameraIDs[0])
        XCTAssertEqual(telemetrySample.droppedFrames, 4, "4 older unconsumed frames must be dropped per camera")

        // Simulate 64 Scheduling cycles and verify every single camera gets serviced (zero starvation)
        var servicedCameras = Set<UUID>()
        for step in 0..<64 {
            now += 0.02
            if let item = scheduler.popNextReadyWorkItem(now: now, settings: settings) {
                servicedCameras.insert(item.cameraID)
                scheduler.completeWorkItem(
                    cameraID: item.cameraID,
                    inferenceLatencyMs: 6.5,
                    activePersonTracks: step % 3 == 0 ? 1 : 0,
                    hasElevatedFallPhase: false,
                    hasActiveIncident: false
                )
            }
        }
        XCTAssertEqual(servicedCameras.count, 64, "All 64 cameras must be serviced fairly without starvation")
    }

    func testBehaviorAnalysisEngineDetectsInactivityZoneLoiteringRunningAndFight() {
        var engine = BehaviorAnalysisEngine()
        engine.fightHoldSeconds = 0.6
        engine.runningHoldSeconds = 0.6
        engine.crowdPersonThreshold = 3
        engine.crowdHoldSeconds = 0.6

        let cameraID = UUID()
        let zone = RestrictedZoneRegion.rectangle(name: "High Voltage Zone", x: 0.1, y: 0.1, width: 0.4, height: 0.4, holdSeconds: 0.5)
        var settings = VideoAnalyticsSettings.safeDefaults
        settings.enableFightDetection = true
        settings.inactivityThresholdSeconds = 2.0
        settings.loiteringThresholdSeconds = 3.0
        settings.alertCooldownSeconds = 10.0
        settings.cameraOverrides[cameraID] = CameraAnalyticsOverride(
            cameraID: cameraID,
            inheritGlobalSettings: false,
            analyticsEnabled: true,
            personDetectionEnabled: true,
            poseEstimationEnabled: true,
            fallDetectionEnabled: true,
            behaviorAnalysisEnabled: true,
            inactivityDetectionEnabled: true,
            loiteringDetectionEnabled: true,
            zoneMonitoringEnabled: true,
            fightDetectionEnabled: true,
            secondaryVLMVerificationEnabled: true,
            restrictedZones: [zone]
        )
        let config = settings.effectiveConfiguration(for: cameraID)

        let trackA = UUID()
        let keypoints = Array(repeating: FallKeypoint(x: 0.25, y: 0.25, confidence: 0.9), count: 17)
        let metrics = FallMetrics(torsoAngleDegrees: 72, aspectRatio: 1.8, heightRatio: 0.4, baselineHeightPixels: 200, visibleKeypointCount: 14)

        var collectedTypes = Set<SafetyIncidentType>()
        var t = 10.0
        for _ in 0..<20 {
            let snap = FallTrackSnapshot(
                trackID: trackA,
                state: .sitting,
                phase: .normal,
                behaviorState: .lying,
                confidence: 0.9,
                box: FallBoundingBox(x: 0.2, y: 0.2, width: 0.15, height: 0.1),
                keypoints: keypoints,
                metrics: metrics,
                relinkCount: 0
            )
            let res = engine.evaluate(
                cameraID: cameraID,
                fallUpdate: FallDetectorUpdate(tracks: [snap], events: []),
                config: config,
                monotonicTimestamp: t
            )
            res.candidates.forEach { collectedTypes.insert($0.type) }
            t += 0.25
        }

        XCTAssertTrue(collectedTypes.contains(.restrictedZoneIntrusion))
        XCTAssertTrue(collectedTypes.contains(.possibleUnresponsivePerson))
        XCTAssertTrue(collectedTypes.contains(.loitering))

        // Test Stage-A Fight Interaction Heuristic (2 close tracks with rapid wrist motion)
        let fighter1 = UUID()
        let fighter2 = UUID()
        var fightCandidates: [BehaviorSafetyCandidate] = []
        for step in 0..<10 {
            var kp1 = keypoints
            var kp2 = keypoints
            let swing = (step % 2 == 0) ? 0.18 : 0.36
            kp1[FallPoseObservation.leftWrist] = FallKeypoint(x: swing, y: 0.3, confidence: 0.95)
            kp2[FallPoseObservation.rightWrist] = FallKeypoint(x: 0.5 - swing, y: 0.3, confidence: 0.95)

            let s1 = FallTrackSnapshot(
                trackID: fighter1,
                state: .walking,
                phase: .normal,
                behaviorState: .walking,
                confidence: 0.92,
                box: FallBoundingBox(x: 0.40, y: 0.30, width: 0.12, height: 0.30),
                keypoints: kp1,
                metrics: FallMetrics(torsoAngleDegrees: 25, aspectRatio: 0.4, heightRatio: 0.95, baselineHeightPixels: 200, angularVelocityDegreesPerSecond: 80, visibleKeypointCount: 15),
                speedBodyHeightsPerSecond: 0.9,
                relinkCount: 0
            )
            let s2 = FallTrackSnapshot(
                trackID: fighter2,
                state: .walking,
                phase: .normal,
                behaviorState: .walking,
                confidence: 0.91,
                box: FallBoundingBox(x: 0.44, y: 0.30, width: 0.12, height: 0.30),
                keypoints: kp2,
                metrics: FallMetrics(torsoAngleDegrees: 28, aspectRatio: 0.4, heightRatio: 0.95, baselineHeightPixels: 200, angularVelocityDegreesPerSecond: 85, visibleKeypointCount: 15),
                speedBodyHeightsPerSecond: 0.9,
                relinkCount: 0
            )
            let res = engine.evaluate(
                cameraID: cameraID,
                fallUpdate: FallDetectorUpdate(tracks: [s1, s2], events: []),
                config: config,
                monotonicTimestamp: t
            )
            fightCandidates += res.candidates.filter { $0.type == .possiblePhysicalFight }
            t += 0.2
        }
        XCTAssertEqual(fightCandidates.count, 1)
        XCTAssertEqual(fightCandidates.first?.detectorSource, "PoseInteractionHeuristicStageA")
        XCTAssertEqual(fightCandidates.first?.requiresSecondaryVLMVerification, true)
    }

    func testUnifiedIncidentManagerEvidenceStoreAndAuditTrail() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("incident-mgr-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let auditURL = tempDir.appendingPathComponent("audit.json")
        let incidentsURL = tempDir.appendingPathComponent("incidents.json")
        let evidenceURL = tempDir.appendingPathComponent("evidence", isDirectory: true)

        let auditLog = OperatorAuditLog(url: auditURL)
        let manager = UnifiedIncidentManager(storageURL: incidentsURL, auditLog: auditLog)
        let evidenceStore = SafetyEvidenceStore(baseDirectoryURL: evidenceURL)

        let cameraID = UUID()
        let trackID = UUID()
        let now = Date()

        // Record 3 pre-event frames at 0.6s intervals
        let dummyJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
        evidenceStore.recordSampledFrame(cameraID: cameraID, jpegData: dummyJPEG, capturedAt: now.addingTimeInterval(-1.5))
        evidenceStore.recordSampledFrame(cameraID: cameraID, jpegData: dummyJPEG, capturedAt: now.addingTimeInterval(-0.8))

        let fallCandidate = BehaviorSafetyCandidate(
            cameraID: cameraID,
            trackIDs: [trackID],
            type: .fallConfirmed,
            severity: .critical,
            confidence: 0.91,
            monotonicTimestamp: 100.0,
            occurredAt: now,
            primaryBox: FallBoundingBox(x: 0.2, y: 0.5, width: 0.3, height: 0.12),
            explanation: "Fall confirmed after 0.9 s",
            detectorSource: "FallDetectorV2"
        )

        let bundle = try evidenceStore.createEvidenceBundle(
            for: fallCandidate,
            cameraName: "Lobby North",
            triggerSnapshotJPEG: dummyJPEG,
            postEventBufferSeconds: 2.0,
            now: now
        )
        // Feed 1 post-event frame
        evidenceStore.recordSampledFrame(cameraID: cameraID, jpegData: dummyJPEG, capturedAt: now.addingTimeInterval(0.6))

        let created = try XCTUnwrap(manager.ingest(
            candidate: fallCandidate,
            cameraName: "Lobby North",
            clipID: bundle.bundleID,
            snapshotRelativePath: bundle.snapshotRelativePath,
            cooldownSeconds: 30.0
        ))
        XCTAssertEqual(created.status, .active)
        XCTAssertEqual(created.type, .fallConfirmed)
        XCTAssertEqual(evidenceStore.loadClipFrames(for: created.id).count, 4) // 2 pre + 1 trigger + 1 post
        XCTAssertNotNil(evidenceStore.loadSnapshot(for: created.id))

        // Escalate to PERSON_DOWN
        let downCandidate = BehaviorSafetyCandidate(
            cameraID: cameraID,
            trackIDs: [trackID],
            type: .personDown,
            severity: .critical,
            confidence: 0.94,
            monotonicTimestamp: 112.0,
            occurredAt: now.addingTimeInterval(12.0),
            explanation: "Person remained down for 12.0 s",
            detectorSource: "FallDetectorV2"
        )
        let escalated = try XCTUnwrap(manager.ingest(candidate: downCandidate, cameraName: "Lobby North"))
        XCTAssertEqual(escalated.id, created.id, "PERSON_DOWN must escalate the existing open FALL_CONFIRMED incident")
        XCTAssertEqual(escalated.type, .personDown)
        XCTAssertEqual(escalated.escalationCount, 1)

        // Operator acknowledges then resolves
        _ = manager.transitionStatus(incidentID: created.id, to: .acknowledged, operatorNote: "Checking camera")
        let resolved = try XCTUnwrap(manager.transitionStatus(incidentID: created.id, to: .resolved, operatorNote: "Assisted person"))
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertNotNil(resolved.acknowledgedAt)
        XCTAssertNotNil(resolved.resolvedAt)

        // Verify persistence across reload and audit log entries
        let reloadedManager = UnifiedIncidentManager(storageURL: incidentsURL, auditLog: auditLog)
        XCTAssertEqual(reloadedManager.allIncidents().count, 1)
        XCTAssertEqual(reloadedManager.allIncidents().first?.status, .resolved)
        XCTAssertGreaterThanOrEqual(auditLog.recentEntries().count, 4)
    }
}
