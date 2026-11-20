import Darwin
import Foundation
import XCTest
@testable import CameraCore

final class OperatorAuditLogCoordinationTests: XCTestCase {
    private struct Failure: Error {}

    private func fixture() throws -> IsolatedStoreTestDirectory {
        try IsolatedStoreTestDirectory()
    }

    private func read(_ url: URL) throws -> [OperatorAuditEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([OperatorAuditEntry].self, from: Data(contentsOf: url))
    }

    private func write(_ entries: [OperatorAuditEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    func testInstancesRefreshAndRetainLegacyJSONWithBoundedHistory() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let original = OperatorAuditEntry(action: .settingsUpdated, summary: "legacy")
        try write([original], to: url)
        let first = OperatorAuditLog(url: url, maxEntries: 50)
        let second = OperatorAuditLog(url: url, maxEntries: 50)
        first.record(action: .settingsUpdated, summary: "first")
        XCTAssertEqual(second.recentEntries().map(\.summary), ["first", "legacy"])
        second.record(action: .settingsUpdated, summary: "second")
        XCTAssertEqual(first.recentEntries().map(\.summary), ["second", "first", "legacy"])
        for index in 0..<50 { first.record(action: .settingsUpdated, summary: "\(index)") }
        let entries = second.recentEntries(limit: 100)
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(entries.first?.summary, "49")
        XCTAssertEqual(try read(url).map(\.id), entries.map(\.id))
    }

    func testFailedSaveRetriesPendingAgainstOtherWriterAndReconcilesUncertainPublication() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        var failBefore = true
        var failAfter = false
        let audit = OperatorAuditLog(url: url, load: { try self.read(url) }, save: {
            if failBefore { throw Failure() }
            try self.write($0, to: url)
            if failAfter { throw Failure() }
        }, coordinated: true)
        let other = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        other.record(action: .settingsUpdated, summary: "other")
        XCTAssertEqual(audit.recentEntries().map(\.summary), ["pending", "other"])
        XCTAssertNotNil(audit.lastPersistenceError)
        failBefore = false
        failAfter = true
        audit.record(action: .settingsUpdated, summary: "published")
        XCTAssertNotNil(audit.lastPersistenceError)
        other.record(action: .settingsUpdated, summary: "between")
        failAfter = false
        audit.record(action: .settingsUpdated, summary: "retry")
        XCTAssertNil(audit.lastPersistenceError)
        let saved = try read(url)
        XCTAssertEqual(Set(saved.map(\.summary)), Set(["pending", "other", "published", "between", "retry"]))
        XCTAssertEqual(Set(saved.map(\.id)).count, 5)
        XCTAssertEqual(audit.recentEntries().map(\.id), saved.map(\.id))
    }

    func testRefreshRetriesPendingWithoutNewAuditEvent() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        var fail = true
        let audit = OperatorAuditLog(url: url, load: { try self.read(url) }, save: {
            if fail { throw Failure() }
            try self.write($0, to: url)
        }, coordinated: true)
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(audit.recentEntries().map(\.summary), ["pending"])
        XCTAssertNotNil(audit.lastPersistenceError)
        let other = OperatorAuditLog(url: url)
        other.record(action: .settingsUpdated, summary: "other")
        fail = false
        XCTAssertEqual(audit.recentEntries().map(\.summary), ["pending", "other"])
        XCTAssertNil(audit.lastPersistenceError)
        XCTAssertEqual(try read(url).map(\.summary), ["pending", "other"])
    }

    func testRefreshReconcilesUncertainPublicationWithoutDuplicatingEntries() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        var failAfterPublication = true
        let audit = OperatorAuditLog(url: url, load: { try self.read(url) }, save: {
            try self.write($0, to: url)
            if failAfterPublication { throw Failure() }
        }, coordinated: true)
        audit.record(action: .settingsUpdated, summary: "published")
        XCTAssertNotNil(audit.lastPersistenceError)
        let other = OperatorAuditLog(url: url)
        other.record(action: .settingsUpdated, summary: "other")
        failAfterPublication = false
        let entries = audit.recentEntries()
        XCTAssertNil(audit.lastPersistenceError)
        XCTAssertEqual(Set(entries.map(\.summary)), Set(["published", "other"]))
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertEqual(try read(url).map(\.id), entries.map(\.id))
    }

    func testPendingOverflowDoesNotDiscardUnwrittenEntries() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        var fail = true
        let audit = OperatorAuditLog(url: url, maxEntries: 50, load: { try self.read(url) }, save: {
            if fail { throw Failure() }
            try self.write($0, to: url)
        }, coordinated: true)
        for index in 0..<51 {
            audit.record(action: .settingsUpdated, summary: "\(index)")
        }
        fail = false
        XCTAssertEqual(audit.recentEntries(limit: 100).count, 51)
        XCTAssertTrue(audit.lastPersistenceError?.contains("exceed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptionAfterInitializationStaysUntouchedAndErrorIsSticky() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let audit = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "before")
        let broken = Data("{broken".utf8)
        try broken.write(to: url)
        _ = audit.recentEntries()
        XCTAssertNotNil(audit.lastPersistenceError)
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertEqual(try Data(contentsOf: url), broken)
        try write([], to: url)
        audit.record(action: .settingsUpdated, summary: "still pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(try read(url).count, 0)
    }

    func testUnknownAuditFieldsAreNeverOverwrittenOnLoadOrRefresh() throws {
        for introducedAfterInitialization in [false, true] {
            let root = try fixture()
            defer { try? root.remove() }
            let url = root.url.appendingPathComponent("audit.json")
            try write([OperatorAuditEntry(action: .settingsUpdated, summary: "legacy")], to: url)
            let audit = introducedAfterInitialization ? OperatorAuditLog(url: url) : nil
            var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            records[0]["futureField"] = ["nested": "preserve"]
            let legacy = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try legacy.write(to: url)
            XCTAssertEqual(try read(url).count, 1)
            let instance = audit ?? OperatorAuditLog(url: url)
            instance.record(action: .settingsUpdated, summary: "must not overwrite")
            XCTAssertNotNil(instance.lastPersistenceError)
            XCTAssertEqual(try Data(contentsOf: url), legacy)
            _ = instance.recentEntries()
            XCTAssertNotNil(instance.lastPersistenceError)
            XCTAssertEqual(try Data(contentsOf: url), legacy)
        }
    }

    func testDuplicateAuditKeysAreNeverOverwritten() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        try write([OperatorAuditEntry(action: .settingsUpdated, summary: "legacy")], to: url)
        let original = try String(contentsOf: url, encoding: .utf8)
        let duplicate = original.replacingOccurrences(of: "\"summary\":\"legacy\"",
                                                      with: "\"summary\":\"future\",\"summary\":\"legacy\"")
        XCTAssertNotEqual(duplicate, original)
        let legacy = Data(duplicate.utf8)
        try legacy.write(to: url)
        let audit = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "must not overwrite")
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: url), legacy)
    }

    func testLargeCompatibleAuditRemainsWritable() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let large = String(repeating: "a", count: 4_050_000) + "\"\\\n😀"
        let original = OperatorAuditEntry(action: .settingsUpdated, summary: large)
        try write([original], to: url)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 4_000_000)
        let audit = OperatorAuditLog(url: url)
        XCTAssertNil(audit.lastPersistenceError)
        XCTAssertEqual(audit.recentEntries().first?.summary, large)
        audit.record(action: .settingsUpdated, summary: "new")
        XCTAssertNil(audit.lastPersistenceError)
        let saved = try read(url)
        XCTAssertEqual(saved.map(\.summary), ["new", large])
        let reopened = OperatorAuditLog(url: url)
        XCTAssertNil(reopened.lastPersistenceError)
        XCTAssertEqual(reopened.recentEntries().map(\.summary), ["new", large])
    }

    func testLargeAuditWithUnknownOrDuplicateFieldIsNeverOverwritten() throws {
        for duplicate in [false, true] {
            let root = try fixture()
            defer { try? root.remove() }
            let url = root.url.appendingPathComponent("audit.json")
            try write([OperatorAuditEntry(action: .settingsUpdated,
                                          summary: String(repeating: "a", count: 4_050_000))], to: url)
            let normal = try Data(contentsOf: url)
            XCTAssertTrue(normal.starts(with: Data("[{".utf8)))
            let prefix = duplicate ? "[{\"\\u0061ction\":\"SETTINGS_UPDATED\"," : "[{\"future\":{\"nested\":true},"
            var legacy = Data(prefix.utf8)
            legacy.append(normal.dropFirst(2))
            try legacy.write(to: url)
            XCTAssertEqual(try read(url).count, 1)
            let audit = OperatorAuditLog(url: url)
            audit.record(action: .settingsUpdated, summary: "must not overwrite")
            XCTAssertNotNil(audit.lastPersistenceError)
            XCTAssertEqual(try Data(contentsOf: url), legacy)
        }
    }

    func testAuditHistorySymlinksAreRejectedWithoutTouchingLinkOrTarget() throws {
        for targetExists in [false, true] {
            let root = try fixture()
            defer { try? root.remove() }
            let url = root.url.appendingPathComponent("audit.json")
            let target = root.url.appendingPathComponent("target.json")
            let original = Data("[{\"future\":true}]".utf8)
            if targetExists { try original.write(to: target) }
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
            let audit = OperatorAuditLog(url: url)
            XCTAssertNotNil(audit.lastPersistenceError)
            audit.record(action: .settingsUpdated, summary: "must not overwrite")
            XCTAssertNotNil(audit.lastPersistenceError)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
            if targetExists {
                XCTAssertEqual(try Data(contentsOf: target), original)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }
    }

    func testNonRegularAuditHistoryIsRejectedWithoutBlocking() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        let audit = OperatorAuditLog(url: url)
        XCTAssertNotNil(audit.lastPersistenceError)
        audit.record(action: .settingsUpdated, summary: "must not overwrite")
        XCTAssertNotNil(audit.lastPersistenceError)
        var metadata = stat()
        XCTAssertEqual(lstat(url.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFIFO)
    }

    func testAuditHistorySymlinkIntroducedAfterInitializationFailsClosed() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let target = root.url.appendingPathComponent("target.json")
        let original = Data("[]".utf8)
        try original.write(to: target)
        let audit = OperatorAuditLog(url: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        audit.record(action: .settingsUpdated, summary: "must not overwrite")
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
    }

    func testLockFailureIsReportedAndPendingIsRetried() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let lockURL = root.url.appendingPathComponent(".audit.json.lock")
        try FileManager.default.createSymbolicLink(atPath: lockURL.path, withDestinationPath: "missing")
        let audit = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: lockURL)
        audit.record(action: .settingsUpdated, summary: "retry")
        XCTAssertNil(audit.lastPersistenceError)
        XCTAssertEqual(try read(url).map(\.summary), ["retry", "pending"])
    }

    func testInjectedStoreKeepsSingleInstanceRetryAndStickyLoadBehavior() {
        var stored: [OperatorAuditEntry] = []
        var loads = 0, fail = true
        let audit = OperatorAuditLog(url: URL(string: "memory://audit")!, load: {
            loads += 1
            return stored
        }, save: {
            if fail { throw Failure() }
            stored = $0
        })
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        fail = false
        audit.record(action: .settingsUpdated, summary: "retry")
        XCTAssertNil(audit.lastPersistenceError)
        XCTAssertEqual(stored.map(\.summary), ["retry", "pending"])
        _ = audit.recentEntries()
        XCTAssertEqual(loads, 1)

        var saves = 0
        let broken = OperatorAuditLog(url: URL(string: "memory://broken")!,
                                      load: { throw Failure() }, save: { _ in saves += 1 })
        broken.record(action: .settingsUpdated, summary: "never written")
        XCTAssertNotNil(broken.lastPersistenceError)
        XCTAssertEqual(broken.recentEntries().count, 1)
        XCTAssertEqual(saves, 0)
    }

    func testSeparateProcessesAndInstancesPreserveConcurrentRecords() throws {
        guard let helper = ProcessInfo.processInfo.environment["OPERATOR_AUDIT_TEST_HELPER"] else {
            throw XCTSkip("Set OPERATOR_AUDIT_TEST_HELPER to the compiled synthetic helper.")
        }
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let first = OperatorAuditLog(url: url)
        let second = OperatorAuditLog(url: url)
        let children: [(Process, Pipe, Pipe)] = (0..<3).map { index in
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = [url.path, "child\(index)", "30"]
            process.standardInput = input
            process.standardOutput = output
            return (process, input, output)
        }
        for (process, _, _) in children { try process.run() }
        for (_, _, output) in children {
            XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        }
        for (_, input, _) in children { try input.fileHandleForWriting.write(contentsOf: Data([1])) }
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            (index.isMultiple(of: 2) ? first : second)
                .record(action: .settingsUpdated, summary: "parent\(index)")
        }
        for (process, _, _) in children {
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        if first.lastPersistenceError != nil {
            first.record(action: .settingsUpdated, summary: "first-retry")
        }
        if second.lastPersistenceError != nil {
            second.record(action: .settingsUpdated, summary: "second-retry")
        }
        XCTAssertNil(first.lastPersistenceError)
        XCTAssertNil(second.lastPersistenceError)
        let saved = try read(url)
        let expected = Set((0..<40).map { "parent\($0)" } +
                           (0..<3).flatMap { child in (0..<30).map { "child\(child)-\($0)" } })
        XCTAssertTrue(expected.isSubset(of: Set(saved.map(\.summary))))
        XCTAssertEqual(Set(saved.map(\.id)).count, saved.count)
        XCTAssertEqual(Set(first.recentEntries(limit: 1000).map(\.id)), Set(saved.map(\.id)))
    }

    func testSeparateProcessLockFailsFastAndRetriesPending() throws {
        guard let helper = ProcessInfo.processInfo.environment["OPERATOR_AUDIT_TEST_HELPER"] else {
            throw XCTSkip("Set OPERATOR_AUDIT_TEST_HELPER to the compiled synthetic helper.")
        }
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let audit = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "existing")
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [url.path, "hold-lock", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        final class Result: @unchecked Sendable {
            var error: String?
            var entries: [OperatorAuditEntry] = []
            var initialError: String?
        }
        let result = Result()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            audit.record(action: .settingsUpdated, summary: "blocked")
            result.entries = audit.recentEntries()
            result.error = audit.lastPersistenceError
            result.initialError = OperatorAuditLog(url: url).lastPersistenceError
            finished.signal()
        }
        let returnedWhileHeld = finished.wait(timeout: .now() + 2) == .success
        let onDisk = try read(url)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        if !returnedWhileHeld {
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        }
        XCTAssertTrue(returnedWhileHeld)
        XCTAssertEqual(onDisk.map(\.summary), ["existing"])
        XCTAssertTrue(result.error?.contains("busy") == true)
        XCTAssertTrue(result.initialError?.contains("busy") == true)
        XCTAssertEqual(result.entries.map(\.summary), ["blocked", "existing"])
        let other = OperatorAuditLog(url: url)
        other.record(action: .settingsUpdated, summary: "other")
        _ = audit.recentEntries()
        XCTAssertNil(audit.lastPersistenceError)
        let saved = try read(url)
        XCTAssertEqual(Set(saved.map(\.summary)), Set(["existing", "blocked", "other"]))
        XCTAssertEqual(Set(saved.map(\.id)).count, 3)
    }

    func testAuditProcessLockBlocksTransactionAndReleasesWithoutDeadlock() throws {
        guard let helper = ProcessInfo.processInfo.environment["OPERATOR_AUDIT_TEST_HELPER"] else {
            throw XCTSkip("Set OPERATOR_AUDIT_TEST_HELPER to the compiled synthetic helper.")
        }
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let store = try IncidentAuditTransactionStore(incidentURL: root.url.appendingPathComponent("incidents.json"),
                                                       auditURL: url)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [url.path, "hold-lock", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        for operation in [false, true] {
            XCTAssertThrowsError(try operation
                ? store.update { _ in .init(incidents: Data("[]".utf8), audit: Data("[]".utf8)) }
                : store.snapshot()) { error in
                guard case IncidentAuditTransactionStore.StoreError.busy = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        _ = try store.update { _ in .init(incidents: Data("[]".utf8), audit: Data("[]".utf8)) }
        XCTAssertEqual(try store.snapshot().audit, Data("[]".utf8))
    }

    func testJournalProcessBlocksAuditUntilTransactionCompletes() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let audit = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "existing")
        let before = try Data(contentsOf: url)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "strict-pause", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertNotNil(audit.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: url), before)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(audit.recentEntries().map(\.summary), ["pending", "existing"])
        XCTAssertNil(audit.lastPersistenceError)
        XCTAssertEqual(try read(url).map(\.summary), ["pending", "existing"])
    }

    func testPublishedJournalFencesAuditUntilRecoveryAndRetriesPending() throws {
        struct Failure: Error {}
        let boundaries: [IncidentAuditTransactionStore.Boundary] = [
            .afterJournalPublication, .afterJournalDurable,
            .afterIncidentPublication, .afterAuditPublication
        ]
        for boundary in boundaries {
            let root = try fixture()
            defer { try? root.remove() }
            let url = root.url.appendingPathComponent("audit.json")
            let incidents = root.url.appendingPathComponent("incidents.json")
            let audit = OperatorAuditLog(url: url)
            audit.record(action: .settingsUpdated, summary: "existing")
            let failing = try IncidentAuditTransactionStore(incidentURL: incidents, auditURL: url) {
                if $0 == boundary { throw Failure() }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let previous = try read(url)
            let after = try encoder.encode([OperatorAuditEntry(action: .settingsUpdated, summary: "transaction")] + previous)
            XCTAssertThrowsError(try failing.update { _ in .init(incidents: Data("[]".utf8), audit: after) })
            let beforeRetry = try Data(contentsOf: url)
            audit.record(action: .settingsUpdated, summary: "pending")
            XCTAssertTrue(audit.lastPersistenceError?.contains("recovery") == true, "\(boundary)")
            XCTAssertEqual(try Data(contentsOf: url), beforeRetry)
            let recovered = try IncidentAuditTransactionStore(incidentURL: incidents, auditURL: url).snapshot()
            XCTAssertEqual(recovered.audit, after)
            XCTAssertEqual(audit.recentEntries().map(\.summary), ["pending", "transaction", "existing"])
            XCTAssertNil(audit.lastPersistenceError)
            XCTAssertEqual(try read(url).map(\.summary), ["pending", "transaction", "existing"])
        }
    }

    func testRecoveryProcessBlocksAuditUntilRecoveryCompletes() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        struct Failure: Error {}
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let incidents = root.url.appendingPathComponent("incidents.json")
        let audit = OperatorAuditLog(url: url)
        audit.record(action: .settingsUpdated, summary: "existing")
        let failing = try IncidentAuditTransactionStore(incidentURL: incidents, auditURL: url) {
            if $0 == .afterJournalDurable { throw Failure() }
        }
        XCTAssertThrowsError(try failing.update { snapshot in
            .init(incidents: Data("[]".utf8), audit: snapshot.audit)
        })
        let before = try Data(contentsOf: url)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "strict-recover-pause", "0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.waitUntilExit() }
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 1), Data([1]))
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertTrue(audit.lastPersistenceError?.contains("busy") == true)
        XCTAssertEqual(try Data(contentsOf: url), before)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(audit.recentEntries().map(\.summary), ["pending", "existing"])
        XCTAssertNil(audit.lastPersistenceError)
    }

    func testDanglingJournalSymlinkFencesAuditWithoutReplacingIt() throws {
        let root = try fixture()
        defer { try? root.remove() }
        let url = root.url.appendingPathComponent("audit.json")
        let audit = OperatorAuditLog(url: url)
        let journal = root.url.appendingPathComponent(".incident-audit.transaction.json")
        try FileManager.default.createSymbolicLink(atPath: journal.path, withDestinationPath: "missing")
        audit.record(action: .settingsUpdated, summary: "pending")
        XCTAssertTrue(audit.lastPersistenceError?.contains("recovery") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: journal.path), "missing")
    }

    func testNestedAuditAccessFailsFastInsteadOfDeadlocking() throws {
        guard let helper = ProcessInfo.processInfo.environment["INCIDENT_AUDIT_TRANSACTION_HELPER"] else {
            throw XCTSkip("Set INCIDENT_AUDIT_TRANSACTION_HELPER to the compiled synthetic helper.")
        }
        let root = try fixture()
        defer { try? root.remove() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: helper)
        child.arguments = [root.url.path, "strict-nested", "0"]
        try child.run()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { child.waitUntilExit(); finished.signal() }
        guard finished.wait(timeout: .now() + 5) == .success else {
            child.terminate()
            _ = finished.wait(timeout: .now() + 5)
            return XCTFail("Nested audit access did not fail fast")
        }
        XCTAssertEqual(child.terminationStatus, 0)
    }
}
