import Foundation
import XCTest
@testable import CameraCore

private actor SettingsFixture: ACTAExistingSystemSettingsReadProvider {
    enum Failure: Error { case missing, corrupt }
    let value: WallConfiguration?
    let failure: Failure
    private(set) var reads = 0

    init(_ value: WallConfiguration?, failure: Failure = .missing) {
        self.value = value
        self.failure = failure
    }

    func loadExistingConfiguration() throws -> WallConfiguration {
        reads += 1
        guard let value else { throw failure }
        return value
    }
}

private final class SettingsAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ACTABrokerAuditEvent] = []
    let failAt: Int?
    init(failAt: Int? = nil) { self.failAt = failAt }
    func record(_ event: ACTABrokerAuditEvent) throws {
        try lock.withLock {
            entries.append(event)
            if entries.count == failAt { throw CocoaError(.fileWriteUnknown) }
        }
    }
    var events: [ACTABrokerAuditEvent] { lock.withLock { entries } }
}

private actor SuspendedSettingsFixture: ACTAExistingSystemSettingsReadProvider {
    let value: WallConfiguration
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    init(_ value: WallConfiguration) { self.value = value }

    func loadExistingConfiguration() async throws -> WallConfiguration {
        await withCheckedContinuation { continuation in
            release = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        return value
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiters.append($0) } }
    }
    func resume() { release?.resume(); release = nil }
}

final class ACTAScopedSettingsReadActionTests: XCTestCase {
    private func fixture() -> WallConfiguration {
        var config = WallConfiguration()
        config.columns = 7
        config.staleAfterMilliseconds = 2400
        config.detectionThreshold = 0.6
        config.detectionFPS = 4
        config.apiPort = 12345
        config.rtspPort = 12346
        config.go2rtcPath = "/secret/exec"
        config.cameras = [Camera(name: "secret-name", location: "secret-location",
                                 substream: "rtsp://user:password@secret-host/secret-path?token=secret-token",
                                 localDeviceID: "secret-device", fileURL: URL(fileURLWithPath: "/secret/file"),
                                 fileBookmarkData: Data("secret-bookmark".utf8))]
        return config
    }

    private func broker(
        _ action: ACTAScopedSettingsReadAction, audit: SettingsAudit,
        scoped: Bool = true
    ) async throws -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: ["other"],
            audit: { try audit.record($0) })
        let host = try XCTUnwrap(created)
        let issued = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "fixture",
            actionIDs: scoped ? [action.id] : [], inspectionIDs: scoped ? [] : ["other"])
        let session = try XCTUnwrap(issued)
        return (host.broker, host.operatorKey, session)
    }

    func testOnlyExplicitFieldsAreReturnedThroughAuditedBroker() async throws {
        let provider = SettingsFixture(fixture())
        let audit = SettingsAudit()
        let (broker, key, session) = try await broker(ACTAScopedSettingsReadAction(provider: provider), audit: audit)
        for section in ["general", "system"] {
            let result = await broker.request(session: session, actionID: "settings.get_section",
                argumentsJSON: #"{"section":"\#(section)"}"#, expectedThreadID: "fixture")
            XCTAssertTrue(result.success)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["columns", "staleAfterMilliseconds", "detectionThreshold", "detectionFPS"])
            XCTAssertEqual(object["columns"] as? Int, 7)
            XCTAssertEqual(object["staleAfterMilliseconds"] as? Int, 2400)
            XCTAssertEqual(object["detectionThreshold"] as? Double, 0.6)
            XCTAssertEqual(object["detectionFPS"] as? Double, 4)
            let entireResult = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            for forbidden in ["secret", "password", "token", "rtsp", "12345", "12346", "permission"] {
                XCTAssertFalse(entireResult.contains(forbidden), forbidden)
            }
        }
        let events = audit.events
        XCTAssertEqual(events.count, 6)
        for offset in [0, 3] {
            XCTAssertEqual(events[offset].phase, .request)
            XCTAssertEqual(events[offset + 1].phase, .validated)
            XCTAssertEqual(events[offset + 2].phase, .result)
            XCTAssertEqual(events[offset + 2].outcome, "success")
        }
        await broker.closeSession(session, operatorKey: key)
    }

    func testUnsupportedInvalidAndUnscopedRequestsDoNotRead() async throws {
        let provider = SettingsFixture(fixture())
        let audit = SettingsAudit()
        let (broker, key, session) = try await broker(ACTAScopedSettingsReadAction(provider: provider), audit: audit)
        for args in [#"{}"#, #"{"section":"permissions"}"#, #"{"section":"ai"}"#,
                     #"{"section":"general","extra":"secret-token"}"#, #"{"section":false}"#, "not json"] {
            let result = await broker.request(session: session, actionID: "settings.get_section",
                                               argumentsJSON: args, expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("secret"))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
        }
        let wrongThread = await broker.request(session: session, actionID: "settings.get_section",
                                                argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "wrong")
        XCTAssertFalse(wrongThread.success)
        XCTAssertTrue(session.invalidate(operatorKey: key))
        let revoked = await broker.request(session: session, actionID: "settings.get_section",
                                            argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "fixture")
        XCTAssertFalse(revoked.success)
        await broker.closeSession(session, operatorKey: key)
        let (other, otherKey, unscoped) = try await self.broker(
            ACTAScopedSettingsReadAction(provider: provider), audit: audit, scoped: false)
        let denied = await other.request(session: unscoped, actionID: "settings.get_section",
                                         argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "fixture")
        XCTAssertFalse(denied.success)
        await other.closeSession(unscoped, operatorKey: otherKey)
        let reads = await provider.reads
        XCTAssertEqual(reads, 0)
    }

    func testAbsentCorruptUnavailableAndAuditFailureReturnNoData() async throws {
        for failure in [SettingsFixture.Failure.missing, .corrupt] {
            let audit = SettingsAudit()
            let provider = SettingsFixture(nil, failure: failure)
            let (broker, key, session) = try await broker(ACTAScopedSettingsReadAction(provider: provider), audit: audit)
            let result = await broker.request(session: session, actionID: "settings.get_section",
                                               argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("columns"))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
            await broker.closeSession(session, operatorKey: key)
        }
        var invalid = fixture()
        invalid.columns = 0
        let invalidProvider = SettingsFixture(invalid)
        let invalidResult = try await ACTAScopedSettingsReadAction(provider: invalidProvider).execute(
            parameters: ["section": "system"], context: ACTAActionContext())
        XCTAssertFalse(invalidResult.success)
        XCTAssertFalse(invalidResult.outputJSON.contains("columns"))
        invalid = fixture()
        invalid.detectionFPS = 2.5
        let invalidFPS = try await ACTAScopedSettingsReadAction(provider: SettingsFixture(invalid)).execute(
            parameters: ["section": "system"], context: ACTAActionContext())
        XCTAssertFalse(invalidFPS.success)
        invalid = fixture()
        invalid.detectionThreshold = .nan
        let invalidThreshold = try await ACTAScopedSettingsReadAction(provider: SettingsFixture(invalid)).execute(
            parameters: ["section": "system"], context: ACTAActionContext())
        XCTAssertFalse(invalidThreshold.success)
        let unavailable = try await ACTAScopedSettingsReadAction().execute(
            parameters: ["section": "general"], context: ACTAActionContext())
        XCTAssertFalse(unavailable.success)
        XCTAssertTrue(unavailable.error?.hasPrefix("UNAVAILABLE:") == true)
        for failAt in 1...3 {
            let audit = SettingsAudit(failAt: failAt)
            let provider = SettingsFixture(fixture())
            let (broker, key, session) = try await broker(ACTAScopedSettingsReadAction(provider: provider), audit: audit)
            let result = await broker.request(session: session, actionID: "settings.get_section",
                                               argumentsJSON: #"{"section":"system"}"#, expectedThreadID: "fixture")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("columns"))
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testRevocationDuringReadNeverReleasesSnapshot() async throws {
        let provider = SuspendedSettingsFixture(fixture())
        let audit = SettingsAudit()
        let (broker, key, session) = try await broker(ACTAScopedSettingsReadAction(provider: provider), audit: audit)
        let request = Task {
            await broker.request(session: session, actionID: "settings.get_section",
                                 argumentsJSON: #"{"section":"general"}"#, expectedThreadID: "fixture")
        }
        await provider.waitUntilStarted()
        XCTAssertTrue(session.invalidate(operatorKey: key))
        await provider.resume()
        let result = await request.value
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.outputJSON.contains("columns"))
        XCTAssertEqual(audit.events.last?.outcome, "failed")
        await broker.closeSession(session, operatorKey: key)
    }
}
