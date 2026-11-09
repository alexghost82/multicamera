import Foundation
import Testing
@testable import CameraCore

struct LocalCameraTests {
    @Test func localCameraRoundTrip() throws {
        var config = WallConfiguration()
        config.cameras = [
            Camera(name: "MacBook", substream: "", localDeviceID: "built-in-id"),
            Camera(name: "iPhone", substream: "", localDeviceID: "continuity-id"),
            Camera(name: "Network", substream: "rtsp://camera.local/live")
        ]
        try config.validate()
        let decoded = try JSONDecoder().decode(WallConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test func existingCameraConfigurationStillLoads() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Network","substream":"rtsp://camera/live","enabled":true}
        """
        let camera = try JSONDecoder().decode(Camera.self, from: Data(json.utf8))
        #expect(camera.localDeviceID == nil)
        try camera.validate()
    }

    @Test func invalidLocalSourcesAreRejected() {
        #expect(throws: (any Error).self) {
            try Camera(name: "Mac", substream: "", localDeviceID: " ").validate()
        }
        #expect(throws: (any Error).self) {
            try Camera(name: "Mac", substream: "rtsp://camera/live", localDeviceID: "device").validate()
        }
    }
}
