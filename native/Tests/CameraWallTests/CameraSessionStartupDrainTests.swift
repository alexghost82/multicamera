import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import CameraWall

private final class CameraPermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?

    func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
    }

    func resolve(_ allowed: Bool) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(allowed)
    }
}

private actor CameraScreenStartProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            entered = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class SyntheticCaptureDelivery: @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    let buffer: CMSampleBuffer
    let connection: AVCaptureConnection

    init(buffer: CMSampleBuffer) {
        self.buffer = buffer
        connection = AVCaptureConnection(inputPorts: [], output: output)
    }

    func deliver(to session: CameraSession) {
        session.captureOutput(output, didOutput: buffer, from: connection)
    }
}

@MainActor
final class CameraSessionStartupDrainTests: XCTestCase {
    func testStopCancelsPendingCaptureRetryAndDrainsPromptly() async throws {
        let session = CameraSession()
        let scheduled = expectation(description: "retry timer installed")
        let unexpected = expectation(description: "cancelled retry must not run")
        unexpected.isInverted = true
        session.scheduleCaptureRetry(after: .milliseconds(1)) {
            session.scheduleCaptureRetry(after: .seconds(2)) { unexpected.fulfill() }
            session.scheduleCaptureRetry(after: .milliseconds(1)) { scheduled.fulfill() }
        }
        await fulfillment(of: [scheduled], timeout: 1)
        let start = ContinuousClock.now
        try await session.stopAndWait()
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        await fulfillment(of: [unexpected], timeout: 2.1)
    }

    func testStopWaitsForRunningCaptureRetryAndFencesNewOnes() async throws {
        let session = CameraSession()
        let entered = expectation(description: "retry entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        session.scheduleCaptureRetry(after: .milliseconds(1)) {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
        }
        await fulfillment(of: [entered], timeout: 1)
        session.stop()
        let forbidden = expectation(description: "retry after stop")
        forbidden.isInverted = true
        session.scheduleCaptureRetry(after: .milliseconds(1)) { forbidden.fulfill() }
        var finished = false
        let drain = Task { @MainActor in
            try await session.stopAndWait()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)
        release.signal()
        try await drain.value
        XCTAssertTrue(finished)
        await fulfillment(of: [forbidden], timeout: 0.05)
    }

    func testStopWaitsForInFlightCaptureDelegateCallback() async throws {
        let entered = expectation(description: "callback copying frame")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let gate = ACTAFrameCaptureGate(copy: { pixel in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return pixel
        })
        let session = CameraSession(frameCapture: gate)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: try XCTUnwrap(pixel), formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: try XCTUnwrap(pixel),
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let delivery = SyntheticCaptureDelivery(buffer: try XCTUnwrap(sample))
        let capture = Task { try await session.captureNextOwnedFrame() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !session.hasPendingOwnedFrameCapture, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(session.hasPendingOwnedFrameCapture)
        DispatchQueue.global().async {
            delivery.deliver(to: session)
        }
        await fulfillment(of: [entered], timeout: 1)
        session.stop()
        var finished = false
        let drain = Task { @MainActor in
            try await session.stopAndWait()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)
        release.signal()
        try await drain.value
        _ = await capture.result
        delivery.deliver(to: session)
        XCTAssertNil(session.snapshot().pixel)
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testStopWaitsForLatePermissionBeforeQueueDrain() async throws {
        let session = CameraSession()
        let permission = CameraPermissionProbe()
        session.start(deviceID: "synthetic", authorizationStatus: { .notDetermined },
                      requestAccess: { permission.request($0) })
        session.stop()
        var finished = false
        let drain = Task { @MainActor in
            try await session.stopAndWait()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        permission.resolve(true)
        try await drain.value
        XCTAssertTrue(finished)
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testStoppedSessionRejectsPermissionRequest() async throws {
        let session = CameraSession()
        session.stop()
        session.start(deviceID: "synthetic", authorizationStatus: {
            XCTFail("Stopped session must not query camera authorization")
            return .notDetermined
        }, requestAccess: { _ in
            XCTFail("Stopped session must not request camera access")
        })
        try await session.stopAndWait()
    }

    func testImmediateDeniedPermissionKeepsNormalMessage() async throws {
        let session = CameraSession()
        session.start(deviceID: "synthetic", authorizationStatus: { .notDetermined },
                      requestAccess: { $0(false) })
        XCTAssertEqual(session.snapshot().message,
                       "Allow CameraWall in System Settings → Privacy & Security → Camera.")
        try await session.stopAndWait()
    }

    func testStopWaitsForInFlightAuthorizationCheck() async throws {
        let session = CameraSession()
        let entered = expectation(description: "authorization check entered")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.start(deviceID: "synthetic", authorizationStatus: {
                entered.fulfill()
                release.wait()
                return .denied
            }, requestAccess: { _ in
                XCTFail("Denied authorization must not request access")
            })
        }
        await fulfillment(of: [entered], timeout: 1)
        session.stop()
        var finished = false
        let drain = Task { @MainActor in
            try await session.stopAndWait()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        release.signal()
        try await drain.value
        XCTAssertEqual(session.snapshot().message, "Stopped")
    }

    func testStopWaitsForQueuedScreenStartTaskAndFencesNewStarts() async throws {
        let session = CameraSession()
        let probe = CameraScreenStartProbe()
        session.enqueueScreenStart { await probe.wait() }
        while await !probe.entered { await Task.yield() }
        session.stop()
        session.enqueueScreenStart { XCTFail("Stopped session must not enqueue screen work") }
        var finished = false
        let drain = Task { @MainActor in
            try await CameraSession.waitForStoppedSessions()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        await probe.release()
        try await drain.value
        XCTAssertTrue(finished)
    }
}
