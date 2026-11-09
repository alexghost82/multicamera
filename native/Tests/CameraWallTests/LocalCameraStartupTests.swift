import Foundation
import Testing
@testable import CameraWall
import CameraCore

struct LocalCameraStartupTests {
    @Test @MainActor func packagedAppPrefersBundledGo2RTC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("CameraWall.app", isDirectory: true)
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/go2rtc")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        #expect(Go2RTC.executablePath(configuredPath: "/custom/go2rtc", bundleURL: bundleURL) == helper.path)
        #expect(Go2RTC.executablePath(configuredPath: "/custom/go2rtc", bundleURL: directory) == "/custom/go2rtc")
    }

    @Test @MainActor func localOnlyWallDoesNotRequireRelay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var config = WallConfiguration()
        config.go2rtcPath = "/nonexistent/go2rtc"
        // A disabled device avoids requesting hardware access during automated tests.
        config.cameras = [Camera(name: "Mac", substream: "", enabled: false, localDeviceID: "test")]
        try ConfigurationStore.save(config, to: url)
        let model = WallModel(configURL: url)
        defer { model.shutdown() }
        model.start()
        for _ in 0..<100 {
            if !model.connecting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.refresh()
        #expect(model.running)
        #expect(!model.connecting)
        #expect(model.error == nil)
    }
}
