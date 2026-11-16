import AppKit
import Combine
import SwiftUI
import XCTest
import CameraCore
@testable import CameraWall

@MainActor
final class SettingsTests: XCTestCase {
    func testEveryDraftValueSavesAndReloadsWithoutResettingConfidenceOrFPS() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var current = WallConfiguration()
        current.apiPort = 21984
        current.rtspPort = 28554
        current.cameras = [Camera(name: "Synthetic camera", substream: "rtsp://192.0.2.1/live")]
        let draft = WallSettingsDraft(configuration: current)
        draft.configuration.go2rtcPath = " /synthetic/tools/go2rtc "
        draft.configuration.columns = 9
        draft.staleMilliseconds = " 4500 "
        draft.configuration.detectionThreshold = 0.7
        draft.configuration.detectionFPS = 5
        XCTAssertEqual(draft.confidencePercent, 70)
        try draft.submit(save: { next in
            current = try current.applyingSettings(from: next)
            try ConfigurationStore.save(current, to: url)
        }, fileIsExecutable: { $0 == "/synthetic/tools/go2rtc" })
        let saved = try ConfigurationStore.load(from: url)
        XCTAssertEqual(saved, current)
        let reopened = WallSettingsDraft(configuration: saved)
        XCTAssertEqual(reopened.confidencePercent, 70)
        XCTAssertEqual(reopened.configuration.detectionFPS, 5)
        XCTAssertEqual(reopened.configuration.columns, 9)
        XCTAssertEqual(reopened.staleMilliseconds, "4500")
        XCTAssertEqual(reopened.configuration.go2rtcPath, "/synthetic/tools/go2rtc")
        XCTAssertEqual(saved.apiPort, 21984)
        XCTAssertEqual(saved.rtspPort, 28554)
        XCTAssertEqual(saved.cameras.count, 1)
    }

    func testInvalidTextAndMissingExecutableDoNotReachSave() {
        let draft = WallSettingsDraft(configuration: WallConfiguration())
        var saves = 0
        for value in ["", "abc", "2.5", "199", "30001"] {
            draft.staleMilliseconds = value
            XCTAssertThrowsError(try draft.submit(save: { _ in saves += 1 }, fileIsExecutable: { _ in true }))
        }
        draft.staleMilliseconds = "1000"
        XCTAssertThrowsError(try draft.submit(save: { _ in saves += 1 }, fileIsExecutable: { _ in false }))
        XCTAssertEqual(saves, 0)
    }

    func testBundledExecutableDoesNotOverwriteSavedCustomPath() throws {
        var original = WallConfiguration()
        original.go2rtcPath = "/synthetic/custom/go2rtc"
        let draft = WallSettingsDraft(configuration: original, bundledRelayPath: "/synthetic/app/Helpers/go2rtc")
        var saved: WallConfiguration?
        try draft.submit(save: { saved = $0 }, fileIsExecutable: { $0 == "/synthetic/app/Helpers/go2rtc" })
        XCTAssertEqual(saved?.go2rtcPath, original.go2rtcPath)
    }

    func testCancelAndFailedSaveDoNotChangeOriginalConfiguration() throws {
        let original = WallConfiguration()
        let draft = WallSettingsDraft(configuration: original)
        draft.configuration.detectionThreshold = 0.8
        draft.configuration.detectionFPS = 4
        XCTAssertEqual(original.detectionThreshold, 0.35)
        XCTAssertEqual(original.detectionFPS, 2)
        XCTAssertThrowsError(try draft.submit(save: { _ in throw ConfigurationError.invalid("Synthetic save failure") }, fileIsExecutable: { _ in true }))
        XCTAssertEqual(original.detectionThreshold, 0.35)
        XCTAssertEqual(draft.confidencePercent, 80)
    }

    func testNativeSliderUpdatesDraftAndSaveUsesItsValue() async throws {
        _ = NSApplication.shared
        let draft = WallSettingsDraft(configuration: WallConfiguration(), bundledRelayPath: "/usr/bin/true")
        var saved: WallConfiguration?
        let changed = expectation(description: "Slider publishes 70 percent")
        let didSave = expectation(description: "Save submits the draft")
        let observation = draft.$configuration.filter { abs($0.detectionThreshold - 0.7) < 0.0001 }
            .first().sink { _ in changed.fulfill() }
        defer { observation.cancel() }
        var controlFrames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: SettingsForm(draft: draft, save: { saved = $0; didSave.fulfill() }, onControlLayout: { controlFrames = $0 })
            .preferredColorScheme(.dark).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        window.title = "CameraWall Settings Test"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); NSApp.setActivationPolicy(previousPolicy) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        try sendMouseEvents([], to: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.updateWindows()
        XCTAssertTrue(window.isKeyWindow, "The isolated fixture must be key before sending its drag")
        host.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent("settings-before.png"))
        }
        let sliderFrame = try XCTUnwrap(controlFrames["confidence"])
        let inset: CGFloat = 8
        let currentFraction = (draft.configuration.detectionThreshold - 0.1) / 0.8
        let targetFraction = (0.7 - 0.1) / 0.8
        func point(x: CGFloat, y: CGFloat) -> NSPoint {
            host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
        }
        let sliderStart = point(x: sliderFrame.minX + inset + currentFraction * (sliderFrame.width - 2 * inset), y: sliderFrame.midY)
        let sliderEnd = point(x: sliderFrame.minX + inset + targetFraction * (sliderFrame.width - 2 * inset), y: sliderFrame.midY)
        try sendMouseEvents([(.leftMouseDown, sliderStart), (.leftMouseDragged, sliderEnd), (.leftMouseUp, sliderEnd)], to: window)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(draft.configuration.detectionThreshold, 0.7, accuracy: 0.0001)
        XCTAssertEqual(draft.confidencePercent, 70)
        let saveFrame = try XCTUnwrap(controlFrames["save"])
        let savePoint = point(x: saveFrame.midX, y: saveFrame.midY)
        try sendMouseEvents([(.leftMouseDown, savePoint), (.leftMouseUp, savePoint)], to: window)
        await fulfillment(of: [didSave], timeout: 2)
        XCTAssertEqual(saved?.detectionThreshold, 0.7)
        if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent("settings-70.png"))
        }
    }

    private func sendMouseEvents(_ events: [(NSEvent.EventType, NSPoint)], to window: NSWindow) throws {
        for (type, point) in events {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline,
              let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
            NSApp.updateWindows()
        }
    }
}