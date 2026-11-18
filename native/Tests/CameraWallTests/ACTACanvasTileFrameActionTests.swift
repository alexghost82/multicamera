import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class FakeTileFrameTransaction: ACTACanvasTileFrameTransaction {
    var enabled: Set<UUID> = []
    var runtime = VideoWallLayout()
    var persisted = VideoWallLayout()
    var gestureActive = false
    var conflict = false
    var failWrite = false
    var receipt: UUID?
    var writes = 0
    var attempts = 0

    func setFrame(_ frame: VideoTileFrame, for cameraID: UUID) -> ACTACanvasTileFrameOutcome {
        attempts += 1
        guard enabled.contains(cameraID) else { return .unavailable }
        guard !gestureActive else { return .busy }
        guard !conflict, runtime == persisted else { return .conflict }
        guard !failWrite else { return .failed }
        var next = runtime
        next.frames[cameraID.uuidString] = frame
        runtime = next
        persisted = next
        writes += 1
        let token = UUID()
        receipt = token
        return .written(token)
    }

    func verifies(_ receipt: UUID, frame: VideoTileFrame, for cameraID: UUID) -> Bool {
        self.receipt == receipt && enabled.contains(cameraID) && runtime == persisted &&
            runtime.frames[cameraID.uuidString] == frame &&
            persisted.frames[cameraID.uuidString] == frame
    }
}

@MainActor
final class ACTACanvasTileFrameActionTests: XCTestCase {
    private let camera = UUID()
    private let other = UUID()
    private let frame = VideoTileFrame(x: 25, y: 30, width: 400, height: 225)

    private func arguments(_ camera: UUID) -> [String: String] {
        ["camera_id": camera.uuidString, "x": "25", "y": "30", "width": "400", "height": "225"]
    }

    func testTypedActionMergesLatestLayoutAndVerifiesReadback() async throws {
        let transaction = FakeTileFrameTransaction()
        transaction.enabled = [camera, other]
        let otherFrame = VideoTileFrame(x: 3, y: 4, width: 200, height: 100)
        transaction.runtime.frames[other.uuidString] = otherFrame
        transaction.persisted = transaction.runtime
        let action = ACTACanvasSetTileFrameAction(state: .init(transaction: transaction))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let result = try await registry.executeJSON(actionID: action.id, argumentsJSON:
            #"{"camera_id":"\#(camera.uuidString)","x":25,"y":30,"width":400,"height":225}"#)
        XCTAssertTrue(result.success && result.verified, result.summary)
        XCTAssertEqual(transaction.runtime.frames[camera.uuidString], frame)
        XCTAssertEqual(transaction.persisted.frames[other.uuidString], otherFrame)
        transaction.persisted.frames[camera.uuidString] = otherFrame
        let verified = try await action.verify(parameters: arguments(camera), context: .init())
        XCTAssertFalse(verified)
    }

    func testInvalidArgumentsNeverReachTransaction() async throws {
        let transaction = FakeTileFrameTransaction()
        transaction.enabled = [camera]
        let action = ACTACanvasSetTileFrameAction(state: .init(transaction: transaction))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let invalid = [
            #"{"camera_id":"\#(camera.uuidString)","x":0,"y":0,"width":119,"height":90}"#,
            #"{"camera_id":"\#(camera.uuidString)","x":-1,"y":0,"width":120,"height":90}"#,
            #"{"camera_id":"bad","x":0,"y":0,"width":120,"height":90}"#,
            #"{"camera_id":"\#(camera.uuidString)","x":"0","y":0,"width":120,"height":90}"#,
            #"{"camera_id":"\#(camera.uuidString)","x":0,"y":0,"width":120,"height":90,"extra":1}"#
        ]
        for json in invalid {
            let result = try await registry.executeJSON(actionID: action.id, argumentsJSON: json)
            XCTAssertFalse(result.success, json)
        }
        XCTAssertThrowsError(try action.validate(parameters: [
            "camera_id": camera.uuidString, "x": "nan", "y": "0", "width": "120", "height": "90"
        ]))
        XCTAssertEqual(transaction.writes, 0)
    }

    func testCancellationBeforeTransactionDoesNotMutate() async throws {
        let transaction = FakeTileFrameTransaction()
        transaction.enabled = [camera]
        let action = ACTACanvasSetTileFrameAction(state: .init(transaction: transaction))
        let params = arguments(camera)
        let task = Task { try await action.execute(parameters: params, context: .init()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(transaction.attempts, 0)
        XCTAssertEqual(transaction.runtime, VideoWallLayout())
    }

    func testSharedGestureGateBlocksUntilEveryGestureEnds() async throws {
        let transaction = FakeTileFrameTransaction()
        transaction.enabled = [camera]
        let gestures = ACTACanvasGestureTracker()
        let action = ACTACanvasSetTileFrameAction(state: .init(transaction: transaction, gestures: gestures))
        let first = gestures.begin()
        let second = gestures.begin()
        let busy = try await action.execute(parameters: arguments(camera), context: .init())
        XCTAssertFalse(busy.success)
        XCTAssertEqual(transaction.attempts, 0)
        gestures.end(first)
        gestures.end(first)
        let stillBusy = try await action.execute(parameters: arguments(camera), context: .init())
        XCTAssertFalse(stillBusy.success)
        XCTAssertEqual(transaction.attempts, 0)
        gestures.end(second)
        let applied = try await action.execute(parameters: arguments(camera), context: .init())
        XCTAssertTrue(applied.success)
        XCTAssertEqual(transaction.writes, 1)
    }

    func testBusyConflictUnavailableAndFailedWritesPreserveState() async throws {
        let transaction = FakeTileFrameTransaction()
        transaction.enabled = [camera]
        let action = ACTACanvasSetTileFrameAction(state: .init(transaction: transaction))
        let params = arguments(camera)
        let original = transaction.runtime
        transaction.gestureActive = true
        let busy = try await action.execute(parameters: params, context: .init())
        XCTAssertFalse(busy.success)
        transaction.gestureActive = false
        transaction.conflict = true
        let conflict = try await action.execute(parameters: params, context: .init())
        XCTAssertFalse(conflict.success)
        transaction.conflict = false
        transaction.failWrite = true
        let failed = try await action.execute(parameters: params, context: .init())
        XCTAssertFalse(failed.success)
        transaction.failWrite = false
        let unavailable = try await action.execute(parameters: arguments(other), context: .init())
        XCTAssertFalse(unavailable.success)
        XCTAssertEqual(transaction.runtime, original)
        XCTAssertEqual(transaction.persisted, original)
        XCTAssertEqual(transaction.writes, 0)
        let verified = try await action.verify(parameters: params, context: .init())
        XCTAssertFalse(verified)
    }

    func testReceiptInvalidatedByLaterWriteOrFailedAttempt() async throws {
        let transaction = FakeTileFrameTransaction()
        transaction.enabled = [camera, other]
        let action = ACTACanvasSetTileFrameAction(state: .init(transaction: transaction))
        let params = arguments(camera)
        let first = try await action.execute(parameters: params, context: .init())
        XCTAssertTrue(first.success)
        transaction.receipt = UUID()
        let replaced = try await action.verify(parameters: params, context: .init())
        XCTAssertFalse(replaced)
        let second = try await action.execute(parameters: params, context: .init())
        XCTAssertTrue(second.success)
        transaction.gestureActive = true
        let failed = try await action.execute(parameters: arguments(other), context: .init())
        XCTAssertFalse(failed.success)
        let verified = try await action.verify(parameters: params, context: .init())
        XCTAssertFalse(verified)
    }
}
