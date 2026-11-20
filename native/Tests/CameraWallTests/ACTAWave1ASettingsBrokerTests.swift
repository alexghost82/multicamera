import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAWave1ASettingsBrokerTests: XCTestCase {
    private final class FakeAPIKeyStore: ACTAAPIKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: String] = [:]

        func saveKey(_ value: String, account: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                keys.removeValue(forKey: account)
            } else {
                keys[account] = trimmed
            }
            return true
        }

        func hasKey(account: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return keys[account] != nil
        }

        func storedValue(account: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return keys[account]
        }
    }

    @MainActor
    private func makeIsolatedModel(dir: URL) throws -> (WallModel, LanguageSettings) {
        var config = WallConfiguration()
        config.columns = 2
        config.detectionThreshold = 0.45
        config.detectionFPS = 2
        config.staleAfterMilliseconds = 2500
        config.cameras = [Camera(name: "Front Door", substream: "rtsp://fixture.invalid/front", enabled: false)]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: [.yolo, .pose]).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: []),
            to: dir.appendingPathComponent("features.json")
        )
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
        let languageSettings = LanguageSettings(storage: InMemoryLanguageStorage())
        let poseURL = dir.appendingPathComponent("fake-pose.mlmodel")
        let model = WallModel(
            configURL: dir.appendingPathComponent("cameras.json"),
            workerMode: false,
            poseModelURL: poseURL,
            trackingStoreURL: dir.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(
                preferencesURL: dir.appendingPathComponent("features.json"),
                databaseURL: dir.appendingPathComponent("features.sqlite")
            ),
            analyticsDirectoryURL: dir.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: dir.appendingPathComponent("frames")),
            operationsWatchURL: dir.appendingPathComponent("watches.json"),
            missionStoreURL: dir.appendingPathComponent("missions.json"),
            cameraCredentialStore: ACTAIsolatedCredentials(),
            operationsPreferencesURL: dir.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: dir.appendingPathComponent("clips")),
            languageSettings: languageSettings,
            monitorHistoryURL: dir.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(
                modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }
            )
        )
        addTeardownBlock {
            Task { @MainActor in model.shutdown() }
        }
        return (model, languageSettings)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-wave1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private final class ThreadSafeBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T
        init(_ initial: T) { storage = initial }
        func mutate(_ block: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; block(&storage) }
        var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    }

    func testAPIKeySetAndClearThroughBrokerNeverLeakSecret() async throws {
        let keyStore = FakeAPIKeyStore()
        let audited = ThreadSafeBox<[String]>([])
        let secretValue = "sk-super-secret-test-999999"
        let setAction = await MainActor.run {
            ACTASetAPIKeyAction(keyStore: keyStore, promptForSecret: { _ in secretValue })
        }
        let clearAction = await MainActor.run {
            ACTAClearAPIKeyAction(keyStore: keyStore)
        }
        let actions: [any ACTAActionProtocol] = [setAction, clearAction]
        let madeHost = await ACTALocalActionBroker.make(
            actions: actions,
            allowedActionIDs: Set(actions.map(\.id)),
            audit: { event in audited.mutate { $0.append("\(event.phase):\(event.actionID):\(event.auditMetadataJSON)") } }
        )
        let host = try XCTUnwrap(madeHost)
        let openedSession = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .chat,
            threadID: "t-keys",
            actionIDs: Set(actions.map(\.id))
        )
        let session = try XCTUnwrap(openedSession)

        // 1. Request set_api_key -> confirmation required
        let req = await host.broker.request(
            session: session,
            actionID: "settings.set_api_key",
            argumentsJSON: #"{"account":"primary"}"#
        )
        XCTAssertTrue(req.requiresOperatorConfirmation)
        XCTAssertFalse(keyStore.hasKey(account: ACTAKeychainStore.primaryKeyAccount))

        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertFalse(reviews[0].title.contains(secretValue))

        // 2. Approve set_api_key
        let setRes = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: reviews[0],
            approved: true
        )
        XCTAssertTrue(setRes.success, setRes.error ?? "")
        XCTAssertTrue(setRes.verified)
        XCTAssertEqual(keyStore.storedValue(account: ACTAKeychainStore.primaryKeyAccount), secretValue)
        XCTAssertFalse(setRes.outputJSON.contains(secretValue))
        XCTAssertFalse(setRes.summary.contains(secretValue))
        XCTAssertTrue(audited.value.allSatisfy { !$0.contains(secretValue) })

        // 3. Clear key
        let clearReq = await host.broker.request(
            session: session,
            actionID: "settings.clear_api_key",
            argumentsJSON: #"{"account":"primary"}"#
        )
        XCTAssertTrue(clearReq.requiresOperatorConfirmation)
        let clearReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertEqual(clearReviews.count, 1)

        let clearRes = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: clearReviews[0],
            approved: true
        )
        XCTAssertTrue(clearRes.success, clearRes.error ?? "")
        XCTAssertTrue(clearRes.verified)
        XCTAssertFalse(keyStore.hasKey(account: ACTAKeychainStore.primaryKeyAccount))
    }

    func testModelSelectionAndReloadThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, _) = try await makeIsolatedModel(dir: dir)
        let reloaded = ThreadSafeBox(false)
        let updateAction = await MainActor.run { ACTAUpdateModelsAction(model: model) }
        let reloadAction = await MainActor.run {
            ACTAReloadModelsAction(model: model, reloadHook: {
                reloaded.mutate { $0 = true }
                return true
            })
        }
        let actions: [any ACTAActionProtocol] = [updateAction, reloadAction]
        let madeHost = await ACTALocalActionBroker.make(
            actions: actions,
            allowedActionIDs: Set(actions.map(\.id)),
            audit: { _ in }
        )
        let host = try XCTUnwrap(madeHost)
        let openedSession = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .chat,
            threadID: "t-models",
            actionIDs: Set(actions.map(\.id))
        )
        let session = try XCTUnwrap(openedSession)

        let req = await host.broker.request(
            session: session,
            actionID: "settings.update_models",
            argumentsJSON: #"{"service":"pose","enabled":false}"#
        )
        XCTAssertTrue(req.requiresOperatorConfirmation)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        XCTAssertEqual(reviews.count, 1)
        let res = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: reviews[0],
            approved: true
        )
        XCTAssertTrue(res.success, res.error ?? "")
        XCTAssertTrue(res.verified)
        let isEnabled = await MainActor.run { model.modelPreferences.enabled.contains(.pose) }
        XCTAssertFalse(isEnabled)

        // Reload models
        let reloadReq = await host.broker.request(
            session: session,
            actionID: "settings.reload_models",
            argumentsJSON: "{}"
        )
        XCTAssertTrue(reloadReq.requiresOperatorConfirmation)
        let reloadReviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let reloadRes = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: reloadReviews[0],
            approved: true
        )
        XCTAssertTrue(reloadRes.success, reloadRes.error ?? "")
        XCTAssertTrue(reloaded.value)
    }

    func testUnifiedSystemSettingsBrokerSupportsLanguageAndSystemSeparately() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, languageSettings) = try await makeIsolatedModel(dir: dir)
        let action = await MainActor.run {
            ACTAReviewedSystemSettingsAction(model: model, languageSettings: languageSettings)
        }
        let madeHost = await ACTALocalActionBroker.make(
            actions: [action],
            allowedActionIDs: [action.id],
            audit: { _ in }
        )
        let host = try XCTUnwrap(madeHost)
        let openedSession = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .chat,
            threadID: "t-sys",
            actionIDs: [action.id]
        )
        let session = try XCTUnwrap(openedSession)

        // Reject mixed language + columns
        let mixed = await host.broker.request(
            session: session,
            actionID: "settings.update_system",
            argumentsJSON: #"{"language":"ru","columns":4}"#
        )
        XCTAssertFalse(mixed.success)
        XCTAssertFalse(mixed.requiresOperatorConfirmation)

        // Update language
        let langReq = await host.broker.request(
            session: session,
            actionID: "settings.update_system",
            argumentsJSON: #"{"language":"ru"}"#
        )
        XCTAssertTrue(langReq.requiresOperatorConfirmation)
        let langRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let langRes = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: langRev[0],
            approved: true
        )
        XCTAssertTrue(langRes.success, langRes.error ?? "")
        let currentLang = await MainActor.run { languageSettings.language }
        XCTAssertEqual(currentLang, .russian)

        // Update system columns & detection FPS
        let sysReq = await host.broker.request(
            session: session,
            actionID: "settings.update_system",
            argumentsJSON: #"{"columns":4,"detection_fps":3}"#
        )
        XCTAssertTrue(sysReq.requiresOperatorConfirmation)
        let sysRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let sysRes = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: sysRev[0],
            approved: true
        )
        XCTAssertTrue(sysRes.success, sysRes.error ?? "")
        let (cols, fps) = await MainActor.run { (model.config.columns, model.config.detectionFPS) }
        XCTAssertEqual(cols, 4)
        XCTAssertEqual(fps, 3)
    }

    func testShowcaseToggleRequiresFeatureAndRedactsToken() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, _) = try await makeIsolatedModel(dir: dir)
        let action = await MainActor.run { ACTAToggleShowcaseAction(model: model) }
        let madeHost = await ACTALocalActionBroker.make(
            actions: [action],
            allowedActionIDs: [action.id],
            audit: { _ in }
        )
        let host = try XCTUnwrap(madeHost)
        let openedSession = await host.broker.openSession(
            operatorKey: host.operatorKey,
            input: .chat,
            threadID: "t-showcase",
            actionIDs: [action.id]
        )
        let session = try XCTUnwrap(openedSession)

        // Feature disabled by default -> preparation fails closed
        let denied = await host.broker.request(
            session: session,
            actionID: "settings.toggle_showcase",
            argumentsJSON: #"{"running":true}"#
        )
        XCTAssertFalse(denied.success)
        XCTAssertFalse(denied.requiresOperatorConfirmation)

        // Stopping when already stopped succeeds cleanly after review
        let stopReq = await host.broker.request(
            session: session,
            actionID: "settings.toggle_showcase",
            argumentsJSON: #"{"running":false}"#
        )
        XCTAssertTrue(stopReq.requiresOperatorConfirmation)
        let stopRev = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let stopRes = await host.broker.resolve(
            operatorKey: host.operatorKey,
            session: session,
            reviewed: stopRev[0],
            approved: true
        )
        XCTAssertTrue(stopRes.success, stopRes.error ?? "")
        XCTAssertTrue(stopRes.verified)
    }
}
