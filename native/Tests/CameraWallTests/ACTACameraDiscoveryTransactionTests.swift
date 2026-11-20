import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private final class SyntheticDiscoveryCredentials: CameraCredentialStore, @unchecked Sendable {
    var value: Credentials?
    var writes = 0
    init(_ value: Credentials?) { self.value = value }
    func read(_ id: UUID) throws -> Credentials? { value }
    func save(_ credentials: Credentials, for id: UUID) throws { value = credentials; writes += 1 }
    func remove(_ id: UUID) throws { value = nil; writes += 1 }
}

@MainActor
final class ACTACameraDiscoveryTransactionTests: XCTestCase {
    func testMissingConfigurationIsInitializedBeforeDiscoveryAndCommitted() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        memory.go2rtcPath = "/synthetic/bundled-relay"
        let revision = UUID()
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
            readConfiguration: { memory }, readRevision: { revision },
            discover: { _ in
                XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
                return ()
            }, commit: { _, lease, snapshot in
                var next = memory
                next.columns = 7
                try writer.replaceConfiguration(next, to: url, using: lease, expectedSnapshot: snapshot,
                    readMemory: { memory }, installMemory: { memory = $0 }, afterCommit: { _, _ in })
            })
        XCTAssertEqual(memory.columns, 7)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testRealWriterAndSyntheticCredentialsCommitUnderOneWriterLease() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let revision = UUID()
        let camera = Camera(name: "Synthetic", substream: "rtsp://192.0.2.1/live", enabled: false)
        let old = Credentials(username: "old", password: "old")
        let updated = Credentials(username: "new", password: "new")
        let credentials = SyntheticDiscoveryCredentials(old)
        let writer = ACTAGUISettingsWriter(gate: ACTACameraWriterGate())
        var committed = false
        try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
            readConfiguration: { memory }, readRevision: { revision },
            discover: { _ in
                XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
                return camera
            }, commit: { found, lease, snapshot in
                XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
                try ACTACameraCredentialedSave.run(cameraID: found.id, credentials: updated, store: credentials,
                    beforeWrite: {}, commit: {
                        var next = memory
                        next.cameras.append(found)
                        try writer.replaceConfiguration(next, to: url, using: lease, expectedSnapshot: snapshot,
                            readMemory: { memory },
                            installMemory: { memory = $0 }, afterCommit: { _, _ in
                                XCTAssertEqual(credentials.value, updated)
                                XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
                            })
                    })
                committed = true
            })
        XCTAssertTrue(committed)
        XCTAssertEqual(credentials.value, updated)
        XCTAssertEqual(memory.cameras, [camera])
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }

    func testEscapedDiscoveryLeasePreventsCredentialAndConfigurationWrites() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let revision = UUID()
        let original = Credentials(username: "old", password: "old")
        let credentials = SyntheticDiscoveryCredentials(original)
        var escaped: CoordinatedCameraConfigurationStore.RuntimeLease?
        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { lease in escaped = lease; return () },
                commit: { _, _, _ in
                    try credentials.save(Credentials(username: "new", password: "new"), for: UUID())
                    XCTFail("Commit must not run while discovery lease is retained")
                })
            XCTFail("An escaped discovery lease must prevent the writer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("in use"))
        }
        XCTAssertNotNil(escaped)
        XCTAssertEqual(credentials.value, original)
        XCTAssertEqual(credentials.writes, 0)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        escaped = nil
        XCTAssertNoThrow(try CoordinatedCameraConfigurationStore.withStoppedRuntimes(for: url) {})
    }

    func testSnapshotRevisionChangeBeforeCommitRejectsCredentialWrites() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let revision = UUID()
        let original = Credentials(username: "old", password: "old")
        let credentials = SyntheticDiscoveryCredentials(original)
        var revisionChecks = 0
        var mutationError: Error?
        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: {
                    revisionChecks += 1
                    if revisionChecks == 2 {
                        do {
                            try Data(UUID().uuidString.utf8)
                                .write(to: root.appendingPathComponent(".cameras.json.revision"))
                        } catch { mutationError = error }
                    }
                    return revision
                }, discover: { _ in () }, commit: { _, _, _ in
                    try credentials.save(Credentials(username: "new", password: "new"), for: UUID())
                    XCTFail("Stale discovery must not commit")
                })
            XCTFail("A changed disk revision must reject the transaction")
        } catch {}
        XCTAssertNil(mutationError)
        XCTAssertEqual(revisionChecks, 2)
        XCTAssertEqual(credentials.value, original)
        XCTAssertEqual(credentials.writes, 0)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testCredentialRollbackAndUncertainPublicationArePreserved() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let revision = UUID()
        let camera = Camera(name: "Synthetic", substream: "rtsp://192.0.2.1/live", enabled: false)
        let original = Credentials(username: "old", password: "old")
        let updated = Credentials(username: "new", password: "new")
        let credentials = SyntheticDiscoveryCredentials(original)
        let gate = ACTACameraWriterGate()
        let writer = ACTAGUISettingsWriter(gate: gate)

        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision }, discover: { _ in camera },
                commit: { found, lease, snapshot in
                    try ACTACameraCredentialedSave.run(cameraID: found.id, credentials: updated, store: credentials,
                        beforeWrite: {}, commit: {
                            var invalid = memory
                            invalid.columns = 0
                            try writer.replaceConfiguration(invalid, to: url, using: lease, expectedSnapshot: snapshot,
                                readMemory: { memory }, installMemory: { memory = $0 }, afterCommit: { _, _ in })
                        })
                })
            XCTFail("Invalid configuration must fail")
        } catch {}
        XCTAssertEqual(credentials.value, original)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)

        let emptyCredentials = SyntheticDiscoveryCredentials(nil)
        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision }, discover: { _ in camera },
                commit: { found, _, _ in
                    try ACTACameraCredentialedSave.run(cameraID: found.id, credentials: updated,
                        store: emptyCredentials, beforeWrite: {}, commit: { throw CocoaError(.fileWriteUnknown) })
                })
            XCTFail("Failed commit must roll back newly created credentials")
        } catch {}
        XCTAssertNil(emptyCredentials.value)
        XCTAssertEqual(emptyCredentials.writes, 2)

        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision }, discover: { _ in camera },
                commit: { found, lease, snapshot in
                    try ACTACameraCredentialedSave.run(cameraID: found.id, credentials: updated, store: credentials,
                        beforeWrite: {}, commit: {
                            var next = memory
                            next.cameras.append(found)
                            try writer.replaceConfiguration(next, to: url, using: lease, expectedSnapshot: snapshot,
                                readMemory: { memory }, installMemory: { _ in throw CocoaError(.fileWriteUnknown) },
                                afterCommit: { _, _ in })
                        })
                })
            XCTFail("Failed publication must require reconciliation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("reconcile"))
        }
        XCTAssertEqual(credentials.value, updated)
        XCTAssertEqual(try ConfigurationStore.load(from: url).cameras, [camera])
        XCTAssertThrowsError(try gate.capture { memory })
    }

    func testSnapshotChangeDuringCredentialSaveRollsCredentialsBack() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let revision = UUID()
        let camera = Camera(name: "Synthetic", substream: "rtsp://192.0.2.1/live", enabled: false)
        let original = Credentials(username: "old", password: "old")
        let credentials = SyntheticDiscoveryCredentials(original)
        let gate = ACTACameraWriterGate()
        let writer = ACTAGUISettingsWriter(gate: gate)
        var mutationError: Error?
        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision }, discover: { _ in camera },
                commit: { found, lease, snapshot in
                    try ACTACameraCredentialedSave.run(cameraID: found.id,
                        credentials: Credentials(username: "new", password: "new"), store: credentials,
                        beforeWrite: {
                            do {
                                try Data(UUID().uuidString.utf8)
                                    .write(to: root.appendingPathComponent(".cameras.json.revision"))
                            } catch { mutationError = error }
                        }, commit: {
                            var next = memory
                            next.cameras.append(found)
                            try writer.replaceConfiguration(next, to: url, using: lease, expectedSnapshot: snapshot,
                                readMemory: { memory }, installMemory: { memory = $0 }, afterCommit: { _, _ in })
                        })
                })
            XCTFail("Changed discovery snapshot must not commit")
        } catch {
            guard case ACTAGUISettingsWriter.Failure.stale = error else {
                return XCTFail("Expected stale discovery snapshot, got \(error)")
            }
        }
        XCTAssertNil(mutationError)
        XCTAssertEqual(credentials.value, original)
        XCTAssertEqual(credentials.writes, 2)
        XCTAssertTrue(memory.cameras.isEmpty)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertNoThrow(try gate.capture { memory })
    }

    func testCommitHoldsLeaseAndInitializesOnlyMissingConfiguration() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_COORDINATION_TEST_DRIVER"] else {
            throw XCTSkip("Set CAMERA_COORDINATION_TEST_DRIVER to the synthetic participant.")
        }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        memory.go2rtcPath = "/synthetic/bundled/relay"
        var revision = UUID()
        var pending: CheckedContinuation<String, Never>?
        var committed = false
        let task = Task { @MainActor in
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { _ in await withCheckedContinuation { pending = $0 } },
                commit: { value, writerLease, snapshot in
                    XCTAssertEqual(try self.probe(executable, url), 2)
                    XCTAssertEqual(value, "fixture")
                    var next = memory
                    next.columns = 7
                    try ACTAGUISettingsWriter(gate: ACTACameraWriterGate()).replaceConfiguration(
                        next, to: url, using: writerLease, expectedSnapshot: snapshot, readMemory: { memory },
                        installMemory: { memory = $0 }, afterCommit: { _, _ in })
                    revision = UUID()
                    committed = true
                })
        }
        while pending == nil { await Task.yield() }
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertEqual(try probe(executable, url), 2)
        pending?.resume(returning: "fixture")
        try await task.value
        XCTAssertTrue(committed)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertEqual(try probe(executable, url), 0)
    }

    func testLocalABAAndCancellationNeverCommit() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        var revision = UUID()
        var pending: CheckedContinuation<Void, Never>?
        var commits = 0
        let task = Task { @MainActor in
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { _ in await withCheckedContinuation { pending = $0 } },
                commit: { _, _, _ in commits += 1 })
        }
        while pending == nil { await Task.yield() }
        revision = UUID()
        pending?.resume()
        do { try await task.value; XCTFail("Stale discovery committed") } catch {}
        XCTAssertEqual(commits, 0)

        pending = nil
        let cancelled = Task { @MainActor in
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { _ in await withCheckedContinuation { pending = $0 } },
                commit: { _, _, _ in commits += 1 })
        }
        while pending == nil { await Task.yield() }
        cancelled.cancel()
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.acquireRuntimeLease(for: url))
        pending?.resume()
        do { try await cancelled.value; XCTFail("Cancelled discovery committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
    }

    func testCoordinatedWriterAndOrphanRevisionAreRejected() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        let revision = UUID()
        var pending: CheckedContinuation<Void, Never>?
        var committed = false
        let task = Task { @MainActor in
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { _ in await withCheckedContinuation { pending = $0 } },
                commit: { _, _, _ in committed = true })
        }
        while pending == nil { await Task.yield() }
        var changed = memory
        changed.columns = 7
        let base = try CoordinatedCameraConfigurationStore.snapshot(from: url)
        XCTAssertThrowsError(try CoordinatedCameraConfigurationStore.compareAndSave(changed, expected: base, to: url))
        pending?.resume()
        try await task.value
        XCTAssertTrue(committed)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)

        let missing = root.appendingPathComponent("missing.json")
        let revisionFile = root.appendingPathComponent(".missing.json.revision")
        try Data(UUID().uuidString.utf8).write(to: revisionFile)
        XCTAssertThrowsError(try ACTACameraDiscoveryLeaseScope.acquire(for: missing, expected: memory,
                                                                       initializeMissing: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testUnknownConfigurationIsNotRewrittenOrProbed() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let memory = WallConfiguration()
        try ConfigurationStore.save(memory, to: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["futureSetting"] = "preserve"
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try bytes.write(to: url)
        var discovered = false
        let revision = UUID()
        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { _ in discovered = true }, commit: { _, _, _ in })
            XCTFail("Unknown fields must not be discarded")
        } catch {}
        XCTAssertFalse(discovered)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLegacyFormattedConfigurationAllowsSyntheticSave() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let id = UUID()
        let text = """
          { "rtspPort":18554, "apiPort":11984,
            "go2rtcPath":"\\/synthetic\\/relay", "staleAfterMilliseconds":1000,
            "columns":4, "cameras":[{"id":"\(id.uuidString.lowercased())","name":"Fixture",
            "substream":"","localDeviceID":"synthetic","enabled":false}] }
        """
        try Data(text.utf8).write(to: url)
        var memory = try ConfigurationStore.load(from: url)
        let revision = UUID()
        var committed = false
        try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
            readConfiguration: { memory }, readRevision: { revision },
            discover: { _ in "synthetic" },
            commit: { value, writerLease, snapshot in
                XCTAssertEqual(value, "synthetic")
                var next = memory
                next.columns = 7
                try ACTAGUISettingsWriter(gate: ACTACameraWriterGate()).replaceConfiguration(
                    next, to: url, using: writerLease, expectedSnapshot: snapshot, readMemory: { memory },
                    installMemory: { memory = $0 }, afterCommit: { _, _ in })
                committed = true
            })
        XCTAssertTrue(committed)
        XCTAssertEqual(try ConfigurationStore.load(from: url), memory)
        XCTAssertEqual(memory.cameras.first?.id, id)
    }

    func testDuplicateKeysDoNotReachSyntheticDiscoveryOrCommit() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        let text = """
        {"cameras":[],"columns":4,"col\\u0075mns":4,"staleAfterMilliseconds":1000,
         "go2rtcPath":"/synthetic/relay","apiPort":11984,"rtspPort":18554}
        """
        let bytes = Data(text.utf8)
        try bytes.write(to: url)
        let memory: WallConfiguration
        do { memory = try ConfigurationStore.load(from: url) }
        catch {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            return
        }
        let revision = UUID()
        var discovered = false
        do {
            try await ACTACameraDiscoveryTransaction.run(url: url, configuration: memory, revision: revision,
                readConfiguration: { memory }, readRevision: { revision },
                discover: { _ in discovered = true }, commit: { _, _, _ in })
            XCTFail("Duplicate keys must not be discarded")
        } catch {}
        XCTAssertFalse(discovered)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".discovery-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func probe(_ executable: String, _ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.path, "worker"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
