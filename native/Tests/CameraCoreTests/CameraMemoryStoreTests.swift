import XCTest
@testable import CameraCore

final class CameraMemoryStoreTests: XCTestCase {
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".memory-store-test-\(UUID().uuidString)")
    }

    func testMemorySamplingCadenceAndSummaryAreDeterministic() {
        XCTAssertTrue(CameraMemoryStore.isSampleDue(lastSampleAt: nil, now: 1000))
        XCTAssertFalse(CameraMemoryStore.isSampleDue(lastSampleAt: 1000, now: 1000 + 899))
        XCTAssertTrue(CameraMemoryStore.isSampleDue(lastSampleAt: 1000, now: 1000 + 900))
        XCTAssertFalse(CameraMemoryStore.isSampleDue(lastSampleAt: 1000, now: 999))
        XCTAssertEqual(CameraMemoryStore.summary(for: []), "No tracked objects at sample time.")
        XCTAssertEqual(CameraMemoryStore.summary(for: [
            DetectedObject(id: 0, label: "person", confidence: 0.9, box: .zero),
            DetectedObject(id: 1, label: "car", confidence: 0.8, box: .zero),
            DetectedObject(id: 2, label: "person", confidence: 0.7, box: .zero)
        ]), "Visible detection counts: car=1, person=2.")
    }

    func testMemorySamplingRequiresEveryPrivacyAndLifecycleGate() {
        func allowed(featureEnabled: Bool = true, retain: Bool = true, running: Bool = true,
                     connecting: Bool = false, fresh: Bool = true, busy: Bool = false) -> Bool {
            CameraMemorySamplingPolicy.shouldSample(
                featureEnabled: featureEnabled,
                retainFullFrames: retain,
                wallRunning: running,
                connecting: connecting,
                frameFresh: fresh,
                sampleInProgress: busy,
                lastSampleAt: nil,
                now: 1000
            )
        }

        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(featureEnabled: false))
        XCTAssertFalse(allowed(retain: false))
        XCTAssertFalse(allowed(running: false))
        XCTAssertFalse(allowed(connecting: true))
        XCTAssertFalse(allowed(fresh: false))
        XCTAssertFalse(allowed(busy: true))
    }

    func testMemoryFrameRoundTripsWithPrivatePermissions() throws {
        let directory = fixtureURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CameraMemoryStore(url: directory)
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let image = Data("sampled frame".utf8)

        let saved = try store.save(image, cameraID: UUID(), cameraName: "Entrance",
                                   capturedAt: capturedAt, summary: "One person", now: capturedAt)

        XCTAssertEqual(try store.load(now: capturedAt), [saved])
        XCTAssertEqual(try store.imageData(for: saved), image)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(saved.fileName).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("index.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExpiredMemoryFramesArePurgedAfterSevenDays() throws {
        let directory = fixtureURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CameraMemoryStore(url: directory)
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        let frame = try store.save(Data("sampled frame".utf8), cameraID: UUID(), cameraName: "Gate",
                                  capturedAt: capturedAt, summary: "No visible change", now: capturedAt)

        XCTAssertTrue(try store.load(now: capturedAt.addingTimeInterval(7 * 86_400 - 1)).contains(frame))
        XCTAssertTrue(try store.load(now: capturedAt.addingTimeInterval(7 * 86_400 + 1)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(frame.fileName).path))
    }

    func testInspectionDoesNotPruneExpiredFramesOrOrphans() throws {
        let directory = fixtureURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CameraMemoryStore(url: directory)
        let captured = Date(timeIntervalSince1970: 2_000_000)
        let expired = try store.save(Data("expired".utf8), cameraID: UUID(), cameraName: "Gate",
                                     capturedAt: captured, summary: "", now: captured)
        let orphan = directory.appendingPathComponent("orphan.jpg")
        try Data("orphan".utf8).write(to: orphan)
        let index = directory.appendingPathComponent("index.json")
        let before = try Data(contentsOf: index)
        let afterRetention = captured.addingTimeInterval(7 * 86_400 + 1)

        XCTAssertTrue(try store.inspect(now: afterRetention).isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(expired.fileName).path))
        XCTAssertEqual(try Data(contentsOf: orphan), Data("orphan".utf8))
    }

    func testInspectionDoesNotCreateStorageAndFailsWithoutLock() throws {
        let directory = fixtureURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CameraMemoryStore(url: directory)
        XCTAssertTrue(try store.inspect().isEmpty)
        XCTAssertThrowsError(try store.inspect(now: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.inspect())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".memory.lock").path))
    }

    func testFrameSizeIsBoundedAndDeleteRemovesImage() throws {
        let directory = fixtureURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CameraMemoryStore(url: directory)
        let capturedAt = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertThrowsError(try store.save(Data(repeating: 1, count: CameraMemoryStore.maximumFrameBytes + 1),
                                             cameraID: UUID(), cameraName: "Gate", capturedAt: capturedAt,
                                             summary: "", now: capturedAt))

        let frame = try store.save(Data("sampled frame".utf8), cameraID: UUID(), cameraName: "Gate",
                                   capturedAt: capturedAt, summary: "", now: capturedAt)
        try store.delete(frame.id)
        XCTAssertTrue(try store.load(now: capturedAt).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(frame.fileName).path))
    }

    func testFrameCountCapEvictsOldestFramesFirst() throws {
        let directory = fixtureURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CameraMemoryStore(url: directory)
        let start = Date(timeIntervalSince1970: 2_000_000)
        let cameraID = UUID()
        var firstID: UUID?
        var lastFrame: CameraMemoryFrame?

        for index in 0...CameraMemoryStore.maximumFrames {
            let frame = try store.save(
                Data("frame \(index)".utf8), cameraID: cameraID, cameraName: "Gate",
                capturedAt: start.addingTimeInterval(Double(index)), summary: "", now: start.addingTimeInterval(Double(index))
            )
            if index == 0 { firstID = frame.id }
            lastFrame = frame
        }

        let retained = try store.load(now: start.addingTimeInterval(Double(CameraMemoryStore.maximumFrames)))
        XCTAssertEqual(retained.count, CameraMemoryStore.maximumFrames)
        XCTAssertFalse(retained.contains(where: { $0.id == firstID }))
        XCTAssertTrue(retained.contains(lastFrame!))
    }
}