@testable import CameraCore
@testable import CameraWall
import CoreGraphics
import Foundation
import SQLite3
import XCTest

#if DEBUG
private actor NarrativeTestGate {
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor NarrativePermitGate {
    private(set) var count = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var ready: CheckedContinuation<Void, Never>?

    func enter() async {
        count += 1
        if count >= 2 { ready?.resume(); ready = nil }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitForTwo() async {
        if count < 2 { await withCheckedContinuation { ready = $0 } }
    }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor NarrativeSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
    func wait() async { if !signalled { await withCheckedContinuation { waiter = $0 } } }
}

private final class AlertTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
    func now() -> TimeInterval { lock.withLock { time } }
}

private actor HybridFakeTransport {
    private let gate: NarrativeTestGate
    private let gatedHost: String?
    private var localSucceeds = false
    private(set) var hosts: [String] = []

    init(gate: NarrativeTestGate, gatedHost: String?) {
        self.gate = gate
        self.gatedHost = gatedHost
    }

    func enableLocal() { localSucceeds = true }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url!.host!
        hosts.append(host)
        if host == gatedHost { await gate.wait() }
        if host == "127.0.0.1" {
            if localSucceeds { return try await narrativeFakeTransport(request) }
            throw URLError(.cannotConnectToHost)
        }
        if host == "primary.invalid" { throw URLError(.cannotConnectToHost) }
        let result = ACTATemporalNarrativeResult(chapterTitle: "Test", summary: "Observed", events: [])
        let content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["output_text": content])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor AlertFakeTransport {
    private(set) var evaluations = 0
    private(set) var mentorCalls = 0

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let contents = messages[0]["content"] as! [[String: Any]]
        let prompt = contents[0]["text"] as! String
        let result: Data
        if prompt.contains("ACTACriticalAlertBatch") {
            evaluations += 1
            result = try JSONEncoder().encode(ACTACriticalAlertBatch(alerts: [
                ACTACriticalAlertDetection(ruleCode: "fire", category: "fire", triggered: true,
                    confidence: 0.9, title: "Fire", evidenceSummary: "Smoke")
            ]))
        } else {
            mentorCalls += 1
            result = try JSONEncoder().encode(ACTAAlertMentorBrief(
                alertID: "test", confirmedThreat: true, tacticalHeadline: "Fire", precursorSummary: "Smoke",
                escalationTrajectory: "stable", recommendedOperatorAction: "Check", confidence: 0.9))
        }
        let content = String(decoding: result, as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class NarrativeTestPolicy {
    var enabled = true
    var retain = true
}

@MainActor
final class NarrativeFlushSafetyTests: XCTestCase {
    private func fixture() throws -> (URL, LocalTrackingStore, ACTAAnalyticsCoordinator, CGImage) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".narrative-isolated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let client = narrativeFakeClient(store: store)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return (root, store, coordinator, context.makeImage()!)
    }

    func testReconcilesUncertainCommitWithoutAnotherChapter() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.narrativePostCommitTestHook = { throw CocoaError(.fileReadUnknown) }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let unverified = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(unverified)
        let written = try XCTUnwrap(store.loadACTANarrativeChapterRecords(cameraID: cameraID).first)
        let reconciled = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(reconciled?.chapterID, written.chapterID)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 1)
    }

    func testReconciliationPreservesOperatorChanges() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.narrativePostCommitTestHook = { throw CocoaError(.fileReadUnknown) }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let unverified = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(unverified)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecords(cameraID: cameraID).first)
        try store.setACTANarrativeOperatorText(chapterID: saved.chapterID, operatorText: "reviewed")
        try store.setACTANarrativePinned(chapterID: saved.chapterID, pinned: true)
        let reconciled = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(reconciled?.chapterID, saved.chapterID)
        XCTAssertEqual(reconciled?.operatorText, "reviewed")
        XCTAssertEqual(reconciled?.pinned, true)
        XCTAssertEqual(reconciled?.operatorMarked, true)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 1)
    }

    func testIncompleteJPEGIsRemovedButReplacementIsNot() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraID = UUID()
        store.narrativeJPEGWriteTestHook = { file, _, _ in
            try file.write(contentsOf: Data([1, 2]))
            throw POSIXError(.ENOSPC)
        }
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let failed = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(failed)
        let cropDir = root.appendingPathComponent("identity-crops")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cropDir.path).isEmpty)
        store.narrativeJPEGWriteTestHook = nil
        let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(retried?.frameCount, 1)

        let another = UUID()
        let replaced = root.appendingPathComponent("other-owner.jpg")
        store.narrativeJPEGWriteTestHook = { file, url, _ in
            try file.write(contentsOf: Data([3]))
            try FileManager.default.moveItem(at: url, to: replaced)
            try Data([9]).write(to: url)
            throw POSIXError(.ENOSPC)
        }
        await coordinator.offerCameraFrame(cameraID: another, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["two"], evaluateAlerts: false)
        let blocked = await coordinator.forceCloseNarrativeChapter(cameraID: another, cameraName: "test")
        XCTAssertNil(blocked)
        let files = try FileManager.default.contentsOfDirectory(at: cropDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(try files.contains { try Data(contentsOf: $0) == Data([9]) })
        XCTAssertEqual(try Data(contentsOf: replaced), Data([3]))
    }

    func testRetentionRevokedAfterFailedInsertDoesNotRewriteOrphan() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("tracking.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_narrative BEFORE INSERT ON ghost_narrative_chapters BEGIN SELECT RAISE(FAIL, 'test'); END", nil, nil, nil), SQLITE_OK)
        let current = NarrativeTestPolicy()
        let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let failed = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertNil(failed)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        let cropDir = root.appendingPathComponent("identity-crops")
        let orphan = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cropDir, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: orphan)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fail_narrative", nil, nil, nil), SQLITE_OK)
        current.retain = false
        let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertNotNil(saved)
        XCTAssertNil(saved?.collagePath)
        XCTAssertEqual(try Data(contentsOf: orphan), original)
    }

    func testUnreadableCommittedRowIsNotTreatedAsAbsent() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.narrativePostCommitTestHook = { throw CocoaError(.fileReadUnknown) }
        let current = NarrativeTestPolicy()
        let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let first = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertNil(first)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecords(cameraID: cameraID).first)
        let jpeg = try XCTUnwrap(store.actaNarrativeCollageData(for: saved))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("tracking.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE ghost_narrative_chapters SET chapter_json = 'invalid' WHERE chapter_id = '\(saved.chapterID)'", nil, nil, nil), SQLITE_OK)
        current.retain = false
        let retry = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertNil(retry)
        XCTAssertTrue(try store.actaNarrativeChapterExists(chapterID: saved.chapterID))
        XCTAssertEqual(store.actaNarrativeCollageData(for: saved), jpeg)
    }

    func testRetryAfterPrivacyChangesUsesCurrentPolicy() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraID = UUID()
        let current = NarrativeTestPolicy()
        let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
        let gate = NarrativeTestGate()
        coordinator.narrativeAfterGenerationTestHook = { await gate.wait() }
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let first = Task {
            await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        }
        await gate.waitUntilStarted()
        current.enabled = false
        await gate.release()
        let denied = await first.value
        XCTAssertNil(denied)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        current.enabled = true
        current.retain = false
        let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertEqual(retried?.frameCount, 1)
        XCTAssertNil(retried?.collagePath)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 1)
    }

    func testPrivacyIsRecheckedAfterWaitingForBackgroundPermit() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativePermitGate()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { request in
                await gate.enter()
                return try await narrativeFakeTransport(request)
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        func occupy() -> Task<ACTATemporalNarrativeResult, Never> {
            Task {
                await client.generateStructured(lane: .background, tier: .mini, prompt: "test",
                    useContentCache: false, responseType: ACTATemporalNarrativeResult.self,
                    fallbackFactory: { ACTATemporalNarrativeResult(chapterTitle: "fallback", summary: "") })
            }
        }
        let one = occupy()
        let two = occupy()
        await gate.waitForTwo()
        let queued = NarrativeSignal()
        await client.setBackgroundLaneTestWaitHook { Task { await queued.signal() } }
        let current = NarrativeTestPolicy()
        let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let attempt = Task {
            await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        }
        await queued.wait()
        current.enabled = false
        await gate.release()
        _ = await one.value
        _ = await two.value
        let denied = await attempt.value
        XCTAssertNil(denied)
        let sent = await gate.count
        XCTAssertEqual(sent, 2)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        current.enabled = true
        let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertEqual(retried?.frameCount, 1)
        let total = await gate.count
        XCTAssertEqual(total, 3)
    }

    func testQueuedNarrativeRejectsChangedAIConfiguration() async throws {
        for scenario in 0..<3 {
            let (root, store, _, image) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = NarrativePermitGate()
            let initial = ACTAAIConfiguration(mode: .localVLLM, allowExternalAI: true)
            let client = ACTAAIClient(config: initial, cacheStore: store, transport: { request in
                await gate.enter()
                return try await narrativeFakeTransport(request)
            })
            let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
            func occupy() -> Task<ACTATemporalNarrativeResult, Never> {
                Task {
                    await client.generateStructured(lane: .background, tier: .mini, prompt: "test",
                        useContentCache: false, responseType: ACTATemporalNarrativeResult.self,
                        fallbackFactory: { ACTATemporalNarrativeResult(chapterTitle: "fallback", summary: "") })
                }
            }
            let one = occupy()
            let two = occupy()
            await gate.waitForTwo()
            let queued = NarrativeSignal()
            await client.setBackgroundLaneTestWaitHook { Task { await queued.signal() } }
            let cameraID = UUID()
            await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
            let attempt = Task { await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test") }
            await queued.wait()
            var changed = initial
            if scenario == 0 { changed.allowExternalAI = false }
            else { changed.mode = .mlxInProcess }
            client.updateConfiguration(changed)
            if scenario == 2 { client.updateConfiguration(initial) }
            await gate.release()
            _ = await one.value
            _ = await two.value
            let rejected = await attempt.value
            XCTAssertNil(rejected)
            let sent = await gate.count
            XCTAssertEqual(sent, 2)
            XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
            client.updateConfiguration(initial)
            let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
            XCTAssertEqual(retried?.frameCount, 1)
            let total = await gate.count
            XCTAssertEqual(total, 3)
        }
    }

    func testHybridRechecksPrivacyAndConfigurationBetweenBackends() async throws {
        for scenario in 0..<4 {
            let (root, store, _, image) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = NarrativeTestGate()
            let target = scenario < 2 ? "127.0.0.1" : "primary.invalid"
            let transport = HybridFakeTransport(gate: gate, gatedHost: target)
            let initial = ACTAAIConfiguration(mode: .hybridAuto,
                openAIBaseURL: "https://primary.invalid/responses",
                backupRelayURL: "https://backup.invalid/responses",
                privacyBlurFacesInCloud: false, privacyBlurPlatesInCloud: false, allowExternalAI: true)
            let client = ACTAAIClient(config: initial, cacheStore: store,
                transport: { try await transport.send($0) }, keyProvider: { _ in "fake-key" })
            let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
            let current = NarrativeTestPolicy()
            let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
            let cameraID = UUID()
            await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
            let attempt = Task {
                await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
            }
            await gate.waitUntilStarted()
            if scenario.isMultiple(of: 2) {
                current.enabled = false
            } else {
                var changed = initial
                changed.vllmModelName = "changed"
                client.updateConfiguration(changed)
            }
            await gate.release()
            let denied = await attempt.value
            XCTAssertNil(denied)
            let hosts = await transport.hosts
            XCTAssertEqual(hosts, scenario < 2 ? ["127.0.0.1"] : ["127.0.0.1", "primary.invalid"])
            XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)

            current.enabled = true
            client.updateConfiguration(initial)
            await transport.enableLocal()
            let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
            XCTAssertEqual(saved?.frameCount, 1)
        }
    }

    func testHybridFailoverStillWorksWhenAuthorized() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativeTestGate()
        let transport = HybridFakeTransport(gate: gate, gatedHost: nil)
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .hybridAuto,
            openAIBaseURL: "https://primary.invalid/responses", backupRelayURL: "https://backup.invalid/responses",
            privacyBlurFacesInCloud: false, privacyBlurPlatesInCloud: false, allowExternalAI: true),
            cacheStore: store, transport: { try await transport.send($0) }, keyProvider: { _ in "fake-key" })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(saved?.frameCount, 1)
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["127.0.0.1", "primary.invalid", "backup.invalid"])
    }

    func testDryRunDoesNotCommitInventedNarrative() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), cacheStore: store,
                                  transport: narrativeFakeTransport)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let dryRun = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(dryRun)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        client.updateConfiguration(ACTAAIConfiguration(mode: .localVLLM))
        let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(saved?.aiSummary, "Observed")
    }

    func testReverseConcurrentDeliveryRejectsStaleAndDuplicateFrames() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativeTestGate()
        let cameraID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let older = Task {
            await gate.wait()
            return await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, activeTrackIDs: ["old"], evaluateAlerts: false,
                now: start.addingTimeInterval(10), monotonicTimestamp: 10)
        }
        await gate.waitUntilStarted()
        let later = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["later"], evaluateAlerts: false,
            now: start.addingTimeInterval(20), monotonicTimestamp: 20)
        XCTAssertEqual(later, .notAttempted)
        await gate.release()
        let skipped = await older.value
        XCTAssertEqual(skipped, .staleFrame)
        let duplicate = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["duplicate"], evaluateAlerts: false,
            now: start.addingTimeInterval(20), monotonicTimestamp: 20)
        XCTAssertEqual(duplicate, .staleFrame)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["new"], evaluateAlerts: false,
            now: start.addingTimeInterval(30), monotonicTimestamp: 30)
        let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(saved?.frameCount, 2)
        XCTAssertEqual(saved?.startedAt, start.addingTimeInterval(20))
        XCTAssertEqual(saved?.endedAt, start.addingTimeInterval(30))
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 1)
    }

    func testClockRollbackSplitsChaptersAndPreservesEventAnchorsAndQueries() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { request in
                let result = ACTATemporalNarrativeResult(chapterTitle: "Test", summary: "Observed", events: [
                    ACTANarrativeEventItem(frameBadgeIndex: 2, timestampOffsetSec: 10,
                                           headline: "Event", detail: "Second frame")
                ])
                let content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let cameraID = UUID()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        let first = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["same"], evaluateAlerts: false,
            now: wall.addingTimeInterval(100), monotonicTimestamp: 100)
        XCTAssertEqual(first, .notAttempted)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["same"], evaluateAlerts: false,
            now: wall.addingTimeInterval(110), monotonicTimestamp: 110)
        let afterRollback = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["same"], evaluateAlerts: false,
            now: wall.addingTimeInterval(-20), monotonicTimestamp: 120)
        XCTAssertEqual(afterRollback, .saved)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["same"], evaluateAlerts: false,
            now: wall.addingTimeInterval(-10), monotonicTimestamp: 130)
        let second = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(second?.frameCount, 2)
        let saved = try store.loadACTANarrativeChapterRecords(cameraID: cameraID)
        XCTAssertEqual(saved.count, 2)
        for (start, eventAt) in [(100.0, 110.0), (-20.0, -10.0)] {
            let at = wall.addingTimeInterval(eventAt)
            let records = try store.loadACTANarrativeChapterRecords(cameraID: cameraID, since: at, until: at)
            let chapter = try XCTUnwrap(records.first)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(chapter.frameCount, 2)
            XCTAssertEqual(chapter.startedAt, wall.addingTimeInterval(start))
            let event = try XCTUnwrap(chapter.narrative.events.first)
            XCTAssertEqual(event.frameBadgeIndex, 2)
            XCTAssertEqual(chapter.startedAt.addingTimeInterval(event.timestampOffsetSec), at)
        }
        let gap = wall.addingTimeInterval(40)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID, since: gap, until: gap).isEmpty)
    }

    func testRollbackBackpressurePreservesPendingAndActiveDuringUncertainCommit() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativeTestGate()
        coordinator.narrativeBeforeGenerationTestHook = { await gate.wait() }
        coordinator.narrativePostCommitTestHook = { throw CocoaError(.fileReadUnknown) }
        let cameraID = UUID()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["a"], evaluateAlerts: false,
            now: wall.addingTimeInterval(100), monotonicTimestamp: 100)
        let pending = Task { await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test") }
        await gate.waitUntilStarted()
        let active = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["b"], evaluateAlerts: false,
            now: wall.addingTimeInterval(110), monotonicTimestamp: 110)
        XCTAssertEqual(active, .notAttempted)
        let blocked = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["c"], evaluateAlerts: true,
            now: wall.addingTimeInterval(20), monotonicTimestamp: 120)
        XCTAssertEqual(blocked, .backpressure)
        XCTAssertEqual(coordinator.alertRingFrameCountForTesting(cameraID: cameraID), 1)
        await gate.release()
        let uncertain = await pending.value
        XCTAssertNil(uncertain)
        let first = try XCTUnwrap(store.loadACTANarrativeChapterRecords(cameraID: cameraID).first)
        coordinator.narrativePostCommitTestHook = nil
        let reconciledButBlocked = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["c"], evaluateAlerts: false,
            now: wall.addingTimeInterval(20), monotonicTimestamp: 120)
        XCTAssertEqual(reconciledButBlocked, .backpressure)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).map(\.chapterID), [first.chapterID])
        let replayed = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["c"], evaluateAlerts: false,
            now: wall.addingTimeInterval(20), monotonicTimestamp: 120)
        XCTAssertEqual(replayed, .saved)
        let last = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(last?.startedAt, wall.addingTimeInterval(20))
        let chapters = try store.loadACTANarrativeChapterRecords(cameraID: cameraID)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(Set(chapters.map(\.chapterID)).count, 3)
        XCTAssertEqual(chapters.map(\.frameCount), [1, 1, 1])
        XCTAssertEqual(Set(chapters.map(\.startedAt)),
                       Set([100.0, 110.0, 20.0].map { wall.addingTimeInterval($0) }))
    }

    func testRollbackStartsFreshSamplingWhilePreviousChapterIsInflight() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativeTestGate()
        coordinator.narrativeBeforeGenerationTestHook = { await gate.wait() }
        let cameraID = UUID()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, evaluateAlerts: false,
            now: wall.addingTimeInterval(100), monotonicTimestamp: 100)
        let first = Task { await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test") }
        await gate.waitUntilStarted()
        let offered = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, evaluateAlerts: false,
            now: wall.addingTimeInterval(99), monotonicTimestamp: 101)
        XCTAssertEqual(offered, .notAttempted)
        await gate.release()
        let savedFirst = await first.value
        let savedSecond = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(savedFirst?.startedAt, wall.addingTimeInterval(100))
        XCTAssertEqual(savedSecond?.startedAt, wall.addingTimeInterval(99))
        XCTAssertEqual(savedSecond?.frameCount, 1)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 2)
    }

    func testRollbackRetryRespectsRevokedPrivacy() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sends = NarrativePermitGate()
        await sends.release()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { request in
                await sends.enter()
                return try await narrativeFakeTransport(request)
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let current = NarrativeTestPolicy()
        let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
        let cameraID = UUID()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["a"], evaluateAlerts: false, narrativePrivacy: policy,
            now: wall.addingTimeInterval(100), monotonicTimestamp: 100)
        current.enabled = false
        let denied = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["b"], evaluateAlerts: false, narrativePrivacy: policy,
            now: wall.addingTimeInterval(50), monotonicTimestamp: 110)
        XCTAssertEqual(denied, .notVerified)
        let blocked = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["c"], evaluateAlerts: false, narrativePrivacy: policy,
            now: wall.addingTimeInterval(10), monotonicTimestamp: 120)
        XCTAssertEqual(blocked, .backpressure)
        let deniedSends = await sends.count
        XCTAssertEqual(deniedSends, 0)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        current.enabled = true
        let retried = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["c"], evaluateAlerts: false, narrativePrivacy: policy,
            now: wall.addingTimeInterval(10), monotonicTimestamp: 120)
        XCTAssertEqual(retried, .backpressure)
        let accepted = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["c"], evaluateAlerts: false, narrativePrivacy: policy,
            now: wall.addingTimeInterval(10), monotonicTimestamp: 120)
        XCTAssertEqual(accepted, .saved)
        let last = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertEqual(last?.frameCount, 1)
        let chapters = try store.loadACTANarrativeChapterRecords(cameraID: cameraID)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.map(\.frameCount), [1, 1, 1])
    }

    func testAlertDispatchRateLimitAndDedupUseMonotonicTimeAfterWallClockRollback() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = AlertFakeTransport()
        let clock = AlertTestClock()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { try await fake.send($0) })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        coordinator.alertMonotonicClockForTesting = { clock.now() }
        let cameraID = UUID()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<24 {
            clock.set(Double(index))
            await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: false, evaluateAlerts: true, sampleNarrative: false,
                now: index < 4 ? wall.addingTimeInterval(1000) : wall,
                monotonicTimestamp: Double(index) * 2)
        }
        let before = await fake.evaluations
        let firstMentors = await fake.mentorCalls
        XCTAssertEqual(before, 20)
        XCTAssertEqual(firstMentors, 1)
        XCTAssertEqual(coordinator.recentCriticalAlerts.count, 1)

        clock.set(64)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: false, evaluateAlerts: true, sampleNarrative: false,
            now: wall.addingTimeInterval(1), monotonicTimestamp: 48)
        let after = await fake.evaluations
        let mentors = await fake.mentorCalls
        XCTAssertEqual(after, 21)
        XCTAssertEqual(mentors, 2)
        XCTAssertEqual(coordinator.recentCriticalAlerts.count, 2)
    }

    func testStaleNarrativeFrameStillReachesAlertRing() async throws {
        let (root, _, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cameraID = UUID()
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        let first = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false,
            now: wall, monotonicTimestamp: 10)
        XCTAssertEqual(first, .notAttempted)
        let stale = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: true,
            now: wall.addingTimeInterval(2), monotonicTimestamp: 10)
        XCTAssertEqual(stale, .staleFrame)
        XCTAssertEqual(coordinator.alertRingFrameCountForTesting(cameraID: cameraID), 1)
        let saved = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(saved?.frameCount, 1)
    }

    func testOneInflightWithBoundedActiveBuffer() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativeTestGate()
        coordinator.narrativeBeforeGenerationTestHook = { await gate.wait() }
        let cameraID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["first"], evaluateAlerts: false, now: now)
        let first = Task { await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test") }
        await gate.waitUntilStarted()
        for index in 0..<ACTACameraNarrativeState.flushFrameThreshold {
            let outcome = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, activeTrackIDs: ["active-\(index)"], evaluateAlerts: false,
                now: now.addingTimeInterval(Double(index + 1)))
            XCTAssertEqual(outcome, .notAttempted)
        }
        let blocked = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["rejected"], evaluateAlerts: false,
            now: now.addingTimeInterval(40))
        XCTAssertEqual(blocked, .backpressure)
        let concurrent = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(concurrent)
        await gate.release()
        let firstRecord = await first.value
        XCTAssertEqual(firstRecord?.frameCount, 1)
        let second = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(second?.frameCount, ACTACameraNarrativeState.flushFrameThreshold)
        XCTAssertNotEqual(firstRecord?.chapterID, second?.chapterID)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 2)
    }

    func testRetryAfterCollageWriteFailureKeepsReservedFrames() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("identity-crops")
        try Data("not a directory".utf8).write(to: path)
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let failed = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(failed)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        try FileManager.default.removeItem(at: path)
        let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(retried?.frameCount, 1)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 1)
    }

    func testAutomaticFailureAndBackpressurePreserveBothBatches() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("identity-crops")
        try Data("not a directory".utf8).write(to: path)
        let cameraID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<ACTACameraNarrativeState.flushFrameThreshold {
            let outcome = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, activeTrackIDs: ["first-\(index)"], evaluateAlerts: false,
                now: start.addingTimeInterval(Double(index)))
            XCTAssertEqual(outcome, index == ACTACameraNarrativeState.flushFrameThreshold - 1 ? .notVerified : .notAttempted)
        }
        for index in 0..<ACTACameraNarrativeState.flushFrameThreshold {
            let outcome = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
                hasActiveObjects: true, activeTrackIDs: ["active-\(index)"], evaluateAlerts: false,
                now: start.addingTimeInterval(Double(index + 30)))
            XCTAssertEqual(outcome, .notVerified)
        }
        try FileManager.default.removeItem(at: path)
        let blocked = await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["rejected"], evaluateAlerts: false,
            now: start.addingTimeInterval(60))
        XCTAssertEqual(blocked, .backpressure)
        let second = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(second?.frameCount, ACTACameraNarrativeState.flushFrameThreshold)
        let saved = try store.loadACTANarrativeChapterRecords(cameraID: cameraID)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.map(\.frameCount), Array(repeating: ACTACameraNarrativeState.flushFrameThreshold, count: 2))
    }

    func testCancellationPreservesBatchForRetry() async throws {
        let (root, store, coordinator, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = NarrativeTestGate()
        coordinator.narrativeBeforeGenerationTestHook = { await gate.wait() }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let attempt = Task { await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test") }
        await gate.waitUntilStarted()
        attempt.cancel()
        await gate.release()
        let cancelled = await attempt.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(retried?.frameCount, 1)
    }

    func testModelFailurePreservesBatchForRetry() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .mlxInProcess), cacheStore: store,
                                  transport: narrativeFakeTransport)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let failed = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertNil(failed)
        XCTAssertTrue(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).isEmpty)
        client.updateConfiguration(ACTAAIConfiguration(mode: .localVLLM))
        let retried = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test")
        XCTAssertEqual(retried?.frameCount, 1)
    }

    func testPrivacyChangeDoesNotOverwriteOrDeleteUncertainCommit() async throws {
        let (root, store, _, image) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sends = NarrativePermitGate()
        await sends.release()
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
            transport: { request in
                await sends.enter()
                return try await narrativeFakeTransport(request)
            })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let current = NarrativeTestPolicy()
        let policy: @MainActor @Sendable () -> (enabled: Bool, retain: Bool) = { (current.enabled, current.retain) }
        coordinator.narrativePostCommitTestHook = { throw CocoaError(.fileReadUnknown) }
        let cameraID = UUID()
        await coordinator.offerCameraFrame(cameraID: cameraID, cameraName: "test", cgImage: image,
            hasActiveObjects: true, activeTrackIDs: ["one"], evaluateAlerts: false)
        let unverified = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertNil(unverified)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecords(cameraID: cameraID).first)
        let jpeg = try XCTUnwrap(store.actaNarrativeCollageData(for: saved))
        try store.setACTANarrativeOperatorText(chapterID: saved.chapterID, operatorText: "reviewed")
        try store.setACTANarrativePinned(chapterID: saved.chapterID, pinned: true)
        current.retain = false
        let reconciled = await coordinator.forceCloseNarrativeChapter(cameraID: cameraID, cameraName: "test", narrativePrivacy: policy)
        XCTAssertEqual(reconciled?.chapterID, saved.chapterID)
        XCTAssertEqual(reconciled?.operatorText, "reviewed")
        XCTAssertEqual(reconciled?.pinned, true)
        XCTAssertEqual(store.actaNarrativeCollageData(for: saved), jpeg)
        let sent = await sends.count
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecords(cameraID: cameraID).count, 1)
    }

    func testInsertOnlyPreservesRowsAndConflictingCollages() throws {
        let (root, store, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date(timeIntervalSince1970: 100)
        func record(_ id: String) -> ACTANarrativeChapterRecord {
            ACTANarrativeChapterRecord(chapterID: id, cameraID: UUID(), cameraName: "test",
                startedAt: time, endedAt: time,
                narrative: ACTATemporalNarrativeResult(chapterTitle: "title", summary: "summary",
                    atmosphere: "calm", events: []),
                frameCount: 1, sightingCount: 0, identityCount: 0)
        }
        let jpeg = Data([1, 2, 3])
        let chapter = record(UUID().uuidString)
        try store.insertACTANarrativeChapterRecord(chapter, collageJPEG: jpeg)
        let saved = try XCTUnwrap(store.loadACTANarrativeChapterRecord(chapterID: chapter.chapterID))
        var changed = chapter
        changed.cameraName = "changed"
        XCTAssertThrowsError(try store.insertACTANarrativeChapterRecord(changed, collageJPEG: Data([4])))
        XCTAssertEqual(try store.loadACTANarrativeChapterRecord(chapterID: chapter.chapterID), saved)
        XCTAssertEqual(store.actaNarrativeCollageData(for: saved), jpeg)

        let orphanChapter = record(UUID().uuidString)
        let orphan = root.appendingPathComponent("identity-crops")
            .appendingPathComponent("narrative_\(orphanChapter.chapterID.lowercased()).jpg")
        try Data([9]).write(to: orphan)
        XCTAssertThrowsError(try store.insertACTANarrativeChapterRecord(orphanChapter, collageJPEG: jpeg))
        XCTAssertEqual(try Data(contentsOf: orphan), Data([9]))
        XCTAssertNil(try store.loadACTANarrativeChapterRecord(chapterID: orphanChapter.chapterID))
        try jpeg.write(to: orphan)
        try store.insertACTANarrativeChapterRecord(orphanChapter, collageJPEG: jpeg)
        XCTAssertEqual(try store.loadACTANarrativeChapterRecord(chapterID: orphanChapter.chapterID)?.chapterID,
                       orphanChapter.chapterID)
    }
}
#endif
