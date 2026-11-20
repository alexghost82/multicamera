import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class ColumnsDomainFake: ACTACanvasColumnsDomain {
    var observation: ACTACanvasColumnsObservation
    var writes = 0
    var beforeCompare: (() -> Void)?
    var afterCommit: (() -> Void)?
    var failCapture = false
    var failCommit = false
    var corruptWrite = false
    struct Failure: Error {}

    init(_ config: WallConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(config)
        observation = .init(revision: UUID(), memory: bytes, persisted: bytes)
    }

    func capture() throws -> ACTACanvasColumnsObservation {
        if failCapture { throw Failure() }
        return observation
    }

    func commit(expected: ACTACanvasColumnsObservation, replacement: Data) throws -> ACTACanvasColumnsObservation? {
        beforeCompare?()
        if failCommit { throw Failure() }
        guard observation == expected else { return nil }
        writes += 1
        observation = .init(revision: UUID(), memory: replacement,
                            persisted: corruptWrite ? Data("broken".utf8) : replacement)
        let committed = observation
        afterCommit?()
        return committed
    }

    func replace(memory: Data? = nil, persisted: Data? = nil) {
        observation = .init(revision: UUID(), memory: memory ?? observation.memory,
                            persisted: persisted ?? observation.persisted)
    }
}

@MainActor
final class ACTAPreparedCanvasColumnsActionTests: XCTestCase {
    private func config() -> WallConfiguration {
        var config = WallConfiguration()
        config.cameras = [Camera(name: "Entrance", substream: "rtsp://example.invalid/private")]
        config.staleAfterMilliseconds = 2000
        config.detectionThreshold = 0.6
        config.detectionFPS = 3
        return config
    }

    func testBrokerReviewCommitReadbackAndReplay() async throws {
        let initial = config()
        let domain = try ColumnsDomainFake(initial)
        let action = ACTAPreparedCanvasColumnsAction(domain: domain)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let broker = try XCTUnwrap(made)
        let opened = await broker.broker.openSession(operatorKey: broker.operatorKey,
            input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let pending = await broker.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"columns":7}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertEqual(domain.writes, 0)
        let reviews = await broker.broker.reviews(operatorKey: broker.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        XCTAssertTrue(review.title.contains("4 -> 7"))
        XCTAssertFalse(review.title.contains("example.invalid"))
        let result = await broker.broker.resolve(operatorKey: broker.operatorKey, session: session, reviewed: review, approved: true)
        XCTAssertTrue(result.success && result.verified, result.summary)
        var expected = initial
        expected.columns = 7
        XCTAssertEqual(try JSONDecoder().decode(WallConfiguration.self, from: domain.observation.memory), expected)
        XCTAssertEqual(try JSONDecoder().decode(WallConfiguration.self, from: domain.observation.persisted), expected)
        XCTAssertEqual(domain.writes, 1)
        let replay = await broker.broker.resolve(operatorKey: broker.operatorKey, session: session, reviewed: review, approved: true)
        XCTAssertFalse(replay.success)
        XCTAssertEqual(domain.writes, 1)
    }

    func testStaleMemoryDiskABAAndInterleavingNeverWrite() async throws {
        let params = ["columns": "8"], context = ACTAActionContext(threadID: "test")
        for scenario in 0..<5 {
            let domain = try ColumnsDomainFake(config())
            let action = ACTAPreparedCanvasColumnsAction(domain: domain)
            let prepared = try await action.prepareConfirmation(parameters: params, context: context)
            var other = config()
            other.detectionFPS = 4
            let changed = try JSONEncoder().encode(other)
            switch scenario {
            case 0: domain.replace(memory: changed)
            case 1: domain.replace(persisted: changed)
            case 2: domain.replace(); domain.replace()
            case 3: domain.beforeCompare = { domain.replace(persisted: changed) }
            default: domain.replace(memory: changed, persisted: changed)
            }
            let result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
            XCTAssertEqual(result.error?.components(separatedBy: ":").first, "STALE_REVIEW")
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testRejectsDivergenceUnknownFieldsInvalidAndReuse() async throws {
        let domain = try ColumnsDomainFake(config())
        let action = ACTAPreparedCanvasColumnsAction(domain: domain)
        let context = ACTAActionContext(threadID: "test"), params = ["columns": "2"]
        for input in [["columns": "0"], ["columns": "17"], ["columns": "x"], ["columns": "2", "extra": "x"]] {
            XCTAssertThrowsError(try action.validate(parameters: input))
        }
        let prepared = try await action.prepareConfirmation(parameters: params, context: context)
        let mismatch = try await action.executeConfirmed(parameters: ["columns": "99"], context: context, snapshot: prepared.snapshot)
        XCTAssertEqual(mismatch.error?.components(separatedBy: ":").first, "CONFIRMATION_MISMATCH")
        let replay = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertEqual(replay.error?.components(separatedBy: ":").first, "CONFIRMATION_CONSUMED")
        let direct = try await action.execute(parameters: params, context: context)
        XCTAssertFalse(direct.success)
        var different = config()
        different.apiPort = 12345
        domain.replace(persisted: try JSONEncoder().encode(different))
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Divergent disk must fail")
        } catch {}
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: domain.observation.memory) as? [String: Any])
        object["futureSetting"] = "must not be lost"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        domain.replace(memory: unknown, persisted: unknown)
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Unknown fields must fail")
        } catch {}
        let valid = try ColumnsDomainFake(config()).observation.memory
        let duplicate = Data((String(decoding: valid.dropLast(), as: UTF8.self) + #","columns":4}"#).utf8)
        domain.replace(memory: duplicate, persisted: duplicate)
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Duplicate fields must fail")
        } catch {}
        domain.failCapture = true
        do {
            _ = try await action.prepareConfirmation(parameters: params, context: context)
            XCTFail("Unreadable configuration must fail")
        } catch {}
        XCTAssertEqual(domain.writes, 0)
    }

    func testCommitAndReadbackFailuresAndVerificationChanges() async throws {
        let domain = try ColumnsDomainFake(config())
        let action = ACTAPreparedCanvasColumnsAction(domain: domain)
        let context = ACTAActionContext(threadID: "test"), params = ["columns": "6"]
        var prepared = try await action.prepareConfirmation(parameters: params, context: context)
        domain.failCommit = true
        var result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertEqual(result.error?.components(separatedBy: ":").first, "COMMIT_FAILED")
        domain.failCommit = false
        domain.corruptWrite = true
        prepared = try await action.prepareConfirmation(parameters: params, context: context)
        result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertEqual(result.error?.components(separatedBy: ":").first, "READBACK_FAILED")
        let failedVerify = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(failedVerify)
        domain.replace(persisted: domain.observation.memory)
        domain.corruptWrite = false
        prepared = try await action.prepareConfirmation(parameters: params, context: context)
        domain.afterCommit = { domain.failCapture = true }
        result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertEqual(result.error?.components(separatedBy: ":").first, "READBACK_FAILED")
        domain.failCapture = false
        domain.afterCommit = nil
        prepared = try await action.prepareConfirmation(parameters: params, context: context)
        result = try await action.executeConfirmed(parameters: params, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(result.success)
        domain.replace()
        let changedVerify = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(changedVerify)
        let secondVerify = try await action.verify(parameters: params, context: context)
        XCTAssertFalse(secondVerify)
    }

    func testRejectionAndStaleBrokerReview() async throws {
        let domain = try ColumnsDomainFake(config())
        let action = ACTAPreparedCanvasColumnsAction(domain: domain)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let broker = try XCTUnwrap(made)
        let opened = await broker.broker.openSession(operatorKey: broker.operatorKey, input: .chat,
                                                      threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        for approved in [false, true] {
            let request = await broker.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"columns":5}"#)
            XCTAssertTrue(request.requiresOperatorConfirmation)
            let reviews = await broker.broker.reviews(operatorKey: broker.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            if approved { domain.replace() }
            let result = await broker.broker.resolve(operatorKey: broker.operatorKey, session: session, reviewed: review, approved: approved)
            XCTAssertFalse(result.success)
            if approved { XCTAssertTrue(result.error?.contains("STALE_REVIEW") == true) }
            XCTAssertEqual(domain.writes, 0)
        }
    }
}
