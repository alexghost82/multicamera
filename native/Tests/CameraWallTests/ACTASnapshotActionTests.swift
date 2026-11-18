import CameraCore
import Foundation
import Testing

@testable import CameraWall

private final class SnapshotActionDirectory {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".snapshot-action-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class SnapshotActionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor FakeSnapshotFrames: ACTASnapshotFrameProvider {
    private var frame: ACTASnapshotFrame
    private var captures: [UUID: ACTASnapshotFrame] = [:]
    private let afterCapture: @Sendable () -> Void
    init(_ frame: ACTASnapshotFrame, afterCapture: @escaping @Sendable () -> Void = {}) {
        self.frame = frame
        self.afterCapture = afterCapture
    }
    func captureFreshFrame(cameraID: UUID) async throws -> ACTASnapshotFrame {
        let captured = ACTASnapshotFrame(cameraID: frame.cameraID, frameID: UUID(),
            capturedUptime: frame.capturedUptime, selectedUptime: frame.selectedUptime,
            jpeg: Data([UInt8](frame.jpeg)))
        captures[captured.frameID] = captured
        afterCapture()
        return captured
    }
    func isCaptureValid(_ captured: ACTASnapshotFrame) async throws -> Bool {
        guard let original = captures[captured.frameID] else { return false }
        return original.cameraID == captured.cameraID
            && original.capturedUptime == captured.capturedUptime
            && original.selectedUptime == captured.selectedUptime && original.jpeg == captured.jpeg
    }
    func capturedID() -> UUID? { captures.keys.first }
    func set(_ next: ACTASnapshotFrame) { frame = next }
}

/// This fake publishes to memory only. It does not claim filesystem isolation.
private actor FakeSnapshotPublisher: ACTASnapshotPublicationBackend {
    let foundation = ACTASnapshotExportFoundation()
    let afterPrepare: @Sendable () -> Void
    var written: [UUID: Data] = [:]
    var destinations: Set<String> = []
    var latest: ACTASnapshotExportFoundation.Request?
    var failVerification = false
    var failCurrentVerification = false
    var wrongCamera = false
    var cancelled = 0

    init(afterPrepare: @escaping @Sendable () -> Void = {}) { self.afterPrepare = afterPrepare }

    func prepare(cameraID: UUID, jpeg: Data, destination: String) async throws -> ACTASnapshotExportFoundation.Request {
        let request = try await foundation.prepareForPublication(
            cameraID: wrongCamera ? UUID() : cameraID,
            jpeg: jpeg, destinationPath: destination)
        afterPrepare()
        return request
    }
    func cancel(_ request: ACTASnapshotExportFoundation.Request) async {
        await foundation.cancel(token: request.token)
        cancelled += 1
    }
    func publish(_ request: ACTASnapshotExportFoundation.Request) async throws {
        guard !destinations.contains(request.preview.destinationPath) else {
            throw ACTASnapshotExportFoundation.Failure.destinationExists
        }
        let approved = try await foundation.resolve(token: request.token, reviewed: request.preview, approved: true)
        written[request.token] = approved.jpeg
        destinations.insert(request.preview.destinationPath)
        latest = request
    }
    func verify(_ request: ACTASnapshotExportFoundation.Request) async throws -> Bool {
        !failVerification && written[request.token] != nil && latest?.token == request.token
    }
    func verifyCurrent(cameraID: UUID, destination: String) async throws -> Bool {
        !failVerification && !failCurrentVerification && latest?.preview.cameraID == cameraID
            && latest?.preview.destinationPath == destination
    }
    func setVerificationFailure() { failVerification = true }
    func setCurrentVerificationFailure() { failCurrentVerification = true }
    func setWrongCamera() { wrongCamera = true }
    func data(for request: UUID) -> Data? { written[request] }
    func count() -> Int { written.count }
    func cancellationCount() -> Int { cancelled }
}

struct ACTASnapshotActionTests {
    private let camera = UUID()
    private let frameID = UUID()
    private let bytes = Data([0xff, 0xd8, 1, 0xff, 0xd9])

    private func frame(camera: UUID? = nil, captured: TimeInterval = 99, byte: UInt8 = 1) -> ACTASnapshotFrame {
        ACTASnapshotFrame(
            cameraID: camera ?? self.camera, frameID: frameID, capturedUptime: captured, selectedUptime: 100,
            jpeg: Data([0xff, 0xd8, byte, 0xff, 0xd9]))
    }

    private func args(_ path: String) -> [String: String] {
        ["camera_id": camera.uuidString, "destination_path": path]
    }

    @Test func registryBindsDisplayedReviewToCapturedBytesAndDestination() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("captured.jpg").path
        let frames = FakeSnapshotFrames(frame())
        let publisher = FakeSnapshotPublisher()
        let clock = SnapshotActionClock()
        let action = ACTASnapshotAction(frames: frames, publisher: publisher, now: { clock.now() })
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let parameters = args(path)
        let context = ACTAActionContext(threadID: "review-thread")
        let review = try await registry.execute(actionID: action.id, parameters: parameters, context: context)
        let token = try #require(review.confirmationToken)
        #expect(review.requiresOperatorConfirmation)
        #expect(review.summary.contains(camera.uuidString))
        let capturedID = try #require(await frames.capturedID())
        #expect(review.summary.contains(capturedID.uuidString))
        #expect(review.summary.contains(path))
        #expect(review.summary.contains("directory_device="))
        #expect(review.summary.contains("directory_inode="))
        #expect(review.summary.contains("sha256=adeaec77d1bc772e9694f8b5d7ba0ab621797f61f2587493ba69bd8dbbf09bf1"))
        #expect(review.summary.contains(token))
        await frames.set(frame(byte: 2))
        clock.advance(30)
        let mismatch = try await registry.confirmAndExecute(
            token: token, confirmed: true, expectedActionID: action.id, expectedParameters: parameters,
            expectedThreadID: context.threadID, expectedReviewTitle: review.summary + " changed")
        #expect(!mismatch.success)
        #expect(await publisher.count() == 0)
        let wrongThread = try await registry.confirmAndExecute(
            token: token, confirmed: true, expectedActionID: action.id, expectedParameters: parameters,
            expectedThreadID: "other", expectedReviewTitle: review.summary)
        #expect(!wrongThread.success)
        let result = try await registry.confirmAndExecute(
            token: token, confirmed: true, expectedActionID: action.id, expectedParameters: parameters,
            expectedThreadID: context.threadID, expectedReviewTitle: review.summary)
        #expect(result.success && result.verified)
        #expect(await publisher.count() == 1)
        let latest = await publisher.latest
        #expect(try await publisher.data(for: #require(latest?.token)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: path))
        let replay = try await registry.confirmAndExecute(
            token: token, confirmed: true, expectedActionID: action.id, expectedParameters: parameters,
            expectedThreadID: context.threadID, expectedReviewTitle: review.summary)
        #expect(!replay.success)
    }

    @Test func rejectionAndUnsafeProductionBackendNeverPublish() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let frames = FakeSnapshotFrames(frame())
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: frames, publisher: publisher, now: { 100 })
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let parameters = args(path)
        let review = try await registry.execute(actionID: action.id, parameters: parameters)
        let token = try #require(review.confirmationToken)
        let rejected = try await registry.confirmAndExecute(token: token, confirmed: false)
        #expect(!rejected.success)
        #expect(await publisher.count() == 0)
        let unavailable = ACTASnapshotAction(
            frames: frames,
            publisher: ACTASnapshotUnavailablePublisher(foundation: ACTASnapshotExportFoundation()), now: { 100 })
        await registry.register(unavailable)
        let second = try await registry.execute(actionID: unavailable.id, parameters: parameters)
        let blocked = try await registry.confirmAndExecute(
            token: try #require(second.confirmationToken), confirmed: true, expectedActionID: unavailable.id,
            expectedParameters: parameters, expectedThreadID: "default", expectedReviewTitle: second.summary)
        #expect(!blocked.success && !blocked.verified)
        #expect(blocked.error?.hasPrefix("UNAVAILABLE:") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func rejectsStaleWrongCameraAndMismatchedPreparedSource() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let frames = FakeSnapshotFrames(frame(captured: 97))
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: frames, publisher: publisher, now: { 100 })
        let registry = ACTAActionRegistry()
        await registry.register(action)
        for bad in [frame(captured: 97), frame(captured: 101), frame(camera: UUID())] {
            await frames.set(bad)
            let result = try await registry.execute(actionID: action.id, parameters: args(path))
            #expect(!result.requiresOperatorConfirmation && !result.success)
        }
        await frames.set(frame())
        await publisher.setWrongCamera()
        let result = try await registry.execute(actionID: action.id, parameters: args(path))
        #expect(!result.requiresOperatorConfirmation && !result.success)
        #expect(await publisher.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func heldFrameSurvivesSlowPreparation() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let clock = SnapshotActionClock()
        let publisher = FakeSnapshotPublisher(afterPrepare: { clock.advance(3) })
        let action = ACTASnapshotAction(frames: FakeSnapshotFrames(frame()), publisher: publisher, now: { clock.now() })
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let result = try await registry.execute(actionID: action.id, parameters: args(path))
        #expect(result.requiresOperatorConfirmation)
        #expect(await publisher.cancellationCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func freshSelectionSurvivesSlowEncoding() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let clock = SnapshotActionClock()
        let publisher = FakeSnapshotPublisher()
        let frames = FakeSnapshotFrames(frame(), afterCapture: { clock.advance(3) })
        let action = ACTASnapshotAction(frames: frames, publisher: publisher, now: { clock.now() })
        let prepared = try await action.prepareConfirmation(parameters: args(path), context: ACTAActionContext())
        let result = try await action.executeConfirmed(parameters: args(path),
            context: ACTAActionContext(isConfirmed: true), snapshot: prepared.snapshot)
        #expect(result.success)
        #expect(await publisher.data(for: prepared.snapshot.request.token) == bytes)
    }

    @Test func expiredFrameAfterReviewCancelsWithoutPublishing() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let clock = SnapshotActionClock()
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(
            frames: FakeSnapshotFrames(frame()), publisher: publisher, now: { clock.now() })
        let prepared = try await action.prepareConfirmation(parameters: args(path), context: ACTAActionContext())
        clock.advance(300)
        let result = try await action.executeConfirmed(parameters: args(path),
            context: ACTAActionContext(isConfirmed: true), snapshot: prepared.snapshot)
        #expect(!result.success && result.error?.hasPrefix("STALE_FRAME:") == true)
        #expect(await publisher.cancellationCount() == 1)
        #expect(await publisher.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func directOrChangedArgumentsAndVerificationFailureAreNotSuccess() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let frames = FakeSnapshotFrames(frame())
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: frames, publisher: publisher, now: { 100 })
        let parameters = args(path)
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: ACTAActionContext())
        let direct = try await action.execute(parameters: parameters, context: ACTAActionContext(isConfirmed: true))
        let unconfirmed = try await action.executeConfirmed(
            parameters: parameters, context: ACTAActionContext(),
            snapshot: prepared.snapshot)
        let next = try await action.prepareConfirmation(parameters: parameters, context: ACTAActionContext())
        let changed = try await action.executeConfirmed(
            parameters: args(path + ".jpg"),
            context: ACTAActionContext(isConfirmed: true),
            snapshot: next.snapshot)
        #expect(!direct.success && !unconfirmed.success && !changed.success)
        #expect(await publisher.count() == 0)
        await publisher.setVerificationFailure()
        let last = try await action.prepareConfirmation(parameters: parameters, context: ACTAActionContext())
        let failed = try await action.executeConfirmed(
            parameters: parameters,
            context: ACTAActionContext(isConfirmed: true),
            snapshot: last.snapshot)
        #expect(!failed.success && !failed.verified)
        #expect(failed.error?.hasPrefix("VERIFICATION_FAILED:") == true)
    }

    @Test func changedReviewedBytesAreRejectedAndCancelled() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: FakeSnapshotFrames(frame()), publisher: publisher, now: { 100 })
        let prepared = try await action.prepareConfirmation(parameters: args(path), context: ACTAActionContext())
        let original = prepared.snapshot.frame
        let altered = ACTASnapshotFrame(cameraID: original.cameraID, frameID: original.frameID,
            capturedUptime: original.capturedUptime, selectedUptime: original.selectedUptime,
            jpeg: Data([0xff, 0xd8, 2, 0xff, 0xd9]))
        let tampered = ACTASnapshotAction.Snapshot(frame: altered, request: prepared.snapshot.request)
        let failed = try await action.executeConfirmed(parameters: args(path),
            context: ACTAActionContext(isConfirmed: true), snapshot: tampered)
        #expect(!failed.success && failed.error?.hasPrefix("CONFIRMATION_MISMATCH:") == true)
        #expect(await publisher.cancellationCount() == 1)
        #expect(await publisher.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
        let replay = try await action.executeConfirmed(parameters: args(path),
            context: ACTAActionContext(isConfirmed: true), snapshot: prepared.snapshot)
        #expect(!replay.success)
        #expect(await publisher.count() == 0)
    }

    @Test func cancelledExecutionConsumesPreparedRequestWithoutWriting() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: FakeSnapshotFrames(frame()), publisher: publisher, now: { 100 })
        let prepared = try await action.prepareConfirmation(parameters: args(path), context: ACTAActionContext())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await action.executeConfirmed(parameters: args(path),
                context: ACTAActionContext(isConfirmed: true), snapshot: prepared.snapshot)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await publisher.cancellationCount() == 1)
        #expect(await publisher.count() == 0)
        let replay = try await action.executeConfirmed(parameters: args(path),
            context: ACTAActionContext(isConfirmed: true), snapshot: prepared.snapshot)
        #expect(!replay.success)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func sourceBufferMutationAfterReviewCannotChangeApprovedBytes() async throws {
        let root = try SnapshotActionDirectory()
        let path = root.url.appendingPathComponent("frame.jpg").path
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        defer { storage.deallocate() }
        bytes.copyBytes(to: storage, count: bytes.count)
        let alias = Data(bytesNoCopy: storage, count: bytes.count, deallocator: .none)
        let source = ACTASnapshotFrame(cameraID: camera, frameID: frameID, capturedUptime: 99,
                                       selectedUptime: 100, jpeg: alias)
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: FakeSnapshotFrames(source), publisher: publisher, now: { 100 })
        let prepared = try await action.prepareConfirmation(parameters: args(path), context: ACTAActionContext())
        storage[2] = 9
        let result = try await action.executeConfirmed(parameters: args(path),
            context: ACTAActionContext(isConfirmed: true), snapshot: prepared.snapshot)
        #expect(result.success)
        #expect(await publisher.data(for: prepared.snapshot.request.token) == bytes)
    }

    @Test func independentReviewsRetainEachFrameAndRegistryVerificationMustPass() async throws {
        let root = try SnapshotActionDirectory()
        let olderPath = root.url.appendingPathComponent("older.jpg").path
        let newerPath = root.url.appendingPathComponent("newer.jpg").path
        let frames = FakeSnapshotFrames(frame())
        let publisher = FakeSnapshotPublisher()
        let action = ACTASnapshotAction(frames: frames, publisher: publisher, now: { 100 })
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let olderParameters = args(olderPath)
        let newerParameters = args(newerPath)
        let older = try await registry.execute(actionID: action.id, parameters: olderParameters)
        await frames.set(frame(byte: 2))
        let newer = try await registry.execute(actionID: action.id, parameters: newerParameters)
        #expect(older.summary != newer.summary)
        let newResult = try await registry.confirmAndExecute(
            token: try #require(newer.confirmationToken), confirmed: true, expectedActionID: action.id,
            expectedParameters: newerParameters, expectedThreadID: "default", expectedReviewTitle: newer.summary)
        #expect(newResult.success)
        let newerRequest = try #require(await publisher.latest)
        #expect(await publisher.data(for: newerRequest.token) == frame(byte: 2).jpeg)
        let oldResult = try await registry.confirmAndExecute(
            token: try #require(older.confirmationToken), confirmed: true, expectedActionID: action.id,
            expectedParameters: olderParameters, expectedThreadID: "default", expectedReviewTitle: older.summary)
        #expect(oldResult.success && oldResult.verified)
        let olderRequest = try #require(await publisher.latest)
        #expect(await publisher.data(for: olderRequest.token) == bytes)
        await publisher.setCurrentVerificationFailure()
        let anotherPath = root.url.appendingPathComponent("another.jpg").path
        let anotherParameters = args(anotherPath)
        let another = try await registry.execute(actionID: action.id, parameters: anotherParameters)
        let failed = try await registry.confirmAndExecute(
            token: try #require(another.confirmationToken), confirmed: true, expectedActionID: action.id,
            expectedParameters: anotherParameters, expectedThreadID: "default", expectedReviewTitle: another.summary)
        #expect(!failed.success && !failed.verified)
    }
}
