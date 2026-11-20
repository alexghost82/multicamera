import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAGUICameraPreferenceWriterTests: XCTestCase {
    private func fixture() throws -> (URL, WallConfiguration) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-preference-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("cameras.json")
        var config = WallConfiguration()
        config.cameras = [Camera(name: "Fixture", substream: "", enabled: false,
                                 localDeviceID: "synthetic")]
        try ConfigurationStore.save(config, to: url)
        return (url, config)
    }

    func testUpdatesFlagsAndPreservesLegacyConfiguration() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = """
        {"cameras":[{"id":"\(original.cameras[0].id.uuidString.lowercased())","name":"Fixture",
        "substream":"","enabled":false,"localDeviceID":"synthetic"}],
        "columns":4.0,"staleAfterMilliseconds":1000,"go2rtcPath":"/opt/homebrew/bin/go2rtc",
        "apiPort":11984,"rtspPort":18554}
        """
        try Data(legacy.utf8).write(to: url)
        var memory = original
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
            $0.cameras[0].aiChatEnabled = false
        })
        XCTAssertTrue(memory.cameras[0].yoloEnabled)
        XCTAssertFalse(memory.cameras[0].aiChatEnabled)
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, memory)
        let revision = try CoordinatedCameraConfigurationStore.snapshot(from: url).revision
        XCTAssertFalse(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) { _ in })
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).revision, revision)
    }

    func testRuntimeLeaseAndExternalChangeRejectWithoutPublishing() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let writer = ACTAGUICameraPreferenceWriter()
        var lease: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
        XCTAssertEqual(memory, original)
        lease = nil
        var external = original
        external.columns = 6
        let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(external, expected: snapshot, to: url))
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, external)
        memory = external
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
    }

    func testOtherProcessRuntimeBlocksPreferenceUpdate() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Python is unavailable for the separate-process lease test.")
        }
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var seed: CoordinatedCameraConfigurationStore.RuntimeLease? =
            try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        XCTAssertNotNil(seed)
        let lock = url.deletingLastPathComponent().appendingPathComponent(".cameras.json.runtime-lock")
        seed = nil
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
            import fcntl, sys
            with open(sys.argv[1], 'rb') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                print('ready', flush=True)
                sys.stdin.buffer.read(1)
            """, lock.path]
        let ready = Pipe()
        let release = Pipe()
        child.standardOutput = ready
        child.standardInput = release
        try child.run()
        defer {
            try? release.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        XCTAssertEqual(ready.fileHandleForReading.availableData, Data("ready\n".utf8))
        var memory = original
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), original)
    }

    func testOwnRuntimeAllowsOnlyPreferenceUpdatesWithoutStopping() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 },
                                        runtimeLease: owner) {
            $0.cameras[0].yoloEnabled = true
            $0.cameras[0].aiChatEnabled = false
        })
        XCTAssertTrue(memory.cameras[0].yoloEnabled)
        XCTAssertFalse(memory.cameras[0].aiChatEnabled)
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 },
                                               runtimeLease: owner) { $0.cameras[0].enabled = true })
        XCTAssertFalse(memory.cameras[0].enabled)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
    }

    func testOwnRuntimeRequiresReconciliationAfterPublicationFailure() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { _ in
            throw CocoaError(.fileWriteUnknown)
        }, runtimeLease: owner) { $0.cameras[0].yoloEnabled = true })
        let committed = try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 },
                                               runtimeLease: owner) { $0.cameras[0].aiChatEnabled = false })
        memory = committed
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 },
                                        runtimeLease: owner) { $0.cameras[0].aiChatEnabled = false })
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, memory)
    }

    func testSharedGateRejectsBookmarkWriterDuringOwnerPreferenceUpdate() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let gate = ACTACameraWriterGate()
        let preferences = ACTAGUICameraPreferenceWriter(gate: gate)
        let bookmarks = ACTACameraBookmarkRefresh(gate: gate)
        let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        XCTAssertTrue(try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 },
                                             runtimeLease: owner) { next in
            XCTAssertThrowsError(try bookmarks.persist(camera: original.cameras[0],
                resolvedURL: url.deletingLastPathComponent().appendingPathComponent("fixture.mov"),
                bookmarkData: Data([1]), configURL: url, readMemory: { memory },
                installMemory: { memory = $0 })) { error in
                    guard case ACTACameraWriterGate.GateError.busy = error else {
                        return XCTFail("Expected shared gate to reject reentry, got \(error)")
                    }
                }
            next.cameras[0].yoloEnabled = true
        })
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testSharedDomainDraftIsInvalidatedByOwnerPreferenceWrite() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let gate = ACTACameraWriterGate()
        let domain = ACTACoordinatedCameraDomain(url: url, gate: gate,
                                                 readMemory: { memory }, installMemory: { memory = $0 })
        let draft = try domain.draft()
        let preferences = ACTAGUICameraPreferenceWriter(gate: gate)
        let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        XCTAssertTrue(try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 },
                                             runtimeLease: owner) { next in
            XCTAssertThrowsError(try domain.draft()) { error in
                guard case ACTACameraWriterGate.GateError.busy = error else {
                    return XCTFail("Expected shared gate to reject reentry, got \(error)")
                }
            }
            next.cameras[0].yoloEnabled = true
        })
        XCTAssertThrowsError(try domain.save(original, expected: draft)) { error in
            guard case ACTACameraWriterGate.GateError.stale = error else {
                return XCTFail("Expected old domain draft to be stale, got \(error)")
            }
        }
        XCTAssertEqual(try domain.draft().configuration, memory)
    }

    func testConcurrentCoordinatedWriterCannotEnterPreferenceTransaction() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) { next in
            let first = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            var other = original
            other.columns = 6
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(other, expected: first, to: url))
            next.cameras[0].yoloEnabled = true
        })
        XCTAssertTrue(memory.cameras[0].yoloEnabled)
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, memory)
    }

    func testPublicationFailureRequiresReconciliationBeforeRetry() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { _ in
            throw ACTAGUICameraPreferenceWriter.Failure.stale
        }) { $0.cameras[0].yoloEnabled = true })
        let committed = try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration
        XCTAssertTrue(committed.cameras[0].yoloEnabled)
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].aiChatEnabled = false
        }) { error in
            guard case ACTAGUICameraPreferenceWriter.Failure.reconciliationRequired = error else {
                return XCTFail("Expected reconciliation error, got \(error)")
            }
        }
        XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, committed)
        memory = committed
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].aiChatEnabled = false
        })
    }

    func testUnknownFieldsAndReentrantWriteFailClosed() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["future"] = true
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try bytes.write(to: url)
        var memory = original
        let writer = ACTAGUICameraPreferenceWriter()
        XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(memory, original)

        try ConfigurationStore.save(original, to: url)
        XCTAssertTrue(try writer.update(url: url, readMemory: { memory }, installMemory: { value in
            XCTAssertThrowsError(try writer.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
                $0.cameras[0].aiChatEnabled = false
            })
            memory = value
        }) { $0.cameras[0].yoloEnabled = true })
        XCTAssertTrue(memory.cameras[0].yoloEnabled)
        XCTAssertTrue(memory.cameras[0].aiChatEnabled)
    }
}
