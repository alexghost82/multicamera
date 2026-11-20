import CameraCore
import CoreVideo
import Foundation
import XCTest
#if !ACTA_STANDALONE
@testable import CameraWall
#endif

private struct FrameFileFixture: ACTAReviewedFileSelector {
    let value: ACTAReviewedFileSelection
    func selectAndReview() async throws -> ACTAReviewedFileSelection { value }
}

final class ACTAReviewedFrameExportTests: XCTestCase {
    func testSyntheticFrozenPixelsAndExactPreviewPublication() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        try fill(source, value: 42)
        let copied = try ACTASnapshotPixelCopy.copy(source)
        try fill(source, value: 90)
        XCTAssertEqual(try firstByte(copied), 42)
        let encoded = try await VLMFrameEncoder.jpegData(from: copied)
        var mutableInput = encoded
        let preview = try ACTAFrameExportPreview(jpeg: mutableInput)
        mutableInput[mutableInput.startIndex] = 0
        XCTAssertEqual(preview.bytes, encoded)
        XCTAssertEqual(preview.image.width, 32)
        XCTAssertEqual(preview.image.height, 32)
        let decodedHex = ACTAReviewedFileExportUI.hex(preview.bytes)
            .split(whereSeparator: \.isWhitespace).compactMap { UInt8($0, radix: 16) }
        XCTAssertEqual(Data(decodedHex), encoded)
        XCTAssertThrowsError(try ACTAFrameExportPreview(jpeg: Data("not a JPEG".utf8)))

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".frame-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("frame.jpg")
        let action = ACTAReviewedFileExportAction(kind: .cameraFrame,
            selector: FrameFileFixture(value: .init(kind: .cameraFrame, bytes: preview.bytes, destination: destination)))
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: "fixture", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let injection = await host.broker.request(session: session, actionID: action.id,
                                                   argumentsJSON: #"{"destination_path":"/model.jpg"}"#)
        XCTAssertFalse(injection.success)
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertEqual(try Data(contentsOf: destination), preview.bytes)
        let next = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(next.requiresOperatorConfirmation)
        let collisionReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let collisionReview = try XCTUnwrap(collisionReviews.first)
        let collision = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: collisionReview, approved: true)
        XCTAssertFalse(collision.success)
        XCTAssertEqual(try Data(contentsOf: destination), preview.bytes)
    }

    func testFrameReviewLocalizationInBothLanguages() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ruBundle = try XCTUnwrap(Bundle(url: native.appendingPathComponent("Resources/ru.lproj")))
        let enBundle = try XCTUnwrap(Bundle(url: native.appendingPathComponent("Resources/en.lproj")))
        let ru = InterfaceLocalization(language: .russian, bundle: ruBundle)
        let en = InterfaceLocalization(language: .english, bundle: enBundle)
        XCTAssertEqual(ru.localized("Review the complete camera frame"), "Проверьте кадр целиком")
        XCTAssertEqual(en.localized("Review the complete camera frame"), "Review the complete camera frame")
        let summary = #"Camera frame, destination="/fixture.jpg", bytes=23, sha256=abcd. Full content reviewed locally. Create only; no replacement."#
        XCTAssertTrue(ru.message(summary).contains("Кадр камеры, место сохранения=\"/fixture.jpg\""))
    }

    func testJPEGExtensionDoesNotBypassFileDestinationValidation() async throws {
        let valid = ACTAReviewedFileExportAction(kind: .cameraFrame,
            selector: FrameFileFixture(value: .init(kind: .cameraFrame, bytes: Data([1]),
                destination: URL(fileURLWithPath: "/fixture/frame.jpeg"))))
        _ = try await valid.prepareConfirmation(parameters: [:], context: .init(threadID: "fixture"))
        let invalid = ACTAReviewedFileExportAction(kind: .cameraFrame,
            selector: FrameFileFixture(value: .init(kind: .cameraFrame, bytes: Data([1]),
                destination: URL(string: "https://example.invalid/frame.jpeg")!)))
        do {
            _ = try await invalid.prepareConfirmation(parameters: [:], context: .init(threadID: "fixture"))
            XCTFail("A non-file URL must be rejected")
        } catch {}
    }

    private func fill(_ buffer: CVPixelBuffer, value: UInt8) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw Failure.unavailable }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.unavailable }
        memset(address, Int32(value), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    private func firstByte(_ buffer: CVPixelBuffer) throws -> UInt8 {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Failure.unavailable }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.unavailable }
        return address.load(as: UInt8.self)
    }

    private enum Failure: Error { case unavailable }
}
