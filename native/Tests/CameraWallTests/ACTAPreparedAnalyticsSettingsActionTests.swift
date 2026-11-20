import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class AnalyticsMutationFake: ACTAAnalyticsSettingsMutationDomain {
    struct Failure: Error {}
    var observation = ACTAAnalyticsSettingsObservation(revision: UUID(), memory: .safeDefaults, persisted: .safeDefaults)
    var writes = 0
    var beforeCompare: (() -> Void)?
    var afterCommit: (() -> Void)?
    var failCapture = false
    var failCommit = false
    var corruptWrite = false
    func capture() throws -> ACTAAnalyticsSettingsObservation {
        if failCapture { throw Failure() }
        return observation
    }
    func commit(expected: ACTAAnalyticsSettingsObservation, replacement: VideoAnalyticsSettings) throws -> ACTAAnalyticsSettingsObservation? {
        beforeCompare?()
        if failCommit { throw Failure() }
        guard observation == expected else { return nil }
        writes += 1
        observation = .init(revision: UUID(), memory: replacement,
                            persisted: corruptWrite ? expected.persisted : replacement)
        let result = observation
        afterCommit?()
        return result
    }
    func change(memory: VideoAnalyticsSettings? = nil, persisted: VideoAnalyticsSettings? = nil) {
        observation = .init(revision: UUID(), memory: memory ?? observation.memory, persisted: persisted ?? observation.persisted)
    }
}

@MainActor
final class ACTAPreparedAnalyticsSettingsActionTests: XCTestCase {
    let context = ACTAActionContext(threadID: "test")

    func testReviewedChangesPreserveUnrelatedSettings() async throws {
        let cases: [(ACTAPreparedAnalyticsSettingsAction.Kind, [String: String], (inout VideoAnalyticsSettings) -> Void)] = [
            (.toggle, ["feature": "evidence", "enabled": "false"], { $0.enableEvidenceRecording = false }),
            (.threshold, ["parameter": "maxEvidenceDiskQuotaMB", "value": "512"], { $0.maxEvidenceDiskQuotaMB = 512 }),
            (.sampling, ["fps": "5", "idle_fps": "2", "boost_fps": "10"], {
                $0.analyticsSamplingFPS = 5; $0.idleCameraSamplingFPS = 2; $0.activeFallBoostFPS = 10
            }),
            (.overlay, ["layer": "showTrackID", "enabled": "false"], { $0.overlaySettings.showTrackID = false }),
            (.profile, ["profile": "Conservative"], { $0.applySensitivityProfile(.conservative) }),
            (.executionMode, ["mode": "DISTRIBUTED"], { $0.executionMode = .distributed })
        ]
        for (kind, parameters, apply) in cases {
            let domain = AnalyticsMutationFake()
            let action = ACTAPreparedAnalyticsSettingsAction(kind: kind, domain: domain)
            let before = domain.observation.memory
            var expected = before
            apply(&expected)
            XCTAssertTrue(action.requiresConfirmation(parameters: parameters))
            let review = try await action.prepareConfirmation(parameters: parameters, context: context)
            XCTAssertTrue(review.reviewSummary.contains(" -> "))
            XCTAssertEqual(domain.writes, 0)
            let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(domain.observation.memory, expected)
            XCTAssertEqual(domain.observation.persisted, expected)
            let verified = try await action.verify(parameters: parameters, context: context)
            XCTAssertTrue(verified)
            let verifiedAgain = try await action.verify(parameters: parameters, context: context)
            XCTAssertFalse(verifiedAgain)
            let replay = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
            XCTAssertTrue(replay.error?.contains("CONFIRMATION_CONSUMED") == true)
            XCTAssertEqual(domain.writes, 1)
        }
    }

    func testValidationAndProfileWithoutApplyingValues() async throws {
        let domain = AnalyticsMutationFake()
        let input: [(ACTAPreparedAnalyticsSettingsAction.Kind, [String: String])] = [
            (.toggle, ["feature": "global", "enabled": "1"]), (.overlay, ["layer": "unknown", "enabled": "true"]),
            (.threshold, ["parameter": "minimumVisibleKeypoints", "value": "1.5"]),
            (.threshold, ["parameter": "personConfidenceThreshold", "value": "nan"]),
            (.sampling, ["fps": "5", "extra": "x"]), (.profile, ["profile": "Balanced", "apply_values": "yes"]),
            (.executionMode, ["mode": "unknown"])
        ]
        for (kind, parameters) in input {
            XCTAssertThrowsError(try ACTAPreparedAnalyticsSettingsAction(kind: kind, domain: domain).validate(parameters: parameters))
        }
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .sampling, domain: domain)
        do {
            _ = try await action.prepareConfirmation(parameters: ["fps": "0.1"], context: context)
            XCTFail("Out-of-range settings must fail before writing")
        } catch {}
        let profile = ACTAPreparedAnalyticsSettingsAction(kind: .profile, domain: domain)
        let p = ["profile": "Conservative", "apply_values": "false"]
        let prepared = try await profile.prepareConfirmation(parameters: p, context: context)
        let result = try await profile.executeConfirmed(parameters: p, context: context, snapshot: prepared.snapshot)
        XCTAssertTrue(result.success)
        XCTAssertEqual(domain.observation.memory.sensitivityProfile, .conservative)
        XCTAssertEqual(domain.observation.memory.personConfidenceThreshold, VideoAnalyticsSettings.safeDefaults.personConfidenceThreshold)
    }

    func testStaleABAAndInterleavingNeverWrite() async throws {
        let p = ["layer": "showTrackID", "enabled": "false"]
        for scenario in 0..<4 {
            let domain = AnalyticsMutationFake()
            let action = ACTAPreparedAnalyticsSettingsAction(kind: .overlay, domain: domain)
            let review = try await action.prepareConfirmation(parameters: p, context: context)
            var changed = domain.observation.memory
            changed.enableSoundAlert.toggle()
            switch scenario {
            case 0: domain.change(memory: changed)
            case 1: domain.change(persisted: changed)
            case 2: domain.change(memory: changed, persisted: changed); domain.change(memory: .safeDefaults, persisted: .safeDefaults)
            default: domain.beforeCompare = { domain.change() }
            }
            let result = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
            XCTAssertTrue(result.error?.contains("STALE_REVIEW") == true)
            XCTAssertEqual(domain.writes, 0)
        }
    }

    func testMismatchFailuresDivergenceAndReceipt() async throws {
        let p = ["feature": "sound", "enabled": "true"]
        let domain = AnalyticsMutationFake()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .toggle, domain: domain)
        var review = try await action.prepareConfirmation(parameters: p, context: context)
        let mismatch = try await action.executeConfirmed(parameters: p, context: .init(threadID: "other"), snapshot: review.snapshot)
        XCTAssertTrue(mismatch.error?.contains("CONFIRMATION_MISMATCH") == true)
        let replay = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(replay.error?.contains("CONFIRMATION_CONSUMED") == true)
        domain.failCommit = true
        review = try await action.prepareConfirmation(parameters: p, context: context)
        let failure = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(failure.error?.contains("COMMIT_FAILED") == true)
        domain.failCommit = false
        domain.corruptWrite = true
        review = try await action.prepareConfirmation(parameters: p, context: context)
        let corrupt = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(corrupt.error?.contains("READBACK_FAILED") == true)
        do { _ = try await action.prepareConfirmation(parameters: p, context: context); XCTFail("Divergence") } catch {}
        domain.change(persisted: domain.observation.memory)
        domain.corruptWrite = false
        review = try await action.prepareConfirmation(parameters: p, context: context)
        domain.afterCommit = { domain.failCapture = true }
        let unreadable = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(unreadable.error?.contains("READBACK_FAILED") == true)
        domain.failCapture = false
        domain.afterCommit = nil
        review = try await action.prepareConfirmation(parameters: p, context: context)
        let success = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(success.success)
        domain.change()
        let verified = try await action.verify(parameters: p, context: context)
        XCTAssertFalse(verified)
        let direct = try await action.execute(parameters: p, context: context)
        XCTAssertTrue(direct.error?.contains("CONFIRMATION_REQUIRED") == true)
    }

    func testBrokerApprovalRejectionAndReplay() async throws {
        let domain = AnalyticsMutationFake()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .toggle, domain: domain)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        for approved in [false, true] {
            let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"feature":"sound","enabled":true}"#)
            XCTAssertTrue(pending.requiresOperatorConfirmation)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: approved)
            XCTAssertEqual(result.success, approved)
            if approved { XCTAssertTrue(result.verified) }
            let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
            XCTAssertFalse(replay.success)
        }
        XCTAssertEqual(domain.writes, 1)
    }

    func testIndependentReviewCannotOverwriteAndForeignTicketIsRejected() async throws {
        let domain = AnalyticsMutationFake()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .toggle, domain: domain)
        let foreign = ACTAPreparedAnalyticsSettingsAction(kind: .toggle, domain: domain)
        let p = ["feature": "sound", "enabled": "true"]
        let first = try await action.prepareConfirmation(parameters: p, context: context)
        let second = try await action.prepareConfirmation(parameters: p, context: context)
        let rejected = try await foreign.executeConfirmed(parameters: p, context: context, snapshot: first.snapshot)
        XCTAssertTrue(rejected.error?.contains("CONFIRMATION_CONSUMED") == true)
        let success = try await action.executeConfirmed(parameters: p, context: context, snapshot: first.snapshot)
        XCTAssertTrue(success.success)
        let verified = try await action.verify(parameters: p, context: context)
        XCTAssertTrue(verified)
        let stale = try await action.executeConfirmed(parameters: p, context: context, snapshot: second.snapshot)
        XCTAssertTrue(stale.error?.contains("STALE_REVIEW") == true)
        XCTAssertEqual(domain.writes, 1)
    }

    func testCancelledExecutionAndStaleBrokerReviewDoNotWrite() async throws {
        let domain = AnalyticsMutationFake()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .toggle, domain: domain)
        let p = ["feature": "sound", "enabled": "true"]
        let review = try await action.prepareConfirmation(parameters: p, context: context)
        let task = Task { @MainActor in
            try await action.executeConfirmed(parameters: p, context: self.context, snapshot: review.snapshot)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled execution must throw") } catch is CancellationError {} catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(domain.writes, 0)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: #"{"feature":"sound","enabled":true}"#)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let brokerReview = try XCTUnwrap(reviews.first)
        domain.change()
        let stale = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: brokerReview, approved: true)
        XCTAssertTrue(stale.error?.contains("STALE_REVIEW") == true)
        XCTAssertEqual(domain.writes, 0)
    }
}
