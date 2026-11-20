import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor private final class IncidentFake: ACTAIncidentAcknowledgeDomain {
    var value: ACTAIncidentAcknowledgeObservation
    var writes = 0
    var beforeCompare: (() -> Void)?
    var afterCommit: (() -> Void)?
    var fail = false
    init() { value = .init(revision: UUID(), incidentID: UUID(), cameraID: UUID(), status: .active) }
    func capture(incidentID: UUID) throws -> ACTAIncidentAcknowledgeObservation? {
        if fail { throw Failure() }
        return value.incidentID == incidentID ? value : nil
    }
    func acknowledge(expected: ACTAIncidentAcknowledgeObservation) throws -> ACTAIncidentAcknowledgeObservation? {
        beforeCompare?()
        if fail { throw Failure() }
        guard value == expected, value.status == .active else { return nil }
        value = .init(revision: UUID(), incidentID: value.incidentID, cameraID: value.cameraID, status: .acknowledged)
        writes += 1
        let result = value
        afterCommit?()
        return result
    }
    struct Failure: Error {}
}

@MainActor private final class MissionFake: ACTAMissionDisableDomain {
    var value: ACTAMissionDisableObservation
    var writes = 0
    var beforeCompare: (() -> Void)?
    var afterCommit: (() -> Void)?
    var fail = false
    init() { value = .init(revision: UUID(), missionID: UUID(), cameraID: UUID(), enabled: true, idle: true) }
    func capture(missionID: UUID) throws -> ACTAMissionDisableObservation? {
        if fail { throw Failure() }
        return value.missionID == missionID ? value : nil
    }
    func disable(expected: ACTAMissionDisableObservation) throws -> ACTAMissionDisableObservation? {
        beforeCompare?()
        if fail { throw Failure() }
        guard value == expected, value.enabled, value.idle else { return nil }
        value = .init(revision: UUID(), missionID: value.missionID, cameraID: value.cameraID, enabled: false, idle: true)
        writes += 1
        let result = value
        afterCommit?()
        return result
    }
    struct Failure: Error {}
}

@MainActor final class ACTAPreparedIncidentMissionActionTests: XCTestCase {
    func testBrokerReviewDeclineApprovalAndOneShotForBothActions() async throws {
        let incident = IncidentFake(), mission = MissionFake()
        let actions: [any ACTAActionProtocol] = [
            ACTAPreparedIncidentAcknowledgeAction(domain: incident),
            ACTAPreparedMissionDisableAction(domain: mission)
        ]
        let creation = await ACTALocalActionBroker.make(
            actions: actions, allowedActionIDs: Set(actions.map(\.id)), audit: { _ in })
        let host = try XCTUnwrap(creation)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "test", actionIDs: Set(actions.map(\.id)))
        let session = try XCTUnwrap(opened)
        for (id, json) in [
            ("incident.transition_status", #"{"incident_id":"\#(incident.value.incidentID.uuidString)","status":"acknowledged"}"#),
            ("mission.edit", #"{"mission_id":"\#(mission.value.missionID.uuidString)","enabled":false}"#)
        ] {
            for approved in [false, true] {
                let pending = await host.broker.request(session: session, actionID: id, argumentsJSON: json)
                XCTAssertTrue(pending.requiresOperatorConfirmation)
                let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
                let review = try XCTUnwrap(reviews.first)
                XCTAssertTrue(review.title.contains(id == "mission.edit" ? mission.value.cameraID.uuidString : incident.value.cameraID.uuidString))
                let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: approved)
                XCTAssertEqual(result.success, approved, result.summary)
                if approved { XCTAssertTrue(result.verified) }
                else {
                    XCTAssertEqual(incident.writes, id == "mission.edit" ? 1 : 0)
                    XCTAssertEqual(mission.writes, 0)
                }
                let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
                XCTAssertFalse(replay.success)
            }
        }
        XCTAssertEqual(incident.writes, 1)
        XCTAssertEqual(mission.writes, 1)
    }

    func testStaleABAAndInterleavingRejectWithoutWrites() async throws {
        let context = ACTAActionContext(threadID: "test", isConfirmed: true)
        for scenario in 0..<3 {
            let incident = IncidentFake(), mission = MissionFake()
            let incidentAction = ACTAPreparedIncidentAcknowledgeAction(domain: incident)
            let missionAction = ACTAPreparedMissionDisableAction(domain: mission)
            let ia = ["incident_id": incident.value.incidentID.uuidString, "status": "acknowledged"]
            let ma = ["mission_id": mission.value.missionID.uuidString, "enabled": "false"]
            let ip = try await incidentAction.prepareConfirmation(parameters: ia, context: context)
            let mp = try await missionAction.prepareConfirmation(parameters: ma, context: context)
            let changeIncident = {
                let old = incident.value
                incident.value = .init(revision: UUID(), incidentID: old.incidentID, cameraID: old.cameraID, status: old.status)
            }
            let changeMission = {
                let old = mission.value
                mission.value = .init(revision: UUID(), missionID: old.missionID, cameraID: old.cameraID, enabled: old.enabled, idle: scenario != 1)
            }
            if scenario == 2 { incident.beforeCompare = changeIncident; mission.beforeCompare = changeMission }
            else { changeIncident(); changeMission() }
            let ir = try await incidentAction.executeConfirmed(parameters: ia, context: context, snapshot: ip.snapshot)
            let mr = try await missionAction.executeConfirmed(parameters: ma, context: context, snapshot: mp.snapshot)
            XCTAssertFalse(ir.success)
            XCTAssertFalse(mr.success)
            XCTAssertEqual(incident.writes, 0)
            XCTAssertEqual(mission.writes, 0)
        }
    }

    func testMismatchWrongOwnerReplayAndReadbackFailure() async throws {
        let context = ACTAActionContext(threadID: "test", isConfirmed: true), other = ACTAActionContext(threadID: "other", isConfirmed: true)
        let incident = IncidentFake(), mission = MissionFake()
        let ia = ACTAPreparedIncidentAcknowledgeAction(domain: incident)
        let ma = ACTAPreparedMissionDisableAction(domain: mission)
        let ip = ["incident_id": incident.value.incidentID.uuidString, "status": "acknowledged"]
        let mp = ["mission_id": mission.value.missionID.uuidString, "enabled": "false"]
        let ireview = try await ia.prepareConfirmation(parameters: ip, context: context)
        let mreview = try await ma.prepareConfirmation(parameters: mp, context: context)
        let wrongOwner = ACTAPreparedIncidentAcknowledgeAction(domain: incident)
        let wrong = try await wrongOwner.executeConfirmed(parameters: ip, context: context, snapshot: ireview.snapshot)
        XCTAssertFalse(wrong.success)
        let mismatch = try await ma.executeConfirmed(parameters: mp, context: other, snapshot: mreview.snapshot)
        XCTAssertFalse(mismatch.success)
        let replay = try await ma.executeConfirmed(parameters: mp, context: context, snapshot: mreview.snapshot)
        XCTAssertFalse(replay.success)
        incident.afterCommit = { incident.fail = true }
        let failed = try await ia.executeConfirmed(parameters: ip, context: context, snapshot: ireview.snapshot)
        XCTAssertFalse(failed.success)
        let verified = try await ia.verify(parameters: ip, context: context)
        XCTAssertFalse(verified)
        XCTAssertEqual(mission.writes, 0)
    }

    func testInvalidRequestsAndChangedPostCommitFailVerification() async throws {
        let context = ACTAActionContext(threadID: "test", isConfirmed: true)
        let incident = IncidentFake(), mission = MissionFake()
        let ia = ACTAPreparedIncidentAcknowledgeAction(domain: incident)
        let ma = ACTAPreparedMissionDisableAction(domain: mission)
        let ip = ["incident_id": incident.value.incidentID.uuidString, "status": "acknowledged"]
        let mp = ["mission_id": mission.value.missionID.uuidString, "enabled": "false"]
        XCTAssertThrowsError(try ia.validate(parameters: ip.merging(["note": "secret"]) { _, rhs in rhs }))
        XCTAssertThrowsError(try ma.validate(parameters: ["mission_id": mission.value.missionID.uuidString, "enabled": "true"]))
        let direct = try await ma.execute(parameters: mp, context: context)
        XCTAssertFalse(direct.success)
        let review = try await ma.prepareConfirmation(parameters: mp, context: context)
        let result = try await ma.executeConfirmed(parameters: mp, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success)
        let old = mission.value
        mission.value = .init(revision: UUID(), missionID: old.missionID, cameraID: old.cameraID, enabled: old.enabled, idle: old.idle)
        let verified = try await ma.verify(parameters: mp, context: context)
        XCTAssertFalse(verified)
        let twice = try await ma.verify(parameters: mp, context: context)
        XCTAssertFalse(twice)
    }

    func testUnavailableAndUnexpectedMissionReadbackFailClosed() async throws {
        let context = ACTAActionContext(threadID: "test", isConfirmed: true)
        let incident = IncidentFake(), mission = MissionFake()
        let ia = ACTAPreparedIncidentAcknowledgeAction(domain: incident)
        let ma = ACTAPreparedMissionDisableAction(domain: mission)
        let ip = ["incident_id": incident.value.incidentID.uuidString, "status": "acknowledged"]
        let mp = ["mission_id": mission.value.missionID.uuidString, "enabled": "false"]
        incident.fail = true
        do {
            _ = try await ia.prepareConfirmation(parameters: ip, context: context)
            XCTFail("Unhealthy incident domain must fail closed")
        } catch {}
        let old = mission.value
        mission.value = .init(revision: UUID(), missionID: old.missionID, cameraID: old.cameraID, enabled: true, idle: false)
        do {
            _ = try await ma.prepareConfirmation(parameters: mp, context: context)
            XCTFail("Busy mission must not be reviewed")
        } catch {}
        mission.value = .init(revision: UUID(), missionID: old.missionID, cameraID: old.cameraID, enabled: true, idle: true)
        let review = try await ma.prepareConfirmation(parameters: mp, context: context)
        mission.afterCommit = {
            let current = mission.value
            mission.value = .init(revision: UUID(), missionID: current.missionID, cameraID: current.cameraID, enabled: true, idle: true)
        }
        let result = try await ma.executeConfirmed(parameters: mp, context: context, snapshot: review.snapshot)
        XCTAssertFalse(result.success)
        let verified = try await ma.verify(parameters: mp, context: context)
        XCTAssertFalse(verified)
        XCTAssertEqual(incident.writes, 0)
    }

    func testUnconfirmedPreparedExecutionDoesNotWrite() async throws {
        let incident = IncidentFake(), mission = MissionFake()
        let ia = ACTAPreparedIncidentAcknowledgeAction(domain: incident)
        let ma = ACTAPreparedMissionDisableAction(domain: mission)
        let context = ACTAActionContext(threadID: "test")
        let ip = ["incident_id": incident.value.incidentID.uuidString, "status": "acknowledged"]
        let mp = ["mission_id": mission.value.missionID.uuidString, "enabled": "false"]
        let ireview = try await ia.prepareConfirmation(parameters: ip, context: context)
        let mreview = try await ma.prepareConfirmation(parameters: mp, context: context)
        let ir = try await ia.executeConfirmed(parameters: ip, context: context, snapshot: ireview.snapshot)
        let mr = try await ma.executeConfirmed(parameters: mp, context: context, snapshot: mreview.snapshot)
        XCTAssertFalse(ir.success)
        XCTAssertFalse(mr.success)
        XCTAssertEqual(incident.writes, 0)
        XCTAssertEqual(mission.writes, 0)
    }
}
