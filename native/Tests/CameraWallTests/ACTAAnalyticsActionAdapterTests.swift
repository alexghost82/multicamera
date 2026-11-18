import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAAnalyticsActionAdapterTests: XCTestCase {
    private func fixture() throws -> (URL, WallModel, UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".analytics-action-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var config = WallConfiguration()
        let camera = Camera(name: "Fixture", substream: "rtsp://127.0.0.1/fixture", enabled: false, yoloEnabled: true)
        config.cameras = [camera]
        let configURL = root.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(config, to: configURL)
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(CameraFeaturePreferences(), to: root.appendingPathComponent("features.json"))
        let poseURL = root.appendingPathComponent("unused-pose.mlmodel")
        let model = WallModel(configURL: configURL, workerMode: false, poseModelURL: poseURL,
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(modelURL: { _ in nil }, integrity: { url in
                XCTAssertEqual(url, poseURL)
                return (hash: "synthetic", sizeBytes: 0)
            }))
        XCTAssertFalse(model.running)
        XCTAssertNil(model.tiles[camera.id]?.session)
        XCTAssertFalse(model.featurePreferences.enabledFeatures.contains(.independentWatcher))
        XCTAssertTrue(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
        return (root, model, camera.id)
    }

    func testSensitivityProfilesMatchGUIAndSelectionDoesNotApplyPreset() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        for profile in AnalyticsSensitivityProfile.allCases {
            var expected = model.localAnalyticsEngine.settings
            expected.applySensitivityProfile(profile)
            let result = try await registry.execute(actionID: "analytics.set_sensitivity_profile",
                parameters: ["profile": profile.rawValue])
            XCTAssertTrue(result.success, result.summary)
            XCTAssertEqual(model.localAnalyticsEngine.settings, expected)
            XCTAssertEqual(try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL), expected)
        }
        var expected = model.localAnalyticsEngine.settings
        expected.sensitivityProfile = .conservative
        let selected = try await registry.execute(actionID: "analytics.set_sensitivity_profile",
            parameters: ["profile": AnalyticsSensitivityProfile.conservative.rawValue, "apply_values": "false"])
        XCTAssertTrue(selected.success)
        XCTAssertEqual(model.localAnalyticsEngine.settings, expected)
        let bytes = try Data(contentsOf: model.localAnalyticsEngine.settingsURL)
        let invalid = try await registry.execute(actionID: "analytics.set_sensitivity_profile", parameters: ["profile": "unknown"])
        XCTAssertFalse(invalid.success)
        XCTAssertEqual(try Data(contentsOf: model.localAnalyticsEngine.settingsURL), bytes)
    }

    func testAdvancedCameraOverridesAndConfirmedRemoval() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        for (name, key) in WallAnalyticsAction.cameraFlags {
            let value = !(model.localAnalyticsEngine.settings.cameraOverrides[camera] ?? CameraAnalyticsOverride(cameraID: camera))[keyPath: key]
            let result = try await registry.execute(actionID: "analytics.set_camera_override",
                parameters: ["camera_id": camera.uuidString, name: String(value)])
            XCTAssertTrue(result.success, result.summary)
            let saved = try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL)
            XCTAssertEqual(saved.cameraOverrides[camera]?[keyPath: key], value)
            XCTAssertEqual(saved.cameraOverrides[camera]?.inheritGlobalSettings, false)
        }
        let custom = try await registry.execute(actionID: "analytics.set_camera_override", parameters: [
            "camera_id": camera.uuidString, "fps": "6", "cooldown_seconds": "120",
            "sensitivity_profile": AnalyticsSensitivityProfile.highSensitivity.rawValue])
        XCTAssertTrue(custom.success, custom.summary)
        let override = try XCTUnwrap(model.localAnalyticsEngine.settings.cameraOverrides[camera])
        XCTAssertEqual(override.customSamplingFPS, 6)
        XCTAssertEqual(override.customAlertCooldownSeconds, 120)
        XCTAssertEqual(override.sensitivityProfile, .highSensitivity)
        let cleared = try await registry.execute(actionID: "analytics.set_camera_override", parameters: [
            "camera_id": camera.uuidString, "clear_fps": "true", "clear_cooldown": "true"])
        XCTAssertTrue(cleared.success, cleared.summary)
        XCTAssertNil(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.customSamplingFPS)
        XCTAssertNil(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.customAlertCooldownSeconds)
        let bytes = try Data(contentsOf: model.localAnalyticsEngine.settingsURL)
        for arguments in [
            ["camera_id": camera.uuidString, "fps": "4", "clear_fps": "true"],
            ["camera_id": camera.uuidString, "cooldown_seconds": "1"],
            ["camera_id": camera.uuidString, "inherit": "true", "fightDetectionEnabled": "true"]
        ] {
            let result = try await registry.execute(actionID: "analytics.set_camera_override", parameters: arguments)
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.localAnalyticsEngine.settingsURL), bytes)
        }
        let pending = try await registry.execute(actionID: "analytics.remove_camera_override", parameters: ["camera_id": camera.uuidString])
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertNotNil(model.localAnalyticsEngine.settings.cameraOverrides[camera])
        let removed = try await registry.confirmAndExecute(token: XCTUnwrap(pending.confirmationToken), confirmed: true)
        XCTAssertTrue(removed.success, removed.summary)
        XCTAssertNil(try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL).cameraOverrides[camera])
    }

    func testPolygonAndZonePolicyEditsPreserveIdentityAndRejectInvalidOperations() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let created = try await registry.execute(actionID: "analytics.set_restricted_zone", parameters: [
            "camera_id": camera.uuidString, "name": "Entrance", "x": "0.1", "y": "0.1", "width": "0.4", "height": "0.5"])
        XCTAssertTrue(created.success)
        let zoneID = try XCTUnwrap(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.restrictedZones.first?.id)
        let base = ["camera_id": camera.uuidString, "zone_id": zoneID.uuidString]
        func edit(_ arguments: [String: String]) async throws -> ACTAActionResult {
            try await registry.execute(actionID: "analytics.update_restricted_zone", parameters: base.merging(arguments) { _, new in new })
        }
        let policy = try await edit(["new_name": "Secure area", "enabled": "false", "hold_seconds": "5", "severity": "CRITICAL"])
        XCTAssertTrue(policy.success, policy.summary)
        let moved = try await edit(["point_index": "0", "point_x": "0.2", "point_y": "0.3"])
        XCTAssertTrue(moved.success)
        let appended = try await edit(["append_point": "true", "point_x": "0.3", "point_y": "0.4"])
        XCTAssertTrue(appended.success)
        let removed = try await edit(["remove_point": "true", "point_index": "4"])
        XCTAssertTrue(removed.success)
        let saved = try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL)
        let zone = try XCTUnwrap(saved.cameraOverrides[camera]?.restrictedZones.first)
        XCTAssertEqual(zone.id, zoneID)
        XCTAssertEqual(zone.name, "Secure area")
        XCTAssertFalse(zone.enabled)
        XCTAssertEqual(zone.holdSeconds, 5)
        XCTAssertEqual(zone.severity, .critical)
        XCTAssertEqual(zone.points.count, 4)
        XCTAssertEqual(zone.points[0], NormalizedPoint(x: 0.2, y: 0.3))
        let bytes = try Data(contentsOf: model.localAnalyticsEngine.settingsURL)
        for arguments in [["point_index": "99", "point_x": "0", "point_y": "0"],
                          ["append_point": "true", "point_x": "1.2", "point_y": "0"],
                          ["remove_point": "true", "point_index": "0", "point_x": "0.2"],
                          ["hold_seconds": "-1"], ["severity": "unknown"], ["new_name": " "]] {
            let result = try await edit(arguments)
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: model.localAnalyticsEngine.settingsURL), bytes)
        }
        let triangle = try await edit(["remove_point": "true", "point_index": "3"])
        XCTAssertTrue(triangle.success)
        let invalidTriangle = try await edit(["remove_point": "true", "point_index": "2"])
        XCTAssertFalse(invalidTriangle.success)
        XCTAssertEqual(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.restrictedZones.first?.points.count, 3)
    }

    func testCanvasActionsShareGUIStateAndVerifySavedLayout() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let expanded = try await registry.execute(actionID: "camera.toggle_expand", parameters: ["camera_id": camera.uuidString])
        XCTAssertTrue(expanded.success)
        XCTAssertEqual(model.expanded, camera)
        let collapsed = try await registry.execute(actionID: "camera.toggle_expand", parameters: ["camera_id": camera.uuidString])
        XCTAssertTrue(collapsed.success)
        XCTAssertNil(model.expanded)
        model.connecting = true
        let busy = try await registry.execute(actionID: "camera.toggle_expand", parameters: ["camera_id": camera.uuidString])
        XCTAssertFalse(busy.success)
        XCTAssertNil(model.expanded)
        model.connecting = false
        let tile = VideoTileFrame(x: 10, y: 20, width: 320, height: 180)
        model.setTileFrame(tile, for: camera)
        XCTAssertFalse(model.layout.frames.isEmpty)
        let reset = try await registry.execute(actionID: "canvas.reset_layout", parameters: [:])
        XCTAssertTrue(reset.success, reset.summary)
        XCTAssertTrue(model.layout.frames.isEmpty)
        XCTAssertTrue(try VideoWallLayout.load(from: model.layoutURL).frames.isEmpty)
        try FileManager.default.removeItem(at: model.layoutURL)
        try FileManager.default.createDirectory(at: model.layoutURL, withIntermediateDirectories: true)
        let failed = try await registry.execute(actionID: "canvas.reset_layout", parameters: [:])
        XCTAssertFalse(failed.success)
        XCTAssertFalse(failed.verified)
    }

    func testNumericSettingsRoundTripAndRejectInvalidValuesBeforeWriting() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let values: [String: Double] = ["personConfidenceThreshold": 0.5, "poseKeypointConfidenceThreshold": 0.4,
            "fallConfirmationSeconds": 1.1, "personDownSeconds": 15, "inactivityThresholdSeconds": 60,
            "loiteringThresholdSeconds": 150, "alertCooldownSeconds": 45, "preEventBufferSeconds": 10,
            "postEventBufferSeconds": 9, "minimumVisibleKeypoints": 8, "maxEvidenceDiskQuotaMB": 1024,
            "maxConcurrentInferenceTasks": 3]
        for (name, value) in values {
            var result = try await registry.execute(actionID: "analytics.set_threshold", parameters: ["parameter": name, "value": String(value)])
            if let token = result.confirmationToken { result = try await registry.confirmAndExecute(token: token, confirmed: true) }
            XCTAssertTrue(result.success, result.summary)
            XCTAssertTrue(result.verified)
            let stored = try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL)
            if let key = WallAnalyticsAction.thresholds[name] { XCTAssertEqual(stored[keyPath: key], value) }
            if let key = WallAnalyticsAction.integerThresholds[name] { XCTAssertEqual(stored[keyPath: key], Int(value)) }
            XCTAssertEqual(stored, model.localAnalyticsEngine.settings)
        }
        let url = model.localAnalyticsEngine.settingsURL
        let bytes = try Data(contentsOf: url)
        for arguments in [["parameter": "personConfidenceThreshold", "value": "2"],
                          ["parameter": "minimumVisibleKeypoints", "value": "6.5"],
                          ["parameter": "unknown", "value": "1"],
                          ["parameter": "fallConfirmationSeconds", "value": "nan"]] {
            let result = try await registry.execute(actionID: "analytics.set_threshold", parameters: arguments)
            XCTAssertFalse(result.success)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let sampling = try await registry.execute(actionID: "analytics.set_sampling_fps", parameters: ["fps": "5", "idle_fps": "2", "boost_fps": "10"])
        XCTAssertTrue(sampling.success, sampling.summary)
        XCTAssertEqual(model.localAnalyticsEngine.settings.analyticsSamplingFPS, 5)
        let before = try Data(contentsOf: url)
        let invalid = try await registry.execute(actionID: "analytics.set_sampling_fps", parameters: ["fps": "2", "idle_fps": "4"])
        XCTAssertFalse(invalid.success)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAllOverlaysAndGlobalFlagsUseActualService() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, _) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        for (name, key) in WallAnalyticsAction.overlays {
            let value = !model.localAnalyticsEngine.settings.overlaySettings[keyPath: key]
            let result = try await registry.execute(actionID: "analytics.set_overlay", parameters: ["layer": name, "enabled": String(value)])
            XCTAssertTrue(result.success, result.summary)
            XCTAssertEqual(try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL).overlaySettings[keyPath: key], value)
        }
        let names = ["global", "person", "pose", "fall", "behavior", "inactivity", "loitering", "zone", "unusual_movement",
                     "crowd", "fight", "secondary_vlm", "sound", "banner", "evidence"]
        for name in names {
            let key = try XCTUnwrap(AnalyticsSetGlobalToggleAction.toggles[name])
            let value = !model.localAnalyticsEngine.settings[keyPath: key]
            var result = try await registry.execute(actionID: "analytics.set_global_toggle", parameters: ["feature": name, "enabled": String(value)])
            if name == "evidence" {
                XCTAssertTrue(result.requiresOperatorConfirmation)
                XCTAssertNotEqual(model.localAnalyticsEngine.settings[keyPath: key], value)
                result = try await registry.confirmAndExecute(token: XCTUnwrap(result.confirmationToken), confirmed: true)
            }
            XCTAssertTrue(result.success, result.summary)
            XCTAssertEqual(try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL)[keyPath: key], value)
        }
    }

    func testCameraOverrideAndZoneLifecyclePreservePolicyAndIDs() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let (root, model, camera) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let registry = ACTAActionRegistry()
        await registerAllWallActions(registry: registry, model: model)
        let override = try await registry.execute(actionID: "analytics.set_camera_override", parameters: ["camera_id": camera.uuidString, "enabled": "true", "fps": "7"])
        XCTAssertTrue(override.success, override.summary)
        XCTAssertEqual(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.customSamplingFPS, 7)
        XCTAssertEqual(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.inheritGlobalSettings, false)
        let read = try await registry.execute(actionID: "analytics.get_settings", parameters: ["camera_id": camera.uuidString])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.outputJSON.utf8)) as? [String: Any])
        let effective = try XCTUnwrap(object["effective"] as? [String: Any])
        XCTAssertEqual(effective["samplingFPS"] as? Double, 7)
        var rectangle = ["camera_id": camera.uuidString, "name": "Entrance", "x": "0.1", "y": "0.1", "width": "0.2", "height": "0.3"]
        let added = try await registry.execute(actionID: "analytics.set_restricted_zone", parameters: rectangle)
        XCTAssertTrue(added.success, added.summary)
        let zone = try XCTUnwrap(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.restrictedZones.first)
        var guiDraft = model.localAnalyticsEngine.settings
        guiDraft.cameraOverrides[camera]?.restrictedZones[0].enabled = false
        guiDraft.cameraOverrides[camera]?.restrictedZones[0].holdSeconds = 9
        try model.localAnalyticsEngine.updateSettings(guiDraft)
        rectangle["width"] = "0.4"
        let updated = try await registry.execute(actionID: "analytics.set_restricted_zone", parameters: rectangle)
        XCTAssertTrue(updated.success, updated.summary)
        let stored = try VideoAnalyticsSettingsStore.load(from: model.localAnalyticsEngine.settingsURL)
        XCTAssertEqual(stored.cameraOverrides[camera]?.restrictedZones.first?.id, zone.id)
        XCTAssertEqual(stored.cameraOverrides[camera]?.restrictedZones.first?.holdSeconds, 9)
        XCTAssertEqual(stored.cameraOverrides[camera]?.restrictedZones.first?.enabled, false)
        let inherited = try await registry.execute(actionID: "analytics.set_camera_override", parameters: ["camera_id": camera.uuidString, "inherit": "true"])
        XCTAssertTrue(inherited.success)
        XCTAssertEqual(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.restrictedZones.count, 1)
        let removed = try await registry.execute(actionID: "analytics.remove_restricted_zone", parameters: ["camera_id": camera.uuidString, "name": "Entrance"])
        XCTAssertTrue(removed.success, removed.summary)
        XCTAssertTrue(try XCTUnwrap(model.localAnalyticsEngine.settings.cameraOverrides[camera]?.restrictedZones.isEmpty))
        let bytes = try Data(contentsOf: model.localAnalyticsEngine.settingsURL)
        rectangle["x"] = "0.9"
        let invalidZone = try await registry.execute(actionID: "analytics.set_restricted_zone", parameters: rectangle)
        XCTAssertFalse(invalidZone.success)
        let unknownCamera = try await registry.execute(actionID: "analytics.set_camera_override", parameters: ["camera_id": UUID().uuidString, "fps": "4"])
        XCTAssertFalse(unknownCamera.success)
        XCTAssertEqual(try Data(contentsOf: model.localAnalyticsEngine.settingsURL), bytes)
    }
}
