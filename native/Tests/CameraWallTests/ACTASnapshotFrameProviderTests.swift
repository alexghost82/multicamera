import CameraCore
import CoreVideo
import Foundation
import Testing

@testable import CameraWall

private struct SnapshotTestPixel: @unchecked Sendable {
    let value: CVPixelBuffer
}

private enum SnapshotPixelTestError: Error { case inaccessible }

private func fillSnapshotPixel(_ pixel: CVPixelBuffer, value: UInt8) throws {
    guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else {
        throw SnapshotPixelTestError.inaccessible
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    if CVPixelBufferIsPlanar(pixel) {
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else {
                throw SnapshotPixelTestError.inaccessible
            }
            memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
    } else {
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw SnapshotPixelTestError.inaccessible }
        memset(base, Int32(value), CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
    }
}

private func firstSnapshotByte(_ pixel: CVPixelBuffer, plane: Int? = nil) throws -> UInt8 {
    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
        throw SnapshotPixelTestError.inaccessible
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    let base = plane.map { CVPixelBufferGetBaseAddressOfPlane(pixel, $0) }
        ?? CVPixelBufferGetBaseAddress(pixel)
    guard let base else { throw SnapshotPixelTestError.inaccessible }
    return base.load(as: UInt8.self)
}

private func snapshotPlane(_ pixel: CVPixelBuffer, plane: Int) throws -> [UInt8] {
    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
        throw SnapshotPixelTestError.inaccessible
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else {
        throw SnapshotPixelTestError.inaccessible
    }
    let rows = CVPixelBufferGetHeightOfPlane(pixel, plane)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
    let width = CVPixelBufferGetWidthOfPlane(pixel, plane) * (plane == 0 ? 1 : 2)
    return (0..<rows).flatMap {
        Array(UnsafeBufferPointer(start: base.advanced(by: $0 * stride).assumingMemoryBound(to: UInt8.self),
                                  count: width))
    }
}

private func fillSnapshotPlane(_ pixel: CVPixelBuffer, plane: Int, value: UInt8) throws {
    guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else {
        throw SnapshotPixelTestError.inaccessible
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane) else {
        throw SnapshotPixelTestError.inaccessible
    }
    memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
        * CVPixelBufferGetHeightOfPlane(pixel, plane))
}

@MainActor
private final class SnapshotSourceFixture {
    var camera = Camera(name: "Fake", substream: "")
    var session = CameraSession()

    func source(_ id: UUID) -> ACTAWallSnapshotFrameProvider.Source? {
        guard id == camera.id else { return nil }
        return .init(camera: camera, session: session)
    }
}

@MainActor
struct ACTASnapshotFrameProviderTests {
    private func pixel(width: Int = 2) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, 2, kCVPixelFormatType_32BGRA, nil, &pixel)
        #expect(result == kCVReturnSuccess)
        return try #require(pixel)
    }

    private func capture(_ provider: ACTAWallSnapshotFrameProvider, source: SnapshotSourceFixture,
                         pixel: CVPixelBuffer) async throws -> ACTASnapshotFrame {
        let session = source.session
        let task = Task { try await provider.captureFreshFrame(cameraID: source.camera.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !session.hasPendingOwnedFrameCapture && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard session.hasPendingOwnedFrameCapture else {
            task.cancel()
            throw SnapshotPixelTestError.inaccessible
        }
        session.publish(pixel, message: "Synthetic delivery")
        return try await task.value
    }

    @Test func heldFrameRejectsChangedBytesSessionAndCameraButNotNewFrames() async throws {
        let source = SnapshotSourceFixture()
        let pixel = try pixel()
        source.session.publish(pixel, message: "fake")
        let provider = ACTAWallSnapshotFrameProvider(
            source: { source.source($0) },
            encode: { _ in Data([0xff, 0xd8, 1, 0xff, 0xd9]) },
            now: { ProcessInfo.processInfo.systemUptime })
        let frame = try await capture(provider, source: source, pixel: pixel)
        #expect(try await provider.isCaptureValid(frame))
        let altered = ACTASnapshotFrame(cameraID: frame.cameraID, frameID: frame.frameID,
                                        capturedUptime: frame.capturedUptime, selectedUptime: frame.selectedUptime,
                                        jpeg: Data([0xff, 0xd8, 2, 0xff, 0xd9]))
        #expect(try await !provider.isCaptureValid(altered))
        source.camera.name = "Changed"
        #expect(try await !provider.isCaptureValid(frame))
        source.camera.name = "Fake"
        source.session.publish(pixel, message: "next fake frame")
        #expect(try await provider.isCaptureValid(frame))
        let next = try await capture(provider, source: source, pixel: pixel)
        source.session = CameraSession()
        #expect(try await !provider.isCaptureValid(next))
    }

    @Test func frameChangeDuringEncodingDoesNotReplaceCapturedBytes() async throws {
        let source = SnapshotSourceFixture()
        let pixel = try pixel()
        let next = try self.pixel(width: 3)
        source.session.publish(pixel, message: "fake")
        let provider = ACTAWallSnapshotFrameProvider(
            source: { source.source($0) },
            encode: { buffer in
                source.session.publish(next, message: "changed during encoding")
                return Data([0xff, 0xd8, UInt8(CVPixelBufferGetWidth(buffer)), 0xff, 0xd9])
            },
            now: { ProcessInfo.processInfo.systemUptime })
        let frame = try await capture(provider, source: source, pixel: pixel)
        #expect(frame.jpeg == Data([0xff, 0xd8, 2, 0xff, 0xd9]))
        #expect(try await provider.isCaptureValid(frame))
    }

    @Test func sessionChangeDuringEncodingIsRejected() async throws {
        let source = SnapshotSourceFixture()
        let pixel = try pixel()
        source.session.publish(pixel, message: "fake")
        let provider = ACTAWallSnapshotFrameProvider(
            source: { source.source($0) },
            encode: { _ in
                source.session = CameraSession()
                return Data([0xff, 0xd8, 1, 0xff, 0xd9])
            },
            now: { ProcessInfo.processInfo.systemUptime })
        await #expect(throws: ACTASnapshotActionError.self) {
            try await capture(provider, source: source, pixel: pixel)
        }
    }

    @Test func sessionStopRejectsNextFrameRequest() async throws {
        let session = CameraSession()
        let old = try pixel()
        session.publish(old, message: "old frame")
        let waiting = Task { try await session.captureNextOwnedFrame(timeout: .seconds(2)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !session.hasPendingOwnedFrameCapture && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(session.hasPendingOwnedFrameCapture)
        session.stop()
        session.publish(old, message: "late")
        await #expect(throws: ACTAFrameCaptureGate.Failure.self) { try await waiting.value }
        await #expect(throws: ACTAFrameCaptureGate.Failure.self) {
            try await session.captureNextOwnedFrame()
        }
    }

    @Test func sourceMutationDuringAsyncEncodingCannotAlterCopiedPixels() async throws {
        let source = SnapshotSourceFixture()
        let original = try pixel()
        try fillSnapshotPixel(original, value: 17)
        source.session.publish(original, message: "fake")
        let boxed = SnapshotTestPixel(value: original)
        let provider = ACTAWallSnapshotFrameProvider(
            source: { source.source($0) },
            encode: { copied in
                let mutation = Task.detached { try fillSnapshotPixel(boxed.value, value: 99) }
                try await mutation.value
                return Data([0xff, 0xd8, try firstSnapshotByte(copied), 0xff, 0xd9])
            },
            now: { ProcessInfo.processInfo.systemUptime })
        let frame = try await capture(provider, source: source, pixel: original)
        #expect(try firstSnapshotByte(original) == 99)
        #expect(frame.jpeg == Data([0xff, 0xd8, 17, 0xff, 0xd9]))
    }

    @Test func copiesBothBiPlanarPlanesAndRejectsUnsupportedFormats() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(nil, 4, 4, format, nil, &buffer) == kCVReturnSuccess)
            let original = try #require(buffer)
            try fillSnapshotPlane(original, plane: 0, value: 23)
            try fillSnapshotPlane(original, plane: 1, value: 37)
            let copy = try ACTASnapshotPixelCopy.copy(original)
            #expect(try snapshotPlane(original, plane: 0) == Array(repeating: UInt8(23), count: 16))
            #expect(try snapshotPlane(original, plane: 1) == Array(repeating: UInt8(37), count: 8))
            try fillSnapshotPixel(original, value: 91)
            #expect(try snapshotPlane(copy, plane: 0) == Array(repeating: UInt8(23), count: 16))
            #expect(try snapshotPlane(copy, plane: 1) == Array(repeating: UInt8(37), count: 8))
        }

        var unsupported: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_OneComponent8, nil, &unsupported) == kCVReturnSuccess)
        #expect(throws: ACTASnapshotActionError.self) {
            try ACTASnapshotPixelCopy.copy(#require(unsupported))
        }
    }

    @Test func realEncoderReceivesFrozenDelivery() async throws {
        let source = SnapshotSourceFixture()
        let original = try pixel()
        try fillSnapshotPixel(original, value: 53)
        let expected = try await VLMFrameEncoder.jpegData(from: ACTASnapshotPixelCopy.copy(original))
        let provider = ACTAWallSnapshotFrameProvider(
            source: { source.source($0) },
            encode: { copied in
                try fillSnapshotPixel(original, value: 97)
                return try await VLMFrameEncoder.jpegData(from: copied)
            },
            now: { ProcessInfo.processInfo.systemUptime })
        let frame = try await capture(provider, source: source, pixel: original)
        #expect(frame.jpeg == expected)
        #expect(try firstSnapshotByte(original) == 97)
    }
}
