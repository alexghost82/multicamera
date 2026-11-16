import AppKit
import SwiftUI
import Vision
import XCTest
@testable import CameraCore
@testable import CameraWall

@MainActor
final class SafetyIncidentCenterTests: XCTestCase {
    func testRussianIncidentCenterRendersSavedIncident() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LocalVideoAnalyticsEngine(settingsURL: root.appendingPathComponent("settings.json"),
            incidentsURL: root.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence"), auditLogURL: root.appendingPathComponent("audit.json"))
        let event = BehaviorSafetyCandidate(cameraID: UUID(), trackIDs: [UUID()], type: .fallConfirmed,
            severity: .critical, confidence: 0.91, monotonicTimestamp: 1, explanation: "Synthetic fixture",
            detectorSource: "test")
        _ = engine.incidentManager.ingest(candidate: event, cameraName: "Test Camera")
        engine.updateIncidentNote(event.id, note: "Operator fixture")
        let suite = "ACTA.IncidentCenterTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ru", forKey: "ACTA.interfaceLanguage")
        let language = LanguageSettings(defaults: defaults)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        NSApp.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: SafetyIncidentCenterView(engine: engine, languageSettings: language).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("incident-center-ru.png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        XCTAssertTrue(text.lowercased().contains("инциденты"), text)
        XCTAssertTrue(text.contains("Test Camera"), text)
    }
}
