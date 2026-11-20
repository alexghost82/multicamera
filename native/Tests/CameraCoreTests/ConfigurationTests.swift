import XCTest
@testable import CameraCore

final class ConfigurationTests: XCTestCase {
    func testDefaultWallLayoutUsesFourColumns() {
        XCTAssertEqual(WallConfiguration().columns, 4)
    }

    func testApplyingSettingsPreservesCurrentCamerasAndHiddenPorts() throws {
        var current = WallConfiguration()
        current.cameras = [Camera(name: "Current camera", substream: "rtsp://192.0.2.3/live")]
        current.apiPort = 21984
        current.rtspPort = 28554
        var draft = WallConfiguration()
        draft.columns = 8
        draft.staleAfterMilliseconds = 3600
        draft.go2rtcPath = "/synthetic/new/go2rtc"
        draft.detectionThreshold = 0.6
        draft.detectionFPS = 5
        let next = try current.applyingSettings(from: draft)
        XCTAssertEqual(next.cameras, current.cameras)
        XCTAssertEqual(next.apiPort, current.apiPort)
        XCTAssertEqual(next.rtspPort, current.rtspPort)
        XCTAssertEqual(next.columns, 8)
        XCTAssertEqual(next.staleAfterMilliseconds, 3600)
        XCTAssertEqual(next.go2rtcPath, draft.go2rtcPath)
        XCTAssertEqual(next.detectionThreshold, 0.6)
        XCTAssertEqual(next.detectionFPS, 5)
        draft.detectionThreshold = 2
        XCTAssertThrowsError(try current.applyingSettings(from: draft))
        XCTAssertEqual(current.detectionThreshold, 0.35)
    }

    func testEverySettingsValueRoundTripsAndPreservesCamerasAndHiddenPorts() throws {
        var config = WallConfiguration()
        config.columns = 7
        config.staleAfterMilliseconds = 2400
        config.go2rtcPath = "/synthetic/tools/go2rtc"
        config.apiPort = 21984
        config.rtspPort = 28554
        config.detectionThreshold = 0.7
        config.detectionFPS = 4
        config.cameras = [Camera(name: "Saved camera", substream: "rtsp://192.0.2.1/live", yoloEnabled: true)]
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(config, to: url)
        XCTAssertEqual(try ConfigurationStore.load(from: url), config)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testLegacySettingsDefaultOnlyNewYOLOValues() throws {
        var original = WallConfiguration()
        original.columns = 6
        original.staleAfterMilliseconds = 3300
        original.go2rtcPath = "/synthetic/legacy/go2rtc"
        original.apiPort = 31984
        original.rtspPort = 38554
        original.cameras = [Camera(name: "Legacy camera", substream: "rtsp://192.0.2.2/live")]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "detectionThreshold")
        legacy.removeValue(forKey: "detectionFPS")
        let loaded = try JSONDecoder().decode(WallConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.detectionThreshold, 0.35)
        XCTAssertEqual(loaded.detectionFPS, 2)
    }

    func testSettingsValidationBoundsAndInvalidYOLOValues() throws {
        for columns in [1, 16] {
            for stale in [200, 30000] {
                var config = WallConfiguration()
                config.columns = columns
                config.staleAfterMilliseconds = stale
                XCTAssertNoThrow(try config.validate())
            }
        }
        for columns in [0, 17] {
            var config = WallConfiguration()
            config.columns = columns
            XCTAssertThrowsError(try config.validate())
        }
        for stale in [199, 30001] {
            var config = WallConfiguration()
            config.staleAfterMilliseconds = stale
            XCTAssertThrowsError(try config.validate())
        }
        for threshold in [0.1, 0.35, 0.9] {
            for fps in [1.0, 2, 5] {
                var config = WallConfiguration()
                config.detectionThreshold = threshold
                config.detectionFPS = fps
                XCTAssertNoThrow(try config.validate())
            }
        }
        for threshold in [Double.nan, .infinity, -0.1, 0.0, 0.95] {
            var config = WallConfiguration()
            config.detectionThreshold = threshold
            XCTAssertThrowsError(try config.validate())
        }
        for fps in [Double.nan, .infinity, 0, 2.5, 6] {
            var config = WallConfiguration()
            config.detectionFPS = fps
            XCTAssertThrowsError(try config.validate())
        }
        var config = WallConfiguration()
        config.go2rtcPath = "   "
        XCTAssertThrowsError(try config.validate())
    }

    func testIPOnlyCameraAddresses() throws {
        XCTAssertEqual(try CameraAddress(" 192.0.2.10 ").display, "192.0.2.10")
        XCTAssertEqual(try CameraAddress("192.0.2.10:8080").onvifURL(port: 8080), "onvif://192.0.2.10:8080")
        XCTAssertEqual(try CameraAddress("2001:db8::1").rtspURL(path: "/live"), "rtsp://[2001:db8::1]:554/live")
        XCTAssertEqual(try CameraAddress("[2001:db8::1]:8899").display, "[2001:db8::1]:8899")
        XCTAssertEqual(try CameraAddress("CAMERA.local").host, "camera.local")
        for invalid in ["", "999.999.1.2", "rtsp://camera/live", "user:pass@camera", "camera/path", "camera?exec=bad", "camera#bad", "camera:0", "camera:65536", "camera name"] {
            XCTAssertThrowsError(try CameraAddress(invalid), invalid)
        }
    }

    func testDiscoveredONVIFProfileIsPersistableWithoutCredentials() throws {
        try Camera(name: "Camera", substream: "onvif://192.0.2.10:80?subtype=Profile_2").validate()
        XCTAssertThrowsError(try Camera(name: "Camera", substream: "onvif://admin:secret@192.0.2.10?subtype=Profile_2").validate())
    }

    func testVendorIndependentSources() throws {
        for source in ["rtsp://192.0.2.1:554/Streaming/Channels/102", "rtsp://camera.local/live?channel=3", "rtsps://[::1]:322/stream"] {
            try Camera(name: "Camera", substream: source).validate()
        }
    }

    func testRejectsCredentialsAndExecutableSources() {
        for source in ["rtsp://user:secret@camera/live", "exec:touch /tmp/file", "https://camera/live", "rtsp://camera/live#exec=bad", "rtsp://"] {
            XCTAssertThrowsError(try Camera(name: "Camera", substream: source).validate())
        }
    }

    func testExpandedSourceAndStableNames() {
        let camera = Camera(name: "Camera", substream: "rtsp://camera/sub", mainstream: "rtsp://camera/main")
        XCTAssertEqual(camera.source(expanded: false), "rtsp://camera/sub")
        XCTAssertEqual(camera.source(expanded: true), "rtsp://camera/main")
        XCTAssertNotEqual(camera.streamName(expanded: false), camera.streamName(expanded: true))
        let fallback = Camera(name: "Camera", substream: "rtsp://camera/live")
        XCTAssertEqual(fallback.source(expanded: true), fallback.substream)
    }

    func testScreenSourceIsBackwardCompatibleAndCannotMixWithOtherSources() throws {
        let screen = Camera(name: "Display", substream: "", screenDisplayID: "42")
        try screen.validate()
        XCTAssertEqual(try JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(screen)), screen)
        XCTAssertEqual(screen.source(expanded: false), "screen://42")

        var invalid = screen
        invalid.substream = "rtsp://192.0.2.1/stream"
        XCTAssertThrowsError(try invalid.validate())
        invalid = screen
        invalid.localDeviceID = "device"
        XCTAssertThrowsError(try invalid.validate())
        invalid = screen
        invalid.isapiEventsEnabled = true
        XCTAssertThrowsError(try invalid.validate())
    }

    func testSixtyCamerasRoundTrip() throws {
        var config = WallConfiguration()
        config.cameras = (1...60).map {
            Camera(name: "Camera \($0)", location: $0.isMultiple(of: 2) ? "Garage" : nil,
                   substream: "rtsp://camera\($0).local/live",
                   yoloEnabled: $0.isMultiple(of: 2), aiChatEnabled: !$0.isMultiple(of: 3))
        }
        let directory = try IsolatedStoreTestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cameras.json")
        try ConfigurationStore.save(config, to: url)
        XCTAssertEqual(try ConfigurationStore.load(from: url), config)
        config.cameras.append(config.cameras[0])
        XCTAssertThrowsError(try config.validate())
    }

    func testLegacyCameraConfigurationWithoutLocationStillDecodes() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Front Door","substream":"rtsp://camera.local/live","enabled":true}"#.utf8)
        let camera = try JSONDecoder().decode(Camera.self, from: data)
        XCTAssertNil(camera.location)
        XCTAssertEqual(camera.name, "Front Door")
        XCTAssertFalse(camera.yoloEnabled)
        XCTAssertTrue(camera.aiChatEnabled)
        XCTAssertFalse(camera.isapiEventsEnabled)
        XCTAssertFalse(camera.isapiHTTPS)
        XCTAssertEqual(camera.isapiPort, 80)
    }

    func testISAPIEventSettingsRoundTripAndValidation() throws {
        let camera = Camera(name: "Gate", substream: "rtsp://camera.local/live",
                            isapiEventsEnabled: true, isapiHTTPS: true, isapiPort: 8443)
        try camera.validate()
        let data = try JSONEncoder().encode(camera)
        let decoded = try JSONDecoder().decode(Camera.self, from: data)
        XCTAssertEqual(decoded, camera)
        XCTAssertThrowsError(try Camera(name: "Local", substream: "", localDeviceID: "device",
                                         isapiEventsEnabled: true).validate())
        XCTAssertThrowsError(try Camera(name: "Bad port", substream: "rtsp://camera/live",
                                         isapiPort: 70000).validate())
    }
}