import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class SettingsEngineGateFixture {
    let gate = ACTAAnalyticsSettingsWriteGate()
    @Published var settings = VideoAnalyticsSettings.safeDefaults
    var persisted = VideoAnalyticsSettings.safeDefaults
    var effects = 0

    func guiWrite(_ value: VideoAnalyticsSettings, expectedRevision: UUID? = nil, failAfterPersist: Bool = false) throws {
        try gate.perform(expectedRevision: expectedRevision) {
            persisted = value
            if failAfterPersist { throw Failure() }
            settings = value
            effects += 1
        }
    }

    struct Failure: Error {}
}

@MainActor
final class ACTAAnalyticsSettingsWriteGateTests: XCTestCase {
    func testGUIAndLegacyWritesInvalidateReviewIncludingABA() throws {
        let engine = SettingsEngineGateFixture()
        let reviewed = try engine.gate.captureRevision()
        var changed = engine.settings
        changed.enableSoundAlert.toggle()
        try engine.guiWrite(changed)
        try engine.guiWrite(.safeDefaults)
        XCTAssertEqual(engine.settings, .safeDefaults)
        XCTAssertNotEqual(try engine.gate.captureRevision(), reviewed)
        XCTAssertThrowsError(try engine.guiWrite(changed, expectedRevision: reviewed)) {
            XCTAssertTrue($0 is ACTAAnalyticsSettingsWriteGate.Error)
        }
        XCTAssertEqual(engine.effects, 2)
    }

    func testSynchronousPublishedReentryCannotStartWriteOrCapture() throws {
        let engine = SettingsEngineGateFixture()
        var attempted = false
        var rejected = false
        var captureRejected = false
        let subscription = engine.$settings.dropFirst().sink { _ in
            MainActor.assumeIsolated {
                attempted = true
                do { try engine.guiWrite(.safeDefaults) } catch { rejected = true }
                do { _ = try engine.gate.captureRevision() } catch { captureRejected = true }
            }
        }
        var next = engine.settings
        next.enableSoundAlert = true
        try engine.guiWrite(next)
        withExtendedLifetime(subscription) {}
        XCTAssertTrue(attempted && rejected && captureRejected)
        XCTAssertEqual(engine.settings, next)
        XCTAssertEqual(engine.persisted, next)
        XCTAssertEqual(engine.effects, 1)
    }

    func testFailedPartialWriteInvalidatesRevisionAndReleasesGate() throws {
        let engine = SettingsEngineGateFixture()
        let before = try engine.gate.captureRevision()
        var next = engine.settings
        next.enableSoundAlert = true
        XCTAssertThrowsError(try engine.guiWrite(next, failAfterPersist: true))
        XCTAssertNotEqual(try engine.gate.captureRevision(), before)
        XCTAssertNotEqual(engine.persisted, engine.settings)
        XCTAssertThrowsError(try engine.gate.perform(expectedRevision: before) {})
        try engine.guiWrite(next)
        XCTAssertEqual(engine.settings, engine.persisted)
    }

    func testMatchingRevisionRunsOnceAndInvalidatesIt() throws {
        let gate = ACTAAnalyticsSettingsWriteGate()
        let reviewed = try gate.captureRevision()
        var calls = 0
        try gate.perform(expectedRevision: reviewed) { calls += 1 }
        XCTAssertThrowsError(try gate.perform(expectedRevision: reviewed) { calls += 1 })
        XCTAssertEqual(calls, 1)
    }
}
