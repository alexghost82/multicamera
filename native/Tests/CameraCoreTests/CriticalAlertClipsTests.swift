import XCTest
@testable import CameraCore

final class CriticalAlertClipsTests: XCTestCase {
    func testLookbackSamplingRequiresEveryOptInLifecycleAndFreshnessGate() {
        func allowed(
            operations: Bool = true, retainFrames: Bool = true, scheduled: Bool = true, rules: Bool = true,
            running: Bool = true, connecting: Bool = false, cameraEnabled: Bool = true,
            inScope: Bool = true, fresh: Bool = true, frame: Bool = true,
            inFlight: Int = 0, lastSample: TimeInterval? = nil, now: TimeInterval = 10
        ) -> Bool {
            AlertLookbackSamplingPolicy.shouldSample(
                operationsEnabled: operations, retainFullFrames: retainFrames,
                scheduledAnalysisEnabled: scheduled, hasEnabledRules: rules,
                wallRunning: running, connecting: connecting, cameraEnabled: cameraEnabled,
                cameraInScope: inScope, frameFresh: fresh, frameAvailable: frame,
                inFlightCount: inFlight, lastSubmittedAt: lastSample, now: now
            )
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(operations: false))
        XCTAssertFalse(allowed(retainFrames: false))
        XCTAssertFalse(allowed(scheduled: false))
        XCTAssertFalse(allowed(rules: false))
        XCTAssertFalse(allowed(running: false))
        XCTAssertFalse(allowed(connecting: true))
        XCTAssertFalse(allowed(inScope: false))
        XCTAssertFalse(allowed(fresh: false))
        XCTAssertFalse(allowed(frame: false))
        XCTAssertFalse(allowed(inFlight: AlertLookbackSamplingPolicy.maximumConcurrentEncodes))
        XCTAssertFalse(allowed(lastSample: 9.6))
        XCTAssertTrue(allowed(lastSample: 9.5))
    }

    func testLookbackBufferIsPerCameraTimeBoundedAndCapped() {
        var buffer = AlertLookbackBuffer()
        let cameraID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        func frame(_ serial: UInt64, _ offset: TimeInterval) -> AlertLookbackFrame {
            AlertLookbackFrame(serial: serial, capturedAt: start.addingTimeInterval(offset),
                               jpegData: Data(repeating: UInt8(truncatingIfNeeded: serial), count: 100))
        }
        XCTAssertTrue(buffer.append(frame(1, 0), cameraID: cameraID, now: start))
        XCTAssertFalse(buffer.append(frame(1, 0.5), cameraID: cameraID, now: start.addingTimeInterval(0.5)))
        XCTAssertFalse(buffer.append(frame(2, 0.2), cameraID: cameraID, now: start.addingTimeInterval(0.2)))
        XCTAssertTrue(buffer.append(frame(2, 0.5), cameraID: cameraID, now: start.addingTimeInterval(0.5)))
        XCTAssertEqual(buffer.snapshot(cameraID: cameraID, now: start.addingTimeInterval(0.5)).map(\.serial), [1, 2])
        XCTAssertTrue(buffer.snapshot(cameraID: UUID(), now: start.addingTimeInterval(0.5)).isEmpty)
        XCTAssertTrue(buffer.snapshot(cameraID: cameraID, now: start.addingTimeInterval(9)).isEmpty)

        buffer.removeAll()
        for cameraIndex in 0..<129 {
            let id = UUID()
            _ = buffer.append(frame(UInt64(cameraIndex * 2 + 1), 0), cameraID: id, now: start)
            _ = buffer.append(frame(UInt64(cameraIndex * 2 + 2), 0.5), cameraID: id, now: start.addingTimeInterval(0.5))
        }
        XCTAssertLessThanOrEqual(buffer.frameCount, AlertLookbackBuffer.maximumTotalFrames)
        XCTAssertLessThanOrEqual(buffer.byteCount, AlertLookbackBuffer.maximumTotalBytes)
    }

    func testReconnectRequiresASeparateRingAndOldFramesCannotEnterNewSequence() {
        var buffer = AlertLookbackBuffer()
        let cameraID = UUID()
        let before = Date(timeIntervalSince1970: 100)
        let after = before.addingTimeInterval(1)
        _ = buffer.append(AlertLookbackFrame(serial: 1, capturedAt: before, jpegData: Data("old-1".utf8)), cameraID: cameraID, now: before)
        _ = buffer.append(AlertLookbackFrame(serial: 2, capturedAt: before.addingTimeInterval(0.5), jpegData: Data("old-2".utf8)), cameraID: cameraID, now: before.addingTimeInterval(0.5))
        buffer.removeAll(cameraID: cameraID)
        _ = buffer.append(AlertLookbackFrame(serial: 1, capturedAt: after, jpegData: Data("new-1".utf8)), cameraID: cameraID, now: after)
        XCTAssertEqual(buffer.snapshot(cameraID: cameraID, now: after).map { String(decoding: $0.jpegData, as: UTF8.self) }, ["new-1"])
    }

    func testClipStorePersistsPrivateSequenceAndExpiresAfterSevenDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CriticalAlertClipStore(url: directory.appendingPathComponent("alert-clips"))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let alertID = UUID()
        let cameraID = UUID()
        let frames = (0..<4).map { index in
            AlertLookbackFrame(serial: UInt64(index), capturedAt: now.addingTimeInterval(Double(index) / 2),
                               jpegData: Data(repeating: UInt8(index + 1), count: 1024))
        }
        let clip = try store.save(alertID: alertID, cameraID: cameraID, frames: frames, now: now.addingTimeInterval(2))
        XCTAssertEqual(clip.frameCount, 4)
        XCTAssertEqual(try store.frames(for: alertID, now: now.addingTimeInterval(2)), frames.map(\.jpegData))
        XCTAssertEqual(try store.clips(now: now.addingTimeInterval(2)), [clip])
        let root = CriticalAlertClipStore.defaultURL
        let clipDirectory = directory.appendingPathComponent("alert-clips", isDirectory: true)
            .appendingPathComponent(alertID.uuidString.lowercased(), isDirectory: true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("alert-clips").path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: clipDirectory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("alert-clips/index.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: clipDirectory.appendingPathComponent("frame-01.jpg").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(root, directory)
        XCTAssertEqual(try store.pruneExpired(now: clip.expiresAt.addingTimeInterval(1)), 1)
        XCTAssertTrue(try store.clips(now: clip.expiresAt.addingTimeInterval(1)).isEmpty)
        XCTAssertThrowsError(try store.frames(for: alertID, now: clip.expiresAt.addingTimeInterval(1)))
    }

    func testClipStoreRejectsInvalidSequenceAndNeverOverwritesSameAlert() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CriticalAlertClipStore(url: directory.appendingPathComponent("clips"))
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cameraID = UUID()
        let first = AlertLookbackFrame(serial: 1, capturedAt: now, jpegData: Data("frame-1".utf8))
        let second = AlertLookbackFrame(serial: 2, capturedAt: now.addingTimeInterval(0.5), jpegData: Data("frame-2".utf8))
        XCTAssertThrowsError(try store.save(alertID: UUID(), cameraID: cameraID, frames: [first], now: now.addingTimeInterval(0.5)))
        XCTAssertThrowsError(try store.save(alertID: UUID(), cameraID: cameraID, frames: [second, first], now: now.addingTimeInterval(0.5)))
        let alertID = UUID()
        _ = try store.save(alertID: alertID, cameraID: cameraID, frames: [first, second], now: now.addingTimeInterval(0.5))
        XCTAssertThrowsError(try store.save(alertID: alertID, cameraID: cameraID, frames: [first, second], now: now.addingTimeInterval(0.5)))
        try store.delete(alertID)
        XCTAssertTrue(try store.clips().isEmpty)
    }
}