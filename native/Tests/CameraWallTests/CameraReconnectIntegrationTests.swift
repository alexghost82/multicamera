import CameraCore
import CoreVideo
import Foundation
import XCTest
@testable import CameraWall

@MainActor
private final class FakeReconnectTransport {
    private(set) var names: [String] = []
    private(set) var applied: Set<String> = []
    private var pending: [String: (URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = [:]

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let name = components.queryItems!.first { $0.name == "name" }!.value!
        names.append(name)
        return try await withCheckedThrowingContinuation { pending[name] = (request, $0) }
    }

    func complete(_ name: String) {
        guard let (request, continuation) = pending.removeValue(forKey: name) else {
            XCTFail("Missing fake PATCH")
            return
        }
        applied.insert(name)
        continuation.resume(returning: (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                 httpVersion: nil, headerFields: nil)!))
    }

    func fail(_ name: String) {
        guard let (_, continuation) = pending.removeValue(forKey: name) else {
            XCTFail("Missing fake PATCH")
            return
        }
        continuation.resume(throwing: URLError(.cannotConnectToHost))
    }
}

private struct ReconnectCredentials: CameraCredentialStore {
    func read(_ id: UUID) throws -> Credentials? { nil }
    func save(_ credentials: Credentials, for id: UUID) throws { XCTFail("Unexpected credential write") }
    func remove(_ id: UUID) throws { XCTFail("Unexpected credential removal") }
}

@MainActor
private final class ReconnectLanguageStorage: LanguageSettingsStorage {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
}

@MainActor
final class CameraReconnectIntegrationTests: XCTestCase {
    private enum FixtureError: Error { case timeout }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func pixel() throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        return try XCTUnwrap(image)
    }

    private func fixture(_ transport: FakeReconnectTransport,
                         start: @escaping @MainActor (CameraSession, String) -> Void) throws -> (URL, WallModel, Camera, CameraSession) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/reconnect-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let camera = Camera(name: "Fake", substream: "rtsp://fixture.invalid/live")
        var config = WallConfiguration()
        config.cameras = [camera]
        try ConfigurationStore.save(config, to: root.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
        let relay = Go2RTC(transport: { try await transport.send($0) }, runningOverride: { true })
        let model = WallModel(configURL: root.appendingPathComponent("cameras.json"),
            poseModelURL: root.appendingPathComponent("unused.mlmodel"), relayFactory: { relay },
            trackingStoreURL: root.appendingPathComponent("tracks.sqlite"),
            featureCoordinator: CameraFeatureCoordinator(preferencesURL: root.appendingPathComponent("features.json"),
                                                         databaseURL: root.appendingPathComponent("features.sqlite")),
            analyticsDirectoryURL: root.appendingPathComponent("analytics"),
            agentClient: IsolatedWallFixtureSupport.client(),
            cameraMemoryStore: CameraMemoryStore(url: root.appendingPathComponent("frames")),
            operationsWatchURL: root.appendingPathComponent("watches.json"),
            missionStoreURL: root.appendingPathComponent("missions.json"),
            cameraCredentialStore: ReconnectCredentials(), reconnectDecoderStart: start,
            operationsPreferencesURL: root.appendingPathComponent("operations.json"),
            alertClipStore: CriticalAlertClipStore(url: root.appendingPathComponent("clips")),
            languageSettings: LanguageSettings(storage: ReconnectLanguageStorage()),
            monitorHistoryURL: root.appendingPathComponent("monitor.json"),
            analyticsModelDiscovery: IsolatedWallFixtureSupport.modelDiscovery)
        XCTAssertTrue(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
        XCTAssertFalse(model.featurePreferences.enabledFeatures.contains(.independentWatcher))
        let old = CameraSession()
        model.tiles[camera.id]?.session = old
        model.running = true
        return (root, model, camera, old)
    }

    func testLatePatchIsIsolatedAndOnlyFreshReplacementIsInstalled() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started: [CameraSession] = []
        let (root, model, camera, old) = try fixture(transport) { session, _ in started.append(session) }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        old.publish(try pixel(), message: "old")
        let first = Task { try await model.reconnectNetworkVerified(camera, timeout: .seconds(1)) }
        try await waitUntil { transport.names.count == 1 }
        let second = Task { try await model.reconnectNetworkVerified(camera, timeout: .seconds(1)) }
        try await waitUntil { transport.names.count == 2 }
        let oldName = transport.names[0], newName = transport.names[1]
        XCTAssertNotEqual(oldName, newName)
        XCTAssertNotEqual(oldName, camera.streamName(expanded: false))
        XCTAssertNotEqual(newName, camera.streamName(expanded: false))
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
        transport.complete(newName)
        try await waitUntil { started.count == 1 }
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
        started[0].publish(try pixel(), message: "fresh")
        try await second.value
        XCTAssertTrue(model.tiles[camera.id]?.session === started[0])
        XCTAssertNil(old.snapshot().pixel)
        transport.complete(oldName)
        do { try await first.value; XCTFail("Superseded reconnect succeeded") }
        catch {}
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(transport.applied.contains(oldName))
        XCTAssertTrue(transport.applied.contains(newName))
        XCTAssertTrue(model.tiles[camera.id]?.session === started[0])
    }

    func testStopDuringPatchPreventsLateDecoderAndInstallation() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started = false
        let (root, model, camera, _) = try fixture(transport) { _, _ in started = true }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = Task { try await model.reconnectNetworkVerified(camera, timeout: .seconds(1)) }
        try await waitUntil { transport.names.count == 1 }
        model.stop()
        transport.complete(transport.names[0])
        do { try await task.value; XCTFail("Stopped reconnect succeeded") }
        catch {}
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(started)
        XCTAssertNil(model.tiles[camera.id]?.session)
        XCTAssertFalse(model.running)
    }

    func testOldFrameCannotSatisfyReconnectAndTimeoutPreservesOldSession() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started = false
        let (root, model, camera, old) = try fixture(transport) { _, _ in started = true }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        old.publish(try pixel(), message: "old")
        let task = Task { try await model.reconnectNetworkVerified(camera, timeout: .milliseconds(120)) }
        try await waitUntil { transport.names.count == 1 }
        transport.complete(transport.names[0])
        try await waitUntil { started }
        do { try await task.value; XCTFail("Old frame must not verify") }
        catch { XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .timedOut) }
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
        XCTAssertNotNil(old.snapshot().pixel)
    }

    func testGUIReconnectInstallsOnlyAfterNewFrame() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started: CameraSession?
        let (root, model, camera, old) = try fixture(transport) { session, _ in started = session }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.reconnect(camera)
        try await waitUntil { transport.names.count == 1 }
        transport.complete(transport.names[0])
        try await waitUntil { started != nil }
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
        let newSession = try XCTUnwrap(started)
        newSession.publish(try pixel(), message: "fresh")
        try await waitUntil { model.tiles[camera.id]?.session === newSession }
        XCTAssertNil(old.snapshot().pixel)
    }

    func testExpansionCancelsPendingReconnectAndLatePatchCannotInstall() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started = false
        let (root, model, camera, old) = try fixture(transport) { _, _ in started = true }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = Task { try await model.reconnectNetworkVerified(camera, timeout: .seconds(1)) }
        try await waitUntil { transport.names.count == 1 }
        model.toggleExpanded(camera)
        transport.complete(transport.names[0])
        do { try await task.value; XCTFail("Expansion must supersede reconnect") }
        catch {}
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(started)
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
    }

    func testPatchFailureDoesNotReplaceOldSession() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started = false
        let (root, model, camera, old) = try fixture(transport) { _, _ in started = true }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = Task { try await model.reconnectNetworkVerified(camera, timeout: .seconds(1)) }
        try await waitUntil { transport.names.count == 1 }
        transport.fail(transport.names[0])
        do { try await task.value; XCTFail("Failed PATCH must fail reconnect") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        XCTAssertFalse(started)
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
    }

    func testTimeoutDuringPatchFencesLateResponse() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var started = false
        let (root, model, camera, old) = try fixture(transport) { _, _ in started = true }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = Task { try await model.reconnectNetworkVerified(camera, timeout: .milliseconds(100)) }
        try await waitUntil { transport.names.count == 1 }
        do { try await task.value; XCTFail("Unanswered PATCH must time out") }
        catch { XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .timedOut) }
        transport.complete(transport.names[0])
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(started)
        XCTAssertTrue(model.tiles[camera.id]?.session === old)
    }

    func testReplacedTileSessionCannotBeOverwrittenByReconnect() async throws {
        let previous = IsolatedWallFixtureSupport.modelPreferences()
        defer { ModelSelectionRegistry.update(previous) }
        let transport = FakeReconnectTransport()
        var candidate: CameraSession?
        let (root, model, camera, old) = try fixture(transport) { session, _ in candidate = session }
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let task = Task { try await model.reconnectNetworkVerified(camera, timeout: .seconds(1)) }
        try await waitUntil { transport.names.count == 1 }
        transport.complete(transport.names[0])
        try await waitUntil { candidate != nil }
        let replacement = CameraSession()
        old.stop()
        model.tiles[camera.id]?.session = replacement
        let newSession = try XCTUnwrap(candidate)
        newSession.publish(try pixel(), message: "fresh")
        do { try await task.value; XCTFail("Changed tile must reject reconnect") }
        catch { XCTAssertEqual(error as? CameraReconnectAttempt.Failure, .superseded) }
        XCTAssertTrue(model.tiles[camera.id]?.session === replacement)
        XCTAssertNil(newSession.snapshot().pixel)
    }

    func testUncertainPatchRegistrationsAreBoundedPerRelay() async {
        var calls = 0
        let relay = Go2RTC(transport: { _ in
            calls += 1
            throw URLError(.timedOut)
        })
        let camera = Camera(name: "Fake", substream: "rtsp://fixture.invalid/live")
        for _ in 0..<64 {
            do {
                _ = try await relay.registerReconnect(camera: camera, expanded: false,
                                                      attemptID: UUID(), credentials: nil)
                XCTFail("Expected fake timeout")
            } catch {}
        }
        do {
            _ = try await relay.registerReconnect(camera: camera, expanded: false,
                                                  attemptID: UUID(), credentials: nil)
            XCTFail("Relay registration limit was not enforced")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Reconnect limit"))
        }
        XCTAssertEqual(calls, 64)
    }
}
