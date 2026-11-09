import XCTest
@testable import CameraCore

final class WorkerControlTests: XCTestCase {
    func testWorkerControlWireFrameRoundTripsAndEnforcesSizeBounds() throws {
        let registration = makeRegistration()
        let request = WorkerControlRequest(registration: registration)
        try request.validate(supportedProtocolVersion: 1)

        let frame = try WorkerWireCodec.encode(request)
        let header = Data(frame.prefix(WorkerWireCodec.frameHeaderBytes))
        let payloadLength = try WorkerWireCodec.payloadLength(from: header)
        XCTAssertEqual(payloadLength, frame.count - WorkerWireCodec.frameHeaderBytes)

        let payload = Data(frame.dropFirst(WorkerWireCodec.frameHeaderBytes))
        let decoded = try WorkerWireCodec.decode(payload, as: WorkerControlRequest.self)
        XCTAssertEqual(decoded, request)

        XCTAssertThrowsError(try WorkerWireCodec.payloadLength(from: Data([0, 0, 0]))) {
            XCTAssertEqual($0 as? WorkerWireError, .invalidHeader)
        }
        XCTAssertThrowsError(try WorkerWireCodec.payloadLength(from: Data([0x00, 0x01, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? WorkerWireError, .invalidPayloadSize)
        }
    }

    func testRegistrationRequiresAuthenticatedIdentityAndCompatibleProtocol() async throws {
        let coordinator = WorkerCoordinator()
        let workerID = UUID()
        let registration = makeRegistration(workerID: workerID)

        do {
            try await coordinator.register(registration, authenticatedWorkerID: UUID())
            XCTFail("Expected worker identity mismatch to be rejected")
        } catch let error as WorkerCoordinatorError {
            XCTAssertEqual(error, .unauthenticatedWorker)
        }

        let wrongVersion = WorkerRegistration(workerID: workerID, sessionID: registration.sessionID,
                                              displayName: registration.displayName, protocolVersion: 2,
                                              cameraIDs: registration.cameraIDs, maximumCameraCount: 1,
                                              modelIdentifiers: registration.modelIdentifiers)
        do {
            try await coordinator.register(wrongVersion, authenticatedWorkerID: workerID)
            XCTFail("Expected unsupported protocol to be rejected")
        } catch let error as WorkerCoordinatorError {
            XCTAssertEqual(error, .unsupportedProtocolVersion)
        }
    }

    func testLeaseCapacityHeartbeatRenewalAndTelemetry() async throws {
        let coordinator = WorkerCoordinator(leaseDuration: 30, heartbeatTimeout: 10)
        let workerID = UUID()
        let firstCameraID = UUID()
        let secondCameraID = UUID()
        let registration = makeRegistration(workerID: workerID, cameraIDs: [firstCameraID, secondCameraID], capacity: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        try await coordinator.register(registration, authenticatedWorkerID: workerID, at: start)
        try await coordinator.heartbeat(makeHeartbeat(registration, sequence: 1),
                                        authenticatedWorkerID: workerID, at: start)

        let lease = try await coordinator.assign(cameraID: firstCameraID, to: workerID, at: start)
        XCTAssertEqual(lease.generation, 1)
        XCTAssertEqual(lease.expiresAt, start.addingTimeInterval(30))

        do {
            _ = try await coordinator.assign(cameraID: secondCameraID, to: workerID, at: start)
            XCTFail("Expected worker capacity to be enforced")
        } catch let error as WorkerCoordinatorError {
            XCTAssertEqual(error, .workerAtCapacity)
        }

        let nextHeartbeat = WorkerHeartbeat(workerID: workerID, sessionID: registration.sessionID, sequence: 2,
                                            activeCameraIDs: [firstCameraID], processedFramesPerSecond: 4.5,
                                            queueDepth: 2, availableMemoryBytes: 1024)
        let renewed = try await coordinator.heartbeat(nextHeartbeat, authenticatedWorkerID: workerID,
                                                      at: start.addingTimeInterval(5))
        XCTAssertEqual(renewed.map(\.cameraID), [firstCameraID])
        XCTAssertEqual(renewed.first?.expiresAt, start.addingTimeInterval(35))
        let status = await coordinator.workerStatus(workerID)
        XCTAssertEqual(status?.processedFramesPerSecond, 4.5)
    }

    func testStaleHeartbeatAndUnassignedActiveCameraAreRejected() async throws {
        let coordinator = WorkerCoordinator()
        let workerID = UUID()
        let cameraID = UUID()
        let registration = makeRegistration(workerID: workerID, cameraIDs: [cameraID])
        let start = Date(timeIntervalSince1970: 2_000)
        try await coordinator.register(registration, authenticatedWorkerID: workerID, at: start)
        try await coordinator.heartbeat(makeHeartbeat(registration, sequence: 4),
                                        authenticatedWorkerID: workerID, at: start)

        do {
            _ = try await coordinator.heartbeat(makeHeartbeat(registration, sequence: 4),
                                                authenticatedWorkerID: workerID, at: start.addingTimeInterval(1))
            XCTFail("Expected replayed heartbeat to be rejected")
        } catch let error as WorkerCoordinatorError {
            XCTAssertEqual(error, .staleHeartbeat)
        }

        let invalid = WorkerHeartbeat(workerID: workerID, sessionID: registration.sessionID, sequence: 5,
                                      activeCameraIDs: [cameraID], processedFramesPerSecond: 1,
                                      queueDepth: 0)
        do {
            _ = try await coordinator.heartbeat(invalid, authenticatedWorkerID: workerID,
                                                at: start.addingTimeInterval(2))
            XCTFail("Expected unassigned camera activity to be rejected")
        } catch let error as WorkerCoordinatorError {
            XCTAssertEqual(error, .invalidHeartbeat)
        }
    }

    func testExpiredLeaseCanBeReassignedWithNewGeneration() async throws {
        let coordinator = WorkerCoordinator(leaseDuration: 30, heartbeatTimeout: 10)
        let cameraID = UUID()
        let firstWorker = makeRegistration(cameraIDs: [cameraID])
        let secondWorker = makeRegistration(cameraIDs: [cameraID])
        let start = Date(timeIntervalSince1970: 3_000)
        try await coordinator.register(firstWorker, authenticatedWorkerID: firstWorker.workerID, at: start)
        try await coordinator.register(secondWorker, authenticatedWorkerID: secondWorker.workerID, at: start)
        try await coordinator.heartbeat(makeHeartbeat(firstWorker, sequence: 1),
                                        authenticatedWorkerID: firstWorker.workerID, at: start)
        try await coordinator.heartbeat(makeHeartbeat(secondWorker, sequence: 1),
                                        authenticatedWorkerID: secondWorker.workerID, at: start)
        let original = try await coordinator.assign(cameraID: cameraID, to: firstWorker.workerID, at: start)

        let expiredAt = start.addingTimeInterval(11)
        let expired = await coordinator.expire(at: expiredAt)
        XCTAssertEqual(expired.map(\.cameraID), [cameraID])
        try await coordinator.heartbeat(makeHeartbeat(secondWorker, sequence: 2),
                        authenticatedWorkerID: secondWorker.workerID, at: expiredAt)
        let reassigned = try await coordinator.assign(cameraID: cameraID, to: secondWorker.workerID, at: expiredAt)
        XCTAssertNotEqual(reassigned.leaseID, original.leaseID)
        XCTAssertEqual(reassigned.generation, original.generation + 1)
    }

    func testBatchAssignmentDoesNotPartiallyCommitOnCapacityFailure() async throws {
        let coordinator = WorkerCoordinator()
        let workerID = UUID()
        let firstCameraID = UUID()
        let secondCameraID = UUID()
        let registration = makeRegistration(workerID: workerID,
                                            cameraIDs: [firstCameraID, secondCameraID], capacity: 1)
        let start = Date(timeIntervalSince1970: 4_000)
        try await coordinator.register(registration, authenticatedWorkerID: workerID, at: start)
        try await coordinator.heartbeat(makeHeartbeat(registration, sequence: 1),
                                        authenticatedWorkerID: workerID, at: start)

        do {
            _ = try await coordinator.assign(cameraIDs: [firstCameraID, secondCameraID],
                                             to: workerID, at: start)
            XCTFail("Expected batch assignment to enforce worker capacity")
        } catch let error as WorkerCoordinatorError {
            XCTAssertEqual(error, .workerAtCapacity)
        }
        let firstLeaseAfterRejection = await coordinator.lease(for: firstCameraID, at: start)
        let secondLeaseAfterRejection = await coordinator.lease(for: secondCameraID, at: start)
        XCTAssertNil(firstLeaseAfterRejection)
        XCTAssertNil(secondLeaseAfterRejection)

        let accepted = try await coordinator.assign(cameraIDs: [firstCameraID], to: workerID, at: start)
        XCTAssertEqual(accepted.map(\.cameraID), [firstCameraID])
    }

    private func makeRegistration(workerID: UUID = UUID(), sessionID: UUID = UUID(),
                                  cameraIDs: Set<UUID> = [UUID()], capacity: Int = 4) -> WorkerRegistration {
        WorkerRegistration(workerID: workerID, sessionID: sessionID, displayName: "worker-test",
                           cameraIDs: cameraIDs, maximumCameraCount: capacity,
                           modelIdentifiers: ["pose-test"])
    }

    private func makeHeartbeat(_ registration: WorkerRegistration, sequence: UInt64) -> WorkerHeartbeat {
        WorkerHeartbeat(workerID: registration.workerID, sessionID: registration.sessionID, sequence: sequence,
                        activeCameraIDs: [], processedFramesPerSecond: 0, queueDepth: 0)
    }
}