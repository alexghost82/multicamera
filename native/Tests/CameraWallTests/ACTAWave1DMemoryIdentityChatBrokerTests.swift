import CameraCore
import Foundation
import XCTest
@testable import CameraWall

final class ACTAWave1DMemoryIdentityChatBrokerTests: XCTestCase {
    private final class ThreadSafeBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T
        init(_ initial: T) { storage = initial }
        func set(_ value: T) { lock.lock(); defer { lock.unlock() }; storage = value }
        var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acta-wave1d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    @MainActor
    private func makeIsolatedModel(dir: URL) throws -> (WallModel, UUID) {
        let cam = Camera(name: "Gate", substream: "rtsp://127.0.0.1:8554/gate", enabled: false)
        var config = WallConfiguration()
        config.cameras = [cam]
        try ConfigurationStore.save(config, to: dir.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: dir.appendingPathComponent("model-preferences.json"))
        try CameraFeaturePreferencesStore.save(
            CameraFeaturePreferences(enabledFeatures: [.chronologicalMemory, .crossCameraIdentity, .visionDescriptions, .plateRecognition]),
            to: dir.appendingPathComponent("features.json")
        )
        var ai = VLMPreferences()
        ai.actaBackendMode = .dryRun
        try VLMStore.save(ai, to: dir.appendingPathComponent("vlm.json"))
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
            languageSettings: LanguageSettings(storage: InMemoryLanguageStorage()),
            monitorHistoryURL: dir.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: AnalyticsModelDiscovery(
                modelURL: { _ in nil },
                integrity: { _ in (hash: "synthetic", sizeBytes: 0) }
            )
        )
        addTeardownBlock { Task { @MainActor in model.shutdown() } }
        return (model, cam.id)
    }

    func testMemoryClearRebuildCloseDescriptionJobsAndIdentityMutationsThroughBroker() async throws {
        let previous = await MainActor.run { IsolatedWallFixtureSupport.modelPreferences() }
        defer { ModelSelectionRegistry.update(previous) }
        let dir = try tempDir()
        let (model, camID) = try await makeIsolatedModel(dir: dir)

        // Seed 1 sampled memory frame
        try await MainActor.run {
            _ = try model.cameraMemoryStore.save(
                Data([0xFF, 0xD8, 0xFF, 0xD9]),
                cameraID: camID,
                cameraName: "Gate",
                capturedAt: Date(),
                summary: "Gate sample"
            )
        }

        // Seed 2 identities in gallery & SQLite
        let idA = "ID-A-\(UUID().uuidString.prefix(4))"
        let idB = "ID-B-\(UUID().uuidString.prefix(4))"
        try await MainActor.run {
            let store = try XCTUnwrap(model.actaTrackingStore)
            let pA = ACTAIdentityGalleryProfile(
                identityID: idA, kind: "person", displayCode: "P-01",
                centroid: [1, 0, 0], firstSeenAt: Date(), lastSeenAt: Date(),
                lastCameraID: camID.uuidString, memberTrackKeys: ["track-1", "track-2"]
            )
            let pB = ACTAIdentityGalleryProfile(
                identityID: idB, kind: "person", displayCode: "P-02",
                centroid: [0, 1, 0], firstSeenAt: Date(), lastSeenAt: Date(),
                lastCameraID: camID.uuidString, memberTrackKeys: ["track-3"]
            )
            try store.upsertACTAIdentityProfile(pA)
            try store.upsertACTAIdentityProfile(pB)
            model.actaAnalytics?.identityResolver.upsertGallery(pA)
            model.actaAnalytics?.identityResolver.upsertGallery(pB)
        }

        let spokenText = ThreadSafeBox<String?>(nil)
        let actions: [any ACTAActionProtocol] = await MainActor.run {
            let jobService = ACTADescriptionJobService(backend: ACTAWallDescriptionJobBackend(coordinator: model.actaFeatureCoordinator))
            return [
                ACTACameraMemoryClearAction(backend: ACTAWallCameraMemoryClearBackend(model: model)),
                ACTAMemoryCloseChapterAction(model: model),
                ACTAMemoryRebuildKnowledgeAction(model: model),
                ACTAInspectDescriptionJobsAction(service: jobService),
                ACTARetryDescriptionJobAction(service: jobService),
                ACTAIdentityGalleryMutationAction(kind: .rename, model: model),
                ACTAIdentityGalleryMutationAction(kind: .merge, model: model),
                ACTAIdentityGalleryMutationAction(kind: .split, model: model),
                ACTAChatThreadAction(mode: .create, model: model),
                ACTAChatThreadAction(mode: .select, model: model),
                ACTAChatThreadAction(mode: .cancel, model: model),
                ACTAVoiceControlAction(mode: .speakText, model: model, speakHook: { text, _ in spokenText.set(text) }),
                ACTAVoiceControlAction(mode: .stopSpeaking, model: model, stopSpeakHook: {})
            ]
        }
        let ids = Set(actions.map(\.id))
        let madeHost = await ACTALocalActionBroker.make(actions: actions, allowedActionIDs: ids, audit: { _ in })
        let host = try XCTUnwrap(madeHost)
        let opened = await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "t-wave1d", actionIDs: ids
        )
        let session = try XCTUnwrap(opened)

        func approve(_ actionID: String, args: String) async throws -> ACTAActionResult {
            let pending = await host.broker.request(session: session, actionID: actionID, argumentsJSON: args)
            XCTAssertTrue(pending.requiresOperatorConfirmation, "\(actionID): \(pending.error ?? pending.summary)")
            let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
            let review = try XCTUnwrap(reviews.last { $0.actionID == actionID })
            return await host.broker.resolve(operatorKey: host.operatorKey, session: session, reviewed: review, approved: true)
        }

        // 1. Inspect description jobs (read-only)
        let jobsRes = await host.broker.request(session: session, actionID: "description_jobs.inspect", argumentsJSON: "{}")
        XCTAssertTrue(jobsRes.success, jobsRes.error ?? "")

        // 2. Clear sampled memory frames
        let clearMemRes = try await approve("memory.clear_all_frames", args: "{}")
        XCTAssertTrue(clearMemRes.success, clearMemRes.error ?? "")
        XCTAssertTrue(clearMemRes.verified)
        let remainingFrames = try await MainActor.run { try model.cameraMemoryStore.inspect().count }
        XCTAssertEqual(remainingFrames, 0)

        // 3. Close chapter + rebuild knowledge
        let closeRes = try await approve("memory.close_chapter_now", args: #"{"camera_id":"\#(camID.uuidString)"}"#)
        XCTAssertTrue(closeRes.success, closeRes.error ?? "")
        let rebuildRes = try await approve("memory.rebuild_knowledge", args: "{}")
        XCTAssertTrue(rebuildRes.success, rebuildRes.error ?? "")

        // 4. Identity rename -> merge -> split
        let renameRes = try await approve("identity.rename", args: #"{"identity_id":"\#(idA)","new_name":"Security Lead"}"#)
        XCTAssertTrue(renameRes.success, renameRes.error ?? "")
        let mergeRes = try await approve("identity.merge", args: #"{"source_id":"\#(idB)","target_id":"\#(idA)"}"#)
        XCTAssertTrue(mergeRes.success, mergeRes.error ?? "")
        let splitRes = try await approve("identity.split", args: #"{"identity_id":"\#(idA)","track_id":"track-3"}"#)
        XCTAssertTrue(splitRes.success, splitRes.error ?? "")

        // 5. Chat thread create/select/cancel
        let newThreadRes = try await approve("chat.new_thread", args: "{}")
        XCTAssertTrue(newThreadRes.success, newThreadRes.error ?? "")
        let selectRes = try await approve("chat.select_thread", args: #"{"thread_id":"default"}"#)
        XCTAssertTrue(selectRes.success, selectRes.error ?? "")
        let cancelRes = try await approve("chat.cancel_request", args: "{}")
        XCTAssertTrue(cancelRes.success, cancelRes.error ?? "")

        // 6. Local voice speak/stop
        let speakRes = try await approve("voice.speak_text", args: #"{"text":"Status checked","language":"en-US"}"#)
        XCTAssertTrue(speakRes.success, speakRes.error ?? "")
        XCTAssertEqual(spokenText.value, "Status checked")
        let stopSpeakRes = try await approve("voice.stop_speaking", args: "{}")
        XCTAssertTrue(stopSpeakRes.success, stopSpeakRes.error ?? "")
    }
}
