import XCTest
import Foundation
import CoreVideo
import VideoBridge
import CameraCore
@testable import CameraWall

final class StreamingTests: XCTestCase {
    private var go2rtc: String {
        ProcessInfo.processInfo.environment["CAMERAWALL_GO2RTC"] ?? "/opt/homebrew/bin/go2rtc"
    }

    @MainActor
    func testPerCameraAnalysisFlagsPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".streaming-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let previousModels = ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
        defer {
            try? FileManager.default.removeItem(at: directory)
            ModelSelectionRegistry.update(previousModels)
        }
        let first = Camera(name: "Front", substream: "rtsp://front.local/live", enabled: false)
        let second = Camera(name: "Back", substream: "rtsp://back.local/live", enabled: false)
        var config = WallConfiguration()
        config.cameras = [first, second]
        let file = directory.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(config, to: file)
        var models = ModelSelectionPreferences(); models.enabled = []
        try models.save(to: directory.appendingPathComponent("model-preferences.json"))
        var aiPreferences = VLMPreferences(); aiPreferences.actaBackendMode = .dryRun
        try VLMStore.save(aiPreferences, to: directory.appendingPathComponent("vlm.json"))

        let features = CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
            databaseURL: directory.appendingPathComponent("features.sqlite3"))
        try features.savePreferences(CameraFeaturePreferences(enabledFeatures: []))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        })
        let model = WallModel(configURL: file, workerMode: false,
            trackingStoreURL: directory.appendingPathComponent("tracking.sqlite3"),
            featureCoordinator: features, analyticsDirectoryURL: directory.appendingPathComponent("analytics"),
            agentClient: client,
            cameraMemoryStore: CameraMemoryStore(url: directory.appendingPathComponent("frames")),
            operationsWatchURL: directory.appendingPathComponent("watches.json"),
            missionStoreURL: directory.appendingPathComponent("missions.json"),
            cameraCredentialStore: StreamingTestCredentials(),
            operationsPreferencesURL: directory.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: directory.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: directory.appendingPathComponent("monitor.json"))
        defer { model.shutdown() }
        XCTAssertTrue(model.featurePreferences.enabledFeatures.isEmpty)
        XCTAssertTrue(model.config.cameras.allSatisfy { !$0.enabled })
        model.setYOLOEnabled(for: first.id, enabled: true)
        model.setAIChatEnabled(for: second.id, enabled: false)

        let saved = try ConfigurationStore.load(from: file).cameras
        XCTAssertTrue(saved[0].yoloEnabled)
        XCTAssertFalse(saved[1].yoloEnabled)
        XCTAssertTrue(saved[0].aiChatEnabled)
        XCTAssertFalse(saved[1].aiChatEnabled)
        XCTAssertFalse(model.running)
        XCTAssertNil(model.tiles[first.id]?.session)
        XCTAssertNil(model.tiles[second.id]?.session)
    }

    private struct StreamingTestCredentials: CameraCredentialStore {
        private struct UnexpectedAccess: Error {}
        func read(_ id: UUID) throws -> Credentials? { XCTFail("Unexpected credential read"); throw UnexpectedAccess() }
        func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential save"); throw UnexpectedAccess() }
        func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal"); throw UnexpectedAccess() }
    }

    @MainActor
    func testRelayAndHardwareDecoding() async throws {
        guard FileManager.default.isExecutableFile(atPath: go2rtc),
              FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            throw XCTSkip("Set CAMERAWALL_GO2RTC and install FFmpeg for streaming integration tests.")
        }
        let sourcePort = Int.random(in: 30000...39000)
        let sourceAPIPort = Int.random(in: 20000...29000)
        let relayPort = Int.random(in: 40000...49000)
        let apiPort = Int.random(in: 50000...59000)
        let source = Process()
        source.executableURL = URL(fileURLWithPath: go2rtc)
        source.arguments = ["-config", "{\"app\":{\"modules\":[\"api\",\"rtsp\",\"onvif\"]},\"api\":{\"listen\":\"127.0.0.1:\(sourceAPIPort)\",\"allow_paths\":[\"/onvif/\"]},\"rtsp\":{\"listen\":\"127.0.0.1:\(sourcePort)\"},\"streams\":{\"fixture\":[]},\"log\":{\"level\":\"disabled\"}}"]
        source.standardOutput = FileHandle.nullDevice
        source.standardError = FileHandle.nullDevice
        try source.run()
        defer { if source.isRunning { source.terminate(); source.waitUntilExit() } }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(source.isRunning)
        var publisher = Process()
        publisher.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        publisher.arguments = ["-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i",
            "testsrc2=size=640x360:rate=15", "-an", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-g", "15", "-bf", "0", "-pix_fmt", "yuv420p", "-f", "rtsp", "-rtsp_transport", "tcp",
            "rtsp://127.0.0.1:\(sourcePort)/fixture"]
        publisher.standardInput = FileHandle.nullDevice
        publisher.standardOutput = FileHandle.nullDevice
        publisher.standardError = FileHandle.nullDevice
        try publisher.run()
        defer { if publisher.isRunning { publisher.terminate(); publisher.waitUntilExit() } }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(publisher.isRunning)
        let relay = Go2RTC()
        defer { relay.stop() }
        var config = WallConfiguration()
        config.go2rtcPath = go2rtc
        config.apiPort = apiPort
        config.rtspPort = relayPort
        try await relay.start(config: config)
        let detected = try await CameraDiscovery.detect(ip: "127.0.0.1:\(sourceAPIPort)",
            credentials: Credentials(username: "fixture-user", password: "fixture-password"),
            config: config, preferred: nil, progress: { _ in })
        XCTAssertTrue(detected.substream.hasPrefix("onvif://127.0.0.1:"))
        XCTAssertFalse(detected.substream.contains("fixture-password"))
        XCTAssertFalse(detected.substream.contains("fixture-user"))
        let camera = Camera(name: "Fixture", substream: detected.substream, mainstream: detected.mainstream)
        let secondCamera = Camera(name: "Fixture 2", substream: detected.substream, mainstream: detected.mainstream)
        let address = try await relay.register(camera: camera, expanded: false)

        let unauthorized = URL(string: "http://127.0.0.1:\(apiPort)/api/streams")!
        let (_, response) = try await URLSession.shared.data(from: unauthorized)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        let (_, onvifResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(apiPort)/api/onvif")!)
        XCTAssertEqual((onvifResponse as? HTTPURLResponse)?.statusCode, 401)

        let decoder = try XCTUnwrap(cw_create())
        defer { cw_destroy(decoder) }
        XCTAssertEqual(cw_open(decoder, address, 5000), 0)
        var error: Int32 = 0
        var count = 0
        for _ in 0..<8 {
            guard let value = cw_next(decoder, &error) else { break }
            let pixel = value.takeRetainedValue()
            XCTAssertEqual(CVPixelBufferGetWidth(pixel), 640)
            XCTAssertEqual(CVPixelBufferGetHeight(pixel), 360)
            count += 1
        }
        XCTAssertEqual(error, 0)
        XCTAssertEqual(count, 8)
        cw_stop(decoder)
        XCTAssertNil(cw_next(decoder, &error))
        XCTAssertLessThan(error, 0)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var wallConfig = config
        wallConfig.apiPort = Int.random(in: 50000...59000)
        wallConfig.rtspPort = Int.random(in: 40000...49000)
        wallConfig.cameras = [camera, secondCamera]
        let file = directory.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(wallConfig, to: file)
        var helpers: [Go2RTC] = []
        let features = CameraFeatureCoordinator(preferencesURL: directory.appendingPathComponent("features.json"),
            databaseURL: directory.appendingPathComponent("features.sqlite3"))
        let model = WallModel(configURL: file, relayFactory: {
            let helper = Go2RTC()
            helpers.append(helper)
            return helper
        }, trackingStoreURL: directory.appendingPathComponent("tracking.sqlite3"),
           featureCoordinator: features, analyticsDirectoryURL: directory)
        defer { model.shutdown() }
        model.start()
        try await waitForFrames(model: model, camera: camera)
        try await waitForFrames(model: model, camera: secondCamera)
        let metricsDeadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < metricsDeadline && (model.tiles[camera.id]?.session?.snapshot().measuredFPS ?? 0) == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try model.writeDiagnostics(to: model.diagnosticsURL)
        let diagnosticData = try Data(contentsOf: model.diagnosticsURL)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any])
        let cameras = try XCTUnwrap(document["cameras"] as? [[String: Any]])
        let metrics = try XCTUnwrap(cameras.first)
        XCTAssertEqual(metrics["width"] as? Int, 640)
        XCTAssertEqual(metrics["height"] as? Int, 360)
        XCTAssertGreaterThan(try XCTUnwrap(metrics["fps"] as? Double), 0)
        XCTAssertEqual(metrics["stale"] as? Bool, false)
        XCTAssertEqual(metrics["decoder"] as? String, "VideoToolbox")
        let json = String(decoding: diagnosticData, as: UTF8.self)
        for secret in ["fixture-user", "fixture-password", "127.0.0.1", "rtsp://", "onvif://"] { XCTAssertFalse(json.contains(secret)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: model.diagnosticsURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let sessionBeforeLayout = try XCTUnwrap(model.tiles[camera.id]?.session)
        let secondSessionBeforeLayout = try XCTUnwrap(model.tiles[secondCamera.id]?.session)
        let framesBeforeLayout = sessionBeforeLayout.snapshot().frames
        let secondFramesBeforeLayout = secondSessionBeforeLayout.snapshot().frames
        if YOLO26Detector.defaultModelURL != nil {
            model.setYOLOEnabled(for: camera.id, enabled: true)
            let detectionDeadline = ProcessInfo.processInfo.systemUptime + 8
            while ProcessInfo.processInfo.systemUptime < detectionDeadline && model.tiles[camera.id]?.inferenceCount == 0 {
                model.refresh()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertGreaterThan(model.tiles[camera.id]?.inferenceCount ?? 0, 0)
            XCTAssertTrue(model.tiles[camera.id]?.session === sessionBeforeLayout, "YOLO must not restart video decoding")
            XCTAssertGreaterThan(sessionBeforeLayout.snapshot().frames, framesBeforeLayout, "Video must keep advancing during inference")
            model.setYOLOEnabled(for: camera.id, enabled: false)
            XCTAssertTrue(model.tiles[camera.id]?.objects.isEmpty == true)
        }
        let helpersBeforeLayout = helpers.count
        model.setGridColumns(3)
        XCTAssertEqual(model.config.columns, 3)
        XCTAssertTrue(model.tiles[camera.id]?.session === sessionBeforeLayout)
        XCTAssertTrue(model.tiles[secondCamera.id]?.session === secondSessionBeforeLayout)
        XCTAssertEqual(helpers.count, helpersBeforeLayout, "Changing the grid must not restart go2rtc")
        let movedFrame = VideoTileFrame(x: 80, y: 40, width: 480, height: 270)
        model.setTileFrame(movedFrame, for: camera.id)
        XCTAssertTrue(model.tiles[camera.id]?.session === sessionBeforeLayout)
        XCTAssertEqual(try VideoWallLayout.load(from: model.layoutURL).frames[camera.id.uuidString], movedFrame)
        model.resetLayout()
        XCTAssertTrue(model.tiles[camera.id]?.session === sessionBeforeLayout)
        XCTAssertEqual(helpers.count, helpersBeforeLayout)
        let layoutDeadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < layoutDeadline
            && (sessionBeforeLayout.snapshot().frames <= framesBeforeLayout
                || secondSessionBeforeLayout.snapshot().frames <= secondFramesBeforeLayout) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(sessionBeforeLayout.snapshot().frames, framesBeforeLayout)
        XCTAssertGreaterThan(secondSessionBeforeLayout.snapshot().frames, secondFramesBeforeLayout)
        let failedHelper = try XCTUnwrap(helpers.last)
        failedHelper.stop()
        model.refresh()
        XCTAssertTrue(model.connecting)
        XCTAssertTrue(model.notice.contains("1/5"))
        try await waitForFrames(model: model, camera: camera)
        XCTAssertTrue(model.running)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.notice, "Video wall restored")

        let cameraSession = try XCTUnwrap(model.tiles[camera.id]?.session)
        publisher.terminate()
        publisher.waitUntilExit()
        let disconnectDeadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < disconnectDeadline && cameraSession.snapshot().reconnects == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(cameraSession.snapshot().reconnects, 0, "Camera outage must trigger session reconnection")
        model.refresh()
        XCTAssertTrue(model.tiles[camera.id]?.stale == true)
        let framesBeforeResume = cameraSession.snapshot().frames
        let restoredPublisher = Process()
        restoredPublisher.executableURL = publisher.executableURL
        restoredPublisher.arguments = publisher.arguments
        restoredPublisher.standardInput = FileHandle.nullDevice
        restoredPublisher.standardOutput = FileHandle.nullDevice
        restoredPublisher.standardError = FileHandle.nullDevice
        publisher = restoredPublisher
        try publisher.run()
        let resumeDeadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < resumeDeadline && cameraSession.snapshot().frames <= framesBeforeResume + 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(cameraSession.snapshot().frames, framesBeforeResume + 2, "Video must recover when camera returns")
        model.refresh()
        XCTAssertFalse(model.tiles[camera.id]?.stale ?? true)

        helpers.last?.stop()
        model.refresh()
        XCTAssertTrue(model.connecting)
        let helperCount = helpers.count
        model.stop()
        model.refresh()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(model.running)
        XCTAssertEqual(helpers.count, helperCount, "Manual disconnect must cancel pending go2rtc recovery")

        if let rawCount = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_STREAMS"], let count = Int(rawCount), (1...120).contains(count) {
            let sessions = (0..<count).map { _ in CameraSession() }
            defer { sessions.forEach { $0.stop() } }
            for session in sessions { session.start(url: address) }
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline && sessions.contains(where: { $0.snapshot().frames < 5 }) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let live = sessions.filter { $0.snapshot().frames >= 5 }.count
            XCTAssertEqual(live, count, "Every concurrent VideoToolbox session must decode frames")
            print("Concurrent VideoToolbox sessions with >=5 frames: \(live)/\(count)")
        }
    }

    @MainActor
    private func waitForFrames(model: WallModel, camera: Camera) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < deadline {
            model.refresh()
            if !model.connecting, (model.tiles[camera.id]?.session?.snapshot().frames ?? 0) >= 3 { return }
            if let error = model.error { XCTFail(error); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Video wall did not resume producing frames")
    }

    func testUnreachableSourceAndCancellation() throws {
        let decoder = try XCTUnwrap(cw_create())
        defer { cw_destroy(decoder) }
        let started = Date()
        XCTAssertLessThan(cw_open(decoder, "rtsp://127.0.0.1:1/missing", 500), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        cw_stop(decoder)
    }
}