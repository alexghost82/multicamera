import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class CameraInventoryFixture: ACTAAnalyticsCameraInventory {
    var ids: Set<UUID>
    var revision = UUID()
    var locked = false
    init(_ ids: Set<UUID>) { self.ids = ids }
    func withCamera<T>(id: UUID, _ body: (UUID) throws -> T) throws -> T? {
        guard !locked else { throw Failure() }
        guard ids.contains(id) else { return nil }
        locked = true
        defer { locked = false }
        return try body(revision)
    }
    func change(_ ids: Set<UUID>) {
        precondition(!locked)
        self.ids = ids
        revision = UUID()
    }
    struct Failure: Error {}
}

@MainActor
private final class StoredAnalyticsFixture: ACTAAnalyticsSettingsMutationDomain {
    let url: URL
    var saved: VideoAnalyticsSettingsStore.Snapshot
    var memory: VideoAnalyticsSettings
    var revision = UUID()
    var writes = 0
    var beforeCompare: (() -> Void)?

    init(url: URL) throws {
        self.url = url
        saved = try VideoAnalyticsSettingsStore.snapshot(from: url)
        memory = saved.settings
    }
    func capture() throws -> ACTAAnalyticsSettingsObservation {
        guard try VideoAnalyticsSettingsStore.snapshot(from: url) == saved, memory == saved.settings else {
            throw CameraInventoryFixture.Failure()
        }
        return .init(revision: revision, memory: memory, persisted: saved.settings)
    }
    func commit(expected: ACTAAnalyticsSettingsObservation, replacement: VideoAnalyticsSettings) throws -> ACTAAnalyticsSettingsObservation? {
        beforeCompare?()
        guard try capture() == expected,
              let result = try VideoAnalyticsSettingsStore.compareAndSave(replacement, expected: saved, to: url) else { return nil }
        saved = result
        memory = result.settings
        revision = UUID()
        writes += 1
        return try capture()
    }
}

private final class AuditFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var failPhase: ACTABrokerAuditEvent.Phase?
    private var recorded: [ACTABrokerAuditEvent.Phase] = []
    func fail(on phase: ACTABrokerAuditEvent.Phase?) {
        lock.lock(); defer { lock.unlock() }
        failPhase = phase
    }
    func record(_ event: ACTABrokerAuditEvent) throws {
        lock.lock(); defer { lock.unlock() }
        if event.phase == failPhase { throw CameraInventoryFixture.Failure() }
        recorded.append(event.phase)
    }
    func phases() -> [ACTABrokerAuditEvent.Phase] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

@MainActor
private final class ReentrantInventoryFixture {
    @Published var configuration: WallConfiguration {
        willSet { revision = UUID() }
    }
    @Published var analytics = VideoAnalyticsSettings.safeDefaults
    var revision = UUID()
    init(_ configuration: WallConfiguration) { self.configuration = configuration }
}

@MainActor
final class ACTAPreparedCameraAnalyticsActionTests: XCTestCase {
    private let context = ACTAActionContext(threadID: "synthetic")

    private func fixture() throws -> (StoredAnalyticsFixture, CameraInventoryFixture, UUID) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-analytics-action-check/work/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let camera = UUID()
        return (try StoredAnalyticsFixture(url: directory.appendingPathComponent("settings.json")),
                CameraInventoryFixture([camera]), camera)
    }
    private func parameters(_ id: UUID, _ field: String = "analyticsEnabled", _ value: String = "false") -> [String: String] {
        ["camera_id": id.uuidString, "field": field, "value": value]
    }

    func testRealSettingsCASPreservesOtherOverridesAndReviewRequiresConfirmation() async throws {
        let (domain, inventory, id) = try fixture()
        let other = UUID()
        var initial = domain.memory
        initial.cameraOverrides[other] = CameraAnalyticsOverride(cameraID: other, analyticsEnabled: false)
        domain.saved = try XCTUnwrap(VideoAnalyticsSettingsStore.compareAndSave(initial, expected: domain.saved, to: domain.url))
        domain.memory = initial
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inventory)
        let p = parameters(id)
        let review = try await action.prepareConfirmation(parameters: p, context: context)
        XCTAssertTrue(review.reviewSummary.contains(id.uuidString))
        XCTAssertTrue(review.reviewSummary.contains("new override"))
        XCTAssertEqual(domain.writes, 0)
        let direct = try await action.execute(parameters: p, context: context)
        XCTAssertFalse(direct.success)
        let result = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(domain.memory.cameraOverrides[other], initial.cameraOverrides[other])
        XCTAssertEqual(domain.memory.cameraOverrides[id]?.analyticsEnabled, false)
        XCTAssertEqual(try VideoAnalyticsSettingsStore.snapshot(from: domain.url).settings, domain.memory)
        let verified = try await action.verify(parameters: p, context: context)
        XCTAssertTrue(verified)
        let replay = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertFalse(replay.success)
        XCTAssertEqual(domain.writes, 1)
    }

    func testMissingCameraInventoryABAAndSettingsCASRejectStale() async throws {
        let (domain, inventory, id) = try fixture()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inventory)
        let p = parameters(id)
        inventory.change([])
        do { _ = try await action.prepareConfirmation(parameters: p, context: context); XCTFail("Missing camera") } catch {}
        inventory.change([id])
        let review = try await action.prepareConfirmation(parameters: p, context: context)
        inventory.change([])
        let removed = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(removed.error?.contains("STALE_REVIEW") == true)
        inventory.change([id])
        let abaReview = try await action.prepareConfirmation(parameters: p, context: context)
        inventory.change([])
        inventory.change([id])
        let stale = try await action.executeConfirmed(parameters: p, context: context, snapshot: abaReview.snapshot)
        XCTAssertTrue(stale.error?.contains("STALE_REVIEW") == true)
        XCTAssertEqual(domain.writes, 0)
        let second = try await action.prepareConfirmation(parameters: p, context: context)
        var external = domain.memory
        external.enableSoundAlert.toggle()
        try VideoAnalyticsSettingsStore.save(external, to: domain.url)
        try VideoAnalyticsSettingsStore.save(domain.memory, to: domain.url)
        let rejected = try await action.executeConfirmed(parameters: p, context: context, snapshot: second.snapshot)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(domain.writes, 0)
    }

    func testValidationAndReadbackBoundToInventory() async throws {
        let (domain, inventory, id) = try fixture()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inventory)
        for p in [parameters(id, "customSamplingFPS", "nan"), parameters(id, "analyticsEnabled", "1"),
                  parameters(id, "restrictedZones", "x"), parameters(id, "sensitivityProfile", "bad")] {
            XCTAssertThrowsError(try action.validate(parameters: p))
        }
        do { _ = try await action.prepareConfirmation(parameters: parameters(id, "customSamplingFPS", "16"), context: context); XCTFail("Out of range") } catch {}
        let noInventory = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain)
        do { _ = try await noInventory.prepareConfirmation(parameters: parameters(id), context: context); XCTFail("Inventory required") } catch {}
        let p = parameters(id, "customAlertCooldownSeconds", "25")
        let review = try await action.prepareConfirmation(parameters: p, context: context)
        let result = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success)
        inventory.change([id])
        let verified = try await action.verify(parameters: p, context: context)
        XCTAssertFalse(verified)
        XCTAssertTrue(ACTAPreparedAnalyticsSettingsAction.Kind.allCases.contains(.cameraOverride))
        XCTAssertFalse(ACTAPreparedAnalyticsSettingsAction.Kind.productionCases.contains(.cameraOverride))
    }

    func testBrokerApprovalResetAndInventoryExclusion() async throws {
        let (domain, inventory, id) = try fixture()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inventory)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: context.threadID, actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let json = #"{"camera_id":"\#(id.uuidString)","field":"customSamplingFPS","value":"5"}"#
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: json)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let firstReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let first = try XCTUnwrap(firstReviews.first)
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: first, approved: false)
        XCTAssertFalse(rejected.success)
        XCTAssertEqual(domain.writes, 0)
        _ = await host.broker.request(session: session, actionID: action.id, argumentsJSON: json)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        var exclusionObserved = false
        domain.beforeCompare = {
            do { _ = try inventory.withCamera(id: id) { _ in true } }
            catch { exclusionObserved = true }
        }
        let approved = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
        XCTAssertTrue(approved.success)
        XCTAssertTrue(approved.verified)
        XCTAssertTrue(exclusionObserved)
        domain.beforeCompare = nil
        let p = parameters(id, "customSamplingFPS", "inherit")
        let reset = try await action.prepareConfirmation(parameters: p, context: context)
        XCTAssertTrue(reset.reviewSummary.contains("5.0 -> inherit"))
        let result = try await action.executeConfirmed(parameters: p, context: context, snapshot: reset.snapshot)
        XCTAssertTrue(result.success)
        XCTAssertNil(domain.memory.cameraOverrides[id]?.customSamplingFPS)
    }

    func testReviewShowsDormantAndInheritanceEffects() async throws {
        let (domain, inventory, id) = try fixture()
        var initial = domain.memory
        initial.cameraOverrides[id] = CameraAnalyticsOverride(cameraID: id, inheritGlobalSettings: true,
                                                               personDetectionEnabled: false,
                                                               sensitivityProfile: .conservative)
        domain.saved = try XCTUnwrap(VideoAnalyticsSettingsStore.compareAndSave(initial, expected: domain.saved, to: domain.url))
        domain.memory = initial
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inventory)
        let dormant = try await action.prepareConfirmation(parameters: parameters(id, "personDetectionEnabled", "true"), context: context)
        XCTAssertTrue(dormant.reviewSummary.contains("Computed effective changes assuming camera analytics is enabled: none"))
        let active = try await action.prepareConfirmation(parameters: parameters(id, "inheritGlobalSettings", "false"), context: context)
        XCTAssertTrue(active.reviewSummary.contains("personDetectionEnabled: true -> false"))
        XCTAssertTrue(active.reviewSummary.contains("personConfidenceThreshold:"))
        XCTAssertTrue(active.reviewSummary.contains("Actual camera state and model readiness are not verified"))
        XCTAssertEqual(domain.writes, 0)
    }

    func testRemoveOverrideReviewsZoneLossAndRejectsStaleInventory() async throws {
        let (domain, inventory, id) = try fixture()
        let other = UUID()
        var initial = domain.memory
        initial.cameraOverrides[id] = CameraAnalyticsOverride(
            cameraID: id, inheritGlobalSettings: false, personDetectionEnabled: false,
            restrictedZones: [.rectangle(name: "synthetic", x: 0.1, y: 0.1, width: 0.5, height: 0.5)])
        initial.cameraOverrides[other] = CameraAnalyticsOverride(cameraID: other)
        domain.saved = try XCTUnwrap(VideoAnalyticsSettingsStore.compareAndSave(initial, expected: domain.saved, to: domain.url))
        domain.memory = initial
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .removeCameraOverride, domain: domain, cameraInventory: inventory)
        let p = ["camera_id": id.uuidString]
        XCTAssertEqual(action.classification, .destructive)
        XCTAssertFalse(ACTAPreparedAnalyticsSettingsAction.Kind.productionCases.contains(.removeCameraOverride))
        XCTAssertThrowsError(try action.validate(parameters: ["camera_id": "invalid"]))
        XCTAssertThrowsError(try action.validate(parameters: ["camera_id": id.uuidString, "extra": "x"]))
        let staleReview = try await action.prepareConfirmation(parameters: p, context: context)
        XCTAssertTrue(staleReview.reviewSummary.contains("remove override and 1 restricted zone(s)"))
        XCTAssertTrue(staleReview.reviewSummary.contains("restrictedZones: 1 -> 0"))
        XCTAssertTrue(staleReview.reviewSummary.contains("personDetectionEnabled: false -> true"))
        inventory.change([])
        inventory.change([id])
        let stale = try await action.executeConfirmed(parameters: p, context: context, snapshot: staleReview.snapshot)
        XCTAssertTrue(stale.error?.contains("STALE_REVIEW") == true)
        XCTAssertEqual(domain.writes, 0)
        let review = try await action.prepareConfirmation(parameters: p, context: context)
        let result = try await action.executeConfirmed(parameters: p, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertNil(domain.memory.cameraOverrides[id])
        XCTAssertEqual(domain.memory.cameraOverrides[other], initial.cameraOverrides[other])
        XCTAssertEqual(try VideoAnalyticsSettingsStore.snapshot(from: domain.url).settings, domain.memory)
        let verified = try await action.verify(parameters: p, context: context)
        XCTAssertTrue(verified)
        do {
            _ = try await action.prepareConfirmation(parameters: p, context: context)
            XCTFail("Missing override must not be reviewed")
        } catch {}
    }

    func testRemoveOverrideBrokerRejectsWithoutWritingAndApprovesOnce() async throws {
        let (domain, inventory, id) = try fixture()
        var initial = domain.memory
        initial.cameraOverrides[id] = CameraAnalyticsOverride(cameraID: id)
        domain.saved = try XCTUnwrap(VideoAnalyticsSettingsStore.compareAndSave(initial, expected: domain.saved, to: domain.url))
        domain.memory = initial
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .removeCameraOverride, domain: domain, cameraInventory: inventory)
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                    threadID: context.threadID, actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let json = #"{"camera_id":"\#(id.uuidString)"}"#
        for approved in [false, true] {
            let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: json)
            XCTAssertTrue(pending.requiresOperatorConfirmation)
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.first)
            let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: approved)
            XCTAssertEqual(result.success, approved)
            if approved { XCTAssertTrue(result.verified) }
            else { XCTAssertEqual(domain.writes, 0) }
            let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
            XCTAssertFalse(replay.success)
        }
        XCTAssertEqual(domain.writes, 1)
        XCTAssertNil(domain.memory.cameraOverrides[id])
    }

    func testBrokerAuditFailurePreventsApprovalAndReportsUnknownResult() async throws {
        let (domain, inventory, id) = try fixture()
        let action = ACTAPreparedAnalyticsSettingsAction(kind: .cameraOverride, domain: domain, cameraInventory: inventory)
        let audit = AuditFixture()
        let made = await ACTALocalActionBroker.make(actions: [action], allowedActionIDs: [action.id], audit: { try audit.record($0) })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey, input: .chat,
                                                   threadID: context.threadID, actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let json = #"{"camera_id":"\#(id.uuidString)","field":"analyticsEnabled","value":"false"}"#
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: json)
        XCTAssertTrue(pending.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        audit.fail(on: .review)
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
        XCTAssertTrue(rejected.error?.contains("AUDIT_FAILED") == true)
        XCTAssertEqual(domain.writes, 0)
        audit.fail(on: .result)
        let unknown = await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
        XCTAssertTrue(unknown.error?.contains("may have executed") == true)
        XCTAssertEqual(domain.writes, 1)
        XCTAssertTrue(audit.phases().contains(.review))
        XCTAssertEqual(domain.memory.cameraOverrides[id]?.analyticsEnabled, false)
    }

    func testCameraStoreLockCanCoverAnalyticsCASAndDetectCooperatingABA() throws {
        let (analytics, _, id) = try fixture()
        let url = analytics.url.deletingLastPathComponent().appendingPathComponent("cameras.json")
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var cameras = empty.configuration
        cameras.cameras = [Camera(id: id, name: "Synthetic", substream: "", localDeviceID: "synthetic")]
        let reviewed = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(cameras, expected: empty, to: url))
        var replacement = analytics.memory
        replacement.cameraOverrides[id] = CameraAnalyticsOverride(cameraID: id, analyticsEnabled: false)

        try CoordinatedCameraConfigurationStore.withLockedSnapshot(from: url) { locked in
            XCTAssertTrue(locked.matches(reviewed))
            var removed = cameras
            removed.cameras = []
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(removed, expected: locked, to: url))
            XCTAssertNotNil(try VideoAnalyticsSettingsStore.compareAndSave(replacement, expected: analytics.saved, to: analytics.url))
        }
        var removed = cameras
        removed.cameras = []
        let changed = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(removed, expected: reviewed, to: url))
        let restored = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(cameras, expected: changed, to: url))
        XCTAssertEqual(restored.configuration, reviewed.configuration)
        XCTAssertFalse(restored.matches(reviewed))
    }

    func testInventoryLockAndCaptureDoNotFenceDirectReentrantMemoryWriter() throws {
        let (analytics, _, id) = try fixture()
        let url = analytics.url.deletingLastPathComponent().appendingPathComponent("cameras.json")
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var cameras = empty.configuration
        cameras.cameras = [Camera(id: id, name: "Synthetic", substream: "", localDeviceID: "synthetic")]
        let reviewed = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(cameras, expected: empty, to: url))
        let memory = ReentrantInventoryFixture(cameras)
        let gate = ACTACameraWriterGate()
        let subscription = memory.$analytics.dropFirst().sink { _ in
            MainActor.assumeIsolated { memory.configuration.cameras = [] }
        }
        var replacement = analytics.memory
        replacement.cameraOverrides[id] = CameraAnalyticsOverride(cameraID: id, analyticsEnabled: false)
        let revision = memory.revision

        let result = try gate.capture {
            try CoordinatedCameraConfigurationStore.withLockedSnapshot(from: url) { locked in
                XCTAssertTrue(locked.matches(reviewed))
                XCTAssertEqual(memory.configuration, locked.configuration)
                _ = try XCTUnwrap(VideoAnalyticsSettingsStore.compareAndSave(replacement, expected: analytics.saved, to: analytics.url))
                memory.analytics = replacement
                return memory.revision == revision && memory.configuration == locked.configuration
            }
        }
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(result.value)
        XCTAssertTrue(memory.configuration.cameras.isEmpty)
        XCTAssertEqual(try VideoAnalyticsSettingsStore.snapshot(from: analytics.url).settings, replacement)
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, cameras)
    }

    func testNoncooperatingCameraWriterCanBypassLockAndRevision() throws {
        let (analytics, _, id) = try fixture()
        let url = analytics.url.deletingLastPathComponent().appendingPathComponent("cameras.json")
        let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var cameras = empty.configuration
        cameras.cameras = [Camera(id: id, name: "Synthetic", substream: "", localDeviceID: "synthetic")]
        let reviewed = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(cameras, expected: empty, to: url))
        var removed = cameras
        removed.cameras = []
        try CoordinatedCameraConfigurationStore.withLockedSnapshot(from: url) { locked in
            XCTAssertTrue(locked.matches(reviewed))
            try ConfigurationStore.save(removed, to: url)
            XCTAssertEqual(try ConfigurationStore.load(from: url), removed)
            try ConfigurationStore.save(cameras, to: url)
        }
        XCTAssertTrue(try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(reviewed))
    }
}
