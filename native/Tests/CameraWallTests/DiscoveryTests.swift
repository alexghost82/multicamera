import XCTest
import CameraCore
@testable import CameraWall

@MainActor
final class DiscoveryTests: XCTestCase {
    private let login = Credentials(username: "admin", password: "not-logged")

    func testProfilesSelectedByResolutionNotOrder() async throws {
        let sources = ["onvif://192.0.2.1?subtype=small", "onvif://192.0.2.1?subtype=large", "onvif://192.0.2.1?subtype=medium"]
        let discovery = CameraDiscovery(profiles: { _, _ in sources }, probe: { source, _ in
            let width = source == sources[0] ? 640 : (source == sources[1] ? 3840 : 1920)
            return DetectedStream(source: source, width: width, height: width / 2)
        })
        let result = try await discovery.discover(address: CameraAddress("192.0.2.1"), credentials: login, progress: { _ in })
        XCTAssertEqual(result.substream, sources[0])
        XCTAssertEqual(result.mainstream, sources[1])
    }

    func testHikvisionFallbackMustActuallyProduceFrames() async throws {
        var checked: [String] = []
        let discovery = CameraDiscovery(profiles: { _, _ in [] }, probe: { source, _ in
            checked.append(source)
            guard source.hasSuffix("/102") || source.hasSuffix("/101") else { return nil }
            return DetectedStream(source: source, width: source.hasSuffix("/102") ? 640 : 1920, height: 360)
        })
        let result = try await discovery.discover(address: CameraAddress("192.0.2.10"), credentials: login, progress: { _ in })
        XCTAssertEqual(result.substream, "rtsp://192.0.2.10:554/Streaming/Channels/102")
        XCTAssertEqual(result.mainstream, "rtsp://192.0.2.10:554/Streaming/Channels/101")
        XCTAssertEqual(checked.count, 2)
    }

    func testNoWorkingStreamIsNotSavedAsGuessedHikvisionURL() async throws {
        let discovery = CameraDiscovery(profiles: { _, _ in [] }, probe: { _, _ in nil })
        do {
            _ = try await discovery.discover(address: CameraAddress("192.0.2.1"), credentials: login, progress: { _ in })
            XCTFail("Discovery must fail instead of inventing a stream")
        } catch { XCTAssertTrue(error is ConfigurationError) }
    }

    func testSingleProfileAndUnsupportedProfile() async throws {
        let source = "onvif://192.0.2.1?subtype=only"
        let discovery = CameraDiscovery(profiles: { _, _ in ["onvif://192.0.2.1?subtype=unsupported", source] }, probe: { candidate, _ in
            candidate == source ? DetectedStream(source: source, width: 1280, height: 720) : nil
        })
        let result = try await discovery.discover(address: CameraAddress("192.0.2.1"), credentials: login, progress: { _ in })
        XCTAssertEqual(result.substream, source)
        XCTAssertNil(result.mainstream)
    }

    func testExistingCustomRTSPPathIsPreserved() async throws {
        let camera = Camera(name: "Existing", substream: "rtsp://192.0.2.1:8554/vendor/path")
        let discovery = CameraDiscovery(profiles: { _, _ in XCTFail("Do not rediscover a working saved source"); return [] }, probe: { source, _ in
            DetectedStream(source: source, width: 640, height: 360)
        })
        let result = try await discovery.discover(address: CameraAddress("192.0.2.1"), credentials: login, preferred: camera, progress: { _ in })
        XCTAssertEqual(result.substream, camera.substream)
    }

    func testCancelledDiscoveryDoesNotReturnAResult() async throws {
        let discovery = CameraDiscovery(profiles: { _, _ in ["onvif://192.0.2.1?subtype=only"] }, probe: { source, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return DetectedStream(source: source, width: 640, height: 360)
        })
        let task = Task { try await discovery.discover(address: CameraAddress("192.0.2.1"), credentials: login, progress: { _ in }) }
        do { _ = try await task.value; XCTFail("Cancelled discovery must not be saved") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}