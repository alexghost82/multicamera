import AppKit
import SwiftUI
import XCTest
import ScreenCaptureKit
import CoreMedia
import CoreImage
import CoreVideo
import Vision
import CameraCore
@testable import CameraWall

@MainActor
private final class ScheduleLayoutFixture: ObservableObject {
    @Published var preferences = VLMPreferences()
    @Published var operations = OperationsPreferences()
    @Published var descriptionsEnabled = true
    @Published var language = "en"
    @Published var updateSerial = 0

    init() {
        preferences.model = "/synthetic/very-long-application-directory/another-long-directory/local-models/qwen3.5-9b"
        preferences.analyzeAllEnabledCameras = false
        preferences.alertRules = [
            VLMAlertRule(condition: "A person is visible near the entrance to the building and the door remains open.", priority: .critical),
            VLMAlertRule(condition: "Проверьте видимое скопление людей рядом с входом в здание и открытой дверью.")
        ]
    }
}

@MainActor
private struct LocalizedScheduleLayoutView: View {
    @ObservedObject var fixture: ScheduleLayoutFixture
    let localizationBundle: Bundle
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color(red: 1, green: 0, blue: 1).frame(width: 24)
            VLMScheduleForm(draft: $fixture.preferences, operations: $fixture.operations,
                cameras: [], descriptionsEnabled: $fixture.descriptionsEnabled,
                descriptionQueue: Text("\(fixture.updateSerial)").frame(height: 200), errorMessage: "", save: {},
                localizationBundle: localizationBundle)
                .padding(12).frame(width: width, height: 720).background(ACTATheme.sidebar)
            Color(red: 1, green: 0, blue: 1).frame(width: 24)
        }
        .frame(width: width + 48, height: 720)
        .environment(\.locale, Locale(identifier: fixture.language))
        .preferredColorScheme(.dark)
    }
}

@MainActor
private struct CompositedSidebarFixture: View {
    @ObservedObject var fixture: ScheduleLayoutFixture
    let localizationBundle: Bundle

    var body: some View {
        VStack(spacing: 10) {
            Text("Анализ ИИ").frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Picker("", selection: .constant(2)) {
                Text("Спросить").tag(0)
                Text("История").tag(1)
                Text("Расписание").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 12)
            VLMScheduleForm(draft: $fixture.preferences, operations: $fixture.operations,
                cameras: [], descriptionsEnabled: $fixture.descriptionsEnabled,
                descriptionQueue: Text("\(fixture.updateSerial)").monospacedDigit().frame(height: 100)
                    .overlay(alignment: .topLeading) { Color(red: 1, green: 0, blue: 0).frame(width: 12, height: 12) },
                errorMessage: "", save: {}, localizationBundle: localizationBundle)
                .padding(12)
        }
        .frame(width: 420, height: 860)
        .modifier(AnalysisSidebarSurface())
        .environment(\.locale, Locale(identifier: "ru"))
        .preferredColorScheme(.dark)
    }
}

private struct OversizedNativeSidebarButton: NSViewRepresentable {
    let press: () -> Void

    func makeCoordinator() -> Target { Target(press: press) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Synthetic native control", target: context.coordinator, action: #selector(Target.activate))
        button.bezelStyle = .flexiblePush
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {}

    final class Target: NSObject {
        let press: () -> Void
        init(press: @escaping () -> Void) { self.press = press }
        @objc func activate() { press() }
    }
}

@MainActor
final class VLMSidebarLayoutTests: XCTestCase {
    func testRealRussianChatSendButtonReceivesMouseAndKeyboard() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        for width in [280, 420] {
            var submissions = 0
            let content = AnalysisQuestionComposer(question: .constant("Что видно у входа?"), sendDisabled: false) {
                submissions += 1
            }
            .padding(12).frame(width: CGFloat(width), height: 200)
            .environment(\.locale, Locale(identifier: "ru"))
            .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Isolated Chat Send Test"
            window.contentView = host
            defer { window.close() }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("chat-send-\(width).png"))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = false
            let originalImage = try XCTUnwrap(bitmap.cgImage)
            let enlarged = try XCTUnwrap(CGContext(data: nil, width: originalImage.width * 3, height: originalImage.height * 3,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            enlarged.interpolationQuality = .high
            enlarged.draw(originalImage, in: CGRect(x: 0, y: 0, width: originalImage.width * 3, height: originalImage.height * 3))
            try VNImageRequestHandler(cgImage: XCTUnwrap(enlarged.makeImage()), options: [:]).perform([request])
            // Vision may ignore white text on a saturated accent fill. Retry the
            // same visible bitmap in grayscale/inverted form without changing its geometry.
            if request.results?.contains(where: { $0.topCandidates(1).first?.string.lowercased().contains("отправить") == true }) != true {
                let normalized = CIImage(cgImage: try XCTUnwrap(enlarged.makeImage()))
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                    .applyingFilter("CIColorInvert")
                let image = try XCTUnwrap(CIContext().createCGImage(normalized, from: normalized.extent))
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            }
            let button = try XCTUnwrap(request.results?.first { result in
                result.topCandidates(1).first?.string.lowercased().contains("отправить") == true
            }, "The real visible Send label must be readable at width \(width); recognized: \(request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])")
            let bounds = button.boundingBox
            XCTAssertGreaterThan(bounds.minX, 0)
            XCTAssertLessThan(bounds.maxX, 1)
            let point = NSPoint(x: bounds.midX * host.bounds.width,
                y: (host.isFlipped ? 1 - bounds.midY : bounds.midY) * host.bounds.height)
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
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
            XCTAssertEqual(submissions, 1, "A real click must reach the production composer action")
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: key))
            XCTAssertEqual(submissions, 2, "Command-Return must activate the same Send action")
        }
    }

    func testRealRussianHistoryLabelsAndInputFitWithoutCropping() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        for width in [280, 320, 420, 600] {
            let content = AnalysisPanelViewport {
                AnalysisPanelTabs(selection: .constant(.history), alertCount: 2)
                AnalysisHistoryPage(status: AppLanguage.russian.localized("Local VLM not connected"), busy: false,
                    persistHistory: .constant(false), allowActions: .constant(false), expandTerms: .constant(false),
                    question: .constant(""), sendDisabled: true, clear: {}, submit: {}) {
                    AnalysisPanelEmptyState(title: "Ask about local track history", icon: "text.magnifyingglass",
                        detail: "Answers use recent saved track metadata and descriptions.")
                        .frame(minHeight: 180)
                }
            }
            .modifier(AnalysisSidebarSurface())
            .frame(width: CGFloat(width), height: 720)
            .environment(\.locale, Locale(identifier: "ru"))
            .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Isolated Russian History Fit Test"
            window.contentView = host
            defer { window.close() }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let labels = ["Спросить", "История", "Расписание", "Оповещения (2)",
                          "Сохранять локальную историю запросов", "Разрешить предложения действий", "Локально расширять поисковые термины",
                          "Спросить о сохранённой истории камер"]
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("history-fit-\(width).png"))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = false
            let originalImage = try XCTUnwrap(image.cgImage)
            let enlarged = try XCTUnwrap(CGContext(data: nil, width: originalImage.width * 3, height: originalImage.height * 3,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            enlarged.interpolationQuality = .high
            enlarged.draw(originalImage, in: CGRect(x: 0, y: 0, width: originalImage.width * 3, height: originalImage.height * 3))
            try VNImageRequestHandler(cgImage: XCTUnwrap(enlarged.makeImage()), options: [:]).perform([request])
            let observations = request.results ?? []
            func normalized(_ text: String) -> String {
                String(String.UnicodeScalarView(text.lowercased().unicodeScalars.map {
                    CharacterSet.alphanumerics.contains($0) ? $0 : UnicodeScalar(32)!
                })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            let recognized = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            for label in labels { XCTAssertTrue(normalized(recognized).contains(normalized(label)), "Complete label missing at width \(width): \(label). OCR: \(recognized)") }
            for observation in observations {
                XCTAssertGreaterThanOrEqual(observation.boundingBox.minX * CGFloat(width), 6)
                XCTAssertLessThanOrEqual(observation.boundingBox.maxX * CGFloat(width), CGFloat(width - 6))
            }
            let fields = editableFields(in: host)
            XCTAssertFalse(fields.isEmpty)
            for field in fields {
                let frame = field.convert(field.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.minX, 8)
                XCTAssertLessThanOrEqual(frame.maxX, CGFloat(width - 8))
            }
            window.close()
        }
    }

    func testHistoryQuestionRemainsVisibleAndSubmitsInCompactPanel() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        for (width, height) in [(280, 420), (420, 540)] {
            var submissions = 0
            let content = AnalysisPanelViewport {
                AnalysisPanelTabs(selection: .constant(.history), alertCount: 2)
                AnalysisHistoryPage(status: AppLanguage.russian.localized("Local VLM not connected"), busy: false,
                    persistHistory: .constant(false), allowActions: .constant(false), expandTerms: .constant(false),
                    question: .constant("Что было вчера?"), sendDisabled: false, clear: {}, submit: { submissions += 1 }) {
                    ForEach(0..<30, id: \.self) { index in
                        Text("Saved history message \(index)").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .modifier(AnalysisSidebarSurface())
            .frame(width: CGFloat(width), height: CGFloat(height))
            .environment(\.locale, Locale(identifier: "ru"))
            .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            let field = try XCTUnwrap(editableFields(in: host).first)
            let frame = field.convert(field.bounds, to: host)
            XCTAssertTrue(host.bounds.contains(frame), "History input must remain inside a \(width)x\(height) panel: \(frame)")

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let enlarged = try XCTUnwrap(CGContext(data: nil, width: image.width * 3, height: image.height * 3,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            enlarged.interpolationQuality = .high
            enlarged.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 3, height: image.height * 3))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(enlarged.makeImage()), options: [:]).perform([request])
            let button = try XCTUnwrap(request.results?.first {
                $0.topCandidates(1).first?.string.lowercased().contains("отправить") == true
            }, "History must have a visible Send question button at \(width)x\(height)")
            let bounds = button.boundingBox
            let point = NSPoint(x: bounds.midX * host.bounds.width,
                y: (host.isFlipped ? 1 - bounds.midY : bounds.midY) * host.bounds.height)
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
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
            XCTAssertEqual(submissions, 1, "The visible history send button must accept a click")
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: key))
            XCTAssertEqual(submissions, 2, "Command-Return must submit the history question")
            window.close()
        }
    }

    func testSharedBoundaryClipsOversizedContentAtEveryProposedPanelSize() throws {
        for size in [CGSize(width: 20, height: 12), CGSize(width: 80, height: 60),
                     CGSize(width: 160, height: 100), CGSize(width: 296, height: 500),
                     CGSize(width: 420, height: 720), CGSize(width: 600, height: 900)] {
            let content = ZStack(alignment: .topLeading) {
                Color(red: 1, green: 0, blue: 1)
                Color.cyan.frame(width: 1800, height: 1800)
                    .modifier(AnalysisSidebarSurface())
                    .frame(width: size.width, height: size.height)
                    .offset(x: 48, y: 48)
            }
            .frame(width: size.width + 96, height: size.height + 96)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let reference = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
            var overflow = 0
            for row in stride(from: 0, to: image.height, by: 2) {
                for column in stride(from: 0, to: image.width, by: 2) {
                    guard column < 47 || column > Int(size.width) + 48 || row < 47 || row > Int(size.height) + 48 else { continue }
                    let color = try XCTUnwrap(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                    if abs(color.redComponent - reference.redComponent) > 0.03
                        || abs(color.greenComponent - reference.greenComponent) > 0.03
                        || abs(color.blueComponent - reference.blueComponent) > 0.03 { overflow += 1 }
                }
            }
            XCTAssertEqual(overflow, 0, "Oversized content escaped a \(size.width)x\(size.height) panel")
            let center = try XCTUnwrap(bitmap.colorAt(x: 48 + Int(size.width / 2), y: 48 + Int(size.height / 2))?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(abs(center.redComponent - reference.redComponent) + abs(center.greenComponent - reference.greenComponent), 0.5,
                "The content must still render inside the panel")
        }
    }

    func testOversizedSidebarButtonCannotReceiveClicksOutsidePanel() async throws {
        _ = NSApplication.shared
        for nativeControl in [false, true] {
        var inside = 0
        var outside = 0
        let content = ZStack(alignment: .topLeading) {
            Button { outside += 1 } label: { Color.pink.frame(width: 600, height: 400) }
                .buttonStyle(.plain)
            Group {
                if nativeControl {
                    OversizedNativeSidebarButton { inside += 1 }.frame(width: 1800, height: 1800)
                } else {
                    Button { inside += 1 } label: { Color.cyan.frame(width: 1800, height: 1800) }
                        .buttonStyle(.plain)
                }
            }
                .modifier(AnalysisSidebarSurface())
                .frame(width: 160, height: 100)
                .offset(x: 48, y: 48)
        }.frame(width: 600, height: 400)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { window.close(); NSApp.setActivationPolicy(policy) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: 80, y: 80), NSPoint(x: 280, y: 200)] {
            let location = host.convert(NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
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
        XCTAssertEqual(inside, 1, "Only the click within panel bounds may activate its child; native=\(nativeControl)")
        XCTAssertEqual(outside, 1, "A clipped child must not intercept clicks in the adjacent view")
        }
    }

    func testCompositedGlassSidebarKeepsContentMarkerFixedDuringUpdates() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("Existing Screen Recording permission is required for the isolated compositor test.") }
        _ = NSApplication.shared
        let fixture = ScheduleLayoutFixture()
        fixture.language = "ru"
        fixture.descriptionsEnabled = false
        fixture.preferences.alertRules = []
        fixture.preferences.analyzeAllEnabledCameras = true
        let nativeRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let russian = try XCTUnwrap(Bundle(url: nativeRoot.appendingPathComponent("Resources/ru.lproj")))
        XCTAssertNotEqual(russian.localizedString(forKey: "Scheduled analysis", value: nil, table: nil), "Scheduled analysis")
        let host = NSHostingView(rootView: CompositedSidebarFixture(fixture: fixture, localizationBundle: russian))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.title = "Isolated Sidebar Compositor Test"
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { window.close(); NSApp.setActivationPolicy(previousPolicy) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        let modelField = try XCTUnwrap(editableFields(in: host).first, "The compositor test must focus the actual model-path editor")
        XCTAssertTrue(window.makeFirstResponder(modelField))
        let editor = try XCTUnwrap(window.fieldEditor(false, for: modelField) as? NSTextView)
        editor.setSelectedRange(NSRange(location: modelField.stringValue.utf16.count, length: 0))
        let marker = NSView(frame: NSRect(x: 2, y: 2, width: 12, height: 12))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.red.cgColor
        modelField.addSubview(marker, positioned: .above, relativeTo: nil)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = 420
        configuration.height = 888
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let observer = SidebarMarkerFrames()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(observer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "CameraWall.SidebarPixelTest"))
        try await stream.startCapture()
        do {
            for serial in 1...150 {
                fixture.updateSerial = serial
                try await Task.sleep(for: .milliseconds(16))
            }
            try await stream.stopCapture()
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        let frames = observer.snapshot()
        XCTAssertGreaterThan(frames.count, 20, "The compositor test must inspect rendered frames, not only settled layout")
        let reference = try XCTUnwrap(frames.dropFirst(5).compactMap { $0 }.first)
        for marker in frames.dropFirst(5) {
            let bounds = try XCTUnwrap(marker, "The content marker must not disappear during a redraw")
            XCTAssertEqual(bounds.minX, reference.minX, accuracy: 2)
            XCTAssertEqual(bounds.minY, reference.minY, accuracy: 2)
        }
    }

    func testRussianLanguageSwitchSettlesWithoutRepeatedRelayoutOrLosingDraft() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = directory.appendingPathComponent("Localization.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.camerawall.sidebar-language-test", "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "ru"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let nativeRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "ru"] {
            try FileManager.default.copyItem(at: nativeRoot.appendingPathComponent("Resources/\(language).lproj"),
                to: resources.appendingPathComponent("\(language).lproj"))
        }
        let bundle = try XCTUnwrap(Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent()))
        let russian = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("ru.lproj")))
        XCTAssertNotEqual(russian.localizedString(forKey: "Scheduled analysis", value: nil, table: nil), "Scheduled analysis")
        for width in [320, 420, 600] {
            let fixture = ScheduleLayoutFixture()
            let initial = fixture.preferences
            let operations = fixture.operations
            let host = NSHostingView(rootView: LocalizedScheduleLayoutView(fixture: fixture, localizationBundle: bundle, width: CGFloat(width)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 48, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(in: host).first)
            scroll.scrollerStyle = .legacy
            let observedDocument = try XCTUnwrap(scroll.documentView)
            observedDocument.postsFrameChangedNotifications = true
            let frameHistory = SidebarFrameHistory()
            NotificationCenter.default.addObserver(frameHistory, selector: #selector(SidebarFrameHistory.capture(_:)),
                name: NSView.frameDidChangeNotification, object: observedDocument)
            defer { NotificationCenter.default.removeObserver(frameHistory) }
            window.makeFirstResponder(nil)
            var languageSizes: [String: NSSize] = [:]
            var images: [String: Data] = [:]
            for (iteration, language) in ["ru", "en", "ru", "en"].enumerated() {
                withAnimation(.easeInOut(duration: 0.2)) { fixture.language = language }
                try await Task.sleep(for: .milliseconds(250))
                var previousSize: NSSize?
                for _ in 0..<4 {
                    fixture.objectWillChange.send()
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let document = try XCTUnwrap(scroll.documentView)
                    let size = document.bounds.size
                    XCTAssertLessThanOrEqual(size.width, scroll.contentView.bounds.width + 1)
                    if let previousSize {
                        XCTAssertEqual(size.width, previousSize.width, accuracy: 0.5)
                        XCTAssertEqual(size.height, previousSize.height, accuracy: 0.5)
                    }
                    previousSize = size
                    try await Task.sleep(for: .milliseconds(50))
                }
                let size = try XCTUnwrap(previousSize)
                if let original = languageSizes[language] {
                    XCTAssertEqual(size.height, original.height, accuracy: 0.5)
                    XCTAssertEqual(size.width, original.width, accuracy: 0.5)
                }
                languageSizes[language] = size
                images[language] = try checkImage(host, panelWidth: width, position: "\(language)-\(iteration)")
                XCTAssertEqual(fixture.preferences, initial)
                XCTAssertEqual(fixture.operations, operations)
                XCTAssertTrue(fixture.descriptionsEnabled)
            }
            XCTAssertNotEqual(images["ru"], images["en"], "Real localized strings must render differently")
            fixture.language = "ru"
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let document = try XCTUnwrap(scroll.documentView)
            let target = NSPoint(x: 0, y: min(200, max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
            let initialOrigin = scroll.contentView.bounds.origin
            let initialSize = document.bounds.size
            XCTAssertGreaterThan(initialOrigin.y, 0)
            for serial in 1...30 {
                fixture.updateSerial = serial
                try await Task.sleep(for: .milliseconds(16))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                XCTAssertEqual(document.bounds.width, initialSize.width, accuracy: 0.5)
                XCTAssertEqual(document.bounds.height, initialSize.height, accuracy: 0.5)
                XCTAssertEqual(scroll.contentView.bounds.origin.y, initialOrigin.y, accuracy: 0.5)
            }
            XCTAssertEqual(fixture.preferences, initial)
            XCTAssertEqual(fixture.operations, operations)
            if width == 420 {
                let originalHeight = document.bounds.height
                fixture.preferences.alertRules.append(contentsOf: (0..<8).map { _ in
                    VLMAlertRule(condition: "Additional long synthetic condition for checking dynamic document height after native hosting updates.")
                })
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(document.bounds.height, originalHeight)
                fixture.preferences.alertRules = initial.alertRules
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(document.bounds.height, originalHeight, accuracy: 1)
                XCTAssertEqual(fixture.preferences, initial)
            }
            for frame in frameHistory.frames where frame.width > 0 {
                XCTAssertLessThanOrEqual(frame.width, scroll.contentView.bounds.width + 1,
                    "Intermediate document frames must not expand beyond the viewport")
                XCTAssertEqual(frame.minX, 0, accuracy: 0.5,
                    "Intermediate document frames must remain leading-aligned")
            }
            window.close()
        }
    }

    func testScheduleFieldsStayInsideNarrowAndWidePanelBeforeAndAfterScrolling() async throws {
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for width in [320, 420, 600] {
            let fixture = ScheduleLayoutFixture()
            let initial = fixture.preferences
            var saves = 0
            let form = VLMScheduleForm(
                draft: Binding(get: { fixture.preferences }, set: { fixture.preferences = $0 }),
                operations: Binding(get: { fixture.operations }, set: { fixture.operations = $0 }),
                cameras: [Camera(name: "Очень длинное название камеры у главного входа в административное здание", substream: "rtsp://192.0.2.1/live")],
                descriptionsEnabled: Binding(get: { fixture.descriptionsEnabled }, set: { fixture.descriptionsEnabled = $0 }),
                descriptionQueue: Text("Synthetic description queue with a very long status message that must wrap within the panel.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true),
                errorMessage: "Synthetic settings error with enough text to verify that the footer also wraps within the available width.",
                save: { saves += 1 }
            )
            let content = HStack(spacing: 0) {
                Color(red: 1, green: 0, blue: 1).frame(width: 24)
                form.padding(12).frame(width: CGFloat(width), height: 720).background(ACTATheme.sidebar)
                Color(red: 1, green: 0, blue: 1).frame(width: 24)
            }
            .frame(width: CGFloat(width + 48), height: 720)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 48, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.title = "CameraWall Sidebar Layout Test"
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try checkImage(host, panelWidth: width, position: "top")
            let scroll = try XCTUnwrap(scrollViews(in: host).max { $0.bounds.height < $1.bounds.height })
            XCTAssertFalse(scroll.hasHorizontalScroller)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            XCTAssertLessThanOrEqual(document.bounds.width, scroll.bounds.width + 1)
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try checkImage(host, panelWidth: width, position: "bottom")
            XCTAssertEqual(fixture.preferences, initial)
            XCTAssertTrue(fixture.descriptionsEnabled)
            XCTAssertEqual(saves, 0)
            window.close()
        }
    }

    @discardableResult
    private func checkImage<Content: View>(_ host: NSHostingView<Content>, panelWidth: Int, position: String) throws -> Data {
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / host.bounds.width
        let reference = try XCTUnwrap(image.colorAt(x: Int(4 * scale), y: Int(4 * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(reference.redComponent - reference.greenComponent, 0.5)
        XCTAssertGreaterThan(reference.blueComponent - reference.greenComponent, 0.5)
        var overflow = 0
        for edge in [23, panelWidth + 24] {
            for height in stride(from: 4, to: 716, by: 4) {
                let color = try XCTUnwrap(image.colorAt(x: Int(CGFloat(edge) * scale), y: Int(CGFloat(height) * scale))?.usingColorSpace(.deviceRGB))
                if abs(color.redComponent - reference.redComponent) > 0.03
                    || abs(color.greenComponent - reference.greenComponent) > 0.03
                    || abs(color.blueComponent - reference.blueComponent) > 0.03 { overflow += 1 }
            }
        }
        XCTAssertEqual(overflow, 0, "Content crossed the panel edge at width \(panelWidth), \(position)")
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        if let directory = ProcessInfo.processInfo.environment["CAMERAWALL_TEST_ARTIFACTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try png.write(to: url.appendingPathComponent("sidebar-\(panelWidth)-\(position).png"))
        }
        return png
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let matches = (view as? NSScrollView).map { [$0] } ?? []
        return matches + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        let matches = (view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []
        return matches + view.subviews.flatMap { editableFields(in: $0) }
    }
}

@MainActor
private final class SidebarFrameHistory: NSObject {
    var frames: [NSRect] = []

    @objc func capture(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }
        frames.append(view.frame)
    }
}

private final class SidebarMarkerFrames: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CGRect?] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, rawStatus == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        let stride = CVPixelBufferGetBytesPerRow(image)
        var left = width, top = height, right = 0, bottom = 0
        for row in Swift.stride(from: 0, to: height, by: 2) {
            for column in Swift.stride(from: 0, to: width, by: 2) {
                let offset = row * stride + column * 4
                if base[offset + 2] > 180, base[offset + 1] < 80, base[offset] < 80 {
                    left = min(left, column); top = min(top, row)
                    right = max(right, column); bottom = max(bottom, row)
                }
            }
        }
        let bounds = left < right && top < bottom ? CGRect(x: left, y: top, width: right - left, height: bottom - top) : nil
        lock.lock()
        frames.append(bounds)
        lock.unlock()
    }

    func snapshot() -> [CGRect?] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}