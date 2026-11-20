import Darwin
import Foundation
import XCTest

final class RelayLeaseGuardianTests: XCTestCase {
    func testParentDeathRetainsLeaseUntilOwnedChildExits() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_GUARDIAN_TEST_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: executable),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Set CAMERA_GUARDIAN_TEST_EXECUTABLE to the isolated guardian driver.")
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".relay-guardian-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let relay = directory.appendingPathComponent("relay")
        let config = directory.appendingPathComponent("config.json")
        let lock = directory.appendingPathComponent("runtime.lock")
        let ready = directory.appendingPathComponent("ready")
        let signalled = directory.appendingPathComponent("signalled")
        let release = directory.appendingPathComponent("release")
        let script = """
            #!/usr/bin/python3
            import os, signal, time
            d = os.path.dirname(__file__)
            signal.signal(signal.SIGTERM, lambda *_: open(os.path.join(d, 'signalled'), 'w').close())
            open(os.path.join(d, 'ready'), 'w').close()
            while not os.path.exists(os.path.join(d, 'release')):
                time.sleep(0.01)
            """
        try Data(script.utf8).write(to: relay)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: relay.path)
        try Data("{}".utf8).write(to: config)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-c", """
            import fcntl, os, subprocess, sys, time
            lock = open(sys.argv[1], 'a+')
            fcntl.flock(lock, fcntl.LOCK_EX)
            subprocess.Popen([sys.argv[2], '--relay-lease-guardian', str(os.getpid()),
                              sys.argv[3], sys.argv[4]], stdin=lock,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            while True: time.sleep(1)
            """, lock.path, executable, relay.path, config.path]
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer {
            try? Data().write(to: release)
            if parent.isRunning { parent.terminate() }
            parent.waitUntilExit()
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        XCTAssertEqual(kill(parent.processIdentifier, SIGKILL), 0)
        parent.waitUntilExit()
        try await wait { FileManager.default.fileExists(atPath: signalled.path) }
        let fd = open(lock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_SH | LOCK_NB), 0)
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        try Data().write(to: release)
        try await wait { flock(fd, LOCK_EX | LOCK_NB) == 0 }
        _ = flock(fd, LOCK_UN)
        try FileManager.default.removeItem(at: directory)
    }
}
