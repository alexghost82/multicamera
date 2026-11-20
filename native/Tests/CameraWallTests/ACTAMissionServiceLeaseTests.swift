import Foundation
import XCTest
@testable import CameraWall

final class ACTAMissionServiceLeaseTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".mission-lease-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("missions.json")
    }

    private func python(_ code: String, lockURL: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", "-c", code, lockURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    func testOtherProcessCannotAcquireUntilOwnerReleases() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        var lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        let code = """
        import fcntl, os, sys
        f = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(7)
        """
        func attempt() throws -> Int32 {
            let process = try python(code, lockURL: lockURL)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try attempt(), 7)
        withExtendedLifetime(lease) {}
        lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url.deletingLastPathComponent()
            .appendingPathComponent("different.json")))
        XCTAssertEqual(try attempt(), 0)
        withExtendedLifetime(lease) {}
    }

    func testChildOwnerBlocksThenProcessExitReleases() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        let code = """
        import fcntl, os, sys
        f = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        print("ready", flush=True)
        sys.stdin.read(1)
        """
        let process = try python(code, lockURL: lockURL)
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        let output = try XCTUnwrap(process.standardOutput as? Pipe)
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "ready\n")
        XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: url))
        try input.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNotNil(try ACTAMissionServiceLease.acquire(storeURL: url))
    }

    func testUnsafeLockFilesFailClosed() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: url)
        XCTAssertThrowsError(try ACTAMissionServiceLease.acquire(storeURL: url))
    }

    func testStoreRejectsSymlinksAndHardLinks() throws {
        let url = try fixture()
        XCTAssertFalse(try ACTAMissionServiceLease.storeExistsAndIsRegular(url))
        let target = url.deletingLastPathComponent().appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data("fixture".utf8)))
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try ACTAMissionServiceLease.storeExistsAndIsRegular(url))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.linkItem(at: target, to: url)
        XCTAssertThrowsError(try ACTAMissionServiceLease.storeExistsAndIsRegular(url))
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(try ACTAMissionServiceLease.storeExistsAndIsRegular(target))
    }

    func testProcessTerminationReleasesLease() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        let code = """
        import fcntl, os, sys
        f = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        print("ready", flush=True)
        sys.stdin.read()
        """
        let process = try python(code, lockURL: lockURL)
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let output = try XCTUnwrap(process.standardOutput as? Pipe)
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "ready\n")
        XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: url))
        process.terminate()
        process.waitUntilExit()
        XCTAssertNotNil(try ACTAMissionServiceLease.acquire(storeURL: url))
    }

    func testSameProcessAndParentAliasShareLease() throws {
        let url = try fixture()
        let alias = url.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url.deletingLastPathComponent())
        let lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: alias.appendingPathComponent("missions.json")))
        withExtendedLifetime(lease) {}
    }

    func testInsecurePermissionsAndHardLinksFailClosed() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data(),
                                                     attributes: [.posixPermissions: 0o666]))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lockURL.path)
        XCTAssertThrowsError(try ACTAMissionServiceLease.acquire(storeURL: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        try FileManager.default.linkItem(at: lockURL, to: url.deletingLastPathComponent().appendingPathComponent("alias-lock"))
        XCTAssertThrowsError(try ACTAMissionServiceLease.acquire(storeURL: url))
    }

    @MainActor
    func testMutationGateAndStickyInvalidation() throws {
        let url = try fixture()
        let lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        let access = ACTAMissionServiceAccess(lease: lease)
        XCTAssertThrowsError(try access.requireRead())
        access.loaded()
        try access.requireRead()
        try access.withMutation {
            try access.requireActiveMutation()
            XCTAssertThrowsError(try access.requireRead())
            XCTAssertThrowsError(try access.withMutation {})
        }
        try access.requireRead()
        XCTAssertThrowsError(try access.withMutation {
            access.invalidate()
            XCTAssertThrowsError(try access.requireActiveMutation())
        })
        access.loaded()
        XCTAssertThrowsError(try access.requireRead())
        XCTAssertThrowsError(try access.withMutation {})
        XCTAssertNil(try ACTAMissionServiceLease.acquire(storeURL: url))
        withExtendedLifetime(access) {}
    }

    @MainActor
    func testReplacedLockInvalidatesServiceEvenIfRestored() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        let oldURL = url.deletingLastPathComponent().appendingPathComponent("old-lock")
        let lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        let access = ACTAMissionServiceAccess(lease: lease)
        access.loaded()
        try access.requireRead()

        try FileManager.default.moveItem(at: lockURL, to: oldURL)
        let competing = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        XCTAssertThrowsError(try access.requireRead())
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.moveItem(at: oldURL, to: lockURL)
        access.loaded()
        XCTAssertThrowsError(try access.withMutation { XCTFail("Invalidated service must not mutate") })
        withExtendedLifetime((access, competing)) {}
    }

    @MainActor
    func testLockLossDuringMutationFailsAndRemainsInvalid() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        let lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        let access = ACTAMissionServiceAccess(lease: lease)
        access.loaded()
        XCTAssertThrowsError(try access.withMutation {
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lockURL.path)
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        access.loaded()
        XCTAssertThrowsError(try access.requireRead())
    }

    @MainActor
    func testActiveMutationDetectsMissingLock() throws {
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        let oldURL = url.deletingLastPathComponent().appendingPathComponent("old-lock")
        let lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        let access = ACTAMissionServiceAccess(lease: lease)
        access.loaded()
        XCTAssertThrowsError(try access.withMutation {
            try FileManager.default.moveItem(at: lockURL, to: oldURL)
            try access.requireActiveMutation()
        })
        try FileManager.default.moveItem(at: oldURL, to: lockURL)
        access.loaded()
        XCTAssertThrowsError(try access.requireRead())
    }

    @MainActor
    func testThrowingMutationChecksLeaseWithoutPoisoningOrdinaryFailures() throws {
        struct ExpectedFailure: Error {}
        let url = try fixture()
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".missions.json.service.lock")
        let oldURL = url.deletingLastPathComponent().appendingPathComponent("old-lock")
        let lease = try XCTUnwrap(ACTAMissionServiceLease.acquire(storeURL: url))
        let access = ACTAMissionServiceAccess(lease: lease)
        access.loaded()
        XCTAssertThrowsError(try access.withMutation { throw ExpectedFailure() })
        try access.requireRead()
        XCTAssertThrowsError(try access.withMutation {
            try FileManager.default.moveItem(at: lockURL, to: oldURL)
            throw ExpectedFailure()
        })
        try FileManager.default.moveItem(at: oldURL, to: lockURL)
        access.loaded()
        XCTAssertThrowsError(try access.requireRead())
    }
}
