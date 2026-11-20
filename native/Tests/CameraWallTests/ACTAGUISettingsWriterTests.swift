import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAGUISettingsWriterTests: XCTestCase {
    private func fixture() throws -> (URL, WallConfiguration) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-settings-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("cameras.json")
        var config = WallConfiguration()
        config.cameras = [Camera(name: "Fixture", substream: "", enabled: false, localDeviceID: "synthetic")]
        try ConfigurationStore.save(config, to: url)
        return (url, config)
    }

    func testSettingsPreserveCamerasPortsAndPublishBeforeEffects() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let gate = ACTACameraWriterGate()
        let writer = ACTAGUISettingsWriter(gate: gate)
        var draft = original
        draft.columns = 7
        draft.detectionThreshold = 0.6
        draft.detectionFPS = 4
        draft.apiPort = 22001
        draft.rtspPort = 22002
        var effects = 0
        try writer.save(draft, includingPorts: false, to: url, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { previous, saved in
            effects += 1
            XCTAssertEqual(previous, original)
            XCTAssertEqual(memory, saved)
            XCTAssertEqual(try ConfigurationStore.load(from: url), saved)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
            XCTAssertThrowsError(try gate.write {})
        })
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(memory.cameras, original.cameras)
        XCTAssertEqual(memory.apiPort, original.apiPort)
        XCTAssertEqual(memory.rtspPort, original.rtspPort)
        XCTAssertEqual(memory.columns, 7)
        XCTAssertEqual(memory.detectionThreshold, 0.6)
        XCTAssertEqual(memory.detectionFPS, 4)
        try writer.save(draft, includingPorts: true, to: url, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { _, _ in effects += 1 })
        XCTAssertEqual(memory.apiPort, 22001)
        XCTAssertEqual(memory.rtspPort, 22002)
        XCTAssertEqual(memory.cameras, original.cameras)
        XCTAssertEqual(effects, 2)
    }

    func testMissingInitialConfigurationAllowsDetectedRelayPath() throws {
        let (url, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        var memory = WallConfiguration()
        memory.go2rtcPath = "/synthetic/bundled-relay"
        var draft = memory
        draft.columns = 6
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        try writer.save(draft, includingPorts: false, to: url, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { _, _ in })
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertEqual(memory.columns, 6)
        XCTAssertEqual(memory.go2rtcPath, "/synthetic/bundled-relay")
    }

    func testStaleAndUnknownFieldsAreRejectedWithoutEffects() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        var external = original
        external.columns = 5
        try ConfigurationStore.save(external, to: url)
        var effects = 0
        XCTAssertThrowsError(try writer.save(original, includingPorts: true, to: url,
            readMemory: { memory }, installMemory: { memory = $0 }, afterCommit: { _, _ in effects += 1 }))
        XCTAssertEqual(try ConfigurationStore.load(from: url), external)
        memory = external
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["futureField"] = true
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: url)
        XCTAssertThrowsError(try writer.save(original, includingPorts: true, to: url,
            readMemory: { memory }, installMemory: { memory = $0 }, afterCommit: { _, _ in effects += 1 }))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(memory, external)
        XCTAssertEqual(effects, 0)
    }

    func testInvalidSettingsDoNotWriteOrPoisonLaterRetry() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let before = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var draft = original
        draft.detectionFPS = 1.5
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        XCTAssertThrowsError(try writer.save(draft, includingPorts: false, to: url,
            readMemory: { memory }, installMemory: { memory = $0 },
            afterCommit: { _, _ in XCTFail("Invalid settings must have no effects") }))
        XCTAssertTrue(try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(before))
        draft.detectionFPS = 3
        try writer.save(draft, includingPorts: false, to: url, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { _, _ in })
        XCTAssertEqual(memory.detectionFPS, 3)
    }

    func testCASRejectsLateLegacyWriteAndCanRetryAfterReload() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        var external = original
        external.columns = 5
        var reads = 0
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        XCTAssertThrowsError(try writer.save(original, includingPorts: false, to: url, readMemory: {
            reads += 1
            if reads == 2 {
                do { try ConfigurationStore.save(external, to: url) }
                catch { XCTFail("Could not simulate external save: \(error)") }
            }
            return memory
        }, installMemory: { memory = $0 }, afterCommit: { _, _ in XCTFail("Stale save has no effects") })) {
            guard case ACTAGUISettingsWriter.Failure.stale = $0 else { return XCTFail("Expected stale CAS") }
        }
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), external)
        memory = external
        var draft = memory
        draft.columns = 6
        try writer.save(draft, includingPorts: false, to: url, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { _, _ in })
        XCTAssertEqual(memory.columns, 6)
    }

    func testUnknownPublicationOutcomeBlocksSharedWritersUntilStoppedReload() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        var draft = original
        draft.columns = 8
        let gate = ACTACameraWriterGate()
        let writer = ACTAGUISettingsWriter(gate: gate)
        let preferences = ACTAGUICameraPreferenceWriter(gate: gate)
        let domain = ACTACoordinatedCameraDomain(url: url, gate: gate, readMemory: { memory },
                                                 installMemory: { memory = $0 })
        XCTAssertThrowsError(try writer.save(draft, includingPorts: false, to: url,
            readMemory: { memory }, installMemory: { _ in throw CocoaError(.fileWriteUnknown) },
            afterCommit: { _, _ in XCTFail("Unpublished settings have no effects") }))
        XCTAssertThrowsError(try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        }) {
            guard case ACTACameraWriterGate.GateError.reconciliationRequired = $0 else {
                return XCTFail("Expected shared gate to require reconciliation")
            }
        }
        XCTAssertThrowsError(try gate.write {})
        try domain.reloadIfStopped()
        XCTAssertEqual(memory.columns, 8)
        XCTAssertTrue(try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
    }

    func testReplaceConfigurationPublishesAllFieldsBeforeEffectsUnderLease() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        var replacement = original
        replacement.columns = 7
        replacement.apiPort = 22001
        replacement.cameras = [Camera(name: "Replacement", substream: "", enabled: false,
                                      localDeviceID: "synthetic-replacement")]
        let gate = ACTACameraWriterGate()
        let writer = ACTAGUISettingsWriter(gate: gate)
        var effects = 0
        try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
            installMemory: { memory = $0 }, afterCommit: { previous, saved in
                effects += 1
                XCTAssertEqual(previous, original)
                XCTAssertEqual(saved, replacement)
                XCTAssertEqual(memory, saved)
                XCTAssertEqual(try ConfigurationStore.load(from: url), saved)
                XCTAssertThrowsError(try gate.write {})
                XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
            })
        XCTAssertEqual(effects, 1)
        XCTAssertEqual(memory, replacement)
        XCTAssertEqual(try ConfigurationStore.load(from: url), replacement)
    }

    func testReplaceConfigurationRejectsStaleAndUnknownFieldsWithoutEffects() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        var replacement = original
        replacement.columns = 7
        var external = original
        external.columns = 5
        try ConfigurationStore.save(external, to: url)
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        var installs = 0
        var effects = 0
        XCTAssertThrowsError(try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
            installMemory: { installs += 1; memory = $0 }, afterCommit: { _, _ in effects += 1 })) {
                guard case ACTAGUISettingsWriter.Failure.stale = $0 else { return XCTFail("Expected stale") }
            }
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), external)
        memory = external
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["futureField"] = true
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: url)
        XCTAssertThrowsError(try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
            installMemory: { installs += 1; memory = $0 }, afterCommit: { _, _ in effects += 1 }))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(memory, external)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(effects, 0)
    }

    func testReplaceConfigurationRejectsLateWriteWithoutEffects() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = original
        var external = original
        external.columns = 5
        var replacement = original
        replacement.columns = 7
        var reads = 0
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        XCTAssertThrowsError(try writer.replaceConfiguration(replacement, to: url, readMemory: {
            reads += 1
            if reads == 2 {
                do { try ConfigurationStore.save(external, to: url) }
                catch { XCTFail("Could not simulate external save: \(error)") }
            }
            return memory
        }, installMemory: { _ in XCTFail("Stale replacement must not publish") },
           afterCommit: { _, _ in XCTFail("Stale replacement must not have effects") })) {
            guard case ACTAGUISettingsWriter.Failure.stale = $0 else { return XCTFail("Expected stale CAS") }
        }
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), external)
    }

    func testReplaceConfigurationUnknownPublicationBlocksSharedGateUntilReload() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        var replacement = original
        replacement.columns = 8
        let gate = ACTACameraWriterGate()
        let writer = ACTAGUISettingsWriter(gate: gate)
        let preferences = ACTAGUICameraPreferenceWriter(gate: gate)
        let domain = ACTACoordinatedCameraDomain(url: url, gate: gate, readMemory: { memory },
                                                 installMemory: { memory = $0 })
        var effects = 0
        XCTAssertThrowsError(try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
            installMemory: { _ in throw CocoaError(.fileWriteUnknown) },
            afterCommit: { _, _ in effects += 1 })) {
                guard case ACTAGUISettingsWriter.Failure.reconciliationRequired = $0 else {
                    return XCTFail("Expected reconciliation")
                }
            }
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), replacement)
        XCTAssertThrowsError(try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        }) {
            guard case ACTACameraWriterGate.GateError.reconciliationRequired = $0 else {
                return XCTFail("Expected shared gate to require reconciliation")
            }
        }
        try domain.reloadIfStopped()
        XCTAssertEqual(memory, replacement)
        XCTAssertTrue(try preferences.update(url: url, readMemory: { memory }, installMemory: { memory = $0 }) {
            $0.cameras[0].yoloEnabled = true
        })
    }

    func testReplaceConfigurationBlockedByRuntimeLeaseWithoutEffects() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let memory = original
        var replacement = original
        replacement.columns = 8
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        let lease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
                installMemory: { _ in XCTFail("Blocked replacement must not publish") },
                afterCommit: { _, _ in XCTFail("Blocked replacement must not have effects") }))
            XCTAssertEqual(memory, original)
            XCTAssertEqual(try ConfigurationStore.load(from: url), original)
        }
    }

    func testReplaceConfigurationRejectsInvalidReplacementAndAllowsRetry() throws {
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var memory = original
        let before = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        var replacement = original
        replacement.detectionFPS = 1.5
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        XCTAssertThrowsError(try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
            installMemory: { _ in XCTFail("Invalid replacement must not publish") },
            afterCommit: { _, _ in XCTFail("Invalid replacement must not have effects") }))
        XCTAssertTrue(try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(before))
        XCTAssertEqual(memory, original)
        replacement.detectionFPS = 3
        try writer.replaceConfiguration(replacement, to: url, readMemory: { memory },
                                        installMemory: { memory = $0 }, afterCommit: { _, _ in })
        XCTAssertEqual(memory, replacement)
    }

    func testOtherProcessRuntimeBlocksSaveBeforePublication() throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_BOOKMARK_LEASE_DRIVER"] else {
            throw XCTSkip("Set CAMERA_BOOKMARK_LEASE_DRIVER to the synthetic lease driver.")
        }
        let (url, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let child = Process()
        let input = Pipe()
        let ready = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = [url.path]
        child.standardInput = input
        child.standardOutput = ready
        try child.run()
        defer { try? input.fileHandleForWriting.close(); if child.isRunning { child.waitUntilExit() } }
        XCTAssertEqual(ready.fileHandleForReading.readData(ofLength: 1), Data([1]))
        var memory = original
        var draft = original
        draft.columns = 8
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        XCTAssertThrowsError(try writer.save(draft, includingPorts: true, to: url,
            readMemory: { memory }, installMemory: { memory = $0 },
            afterCommit: { _, _ in XCTFail("Conflicting runtime must prevent effects") })) {
                guard case ConfigurationError.invalid = $0 else { return XCTFail("Expected conflict error") }
            }
        XCTAssertEqual(memory, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), original)
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        try writer.save(draft, includingPorts: true, to: url, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { _, _ in })
        XCTAssertEqual(memory.columns, 8)
    }
}
