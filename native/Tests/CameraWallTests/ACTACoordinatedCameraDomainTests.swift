import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACoordinatedCameraDomainTests: XCTestCase {
    private final class Host {
        var configuration = WallConfiguration()
    }

    func testDestroyedHostFailsClosedWithoutRetainingIt() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var host: Host? = Host()
        weak let weakHost = host
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { [weak host] in
            guard let host else { throw CocoaError(.fileReadUnknown) }
            return host.configuration
        }, installMemory: { [weak host] configuration in
            guard let host else { throw CocoaError(.fileWriteUnknown) }
            host.configuration = configuration
        })
        let draft = try domain.draft()
        host = nil
        XCTAssertNil(weakHost)
        XCTAssertThrowsError(try domain.draft())
        XCTAssertThrowsError(try domain.save(draft.configuration, expected: draft))
        XCTAssertThrowsError(try domain.beginRuntime())
    }

    func testMissingPreviouslySavedConfigurationBlocksRuntimeAndReconciliation() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        let saved = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(
            memory, expected: empty, to: url))
        let original = try Data(contentsOf: url)
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        let draft = try domain.draft()
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try domain.draft())
        XCTAssertThrowsError(try domain.beginRuntime())
        XCTAssertThrowsError(try domain.reloadIfStopped())
        XCTAssertThrowsError(try domain.save(memory, expected: draft))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(memory, saved.configuration)
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})

        try original.write(to: url)
        try domain.reloadIfStopped()
        try domain.beginRuntime()
    }

    func testRuntimeLeaseSurvivesSuspendedAndFailedDrain() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        try domain.beginRuntime()
        var resume: CheckedContinuation<Void, Never>?
        let stopping = Task { @MainActor in
            try await domain.endRuntime {
                await withCheckedContinuation { resume = $0 }
                throw CocoaError(.fileReadUnknown)
            }
        }
        while resume == nil { await Task.yield() }
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        do {
            try await domain.endRuntime(afterDraining: {})
            XCTFail("Concurrent drain must not run")
        } catch { }
        resume?.resume()
        do {
            try await stopping.value
            XCTFail("Failed drain must not release the runtime")
        } catch { }
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        XCTAssertThrowsError(try domain.currentRuntimeLease())
        XCTAssertThrowsError(try domain.beginRuntime())
        try await domain.endRuntime(afterDraining: {})
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }

    func testCancelledDrainKeepsRuntimeFencedUntilSuccessfulRetry() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        try domain.beginRuntime()
        var resume: CheckedContinuation<Void, Never>?
        let stopping = Task { @MainActor in
            try await domain.endRuntime {
                await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        stopping.cancel()
        resume?.resume()
        do {
            try await stopping.value
            XCTFail("Cancelled drain must not release the runtime")
        } catch is CancellationError {
        }
        XCTAssertThrowsError(try domain.currentRuntimeLease())
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        try await domain.endRuntime(afterDraining: {})
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
        try domain.beginRuntime()
        try await domain.endRuntime(afterDraining: {})
    }

    func testRealBrokerReviewsAndCommitsOnlyWhileRuntimesStopped() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        let id = UUID()
        var memory = WallConfiguration()
        memory.cameras = [Camera(id: id, name: "Fixture", substream: "", enabled: false,
                                 localDeviceID: "fixture-\(UUID().uuidString)")]
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(memory, expected: empty, to: url))
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        var otherMemory = memory
        let other = ACTACoordinatedCameraDomain(url: url, readMemory: { otherMemory },
                                                installMemory: { otherMemory = $0 })
        let enabled = ACTAPreparedCameraFlagsAction(kind: .enabled, domain: domain)
        let processing = ACTAPreparedCameraFlagsAction(kind: .processing, domain: domain)
        let made = await ACTALocalActionBroker.make(
            actions: [enabled, processing], allowedActionIDs: [enabled.id, processing.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "fixture", actionIDs: [enabled.id, processing.id])
        let session = try XCTUnwrap(opened)
        let arguments = #"{"camera_id":"\#(id.uuidString)","enabled":true,"feature":"yolo"}"#
        let pending = await host.broker.request(session: session, actionID: processing.id, argumentsJSON: arguments)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        XCTAssertFalse(memory.cameras[0].yoloEnabled)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        try other.beginRuntime()
        let blocked = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: try XCTUnwrap(reviews.first), approved: true)
        XCTAssertFalse(blocked.success)
        XCTAssertFalse(memory.cameras[0].yoloEnabled)
        try await other.endRuntime(afterDraining: {})
        let retry = await host.broker.request(session: session, actionID: processing.id, argumentsJSON: arguments)
        XCTAssertTrue(retry.requiresOperatorConfirmation)
        let retryReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                 reviewed: try XCTUnwrap(retryReviews.first), approved: true)
        XCTAssertTrue(approved.success && approved.verified, approved.summary)
        XCTAssertTrue(memory.cameras[0].yoloEnabled)
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, memory)
        let enableArguments = #"{"camera_id":"\#(id.uuidString)","enabled":true}"#
        let enableRequest = await host.broker.request(session: session, actionID: enabled.id, argumentsJSON: enableArguments)
        XCTAssertTrue(enableRequest.requiresOperatorConfirmation)
        let enableReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let enableResult = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                     reviewed: try XCTUnwrap(enableReviews.first), approved: true)
        XCTAssertTrue(enableResult.success && enableResult.verified, enableResult.summary)
        XCTAssertTrue(memory.cameras[0].enabled)
        let chatArguments = #"{"camera_id":"\#(id.uuidString)","enabled":false,"feature":"ai_chat"}"#
        let chatRequest = await host.broker.request(session: session, actionID: processing.id, argumentsJSON: chatArguments)
        XCTAssertTrue(chatRequest.requiresOperatorConfirmation)
        let chatReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let chatResult = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                   reviewed: try XCTUnwrap(chatReviews.first), approved: true)
        XCTAssertTrue(chatResult.success && chatResult.verified, chatResult.summary)
        XCTAssertFalse(memory.cameras[0].aiChatEnabled)
    }

    func testFlagsRejectStaleCrossInstanceABAAndRunningRuntime() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        let id = UUID()
        var initial = WallConfiguration()
        initial.cameras = [Camera(id: id, name: "Fixture", substream: "", enabled: false,
                                  localDeviceID: "fixture-\(UUID().uuidString)")]
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(initial, expected: empty, to: url))
        var firstMemory = initial
        var secondMemory = initial
        let first = ACTACoordinatedCameraDomain(url: url, readMemory: { firstMemory },
                                                installMemory: { firstMemory = $0 })
        let second = ACTACoordinatedCameraDomain(url: url, readMemory: { secondMemory },
                                                 installMemory: { secondMemory = $0 })
        let old = try XCTUnwrap(first.capture(cameraID: id))
        let secondDraft = try second.draft()
        var changed = initial
        changed.cameras[0].yoloEnabled = true
        try second.save(changed, expected: secondDraft)
        try second.save(initial, expected: second.draft())
        XCTAssertNil(try first.commit(expected: old, field: .enabled, value: true))
        XCTAssertEqual(firstMemory, initial)

        let review = try XCTUnwrap(first.capture(cameraID: id))
        try second.beginRuntime()
        XCTAssertThrowsError(try first.commit(expected: review, field: .enabled, value: true))
        XCTAssertEqual(firstMemory, initial)
        try await second.endRuntime(afterDraining: {})
        let fresh = try XCTUnwrap(first.capture(cameraID: id))
        let result = try XCTUnwrap(first.commit(expected: fresh, field: .enabled, value: true))
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(try first.capture(cameraID: id), result)
        XCTAssertThrowsError(try second.beginRuntime())
    }

    func testStaleGUIDraftAndFailedPublicationRequireReconciliation() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        var fail = false
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
            installMemory: { value in
                if fail { throw CocoaError(.fileWriteUnknown) }
                memory = value
            })
        let old = try domain.draft()
        var next = memory
        next.columns = 5
        try domain.save(next, expected: old)
        XCTAssertThrowsError(try domain.save(old.configuration, expected: old))
        fail = true
        next.columns = 6
        XCTAssertThrowsError(try domain.save(next, expected: domain.draft()))
        XCTAssertThrowsError(try domain.draft())
        XCTAssertThrowsError(try domain.beginRuntime())
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration.columns, 6)
        fail = false
        try domain.reloadIfStopped()
        XCTAssertEqual(memory.columns, 6)
        XCTAssertEqual(try domain.draft().configuration, memory)
    }

    func testReloadReconcilesOtherInstanceAndInvalidatesDraftsOnlyWhenStopped() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var firstMemory = WallConfiguration()
        var secondMemory = firstMemory
        let first = ACTACoordinatedCameraDomain(url: url, readMemory: { firstMemory },
                                                installMemory: { firstMemory = $0 })
        let second = ACTACoordinatedCameraDomain(url: url, readMemory: { secondMemory },
                                                 installMemory: { secondMemory = $0 })
        let stale = try first.draft()
        var next = secondMemory
        next.columns = 8
        try second.save(next, expected: second.draft())
        XCTAssertThrowsError(try first.draft())
        try second.beginRuntime()
        XCTAssertThrowsError(try first.reloadIfStopped())
        XCTAssertEqual(firstMemory.columns, 4)
        try await second.endRuntime(afterDraining: {})
        try first.reloadIfStopped()
        XCTAssertEqual(firstMemory, next)
        XCTAssertThrowsError(try first.save(stale.configuration, expected: stale))
        try first.beginRuntime()
        try await first.endRuntime(afterDraining: {})
    }

    func testRefreshAfterRuntimePreservesDraftButRejectsWritesAndABA() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-domain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cameras.json")
        var firstMemory = WallConfiguration()
        var secondMemory = firstMemory
        let first = ACTACoordinatedCameraDomain(url: url, readMemory: { firstMemory },
                                                installMemory: { firstMemory = $0 })
        let second = ACTACoordinatedCameraDomain(url: url, readMemory: { secondMemory },
                                                 installMemory: { secondMemory = $0 })
        let old = try first.draft()
        try first.beginRuntime()
        try await first.endRuntime(afterDraining: {})
        XCTAssertThrowsError(try first.save(old.configuration, expected: old))
        let renewed = try first.refreshAfterRuntime(old)
        var change = firstMemory
        change.columns = 6
        try first.save(change, expected: renewed)
        XCTAssertThrowsError(try first.refreshAfterRuntime(old))

        try first.save(WallConfiguration(), expected: first.draft())
        let beforeABA = try first.draft()
        var changed = secondMemory
        changed.columns = 7
        try second.save(changed, expected: second.draft())
        try second.save(WallConfiguration(), expected: second.draft())
        XCTAssertThrowsError(try first.refreshAfterRuntime(beforeABA))
    }
}
