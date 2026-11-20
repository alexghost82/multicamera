import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private final class DrainScreenStream: ScreenCaptureLifecycleStream {
    private let lock = NSLock()
    private var startCompletion: ((Error?) -> Void)?
    private var stopCompletions: [(Error?) -> Void] = []
    func start(completion: @escaping (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        startCompletion = completion
    }
    func stop(completion: @escaping (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        stopCompletions.append(completion)
    }
    func finishStart() {
        lock.lock()
        let callback = startCompletion
        startCompletion = nil
        lock.unlock()
        callback?(nil)
    }
    func finishStops(error: Error? = nil) {
        lock.lock()
        let callbacks = stopCompletions
        stopCompletions.removeAll()
        lock.unlock()
        callbacks.forEach { $0(error) }
    }
    var stops: Int {
        lock.lock(); defer { lock.unlock() }
        return stopCompletions.count
    }
}

@MainActor
final class ScreenCaptureDrainTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testDrainWaitsForLateStartAndBothStopCallbacks() async throws {
        let lifecycle = ScreenCaptureLifecycle()
        let stream = DrainScreenStream()
        await lifecycle.start(makeStream: { stream }, onResult: { _ in })
        var finished = false
        let drain = Task { @MainActor in
            try await lifecycle.stopAndWait()
            finished = true
        }
        try await waitUntil { stream.stops == 1 }
        stream.finishStops()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        stream.finishStart()
        try await waitUntil { stream.stops == 1 }
        XCTAssertFalse(finished)
        stream.finishStops()
        try await drain.value
        XCTAssertTrue(finished)
    }

    func testStopFailureFailsDrain() async throws {
        let lifecycle = ScreenCaptureLifecycle()
        let stream = DrainScreenStream()
        let started = expectation(description: "start callback processed")
        await lifecycle.start(makeStream: { stream }, onResult: { _ in started.fulfill() })
        stream.finishStart()
        await fulfillment(of: [started], timeout: 1)
        let drain = Task { try await lifecycle.stopAndWait() }
        try await waitUntil { stream.stops == 1 }
        stream.finishStops(error: CocoaError(.fileWriteUnknown))
        do {
            try await drain.value
            XCTFail("Failed stop must not be reported as drained")
        } catch { }
    }

    func testDrainWaitsForSuspendedFactoryAndNeverStartsItsLateStream() async throws {
        let lifecycle = ScreenCaptureLifecycle()
        let stream = DrainScreenStream()
        var factory: CheckedContinuation<Void, Never>?
        var drained = false
        let startup = Task { @MainActor in
            await lifecycle.start(makeStream: {
                await withCheckedContinuation { factory = $0 }
                return stream
            }, onResult: { _ in XCTFail("Stopped factory must not publish") })
        }
        try await waitUntil { factory != nil }
        let drain = Task { @MainActor in
            try await lifecycle.stopAndWait()
            drained = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained)
        factory?.resume()
        await startup.value
        try await drain.value
        XCTAssertTrue(drained)
        XCTAssertEqual(stream.stops, 0)
    }

    func testDrainWaitsForSuspendedFactoryThatThrows() async throws {
        let lifecycle = ScreenCaptureLifecycle()
        var factory: CheckedContinuation<Void, Never>?
        var drained = false
        let startup = Task { @MainActor in
            await lifecycle.start(makeStream: {
                await withCheckedContinuation { factory = $0 }
                throw CocoaError(.fileReadUnknown)
            }, onResult: { _ in XCTFail("Stopped factory must not publish") })
        }
        try await waitUntil { factory != nil }
        let drain = Task { @MainActor in
            try await lifecycle.stopAndWait()
            drained = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained)
        factory?.resume()
        await startup.value
        try await drain.value
        XCTAssertTrue(drained)
    }

    func testDomainLeaseExcludesOtherProcessUntilFactoryDrainCompletes() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CAMERA_COORDINATION_TEST_DRIVER"] else {
            throw XCTSkip("Set CAMERA_COORDINATION_TEST_DRIVER to the synthetic participant.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".screen-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cameras.json")
        var memory = WallConfiguration()
        let domain = ACTACoordinatedCameraDomain(url: url, readMemory: { memory },
                                                  installMemory: { memory = $0 })
        try domain.beginRuntime()
        let lifecycle = ScreenCaptureLifecycle()
        let stream = DrainScreenStream()
        var factory: CheckedContinuation<Void, Never>?
        let startup = Task { @MainActor in
            await lifecycle.start(makeStream: {
                await withCheckedContinuation { factory = $0 }
                return stream
            }, onResult: { _ in XCTFail("Stopped factory must not publish") })
        }
        try await waitUntil { factory != nil }
        let drain = Task { @MainActor in
            try await domain.endRuntime { try await lifecycle.stopAndWait() }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(try probe(executable, url), 2)
        factory?.resume()
        await startup.value
        try await drain.value
        XCTAssertEqual(try probe(executable, url), 0)
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
