import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTACameraEditorDraftTests: XCTestCase {
    private final class Owner {}

    func testEditorSaveUsesCapturedCASAndRejectsCrossInstanceABA() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var firstMemory = WallConfiguration()
        var secondMemory = firstMemory
        let first = ACTACoordinatedCameraDomain(url: url, readMemory: { firstMemory },
                                                installMemory: { firstMemory = $0 })
        let second = ACTACoordinatedCameraDomain(url: url, readMemory: { secondMemory },
                                                 installMemory: { secondMemory = $0 })
        let draft = try ACTACameraEditorDraft(domain: first, displayed: firstMemory)
        let other = try second.draft()
        var changed = secondMemory
        changed.columns = 5
        try second.save(changed, expected: other)
        try second.save(WallConfiguration(), expected: second.draft())
        let camera = Camera(name: "Fixture", substream: "", localDeviceID: "fixture-\(UUID())")
        XCTAssertThrowsError(try draft.saveCamera(camera, original: nil))
        XCTAssertTrue(firstMemory.cameras.isEmpty)
        XCTAssertTrue(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration.cameras.isEmpty)
        let fresh = try ACTACameraEditorDraft(domain: first, displayed: firstMemory)
        try fresh.saveCamera(camera, original: nil)
        XCTAssertEqual(firstMemory.cameras, [camera])
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, firstMemory)
    }

    func testEditorRefusesMismatchedCameraAndRuntimeAndSettingsPreserveSources() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let camera = Camera(name: "Fixture", substream: "", localDeviceID: "fixture-\(UUID())")
        var memory = WallConfiguration()
        memory.cameras = [camera]
        let initial = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(memory, expected: initial, to: url))
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        let wrong = Camera(id: camera.id, name: "Old fixture", substream: "", localDeviceID: camera.localDeviceID)
        let staleCameraDraft = try ACTACameraEditorDraft(domain: domain, displayed: memory)
        XCTAssertThrowsError(try staleCameraDraft.saveCamera(camera, original: wrong))
        let runningDraft = try ACTACameraEditorDraft(domain: domain, displayed: memory)
        try domain.beginRuntime()
        var settings = memory
        settings.columns = 7
        XCTAssertThrowsError(try runningDraft.saveSettings(settings, includePorts: true))
        try await domain.endRuntime(afterDraining: {})
        let settingsDraft = try ACTACameraEditorDraft(domain: domain, displayed: memory)
        settings.cameras = []
        settings.apiPort = 21984
        try settingsDraft.saveSettings(settings, includePorts: true)
        XCTAssertEqual(memory.cameras, [camera])
        XCTAssertEqual(memory.columns, 7)
        XCTAssertEqual(memory.apiPort, 21984)
    }

    func testUnboundOrReplacedDomainCannotUseNetworkWriter() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Owner()
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let first = ACTACoordinatedCameraDomain(url: url, readMemory: { memory }, installMemory: { memory = $0 })
        XCTAssertThrowsError(try ACTACameraEditorDraftRegistry.open(owner: owner, displayed: memory))
        ACTACameraEditorDraftRegistry.install(owner: owner, domain: first)
        let draft = try ACTACameraEditorDraftRegistry.open(owner: owner, displayed: memory)
        let second = ACTACoordinatedCameraDomain(url: url, readMemory: { memory }, installMemory: { memory = $0 })
        var called = false
        ACTACameraEditorDraftRegistry.install(owner: owner, domain: second, networkSave: { _, _, _, _, _, _ in
            called = true
        })
        do {
            try await ACTACameraEditorDraftRegistry.saveNetwork(owner: owner, draft: draft, ip: "fixture",
                credentials: Credentials(username: "", password: ""),
                camera: Camera(name: "Fixture", substream: ""), original: nil, progress: { _ in })
            XCTFail("A draft from the replaced domain was accepted")
        } catch { }
        XCTAssertFalse(called)
        ACTACameraEditorDraftRegistry.remove(owner: owner)
    }

    func testRetryAfterLateBindingDoesNotRebaseEditedDraft() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Owner()
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let opening = memory
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory }, installMemory: { memory = $0 })
        XCTAssertThrowsError(try ACTACameraEditorDraftRegistry.open(owner: owner, displayed: opening))
        ACTACameraEditorDraftRegistry.install(owner: owner, domain: domain)
        let retry = try ACTACameraEditorDraftRegistry.open(owner: owner, displayed: opening)
        var changed = memory
        changed.columns = 9
        try retry.saveSettings(changed, includePorts: false)
        XCTAssertThrowsError(try ACTACameraEditorDraftRegistry.open(owner: owner, displayed: opening))
        XCTAssertEqual(memory.columns, 9)
        ACTACameraEditorDraftRegistry.remove(owner: owner)
    }

    func testEditorSurvivesItsOwnJoinedDiscoveryButNotInterveningMutation() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory }, installMemory: { memory = $0 })
        let draft = try ACTACameraEditorDraft(domain: domain, displayed: memory)
        try domain.beginRuntime()
        try await domain.endRuntime(afterDraining: {})
        let refreshed = try draft.refreshAfterRuntime()
        var edited = memory
        edited.columns = 8
        try refreshed.saveSettings(edited, includePorts: false)
        XCTAssertEqual(memory.columns, 8)
        XCTAssertThrowsError(try draft.refreshAfterRuntime())
    }
}
