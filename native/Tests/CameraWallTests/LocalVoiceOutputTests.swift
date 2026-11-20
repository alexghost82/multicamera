import Combine
import Darwin
import XCTest
@testable import CameraWall

@MainActor
final class LocalVoiceOutputTests: XCTestCase {
    private final class Child: LocalVoiceOutputProcess {
        var stops = 0
        func stop() { stops += 1 }
    }

    private final class Capture: LocalVoiceCapture {
        func finish() {}
        func cancel() {}
    }

    func testInputAndSpeechShareLeaseUntilCaptureOrChildStops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-voice-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.lock")
        let input = LocalVoiceInput(speechPermission: { true }, microphonePermission: { true },
            makeCapture: { _, _ in Capture() }, acquireAudioLease: { try LocalVoiceAudioLease.acquire(url: url) })
        let child = Child()
        var complete: (@MainActor (String?) -> Void)?
        let output = LocalVoiceOutput(acquireAudioLease: { try LocalVoiceAudioLease.acquire(url: url) }) {
            _, _, callback in complete = callback; return child
        }
        let attempt = try XCTUnwrap(input.start(localeIdentifier: "en"))
        await attempt.value
        output.speak("hello", localeIdentifier: "en", owner: UUID())
        XCTAssertFalse(output.isBusy)
        XCTAssertNotNil(output.errorMessage)
        input.cancel()

        output.speak("hello", localeIdentifier: "en", owner: UUID())
        XCTAssertTrue(output.isBusy)
        XCTAssertNil(input.start(localeIdentifier: "en"))
        XCTAssertNotNil(input.errorMessage)
        output.stopAll()
        XCTAssertEqual(child.stops, 1)
        XCTAssertNil(input.start(localeIdentifier: "en"))
        complete?(nil)
        let retry = try XCTUnwrap(input.start(localeIdentifier: "en"))
        await retry.value
        input.cancel()
    }

    func testUnsafeVoiceLeaseFileFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-voice-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.lock")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertThrowsError(try LocalVoiceAudioLease.acquire(url: url))
    }

    func testVoiceLeaseExcludesAnotherProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-voice-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.lock")
        var lease: LocalVoiceAudioLease? = try LocalVoiceAudioLease.acquire(url: url)
        func subprocessStatus() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
                import fcntl, sys
                with open(sys.argv[1], 'r+') as f:
                    try:
                        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        sys.exit(42)
                """, url.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertNotNil(lease)
        XCTAssertEqual(try subprocessStatus(), 42)
        lease = nil
        XCTAssertEqual(try subprocessStatus(), 0)
    }

    func testChildHoldsReadOnlyLeaseAfterParentReleasesIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-voice-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.lock")
        var lease: LocalVoiceAudioLease? = try LocalVoiceAudioLease.acquire(url: url)
        let childLease = try XCTUnwrap(lease).duplicateForChild()
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import os, sys
            try:
                os.write(2, b"private text")
                sys.exit(1)
            except OSError:
                pass
            sys.stdin.buffer.read(1)
            """]
        process.standardInput = input
        process.standardError = childLease
        try process.run()
        try childLease.close()
        lease = nil
        XCTAssertThrowsError(try LocalVoiceAudioLease.acquire(url: url))
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        XCTAssertNoThrow(try LocalVoiceAudioLease.acquire(url: url))
    }

    func testChildLeaseSurvivesParentProcessTermination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-voice-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.lock")
        let parent = Process()
        let input = Pipe()
        let output = Pipe()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-c", """
            import fcntl, os, signal, subprocess, sys
            fd = os.open(sys.argv[1], os.O_RDONLY | os.O_CREAT, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            subprocess.Popen([sys.executable, "-c", "import os; os.read(0, 1)"],
                             stdin=sys.stdin, stdout=subprocess.DEVNULL, stderr=fd)
            print("ready", flush=True)
            signal.pause()
            """, url.path]
        parent.standardInput = input
        parent.standardOutput = output
        parent.standardError = FileHandle.nullDevice
        XCTAssertNotEqual(fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1), -1)
        try parent.run()
        defer {
            try? input.fileHandleForWriting.close()
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
        }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(ready, Data("ready\n".utf8))
        guard ready == Data("ready\n".utf8) else { return }
        XCTAssertEqual(kill(parent.processIdentifier, SIGKILL), 0)
        parent.waitUntilExit()
        XCTAssertThrowsError(try LocalVoiceAudioLease.acquire(url: url))
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        var acquired: LocalVoiceAudioLease?
        while acquired == nil && Date() < deadline {
            do { acquired = try LocalVoiceAudioLease.acquire(url: url) }
            catch { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertNotNil(acquired)
    }

    func testSpokenReviewStatusDistinguishesVerifiedResultAndIncludesOperationID() {
        let id = UUID()
        for locale in ["en-US", "ru-RU", "he-IL"] {
            let verified = LocalVoiceReviewStatus.message(verified: true, operationID: id, localeIdentifier: locale)
            let unverified = LocalVoiceReviewStatus.message(verified: false, operationID: id, localeIdentifier: locale)
            XCTAssertTrue(verified.contains(id.uuidString))
            XCTAssertTrue(unverified.contains(id.uuidString))
            XCTAssertNotEqual(verified, unverified)
        }
        XCTAssertTrue(LocalVoiceReviewStatus.message(verified: false, operationID: id, localeIdentifier: "en")
            .contains("not verified"))
    }

    func testStopIsOwnedAndWaitsForChildExit() throws {
        let child = Child()
        var complete: (@MainActor (String?) -> Void)?
        let output = LocalVoiceOutput { _, _, callback in
            complete = callback
            return child
        }
        let owner = UUID()
        output.speak("Hello", localeIdentifier: "en-US", owner: owner)
        output.stop(owner: UUID())
        XCTAssertEqual(child.stops, 0)
        output.stop(owner: owner)
        output.stop(owner: owner)
        XCTAssertEqual(child.stops, 1)
        XCTAssertTrue(output.isBusy)
        complete?("Cancelled")
        XCTAssertFalse(output.isBusy)
        XCTAssertNil(output.errorMessage)
    }

    func testLateCompletionDoesNotAffectNextSpeech() throws {
        var callbacks: [@MainActor (String?) -> Void] = []
        let output = LocalVoiceOutput { _, _, callback in
            callbacks.append(callback)
            return Child()
        }
        output.speak("First", localeIdentifier: "ru-RU", owner: UUID())
        callbacks[0](nil)
        output.speak("Second", localeIdentifier: "he-IL", owner: UUID())
        callbacks[0]("stale error")
        XCTAssertTrue(output.isBusy)
        XCTAssertNil(output.errorMessage)
        callbacks[1](nil)
        XCTAssertFalse(output.isBusy)
    }

    func testAppShutdownStopsSpeechRegardlessOfOwner() {
        let child = Child()
        let output = LocalVoiceOutput { _, _, _ in child }
        output.speak("Hello", localeIdentifier: "en", owner: UUID())
        output.stopAll()
        output.stopAll()
        XCTAssertEqual(child.stops, 1)
    }

    func testInvalidTextAndLanguageFailWithoutLaunching() {
        var launches = 0
        let output = LocalVoiceOutput { _, _, _ in
            launches += 1
            return Child()
        }
        output.speak(" ", localeIdentifier: "en", owner: UUID())
        XCTAssertNotNil(output.errorMessage)
        output.speak(String(repeating: "x", count: 8_001), localeIdentifier: "en", owner: UUID())
        XCTAssertNotNil(output.errorMessage)
        output.speak("hello", localeIdentifier: "fr", owner: UUID())
        XCTAssertEqual(output.errorMessage, "Speech is unavailable for this language.")
        XCTAssertEqual(launches, 0)
    }

    func testReentrantStopDuringStartStopsChild() {
        let child = Child()
        let owner = UUID()
        let output = LocalVoiceOutput { _, _, _ in child }
        let subscription = output.$isBusy.dropFirst().sink { busy in
            if busy {
                XCTAssertTrue(output.isAttemptActive)
                XCTAssertTrue(output.isOwned(by: owner))
                output.stop(owner: owner)
            }
        }
        output.speak("hello", localeIdentifier: "en", owner: owner)
        XCTAssertEqual(child.stops, 1)
        withExtendedLifetime(subscription) {}
    }

    func testSynchronousCompletionDoesNotLeaveAStaleChild() {
        let child = Child()
        let output = LocalVoiceOutput { _, _, callback in
            callback(nil)
            return child
        }
        output.speak("hello", localeIdentifier: "en", owner: UUID())
        XCTAssertFalse(output.isBusy)
        XCTAssertNil(output.errorMessage)
        output.speak("again", localeIdentifier: "ru", owner: UUID())
        XCTAssertFalse(output.isBusy)
    }

    func testRealEnginePipelineWithoutPlayback() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/espeak-ng") ||
              FileManager.default.isExecutableFile(atPath: "/usr/local/bin/espeak-ng") else {
            throw XCTSkip("eSpeak NG is not installed")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-voice-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.lock")
        var lease: LocalVoiceAudioLease? = try LocalVoiceAudioLease.acquire(url: url)
        let finished = expectation(description: "synthesis completes")
        let child = try ESpeakVoiceOutputProcess(text: "Synthetic speech test", voice: "en-us",
            renderWithoutPlayback: true, audioLease: lease) { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        lease = nil
        XCTAssertThrowsError(try LocalVoiceAudioLease.acquire(url: url))
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertNoThrow(try LocalVoiceAudioLease.acquire(url: url))
        withExtendedLifetime(child) {}
    }

    func testRealEngineCanStopDuringInput() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/espeak-ng") ||
              FileManager.default.isExecutableFile(atPath: "/usr/local/bin/espeak-ng") else {
            throw XCTSkip("eSpeak NG is not installed")
        }
        let finished = expectation(description: "stopped process exits")
        let child = try ESpeakVoiceOutputProcess(text: String(repeating: "test ", count: 1_500),
            voice: "en-us", renderWithoutPlayback: true) { _ in finished.fulfill() }
        child.stop()
        await fulfillment(of: [finished], timeout: 10)
    }

    func testEngineSandboxDeniesNetwork() throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", ESpeakVoiceOutputProcess.sandboxProfile,
                             "/usr/bin/nc", "-vz", "-G", "1", "127.0.0.1", "1"]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(message.contains("Operation not permitted"), message)
    }
}
