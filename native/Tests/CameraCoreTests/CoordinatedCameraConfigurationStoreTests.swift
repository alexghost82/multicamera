import Foundation
import Darwin
import XCTest
@testable import CameraCore

final class CoordinatedCameraConfigurationStoreTests: XCTestCase {
    func testCheckedConfigurationRejectsDeletedPreviouslySavedDefault() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            XCTAssertEqual(try CoordinatedCameraConfigurationStore.checkedConfiguration(
                matching: WallConfiguration(), from: url), WallConfiguration())
            _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(
                WallConfiguration(), expected: empty, to: url))
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.checkedConfiguration(
                matching: WallConfiguration(), from: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".camera-cas-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testCompareAndSaveRejectsABAAndWrongStore() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let first = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            var edited = first.configuration
            edited.columns = 5
            let second = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(edited, expected: first, to: url))
            let third = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(first.configuration, expected: second, to: url))
            XCTAssertNotEqual(first.revision, third.revision)
            XCTAssertNil(try CoordinatedCameraConfigurationStore.compareAndSave(edited, expected: first, to: url))
            XCTAssertNil(try CoordinatedCameraConfigurationStore.compareAndSave(edited, expected: third,
                to: directory.appendingPathComponent("other.json")))
            XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, first.configuration)
        }
    }

    func testRejectsUnknownFieldsWithoutRewriting() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let original = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(original.configuration, expected: original, to: url))
            let encoded = try Data(contentsOf: url)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            json["future_field"] = ["keep": true]
            let unknown = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
            try unknown.write(to: url)
            let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(snapshot.configuration, expected: snapshot, to: url))
            XCTAssertEqual(try Data(contentsOf: url), unknown)
        }
    }

    func testSemanticRoundTripHandlesFormattingAndLegacyWithoutDroppingFields() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let id = UUID()
            let legacy = """
            {
              "cameras": [{"id":"\(id.uuidString.lowercased())","name":"Fixture","substream":"",
                           "localDeviceID":"synthetic","location":null,"mainstream":null,
                           "enabled":false}],
              "columns":4.0e0,"staleAfterMilliseconds":1000,
              "go2rtcPath":"\\/synthetic\\/relay","apiPort":11984,"rtspPort":18554
            }
            """
            let bytes = Data(legacy.utf8)
            try bytes.write(to: url)
            let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            XCTAssertTrue(try snapshot.isSemanticallyRoundTrippable())
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            var replacement = snapshot.configuration
            replacement.columns = 5
            let saved = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(replacement, expected: snapshot, to: url))
            XCTAssertEqual(saved.configuration, replacement)
            XCTAssertNil(try CoordinatedCameraConfigurationStore.compareAndSave(replacement, expected: snapshot, to: url))
        }
    }

    func testSemanticRoundTripRejectsDuplicatesUnknownAndNumericPrecisionLoss() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let id = UUID()
            let base = """
            {"cameras":[{"id":"\(id.uuidString)","name":"Fixture","substream":"",
                         "localDeviceID":"synthetic","enabled":falseCAMERA_EXTRA}],
             "columns":4ROOT_EXTRA,"staleAfterMilliseconds":1000,"go2rtcPath":"/synthetic/relay",
             "apiPort":11984,"rtspPort":18554,"detectionThreshold":THRESHOLD}
            """
            let cases: [(String, String, String, Bool)] = [
                (",\"future\":null", "", "0.35", false),
                ("", ",\"future\":{\"preserve\":true}", "0.35", false),
                ("", ",\"col\\u0075mns\":4", "0.35", true),
                (",\"name\":\"Fixture\"", "", "0.35", true),
                ("", "", "0.35000000000000001", false)
            ]
            for (cameraExtra, rootExtra, threshold, decoderMayReject) in cases {
                let text = base.replacingOccurrences(of: "CAMERA_EXTRA", with: cameraExtra)
                    .replacingOccurrences(of: "ROOT_EXTRA", with: rootExtra)
                    .replacingOccurrences(of: "THRESHOLD", with: threshold)
                let bytes = Data(text.utf8)
                try bytes.write(to: url)
                do {
                    let snapshot = try CoordinatedCameraConfigurationStore.snapshot(from: url)
                    XCTAssertFalse(try snapshot.isSemanticallyRoundTrippable(), text)
                    XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(
                        snapshot.configuration, expected: snapshot, to: url), text)
                } catch {
                    if !decoderMayReject { XCTFail("Unexpected decode error: \(error)") }
                }
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testSemanticComparisonRejectsAmbiguousStringsAndNumbers() {
        func matches(_ original: String, _ encoded: String) -> Bool {
            CameraConfigurationRoundTrip.preservesFields(original: Data(original.utf8), encoded: Data(encoded.utf8))
        }
        XCTAssertTrue(matches(#"{"number":4.00e0}"#, #"{"number":4}"#))
        XCTAssertFalse(matches(#"{"number":0.35000000000000001}"#, #"{"number":0.35}"#))
        XCTAssertFalse(matches(#"{"number":1e10001}"#, #"{"number":1}"#))
        XCTAssertFalse(matches(#"{"text":"\uD800"}"#, #"{"text":"�"}"#))
        XCTAssertFalse(matches(#"{"name":"x","na\u006de":"x"}"#, #"{"name":"x"}"#))
        XCTAssertFalse(matches(#"{"nested":{"same":1,"s\u0061me":1}}"#, #"{"nested":{"same":1}}"#))
        XCTAssertFalse(matches(#"{"text":"e\u0301"}"#, #"{"text":"é"}"#))
        XCTAssertFalse(matches(#"{"text":"\q"}"#, #"{"text":"q"}"#))
    }

    func testInvalidRevisionAndNonRegularFilesFailClosed() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let revision = directory.appendingPathComponent(".cameras.json.revision")
            try Data("invalid".utf8).write(to: revision)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.snapshot(from: url))
            try FileManager.default.removeItem(at: revision)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent("missing"))
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.snapshot(from: url))
        }
    }

    func testMissingConfigurationWithRevisionCannotBeReadOrRecreated() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            var configuration = empty.configuration
            configuration.columns = 5
            let saved = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(
                configuration, expected: empty, to: url))
            let original = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)

            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.snapshot(from: url))
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(
                saved.configuration, expected: saved, to: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

            try original.write(to: url)
            XCTAssertTrue(try CoordinatedCameraConfigurationStore.snapshot(from: url).matches(saved))
        }
    }

    func testBusyLockAndInvalidUpdateDoNotWrite() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let before = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let lock = directory.appendingPathComponent(".cameras.json.lock")
            let fd = open(lock.path, O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(before.configuration, expected: before, to: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(flock(fd, LOCK_UN), 0)
            var invalid = before.configuration
            invalid.columns = 0
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(invalid, expected: before, to: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testRuntimeLeaseExcludesWriterAcrossProcesses() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            var seed: CoordinatedCameraConfigurationStore.RuntimeLease? =
                try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            XCTAssertNotNil(seed)
            seed = nil
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw XCTSkip("Python is unavailable for the separate-process lease test.")
            }
            let child = Process()
            let ready = Pipe()
            let release = Pipe()
            child.executableURL = python
            child.arguments = ["-c", """
                import fcntl, sys
                with open(sys.argv[1], 'rb') as lock:
                    fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    print('ready', flush=True)
                    sys.stdin.buffer.read(1)
                """, directory.appendingPathComponent(".cameras.json.runtime-lock").path]
            child.standardOutput = ready
            child.standardInput = release
            try child.run()
            defer {
                try? release.fileHandleForWriting.close()
                child.waitUntilExit()
            }
            XCTAssertEqual(ready.fileHandleForReading.availableData, Data("ready\n".utf8))
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {
                XCTFail("writer entered while another process held a lease")
            })
        }
    }

    func testRuntimeLeaseRejectsAnotherRuntime() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            var first: CoordinatedCameraConfigurationStore.RuntimeLease? =
                try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            XCTAssertNotNil(first)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
            first = nil
            XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
        }
    }

    func testRuntimeOwnerMayOnlyChangeProcessingFlagsAndRejectsStale() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            var config = WallConfiguration()
            config.cameras = [
                Camera(name: "One", substream: "", enabled: false, localDeviceID: "one"),
                Camera(name: "Two", substream: "", enabled: false, localDeviceID: "two")
            ]
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let before = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(config, expected: empty, to: url))
            let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            var flags = config
            flags.cameras[0].yoloEnabled = true
            flags.cameras[1].aiChatEnabled = false
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(flags, expected: before, to: url))
            let saved = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                flags, expected: before, to: url, using: owner))
            XCTAssertNil(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                flags, expected: before, to: url, using: owner))
            config = saved.configuration
            var invalid = config
            invalid.cameras[0].enabled = true
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                invalid, expected: saved, to: url, using: owner))
            invalid = config
            invalid.columns = 5
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                invalid, expected: saved, to: url, using: owner))
            invalid = config
            invalid.cameras.swapAt(0, 1)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                invalid, expected: saved, to: url, using: owner))
            let otherURL = directory.appendingPathComponent("other.json")
            let otherLease = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: otherURL)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                config, expected: saved, to: url, using: otherLease))
            XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, config)
        }
    }

    func testWriterLeaseExpiresAtScopeExitAndCannotBeReusedForAnotherStore() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let other = directory.appendingPathComponent("other.json")
            let expected = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let otherExpected = try CoordinatedCameraConfigurationStore.snapshot(from: other)
            var escaped: CoordinatedCameraConfigurationStore.WriterLease?
            try CoordinatedCameraConfigurationStore.withWriterLease(for: url) { lease in
                escaped = lease
                XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(
                    otherExpected.configuration, expected: otherExpected, to: other, using: lease))
                XCTAssertNotNil(try CoordinatedCameraConfigurationStore.compareAndSave(
                    expected.configuration, expected: expected, to: url, using: lease))
            }
            let current = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(
                current.configuration, expected: current, to: url, using: XCTUnwrap(escaped)))
            XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
        }
    }

    func testRuntimeCannotCreateMissingConfigurationOrUseReplacedLock() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                empty.configuration, expected: empty, to: url, using: owner))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let lock = directory.appendingPathComponent(".cameras.json.runtime-lock")
            try FileManager.default.removeItem(at: lock)
            try Data().write(to: lock)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.initializeMissingForDiscovery(
                empty.configuration, expected: empty, to: url, using: owner))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testDiscoveryInitializationIsLimitedToMissingDefault() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            var invalid = empty.configuration
            invalid.columns = 5
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.initializeMissingForDiscovery(
                invalid, expected: empty, to: url, using: owner))
            var initial = empty.configuration
            initial.go2rtcPath = "/synthetic/relay"
            let saved = try XCTUnwrap(CoordinatedCameraConfigurationStore.initializeMissingForDiscovery(
                initial, expected: empty, to: url, using: owner))
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.initializeMissingForDiscovery(
                initial, expected: saved, to: url, using: owner))
        }
    }

    func testOtherProcessCannotCompareAndSaveWhileRuntimeIsHeld() throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_CAS_TEST_DRIVER"] else {
            throw XCTSkip("Set CAMERA_CAS_TEST_DRIVER to the synthetic CAS participant.")
        }
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            let before = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            _ = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(before.configuration, expected: before, to: url))
            func run() throws -> Int32 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = [url.path]
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }
            var runtime: CoordinatedCameraConfigurationStore.RuntimeLease? =
                try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            XCTAssertNotNil(runtime)
            XCTAssertEqual(try run(), 2)
            XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration.columns, 4)
            runtime = nil
            XCTAssertEqual(try run(), 0)
            XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration.columns, 7)
        }
    }

    func testRuntimePreferenceWriteRejectsOtherProcessHoldingStoreLock() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Python is unavailable for the separate-process lock test.")
        }
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            var config = WallConfiguration()
            config.cameras = [Camera(name: "Fixture", substream: "", enabled: false, localDeviceID: "synthetic")]
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let expected = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(config, expected: empty, to: url))
            let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            let child = Process()
            let ready = Pipe()
            let release = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-c", """
                import fcntl, sys
                with open(sys.argv[1], 'rb') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    print('ready', flush=True)
                    sys.stdin.buffer.read(1)
                """, directory.appendingPathComponent(".cameras.json.lock").path]
            child.standardOutput = ready
            child.standardInput = release
            try child.run()
            defer {
                try? release.fileHandleForWriting.close()
                child.waitUntilExit()
            }
            XCTAssertEqual(ready.fileHandleForReading.availableData, Data("ready\n".utf8))
            config.cameras[0].yoloEnabled = true
            XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                config, expected: expected, to: url, using: owner))
            try release.fileHandleForWriting.close()
            child.waitUntilExit()
            XCTAssertNotNil(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                config, expected: expected, to: url, using: owner))
        }
    }

    func testRuntimePreferenceRejectsCrossProcessABA() throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_CAS_TEST_DRIVER"] else {
            throw XCTSkip("Set CAMERA_CAS_TEST_DRIVER to the synthetic CAS participant.")
        }
        try withDirectory { directory in
            let url = directory.appendingPathComponent("cameras.json")
            var config = WallConfiguration()
            config.cameras = [Camera(name: "Fixture", substream: "", enabled: false, localDeviceID: "synthetic")]
            let empty = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            let stale = try XCTUnwrap(CoordinatedCameraConfigurationStore.compareAndSave(config, expected: empty, to: url))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = [url.path, "aba"]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            let current = try CoordinatedCameraConfigurationStore.snapshot(from: url)
            XCTAssertEqual(current.configuration, stale.configuration)
            XCTAssertFalse(current.matches(stale))
            let owner = try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url)
            config.cameras[0].yoloEnabled = true
            XCTAssertNil(try CoordinatedCameraConfigurationStore.compareAndSaveRuntimePreferences(
                config, expected: stale, to: url, using: owner))
            XCTAssertEqual(try CoordinatedCameraConfigurationStore.snapshot(from: url).configuration, current.configuration)
        }
    }

    func testUnsafeLockFilesFailClosed() throws {
        for suffix in ["lock", "runtime-lock"] {
            for kind in ["symlink", "hardlink", "permissions", "fifo"] {
                try withDirectory { directory in
                    let url = directory.appendingPathComponent("cameras.json")
                    let lock = directory.appendingPathComponent(".cameras.json.\(suffix)")
                    let target = directory.appendingPathComponent("target")
                    switch kind {
                    case "symlink":
                        try Data().write(to: target)
                        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
                    case "hardlink":
                        try Data().write(to: target)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                        try FileManager.default.linkItem(at: target, to: lock)
                    case "permissions":
                        try Data().write(to: lock)
                        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
                    default:
                        XCTAssertEqual(mkfifo(lock.path, mode_t(0o600)), 0)
                    }
                    if suffix == "lock" {
                        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.snapshot(from: url), kind)
                    } else {
                        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url), kind)
                    }
                    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                }
            }
        }
    }
}
