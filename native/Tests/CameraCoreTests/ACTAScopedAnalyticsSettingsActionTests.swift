import Foundation
import XCTest
@testable import CameraCore

private func sampleSettings() -> ACTAAnalyticsSettingsSnapshot {
    .init(globalEnabled: true, executionMode: .distributed, sensitivity: .highSensitivity,
          personDetection: true, poseEstimation: false, fallDetection: true, behaviorAnalysis: false,
          inactivityDetection: true, loiteringDetection: false, zoneMonitoring: true,
          unusualMovement: false, crowdActivity: true, fightDetection: false,
          secondaryVerification: true, soundAlert: false, visualAlert: true, evidenceRecording: false,
          overlays: .init(settings: .init()), advanced: .init(settings: .safeDefaults))
}

private actor AnalyticsSettingsFixture: ACTAAnalyticsSettingsReadProvider {
    enum Response { case value, unavailable, failure }
    struct SecretError: LocalizedError {
        var errorDescription: String? { "synthetic-secret rtsp://host/path camera-id" }
    }
    let response: Response
    private(set) var reads = 0
    init(_ response: Response) { self.response = response }
    func appliedGlobalSettings() throws -> ACTAAnalyticsSettingsSnapshot {
        reads += 1
        switch response {
        case .value: return sampleSettings()
        case .unavailable: throw ACTAAnalyticsSettingsReadError.unavailable
        case .failure: throw SecretError()
        }
    }
}

private actor SuspendedAnalyticsSettingsFixture: ACTAAnalyticsSettingsReadProvider {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func appliedGlobalSettings() async throws -> ACTAAnalyticsSettingsSnapshot {
        await withCheckedContinuation { continuation in
            release = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        return sampleSettings()
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiters.append($0) } }
    }
    func resume() { release?.resume(); release = nil }
}

private final class AnalyticsSettingsAudit: @unchecked Sendable {
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

final class ACTAScopedAnalyticsSettingsActionTests: XCTestCase {
    private func broker(_ action: ACTAScopedAnalyticsSettingsAction, _ audit: AnalyticsSettingsAudit,
                        scoped: Bool = true) async throws
        -> (ACTALocalActionBroker, ACTABrokerOperator, ACTABrokerSession) {
        let created = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], allowedInspectionIDs: ["other"],
            audit: { try audit.record($0) })
        let host = try XCTUnwrap(created)
        let session = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
            threadID: "test", actionIDs: scoped ? [action.id] : [], inspectionIDs: scoped ? [] : ["other"])
        return (host.broker, host.operatorKey, try XCTUnwrap(session))
    }

    func testAuditedSnapshotContainsOnlyTypedGlobalFields() async throws {
        let provider = AnalyticsSettingsFixture(.value)
        let audit = AnalyticsSettingsAudit()
        let action = ACTAScopedAnalyticsSettingsAction(provider: provider)
        let (broker, key, session) = try await broker(action, audit)
        let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        XCTAssertTrue(result.success)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["globalEnabled", "executionMode", "sensitivity", "personDetection",
            "poseEstimation", "fallDetection", "behaviorAnalysis", "inactivityDetection", "loiteringDetection",
            "zoneMonitoring", "unusualMovement", "crowdActivity", "fightDetection", "secondaryVerification",
            "soundAlert", "visualAlert", "evidenceRecording", "overlays", "advanced"])
        XCTAssertEqual(object["executionMode"] as? String, "distributed")
        XCTAssertEqual(object["sensitivity"] as? String, "highSensitivity")
        XCTAssertEqual(object["poseEstimation"] as? Bool, false)
        XCTAssertEqual(object["evidenceRecording"] as? Bool, false)
        let advanced = try XCTUnwrap(object["advanced"] as? [String: Any])
        XCTAssertEqual(Set(advanced.keys), ["personConfidenceThreshold", "poseKeypointConfidenceThreshold",
            "analyticsSamplingFPS", "idleCameraSamplingFPS", "activeFallBoostFPS", "fallConfirmationSeconds",
            "personDownSeconds", "inactivityThresholdSeconds", "loiteringThresholdSeconds", "minimumVisibleKeypoints",
            "alertCooldownSeconds", "preEventBufferSeconds", "postEventBufferSeconds", "maxEvidenceDiskQuotaMB",
            "maxConcurrentInferenceTasks"])
        XCTAssertEqual(advanced["analyticsSamplingFPS"] as? Double, VideoAnalyticsSettings.safeDefaults.analyticsSamplingFPS)
        let overlays = try XCTUnwrap(object["overlays"] as? [String: Any])
        XCTAssertEqual(Set(overlays.keys), ["showBoundingBoxes", "showPoseSkeleton", "showTrackID",
            "showBehaviorState", "showFallStatus", "showConfidence", "showCriticalAlertMarker", "showRestrictedZones"])
        XCTAssertEqual(overlays["showBoundingBoxes"] as? Bool, true)
        XCTAssertEqual(audit.events.map(\.phase), [.request, .validated, .result])
        XCTAssertEqual(audit.events.last?.outcome, "success")
        await broker.closeSession(session, operatorKey: key)
    }

    func testUnavailableAndErrorsAreExplicitAndSanitized() async throws {
        let cases: [(ACTAScopedAnalyticsSettingsAction, String)] = [
            (.init(), "UNAVAILABLE:"),
            (.init(provider: AnalyticsSettingsFixture(.unavailable)), "UNAVAILABLE:"),
            (.init(provider: AnalyticsSettingsFixture(.failure)), "READ_ERROR:")
        ]
        for (action, code) in cases {
            let direct = try await action.execute(parameters: [:], context: ACTAActionContext())
            XCTAssertFalse(direct.success)
            XCTAssertTrue(direct.error?.hasPrefix(code) == true)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(direct), as: UTF8.self).contains("synthetic-secret"))
            let audit = AnalyticsSettingsAudit()
            let (broker, key, session) = try await broker(action, audit)
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("globalEnabled"))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("synthetic-secret"))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testInvalidUnscopedWrongThreadAndRevokedNeverRead() async throws {
        let provider = AnalyticsSettingsFixture(.value)
        let action = ACTAScopedAnalyticsSettingsAction(provider: provider)
        let audit = AnalyticsSettingsAudit()
        let (broker, key, session) = try await broker(action, audit)
        for arguments in [#"{"camera_id":"synthetic-secret"}"#, #"{"other":true}"#, "[]", "null", "not-json"] {
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: arguments)
            XCTAssertFalse(result.success)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("synthetic-secret"))
        }
        let wrong = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}", expectedThreadID: "wrong")
        XCTAssertFalse(wrong.success)
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

    func testEachAuditFailureWithholdsSnapshot() async throws {
        for failAt in 1...3 {
            let provider = AnalyticsSettingsFixture(.value)
            let action = ACTAScopedAnalyticsSettingsAction(provider: provider)
            let (broker, key, session) = try await broker(action, AnalyticsSettingsAudit(failAt: failAt))
            let result = await broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.error?.hasPrefix("AUDIT_FAILED:") == true)
            XCTAssertFalse(result.outputJSON.contains("globalEnabled"))
            let reads = await provider.reads
            XCTAssertEqual(reads, failAt == 3 ? 1 : 0)
            await broker.closeSession(session, operatorKey: key)
        }
    }

    func testRevocationAndCancellationDuringReadWithholdSnapshot() async throws {
        for cancel in [false, true] {
            let provider = SuspendedAnalyticsSettingsFixture()
            let action = ACTAScopedAnalyticsSettingsAction(provider: provider)
            let audit = AnalyticsSettingsAudit()
            let (broker, key, session) = try await broker(action, audit)
            let request = Task { await broker.request(session: session, actionID: action.id, argumentsJSON: "{}") }
            await provider.waitUntilStarted()
            if cancel { request.cancel() } else { XCTAssertTrue(session.invalidate(operatorKey: key)) }
            await provider.resume()
            let result = await request.value
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.outputJSON.contains("globalEnabled"))
            XCTAssertEqual(audit.events.last?.outcome, "failed")
            await broker.closeSession(session, operatorKey: key)
        }
    }
}
