import Foundation
import XCTest
@testable import CameraCore

private actor WatchFixture: ACTAWatchListReadProvider {
    enum Response {
        case rules([ACTAWatchMetadata])
        case unavailable
        case failed
    }
    struct SecretError: LocalizedError {
        var errorDescription: String? { "synthetic-secret /path camera-id" }
    }
    let response: Response
    private(set) var reads = 0
    init(_ response: Response) { self.response = response }
    func activeWatchMetadata() throws -> [ACTAWatchMetadata] {
        reads += 1
        switch response {
        case .rules(let rules): return rules
        case .unavailable: throw ACTAWatchListReadError.unavailable
        case .failed: throw SecretError()
        }
    }
}

private actor SuspendedWatchFixture: ACTAWatchListReadProvider {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func activeWatchMetadata() async throws -> [ACTAWatchMetadata] {
        await withCheckedContinuation { continuation in
            release = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        return [ACTAWatchMetadata(cameraScope: .selected, expiration: .timed)]
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiters.append($0) } }
    }
    func resume() { release?.resume(); release = nil }
}

private final class WatchAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ACTABrokerAuditEvent] = []
    private let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func record(_ event: ACTABrokerAuditEvent) throws {
        try lock.withLock {
            entries.append(event)
            if entries.count == failAt { throw CocoaError(.fileWriteUnknown) }
        }
    }
    var events: [ACTABrokerAuditEvent] { lock.withLock { entries } }
}

private final class RevokingWatchAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (ACTABrokerSession, ACTABrokerOperator)?
    func setTarget(_ session: ACTABrokerSession, _ key: ACTABrokerOperator) {
        lock.withLock { target = (session, key) }
    }
    func record(_ event: ACTABrokerAuditEvent) {
        if event.phase == .result, event.outcome == "success" {
            let pair = lock.withLock { target }
            if let (session, key) = pair { session.invalidate(operatorKey: key) }
        }
    }
}

final class ACTAScopedWatchListActionTests: XCTestCase {
    private func broker(_ action: ACTAScopedWatchListAction, _ audit: WatchAudit, scoped: Bool = true) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: ["other"],
            audit: { try audit.record($0) })
        let host = try XCTUnwrap(created)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "test-thread", actionIDs: scoped ? [action.id] : [],
            inspectionIDs: scoped ? [] : ["other"])
        return (host.broker, host.operatorKey, try XCTUnwrap(issued))
    }

    func testAuditedListIsLimitedToTypedMetadataAndStableOrder() async throws {
        let provider = WatchFixture(.rules([
            .init(cameraScope: .selected, expiration: .timed),
            .init(cameraScope: .all, expiration: .indefinite),
            .init(cameraScope: .all, expiration: .timed)
        ]))
        let audit = WatchAudit()
        let action = ACTAScopedWatchListAction(provider: provider)
        let (broker, key, session) = try await broker(action, audit)
        let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}",
                                          expectedThreadID: "test-thread")
        XCTAssertTrue(result.success)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["watch_rules"])
        let rules = try XCTUnwrap(object["watch_rules"] as? [[String: String]])
        XCTAssertEqual(rules, [
            ["cameraScope": "all", "expiration": "indefinite"],
            ["cameraScope": "all", "expiration": "timed"],
            ["cameraScope": "selected", "expiration": "timed"]
        ])
        XCTAssertEqual(audit.events.map(\.phase), [.request, .validated, .result])
        XCTAssertEqual(audit.events.last?.outcome, "success")
        await broker.closeSession(session, operatorKey: key)
    }

    func testEmptyListRequiresSuccessfulProvider() async throws {
        let provider = WatchFixture(.rules([]))
        let audit = WatchAudit()
        let action = ACTAScopedWatchListAction(provider: provider)
        let (broker, key, session) = try await broker(action, audit)
        let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputJSON, #"{"watch_rules":[]}"#)
        await broker.closeSession(session, operatorKey: key)
    }

    func testServiceErrorsAreExplicitAndSanitized() async throws {
        let tooMany = Array(repeating: ACTAWatchMetadata(cameraScope: .all, expiration: .timed), count: 25)
        let cases: [(ACTAScopedWatchListAction, String)] = [
            (ACTAScopedWatchListAction(), "UNAVAILABLE:"),
            (ACTAScopedWatchListAction(provider: WatchFixture(.unavailable)), "UNAVAILABLE:"),
            (ACTAScopedWatchListAction(provider: WatchFixture(.failed)), "STORAGE_ERROR:"),
            (ACTAScopedWatchListAction(provider: WatchFixture(.rules(tooMany))), "STORAGE_ERROR:")
        ]
        for (action, code) in cases {
            let direct = try await action.execute(parameters: [:], context: ACTAActionContext())
            XCTAssertFalse(direct.success)
            XCTAssertTrue(direct.error?.hasPrefix(code) == true)
            XCTAssertFalse(direct.outputJSON.contains("synthetic-secret"))
            let audit = WatchAudit()
            let (broker, key, session) = try await broker(action, audit)
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("ACTION_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("watch_rules"))
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testInvalidUnscopedWrongThreadAndRevokedNeverRead() async throws {
        let provider = WatchFixture(.rules([.init(cameraScope: .all, expiration: .timed)]))
        let action = ACTAScopedWatchListAction(provider: provider)
        let audit = WatchAudit()
        let (broker, key, session) = try await broker(action, audit)
        for args in [#"{"camera_id":"synthetic-secret"}"#, "[]", "not-json"] {
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: args)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("synthetic-secret"))
        }
        let wrongThread = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}",
                                               expectedThreadID: "wrong")
        XCTAssertFalse(wrongThread.success)
        XCTAssertTrue(session.invalidate(operatorKey: key))
        let revoked = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(revoked.success)
        await broker.closeSession(session, operatorKey: key)
        let (other, otherKey, unscoped) = try await self.broker(action, audit, scoped: false)
        let denied = await other.request(session: unscoped, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(denied.success)
        await other.closeSession(unscoped, operatorKey: otherKey)
        let reads = await provider.reads
        XCTAssertEqual(reads, 0)
    }

    func testAuditFailureAtEachStageNeverReleasesData() async throws {
        for failAt in 1...3 {
            let provider = WatchFixture(.rules([.init(cameraScope: .selected, expiration: .timed)]))
            let audit = WatchAudit(failAt: failAt)
            let action = ACTAScopedWatchListAction(provider: provider)
            let (broker, key, session) = try await broker(action, audit)
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("watch_rules"))
            let reads = await provider.reads
            XCTAssertEqual(reads, failAt == 3 ? 1 : 0)
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testRevocationDuringReadNeverReleasesData() async throws {
        let provider = SuspendedWatchFixture()
        let audit = WatchAudit()
        let action = ACTAScopedWatchListAction(provider: provider)
        let (broker, key, session) = try await broker(action, audit)
        let request = Task {
            await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        }
        await provider.waitUntilStarted()
        XCTAssertTrue(session.invalidate(operatorKey: key))
        await provider.resume()
        let result = await request.value
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.outputJSON.contains("watch_rules"))
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }

    func testCancellationDuringReadNeverReleasesData() async throws {
        let provider = SuspendedWatchFixture()
        let audit = WatchAudit()
        let action = ACTAScopedWatchListAction(provider: provider)
        let (broker, key, session) = try await broker(action, audit)
        let request = Task {
            await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        }
        await provider.waitUntilStarted()
        request.cancel()
        await provider.resume()
        let result = await request.value
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.outputJSON.contains("watch_rules"))
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }

    func testRevocationDuringResultAuditNeverReleasesData() async throws {
        let provider = WatchFixture(.rules([.init(cameraScope: .selected, expiration: .timed)]))
        let action = ACTAScopedWatchListAction(provider: provider)
        let audit = RevokingWatchAudit()
        let created = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id],
                                                       audit: { audit.record($0) })
        let host = try XCTUnwrap(created)
        let issued = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "test-thread", actionIDs: [action.id])
        let session = try XCTUnwrap(issued)
        audit.setTarget(session, host.operatorKey)
        let result = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
        XCTAssertFalse(result.outputJSON.contains("watch_rules"))
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }
}
