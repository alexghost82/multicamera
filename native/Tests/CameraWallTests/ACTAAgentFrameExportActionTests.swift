import CameraCore
import CoreVideo
import Foundation
import Testing

@testable import CameraWall

private enum AgentFrameFixtureError: Error { case unavailable }

private final class AgentFrameTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime + offset
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        offset += seconds
    }
}

@MainActor
private final class AgentFrameFixture {
    var camera = Camera(name: "Synthetic camera", substream: "")
    var session = CameraSession()
    var inventoryRevision = UUID()
    var available = true
    var preview: Data?
    var reviewCount = 0
    let destination: URL
    let pixel: CVPixelBuffer

    init(destination: URL) throws {
        self.destination = destination
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw AgentFrameFixtureError.unavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AgentFrameFixtureError.unavailable }
        memset(base, 42, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        pixel = buffer
    }

    func provider() -> ACTAWallSnapshotFrameProvider {
        ACTAWallSnapshotFrameProvider(
            source: { [weak self] id in
                guard let self, self.available, self.camera.id == id, !self.session.isStopped else { return nil }
                return .init(camera: self.camera, session: self.session, inventoryRevision: self.inventoryRevision)
            },
            encode: { try await VLMFrameEncoder.jpegData(from: $0) },
            now: { ProcessInfo.processInfo.systemUptime })
    }

    func review(cameraID: UUID, frames: any ACTASnapshotFrameProvider) async throws -> ACTAReviewedCameraFrame {
        reviewCount += 1
        let frame = try await frames.captureFreshFrame(cameraID: cameraID)
        let preview = try ACTAFrameExportPreview(jpeg: frame.jpeg)
        self.preview = preview.bytes
        return .init(frame: frame, selection: .init(kind: .cameraFrame, bytes: preview.bytes, destination: destination))
    }

    func deliver() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !session.hasPendingOwnedFrameCapture && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard session.hasPendingOwnedFrameCapture else { throw AgentFrameFixtureError.unavailable }
        session.publish(pixel, message: "Synthetic")
    }
}

@MainActor
struct ACTAAgentFrameExportActionTests {
    private func directory() throws -> URL {
        let result = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".agent-frame-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }

    private func action(_ fixture: AgentFrameFixture) -> ACTAAgentFrameExportAction {
        let provider = fixture.provider()
        return ACTAAgentFrameExportAction(frames: provider, review: { camera, frames in
            try await fixture.review(cameraID: camera, frames: frames)
        }, language: { .english })
    }

    @Test func brokerAcceptsOnlyCameraAndPublishesExactlyReviewedBytes() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let action = action(fixture)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "one", actionIDs: [action.id]))
        let other = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "two", actionIDs: [action.id]))
        let descriptor = try #require(await host.broker.catalogue(session: session).first)
        #expect(descriptor.parameters.map(\.name) == ["camera_id"])
        #expect(descriptor.parameters.first?.isRequired == true)
        let id = fixture.camera.id.uuidString
        for json in ["{}", #"{"camera_id":1}"#, #"{"camera_id":"not-a-uuid"}"#,
                     #"{"camera_id":"\#(id)","destination_path":"/model.jpg"}"#,
                     #"{"camera_id":"\#(id)","bytes":"ff"}"#,
                     #"{"camera_id":"\#(id)","camera_id":"\#(id)"}"#] {
            let result = await host.broker.request(session: session, actionID: action.id, argumentsJSON: json)
            #expect(!result.success && !result.requiresOperatorConfirmation)
        }
        #expect(fixture.reviewCount == 0)
        let request = Task {
            await host.broker.request(session: session, actionID: action.id,
                                      argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        }
        try await fixture.deliver()
        let pending = await request.value
        #expect(pending.requiresOperatorConfirmation && pending.confirmationToken == nil)
        #expect(!pending.summary.contains(fixture.destination.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        let reviewedBytes = try #require(fixture.preview)
        let hex = ACTAReviewedFileExportUI.hex(reviewedBytes)
        #expect(Data(hex.split(whereSeparator: \.isWhitespace).compactMap { UInt8($0, radix: 16) }) == reviewedBytes)
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        #expect(review.parameters == ["camera_id": id])
        #expect(review.title.contains(id) && review.title.contains(fixture.destination.path))
        guard CVPixelBufferLockBaseAddress(fixture.pixel, []) == kCVReturnSuccess else {
            throw AgentFrameFixtureError.unavailable
        }
        guard let base = CVPixelBufferGetBaseAddress(fixture.pixel) else {
            CVPixelBufferUnlockBaseAddress(fixture.pixel, [])
            throw AgentFrameFixtureError.unavailable
        }
        memset(base, 97, CVPixelBufferGetBytesPerRow(fixture.pixel) * CVPixelBufferGetHeight(fixture.pixel))
        CVPixelBufferUnlockBaseAddress(fixture.pixel, [])
        fixture.session.publish(fixture.pixel, message: "Later synthetic frame")
        let wrongThread = await host.broker.resolve(operatorKey: host.operatorKey, session: other,
                                                    reviewed: review, approved: true)
        #expect(!wrongThread.success && !FileManager.default.fileExists(atPath: fixture.destination.path))
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        #expect(result.success && result.verified)
        #expect(try Data(contentsOf: fixture.destination) == reviewedBytes)
        let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        #expect(!replay.success)
        let collisionRequest = Task {
            await host.broker.request(session: session, actionID: action.id,
                                      argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        }
        try await fixture.deliver()
        #expect(await collisionRequest.value.requiresOperatorConfirmation)
        let collisionReview = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        let collision = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                  reviewed: collisionReview, approved: true)
        #expect(!collision.success)
        #expect(try Data(contentsOf: fixture.destination) == reviewedBytes)
    }

    @Test func productionCoordinatorRoutesFrameToolThroughBroker() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let action = action(fixture)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "one", actionIDs: [action.id]))
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun),
            transport: { _ in throw AgentFrameFixtureError.unavailable },
            keyProvider: { _ in nil }))
        let name = "acta__camera__snapshot"
        let id = fixture.camera.id.uuidString
        let absent = ACTAAgentFunctionCall(callID: "absent", name: name,
                                           argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        let notAdvertised = await coordinator.executeModelGeneratedAgentTool(absent, threadID: "one",
            requestToolNames: [], broker: host.broker, brokerSession: session)
        let absentJSON = try #require(JSONSerialization.jsonObject(with: Data(notAdvertised.outputJSON.utf8)) as? [String: Any])
        #expect(absentJSON["error"] is String)
        let bad = ACTAAgentFunctionCall(callID: "bad", name: name,
            argumentsJSON: #"{"camera_id":"\#(id)"}"#,
            rawArgumentsJSON: #"{"camera_id":"\#(id)","destination_path":"/model.jpg"}"#)
        let rejected = await coordinator.executeModelGeneratedAgentTool(bad, threadID: "one",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let badJSON = try #require(JSONSerialization.jsonObject(with: Data(rejected.outputJSON.utf8)) as? [String: Any])
        #expect(badJSON["action_success"] as? Bool == false)
        let wrongThread = await coordinator.executeModelGeneratedAgentTool(absent, threadID: "other",
            requestToolNames: [name], broker: host.broker, brokerSession: session)
        let wrongJSON = try #require(JSONSerialization.jsonObject(with: Data(wrongThread.outputJSON.utf8)) as? [String: Any])
        #expect(wrongJSON["error"] is String)
        #expect(fixture.reviewCount == 0)

        let call = ACTAAgentFunctionCall(callID: "capture", name: name,
                                         argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        let request = Task {
            await coordinator.executeModelGeneratedAgentTool(call, threadID: "one",
                requestToolNames: [name], broker: host.broker, brokerSession: session)
        }
        try await fixture.deliver()
        let routed = await request.value
        let json = try #require(JSONSerialization.jsonObject(with: Data(routed.outputJSON.utf8)) as? [String: Any])
        #expect(json["requires_operator_confirmation"] as? Bool == true)
        #expect(json["action_success"] as? Bool == false)
        #expect(json["action_verified"] as? Bool == false)
        #expect(!routed.outputJSON.contains(fixture.destination.path))
        #expect(!routed.outputJSON.contains("CONFIRM-"))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        let expected = try #require(fixture.preview)
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        #expect(review.actionID == "camera.snapshot" && review.parameters == ["camera_id": id])
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        #expect(result.success && result.verified)
        #expect(try Data(contentsOf: fixture.destination) == expected)
    }

    @Test func changedSourceRejectsApprovalWithoutCreatingFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let action = action(fixture)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .voice,
            threadID: "one", actionIDs: [action.id]))
        let id = fixture.camera.id.uuidString
        let request = Task {
            await host.broker.request(session: session, actionID: action.id,
                                      argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        }
        try await fixture.deliver()
        #expect(await request.value.requiresOperatorConfirmation)
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        fixture.session = CameraSession()
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        #expect(!result.success)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func snapshotIsBoundToCameraThreadAndSingleConfirmation() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let action = action(fixture)
        let args = ["camera_id": fixture.camera.id.uuidString]
        for (parameters, context) in [
            (["camera_id": UUID().uuidString], ACTAActionContext(threadID: "one", isConfirmed: true)),
            (args, ACTAActionContext(threadID: "two", isConfirmed: true)),
            (args, ACTAActionContext(threadID: "one", isConfirmed: false))
        ] {
            let preparing = Task { try await action.prepareConfirmation(parameters: args, context: .init(threadID: "one")) }
            try await fixture.deliver()
            let prepared = try await preparing.value
            let wrong = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: prepared.snapshot)
            #expect(!wrong.success)
            let replay = try await action.executeConfirmed(parameters: args,
                context: .init(threadID: "one", isConfirmed: true), snapshot: prepared.snapshot)
            #expect(!replay.success)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func expiredReviewAndRevokedSessionCannotPublish() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let provider = fixture.provider()
        let clock = AgentFrameTestClock()
        let action = ACTAAgentFrameExportAction(frames: provider, review: { camera, frames in
            try await fixture.review(cameraID: camera, frames: frames)
        }, now: { clock.now() }, language: { .english })
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "one", actionIDs: [action.id]))
        let id = fixture.camera.id.uuidString
        let request = Task {
            await host.broker.request(session: session, actionID: action.id,
                                      argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        }
        try await fixture.deliver()
        #expect(await request.value.requiresOperatorConfirmation)
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        clock.advance(301)
        let expired = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: review, approved: true)
        #expect(!expired.success && !FileManager.default.fileExists(atPath: fixture.destination.path))

        let another = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "two", actionIDs: [action.id]))
        await host.broker.closeSession(another, operatorKey: host.operatorKey)
        let revoked = await host.broker.request(session: another, actionID: action.id,
                                                argumentsJSON: #"{"camera_id":"\#(id)"}"#)
        #expect(!revoked.success && !revoked.requiresOperatorConfirmation)
    }

    @Test func changedFrameBytesDuringReviewAreRejected() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let provider = fixture.provider()
        let action = ACTAAgentFrameExportAction(frames: provider, review: { camera, frames in
            let reviewed = try await fixture.review(cameraID: camera, frames: frames)
            return .init(frame: reviewed.frame, selection: .init(kind: .cameraFrame,
                bytes: Data([0xff, 0xd8, 0xff, 0xd9]), destination: reviewed.selection.destination))
        }, language: { .english })
        let request = Task { try await action.prepareConfirmation(
            parameters: ["camera_id": fixture.camera.id.uuidString], context: .init(threadID: "one")) }
        try await fixture.deliver()
        await #expect(throws: ACTASnapshotActionError.self) { try await request.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func inventoryRevisionChangeInvalidatesRestoredCameraValues() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let action = action(fixture)
        let args = ["camera_id": fixture.camera.id.uuidString]
        let preparing = Task { try await action.prepareConfirmation(parameters: args, context: .init(threadID: "one")) }
        try await fixture.deliver()
        let prepared = try await preparing.value
        let originalName = fixture.camera.name
        fixture.camera.name = "Changed"
        fixture.inventoryRevision = UUID()
        fixture.camera.name = originalName
        fixture.inventoryRevision = UUID()
        let result = try await action.executeConfirmed(parameters: args, context: .init(threadID: "one", isConfirmed: true),
                                                       snapshot: prepared.snapshot)
        #expect(!result.success && !FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func sourceLossDuringReviewAndOperatorRejectionDoNotCreateFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try AgentFrameFixture(destination: dir.appendingPathComponent("frame.jpg"))
        let provider = fixture.provider()
        let unavailable = ACTAAgentFrameExportAction(frames: provider, review: { camera, frames in
            let reviewed = try await fixture.review(cameraID: camera, frames: frames)
            await MainActor.run { fixture.available = false }
            return reviewed
        }, language: { .english })
        let parameters = ["camera_id": fixture.camera.id.uuidString]
        let preparing = Task { try await unavailable.prepareConfirmation(parameters: parameters, context: .init(threadID: "one")) }
        try await fixture.deliver()
        await #expect(throws: ACTASnapshotActionError.self) { try await preparing.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))

        fixture.available = true
        let action = action(fixture)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "one", actionIDs: [action.id]))
        let request = Task {
            await host.broker.request(session: session, actionID: action.id,
                                      argumentsJSON: #"{"camera_id":"\#(fixture.camera.id.uuidString)"}"#)
        }
        try await fixture.deliver()
        #expect(await request.value.requiresOperatorConfirmation)
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: review, approved: false)
        #expect(!rejected.success && !FileManager.default.fileExists(atPath: fixture.destination.path))

        let next = Task {
            await host.broker.request(session: session, actionID: action.id,
                                      argumentsJSON: #"{"camera_id":"\#(fixture.camera.id.uuidString)"}"#)
        }
        try await fixture.deliver()
        #expect(await next.value.requiresOperatorConfirmation)
        let revokedReview = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
        let revoked = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: revokedReview, approved: true)
        #expect(!revoked.success && !FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func frameReviewAndStaleErrorHaveRussianAndEnglishText() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ruBundle = try #require(Bundle(url: native.appendingPathComponent("Resources/ru.lproj")))
        let enBundle = try #require(Bundle(url: native.appendingPathComponent("Resources/en.lproj")))
        let ru = InterfaceLocalization(language: .russian, bundle: ruBundle)
        let en = InterfaceLocalization(language: .english, bundle: enBundle)
        let key = "Camera frame, camera=%@, frame=%@, destination=%@, bytes=%@, sha256=%@. Full content reviewed locally. Create only; no replacement."
        let arguments: [CVarArg] = ["camera", "frame", "\"/frame.jpg\"", "42", "digest"]
        #expect(ru.localized(key, arguments: arguments).contains("Кадр камеры, камера=camera"))
        #expect(en.localized(key, arguments: arguments).contains("Camera frame, camera=camera"))
        #expect(ru.localized("STALE_FRAME: The reviewed capture is no longer available.").contains("КАДР УСТАРЕЛ"))
    }
}
