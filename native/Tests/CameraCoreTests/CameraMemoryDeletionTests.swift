import XCTest
@testable import CameraCore

final class CameraMemoryDeletionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".memory-deletion-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func save(_ store: CameraMemoryStore, at date: Date) throws -> CameraMemoryFrame {
        try store.save(Data("synthetic".utf8), cameraID: UUID(), cameraName: "Fixture",
                       capturedAt: date, summary: "", now: date)
    }

    func testSnapshotRejectsChangedIndexWithoutDeleting() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CameraMemoryStore(url: root)
        let second = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        let a = try save(first, at: date)
        let snapshot = try first.deletionSnapshot()
        let b = try save(second, at: date)
        XCTAssertThrowsError(try first.deleteConfirmedSnapshot(snapshot)) {
            guard case CameraMemoryStoreError.snapshotChanged = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(try first.hasStoredImage(for: a))
        XCTAssertTrue(try first.hasStoredImage(for: b))
        XCTAssertFalse(try first.hasPendingDeletion())
    }

    func testPartialDeletionRequiresExplicitRecoveryAndBlocksMutation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupted = CameraMemoryStore(url: root, deletionFault: { index in
            if index == 0 { throw CameraMemoryStoreError.storageFailure }
        })
        let other = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        let a = try save(interrupted, at: date)
        let b = try save(interrupted, at: date)
        let snapshot = try interrupted.deletionSnapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertThrowsError(try interrupted.deleteConfirmedSnapshot(snapshot))
        XCTAssertTrue(try other.hasPendingDeletion())
        XCTAssertThrowsError(try other.verifyConfirmedDeletion(snapshot))
        XCTAssertThrowsError(try other.load(now: date))
        XCTAssertThrowsError(try other.inspect(now: date)) {
            guard case CameraMemoryStoreError.recoveryRequired = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try save(other, at: date))
        XCTAssertThrowsError(try other.delete(a.id))
        XCTAssertTrue(try other.hasStoredImage(for: a) != other.hasStoredImage(for: b))
        try other.recoverPendingDeletion()
        XCTAssertFalse(try other.hasPendingDeletion())
        XCTAssertFalse(try other.hasStoredImage(for: a))
        XCTAssertFalse(try other.hasStoredImage(for: b))
        XCTAssertTrue(try other.verifyConfirmedDeletion(snapshot))
        XCTAssertTrue(try other.load(now: date).isEmpty)
    }

    func testRecoveryRefusesConflictingIndexWithoutFurtherDeletion() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraMemoryStore(url: root, deletionFault: { _ in
            throw CameraMemoryStoreError.storageFailure
        })
        let recovery = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        _ = try save(store, at: date)
        _ = try save(store, at: date)
        let snapshot = try store.deletionSnapshot()
        XCTAssertThrowsError(try store.deleteConfirmedSnapshot(snapshot))
        let indexURL = root.appendingPathComponent("index.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existing = try decoder.decode([CameraMemoryFrame].self, from: Data(contentsOf: indexURL))
        let remaining = try XCTUnwrap(existing.first { try recovery.hasStoredImage(for: $0) })
        let conflict = CameraMemoryFrame(id: remaining.id, cameraID: remaining.cameraID,
                                         cameraName: "Changed", capturedAt: remaining.capturedAt,
                                         summary: remaining.summary, fileName: remaining.fileName,
                                         fileSize: remaining.fileSize)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([conflict]).write(to: indexURL)
        XCTAssertThrowsError(try recovery.recoverPendingDeletion()) {
            guard case CameraMemoryStoreError.recoveryConflict = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(try recovery.hasStoredImage(for: remaining))
        XCTAssertTrue(try recovery.hasPendingDeletion())
    }

    func testSingleFrameRecoveryPreservesOtherFrames() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupted = CameraMemoryStore(url: root, deletionFault: { _ in
            throw CameraMemoryStoreError.storageFailure
        })
        let recovery = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        let removed = try save(interrupted, at: date)
        let retained = try save(interrupted, at: date)
        XCTAssertThrowsError(try interrupted.delete(removed.id))
        try recovery.recoverPendingDeletion()
        XCTAssertEqual(try recovery.load(now: date), [retained])
        XCTAssertFalse(try recovery.hasStoredImage(for: removed))
        XCTAssertTrue(try recovery.hasStoredImage(for: retained))
    }

    func testVerifiedClearDetectsNewFramesAndRecreatedPaths() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        let frame = try save(store, at: date)
        let snapshot = try store.deletionSnapshot()
        try store.deleteConfirmedSnapshot(snapshot)
        XCTAssertTrue(try store.verifyConfirmedDeletion(snapshot))

        let imageURL = root.appendingPathComponent(frame.fileName)
        try FileManager.default.createSymbolicLink(atPath: imageURL.path, withDestinationPath: "missing")
        XCTAssertTrue(try store.hasStoredImage(for: frame))
        XCTAssertFalse(try store.verifyConfirmedDeletion(snapshot))
        try FileManager.default.removeItem(at: imageURL)
        _ = try save(store, at: date)
        XCTAssertFalse(try store.verifyConfirmedDeletion(snapshot))
    }

    func testSnapshotCannotBeUsedAgainstAnotherStore() throws {
        let firstRoot = try fixture()
        let secondRoot = try fixture()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let first = CameraMemoryStore(url: firstRoot)
        let second = CameraMemoryStore(url: secondRoot)
        let frame = try save(first, at: Date(timeIntervalSince1970: 2_000_000))
        let snapshot = try first.deletionSnapshot()
        try FileManager.default.copyItem(at: firstRoot.appendingPathComponent("index.json"),
                                         to: secondRoot.appendingPathComponent("index.json"))
        try FileManager.default.copyItem(at: firstRoot.appendingPathComponent(frame.fileName),
                                         to: secondRoot.appendingPathComponent(frame.fileName))
        XCTAssertThrowsError(try second.deleteConfirmedSnapshot(snapshot)) {
            guard case CameraMemoryStoreError.snapshotChanged = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try second.verifyConfirmedDeletion(snapshot))
        XCTAssertTrue(try second.hasStoredImage(for: frame))
    }

    func testNonRegularImageStopsDeletionBeforeAnyFramesAreRemoved() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraMemoryStore(url: root)
        let date = Date(timeIntervalSince1970: 2_000_000)
        _ = try save(store, at: date)
        _ = try save(store, at: date)
        let snapshot = try store.deletionSnapshot()
        let first = snapshot.frames[0]
        let secondURL = root.appendingPathComponent(snapshot.frames[1].fileName)
        try FileManager.default.removeItem(at: secondURL)
        try FileManager.default.createSymbolicLink(atPath: secondURL.path, withDestinationPath: "missing")

        XCTAssertThrowsError(try store.deleteConfirmedSnapshot(snapshot)) {
            guard case CameraMemoryStoreError.recoveryConflict = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(try store.hasPendingDeletion())
        XCTAssertTrue(try store.hasStoredImage(for: first))
        XCTAssertThrowsError(try store.recoverPendingDeletion())
        XCTAssertTrue(try store.hasStoredImage(for: first))
    }

    func testFailedPhysicalVerificationKeepsRecoveryJournal() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = CameraMemoryStore(url: root)
        let frame = try save(setup, at: Date(timeIntervalSince1970: 2_000_000))
        let interrupted = CameraMemoryStore(url: root, deletionFault: { _ in
            try Data("replacement".utf8).write(to: root.appendingPathComponent(frame.fileName))
        })
        let snapshot = try interrupted.deletionSnapshot()
        XCTAssertThrowsError(try interrupted.deleteConfirmedSnapshot(snapshot))
        XCTAssertTrue(try setup.hasPendingDeletion())
        XCTAssertTrue(try setup.hasStoredImage(for: frame))
        XCTAssertThrowsError(try setup.verifyConfirmedDeletion(snapshot))
        XCTAssertThrowsError(try setup.recoverPendingDeletion()) {
            guard case CameraMemoryStoreError.recoveryConflict = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(try setup.hasStoredImage(for: frame))
    }

    func testSeparateInstancesSerializeConcurrentSaves() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = [CameraMemoryStore(url: root), CameraMemoryStore(url: root)]
        let date = Date(timeIntervalSince1970: 2_000_000)
        let failures = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do { _ = try save(stores[index % 2], at: date) }
            catch {
                failures.lock()
                errors.append(error)
                failures.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(try stores[0].load(now: date).count, 40)
    }

    func testStoreWaitsForAnotherProcessHoldingLock() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraMemoryStore(url: root)
        _ = try store.deletionSnapshot()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-I", "-B", "-c",
            "import fcntl, os, sys; f=open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); os.write(1, b'R'); sys.stdin.buffer.read(1)",
            root.appendingPathComponent(".memory.lock").path]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("R".utf8))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? store.deletionSnapshot()
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.15), .timedOut)
        try input.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }
}
