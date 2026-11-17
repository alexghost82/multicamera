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
