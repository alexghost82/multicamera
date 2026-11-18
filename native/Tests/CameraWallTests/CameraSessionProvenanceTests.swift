import CoreVideo
import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import CameraWall
#endif

final class CameraSessionProvenanceTests: XCTestCase {
    func testSyntheticFramesCarryTheirSessionAttemptAndStopFencesPublication() throws {
        let id = UUID()
        let session = CameraSession(attemptID: id)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        XCTAssertNil(session.snapshot().reconnectEvidence)
        let before = ContinuousClock().now
        session.publish(image, message: "Synthetic")
        let first = session.snapshot()
        let evidence = try XCTUnwrap(first.reconnectEvidence)
        XCTAssertNotNil(first.pixel)
        XCTAssertEqual(evidence.attemptID, id)
        XCTAssertEqual(evidence.sequence, 1)
        XCTAssertGreaterThanOrEqual(evidence.receivedAt, before)
        XCTAssertLessThanOrEqual(evidence.receivedAt, ContinuousClock().now)
        session.publish(image, message: "Synthetic")
        XCTAssertEqual(session.snapshot().reconnectEvidence?.sequence, 2)
        session.stop()
        session.publish(image, message: "Late")
        XCTAssertNil(session.snapshot().pixel)
        XCTAssertNil(session.snapshot().reconnectEvidence)
    }

    func testSeparateSessionsCannotShareAttemptIdentityByDefault() {
        let first = CameraSession()
        let second = CameraSession()
        XCTAssertNotEqual(first.attemptID, second.attemptID)
        first.stop()
        second.stop()
    }

    func testLateDeniedCameraPermissionCannotReplaceStoppedStatus() {
        let session = CameraSession()
        session.stop()
        session.cameraAccessResolved(allowed: false, deviceID: "synthetic")
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testDeniedCameraPermissionStillReportsErrorWhileActive() {
        let session = CameraSession()
        defer { session.stop() }
        session.cameraAccessResolved(allowed: false, deviceID: "synthetic")
        XCTAssertEqual(session.snapshot().message,
                       "Allow CameraWall in System Settings → Privacy & Security → Camera.")
    }

    func testStoppedSessionDoesNotStartLocalCapture() {
        let session = CameraSession()
        session.stop()
        var started = false
        session.runLocalCaptureStart(start: { started = true }, stop: {
            XCTFail("Unstarted capture should not need cleanup")
        })
        XCTAssertFalse(started)
    }

    func testStopDuringBlockingLocalStartCleansUpAfterLateCompletion() async {
        let session = CameraSession()
        let started = expectation(description: "fake capture start entered")
        let finished = expectation(description: "late capture cleaned up")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.runLocalCaptureStart(start: {
                started.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }, stop: { finished.fulfill() })
        }
        await fulfillment(of: [started], timeout: 1)
        let beforeStop = ContinuousClock.now
        session.stop()
        XCTAssertLessThan(beforeStop.duration(to: .now), .seconds(1))
        XCTAssertEqual(session.snapshot().message, "Stopped")
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testBlockingDecoderDestructionDoesNotBlockStopOrRetainFrame() async throws {
        let session = CameraSession()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        session.publish(try XCTUnwrap(pixel), message: "Synthetic")
        let destroying = expectation(description: "decoder destruction entered")
        let finished = expectation(description: "decoder destruction finished")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.retireDecoder {
                destroying.fulfill()
                _ = release.wait(timeout: .now() + 2)
            }
            finished.fulfill()
        }
        await fulfillment(of: [destroying], timeout: 1)
        let beforeRead = ContinuousClock.now
        XCTAssertNil(session.snapshot().reconnectEvidence)
        session.stop()
        XCTAssertLessThan(beforeRead.duration(to: .now), .seconds(1))
        XCTAssertNil(session.snapshot().pixel)
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    #if RECONNECT_FAKE_BRIDGE
    func testFakeDecoderFrameCarriesAttemptAndIsClearedOnStop() async throws {
        let id = UUID()
        let session = CameraSession(attemptID: id)
        defer { session.stop() }
        session.start(url: "fake-decoder")
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var snapshot = session.snapshot()
        while snapshot.pixel == nil && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = session.snapshot()
        }
        XCTAssertNotNil(snapshot.pixel)
        XCTAssertEqual(snapshot.reconnectEvidence?.attemptID, id)
        XCTAssertEqual(snapshot.reconnectEvidence?.sequence, snapshot.serial)
        session.stop()
        XCTAssertNil(session.snapshot().reconnectEvidence)
    }
    #endif
}
