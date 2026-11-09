import XCTest
import CoreGraphics
import SQLite3
@testable import CameraCore

final class IdentityTrackingTests: XCTestCase {
    func testAutomaticScansPersistAcrossReopenAndShareExistingRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let record = CameraScanRecord(cameraID: UUID(), cameraName: "Synthetic entrance", observedAt: now, answer: "A vehicle is visible.")
        let store = try LocalTrackingStore(url: url, now: now)
        let trackID = UUID()
        try store.record(DetectedObject(id: 0, label: "car", confidence: 0.9, box: .zero, trackID: trackID),
            cameraID: record.cameraID, cameraName: record.cameraName, at: now)
        try store.saveAutomaticScan(record)
        let reopened = try LocalTrackingStore(url: url, now: now)
        XCTAssertEqual(try reopened.automaticScans(now: now), [record])
        XCTAssertEqual(try reopened.recentTracks().map(\.trackID), [trackID])
        XCTAssertThrowsError(try store.saveAutomaticScan(record))
        XCTAssertEqual(try reopened.automaticScans(now: now), [record])
        XCTAssertEqual(try reopened.purgeExpired(now: now.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertTrue(try reopened.automaticScans(now: now.addingTimeInterval(31 * 86_400)).isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testAutomaticScanPagesCoverRetainedHistoryAndRejectInvalidData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000.125)
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("history.sqlite3"), now: now)
        var inserted: [CameraScanRecord] = []
        for index in 0..<7 {
            let record = CameraScanRecord(cameraID: UUID(), cameraName: "Synthetic camera", observedAt: now.addingTimeInterval(Double(-index)), answer: "Summary \(index)")
            inserted.append(record)
            try store.saveAutomaticScan(record)
        }
        var read: [CameraScanRecord] = []
        try store.forEachAutomaticScanPage(pageSize: 2, now: now) { read += $0 }
        XCTAssertEqual(read, inserted)
        XCTAssertEqual(try store.automaticScans(limit: 3, now: now), Array(inserted.prefix(3)))
        XCTAssertThrowsError(try store.saveAutomaticScan(CameraScanRecord(cameraID: UUID(), cameraName: "Camera", answer: " ")))
        XCTAssertThrowsError(try store.saveAutomaticScan(CameraScanRecord(cameraID: UUID(), cameraName: "Camera", answer: String(repeating: "a", count: 20_001))))
        XCTAssertEqual(try store.automaticScans(now: now).count, 7)
        var snapshot: [CameraScanRecord] = []
        try store.forEachAutomaticScanPage(pageSize: 2, now: now) { page in
            snapshot += page
            if snapshot.count == 2 {
                try store.saveAutomaticScan(CameraScanRecord(cameraID: UUID(), cameraName: "New camera", observedAt: now, answer: "Inserted during read"))
            }
        }
        XCTAssertEqual(snapshot, inserted, "New inserts must not move page boundaries or enter an in-progress query")
    }

    func testDescriptionRejectsEveryTruncatedFencedPrefixWithoutTrap() throws {
        let json = #"{"summary":"Visible dark coat","overallConfidence":0.8,"attributes":{}}"#
        let fenced = "```json\n\(json)\n```"
        let expected = try XCTUnwrap(TrackedObjectDescription.parse(json))
        XCTAssertEqual(TrackedObjectDescription.parse(fenced), expected)
        for end in fenced.indices {
            let prefix = String(fenced[..<end])
            XCTAssertNil(TrackedObjectDescription.parse(prefix), prefix)
        }
        for response in ["```", "```json{", "```json\n```", fenced + " trailing"] {
            XCTAssertNil(TrackedObjectDescription.parse(response), response)
        }
    }

    func testVehicleTextEvidencePersistsAndFollowsTrackDeletionAndRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.sqlite3")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try LocalTrackingStore(url: url, now: now)
        let vehicleID = UUID()
        _ = try store.record(DetectedObject(id: 0, label: "car", confidence: 0.9, box: .zero, trackID: vehicleID),
                             cameraID: UUID(), cameraName: "Garage", at: now)
        let evidence = VehicleTextEvidence(
            trackID: vehicleID, candidates: [VehicleTextCandidate(text: " ab12 ", confidence: 0.9)],
            readAt: now, cropSHA256: String(repeating: "a", count: 64)
        )
        try store.saveVehicleTextEvidence(evidence)
        let reopened = try LocalTrackingStore(url: url, now: now)
        XCTAssertEqual(try reopened.vehicleTextEvidence(for: vehicleID), evidence)
        XCTAssertEqual(evidence.candidates.first?.text, "AB12")
        try reopened.clearVehicleTextEvidence(for: vehicleID)
        XCTAssertNil(try store.vehicleTextEvidence(for: vehicleID))
        try store.saveVehicleTextEvidence(evidence)
        XCTAssertEqual(try store.purgeExpired(now: now.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertNil(try reopened.vehicleTextEvidence(for: vehicleID))
    }

    func testVehicleTextEvidenceRejectsPeopleMissingTracksAndMalformedDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let trackID = UUID()
        let evidence = VehicleTextEvidence(trackID: trackID, candidates: [], cropSHA256: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try store.saveVehicleTextEvidence(evidence))
        _ = try store.record(DetectedObject(id: 0, label: "person", confidence: 0.9, box: .zero, trackID: trackID),
                             cameraID: UUID(), cameraName: "Gate")
        XCTAssertThrowsError(try store.saveVehicleTextEvidence(evidence))
        XCTAssertThrowsError(try store.saveVehicleTextEvidence(VehicleTextEvidence(trackID: trackID, candidates: [], cropSHA256: "bad")))
        let vehicleID = UUID()
        _ = try store.record(DetectedObject(id: 1, label: "truck", confidence: 0.9, box: .zero, trackID: vehicleID),
                             cameraID: UUID(), cameraName: "Garage")
        try store.saveVehicleTextEvidence(VehicleTextEvidence(trackID: vehicleID, candidates: [], cropSHA256: String(repeating: "a", count: 64)))
        try store.delete(trackID: vehicleID)
        XCTAssertNil(try store.vehicleTextEvidence(for: vehicleID))
    }

    func testMotionPredictionPreservesTrackAfterSkippedDetectionFrame() throws {
        var assigner = ObjectTrackAssigner(maximumGap: 3, minimumIoU: 0.25, motionPredictionEnabled: true)
        let start = Date(timeIntervalSince1970: 100)
        func object(_ position: CGFloat, confidence: Double = 0.9) -> DetectedObject {
            DetectedObject(id: 0, label: "person", confidence: confidence,
                           box: CGRect(x: position, y: 0.1, width: 0.12, height: 0.3))
        }
        let first = assigner.assign([object(0.1)], at: start)[0]
        let second = assigner.assign([object(0.16)], at: start.addingTimeInterval(1))[0]
        XCTAssertEqual(second.trackID, first.trackID)
        XCTAssertTrue(assigner.assign([], at: start.addingTimeInterval(2)).isEmpty)
        let afterGap = assigner.assign([object(0.28, confidence: 0.2)], at: start.addingTimeInterval(3))[0]
        XCTAssertEqual(afterGap.trackID, try XCTUnwrap(first.trackID))
        let strongAgain = assigner.assign([object(0.34)], at: start.addingTimeInterval(4))[0]
        XCTAssertEqual(strongAgain.trackID, first.trackID)
    }

    func testMotionPredictionSeparatesCrossingTracksRegardlessOfDetectionOrder() {
        var assigner = ObjectTrackAssigner(maximumGap: 4, minimumIoU: 0.2, motionPredictionEnabled: true)
        let start = Date(timeIntervalSince1970: 100)
        func object(id: Int, position: CGFloat) -> DetectedObject {
            DetectedObject(id: id, label: "car", confidence: 0.9,
                           box: CGRect(x: position, y: 0.1, width: 0.18, height: 0.2))
        }
        let first = assigner.assign([object(id: 0, position: 0.1), object(id: 1, position: 0.65)], at: start)
        _ = assigner.assign([object(id: 0, position: 0.18), object(id: 1, position: 0.57)], at: start.addingTimeInterval(1))
        let crossed = assigner.assign(
            [object(id: 1, position: 0.33), object(id: 0, position: 0.42)], at: start.addingTimeInterval(4)
        )
        XCTAssertEqual(crossed[0].trackID, first[1].trackID)
        XCTAssertEqual(crossed[1].trackID, first[0].trackID)
    }

    func testMotionPredictionIsOptInAndCanRecoverAnAbruptStop() {
        let start = Date(timeIntervalSince1970: 100)
        func object(_ position: CGFloat) -> DetectedObject {
            DetectedObject(id: 0, label: "person", confidence: 0.9,
                           box: CGRect(x: position, y: 0.1, width: 0.18, height: 0.3))
        }
        var basic = ObjectTrackAssigner(maximumGap: 3, minimumIoU: 0.2)
        XCTAssertFalse(basic.motionPredictionEnabled)
        let basicFirst = basic.assign([object(0.1)], at: start)[0]
        _ = basic.assign([object(0.2)], at: start.addingTimeInterval(1))
        let basicAfterGap = basic.assign([object(0.4)], at: start.addingTimeInterval(3))[0]
        XCTAssertNotEqual(basicAfterGap.trackID, basicFirst.trackID)

        var enhanced = ObjectTrackAssigner(maximumGap: 3, minimumIoU: 0.2, motionPredictionEnabled: true)
        let first = enhanced.assign([object(0.1)], at: start)[0]
        _ = enhanced.assign([object(0.2)], at: start.addingTimeInterval(1))
        let stopped = enhanced.assign([object(0.2)], at: start.addingTimeInterval(3))[0]
        XCTAssertEqual(stopped.trackID, first.trackID)
        XCTAssertEqual(enhanced.assign([object(0.2)], at: start.addingTimeInterval(4))[0].trackID, first.trackID)
    }

    func testInvalidConfidenceAndTimestampDoNotCreateOrCorruptTracks() {
        var assigner = ObjectTrackAssigner()
        let start = Date(timeIntervalSince1970: 100)
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
        let object = DetectedObject(id: 0, label: "person", confidence: 0.9, box: box)
        let first = assigner.assign([object], at: start)[0]
        let invalid = assigner.assign([object], at: Date(timeIntervalSince1970: .nan))[0]
        XCTAssertNil(invalid.trackID)
        for confidence in [Double.nan, .infinity, -1, 2] {
            let result = assigner.assign([
                DetectedObject(id: 0, label: "person", confidence: confidence, box: box)
            ], at: start.addingTimeInterval(0.5))
            XCTAssertNil(result[0].trackID)
        }
        XCTAssertEqual(assigner.assign([object], at: start.addingTimeInterval(1))[0].trackID, first.trackID)
    }

    func testRecentTrackPagesCoverHistoryInDeterministicOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let cameraID = UUID()
        let timestamp = Date(timeIntervalSince1970: 2_000_000)
        let trackIDs = (0..<7).map { _ in UUID() }

        for trackID in trackIDs {
            let object = DetectedObject(id: 0, label: "person", confidence: 0.8,
                                        box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
                                        trackID: trackID)
            _ = try store.record(object, cameraID: cameraID, cameraName: "Gate", at: timestamp)
        }

        var pages: [[UUID]] = []
        try store.forEachRecentTrackPage(pageSize: 2) { page in
            XCTAssertLessThanOrEqual(page.count, 2)
            pages.append(page.map(\.trackID))
        }

        XCTAssertEqual(pages.count, 4)
        XCTAssertEqual(pages.flatMap { $0 }, try store.recentTracks(limit: 20).map(\.trackID))
        XCTAssertEqual(Set(pages.flatMap { $0 }), Set(trackIDs))
    }

    func testRecentTrackPageFailureClosesReadConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let object = DetectedObject(id: 0, label: "person", confidence: 0.8,
                        box: .zero, trackID: UUID())
        _ = try store.record(object, cameraID: UUID(), cameraName: "Gate")

        XCTAssertThrowsError(try store.forEachRecentTrackPage { _ in
            throw CancellationError()
        })
        XCTAssertNoThrow(try store.recentTracks())
    }

    func testRecentTrackPagesDoNotBlockWritesOrIncludeLaterRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let cameraID = UUID()
        let first = DetectedObject(id: 0, label: "person", confidence: 0.8,
                                   box: .zero, trackID: UUID())
        let second = DetectedObject(id: 1, label: "person", confidence: 0.8,
                                    box: .zero, trackID: UUID())
        let insertedDuringScan = DetectedObject(id: 2, label: "person", confidence: 0.8,
                                                box: .zero, trackID: UUID())
        _ = try store.record(first, cameraID: cameraID, cameraName: "Gate")
        _ = try store.record(second, cameraID: cameraID, cameraName: "Gate")
        var scannedIDs: [UUID] = []
        var didInsert = false

        try store.forEachRecentTrackPage(pageSize: 1) { page in
            scannedIDs.append(contentsOf: page.map(\.trackID))
            if !didInsert {
                _ = try store.record(insertedDuringScan, cameraID: cameraID, cameraName: "Gate")
                didInsert = true
            }
        }

        XCTAssertEqual(Set(scannedIDs), [first.trackID, second.trackID])
        XCTAssertEqual(try store.recentTracks(limit: 10).count, 3)
    }

    func testDescriptionParserRequiresValidConfidenceAndEvidenceShape() throws {
        let response = """
            ```json
            {"summary":"Dark jacket","overallConfidence":0.8,"attributes":{"clothing":{"value":"dark jacket","confidence":0.9,"evidence":"Visible dark fabric on torso"}}}
            ```
            """
        let description = try XCTUnwrap(TrackedObjectDescription.parse(response))
        XCTAssertEqual(description.summary, "Dark jacket")
        XCTAssertEqual(description.attributes["clothing"]?.evidence, "Visible dark fabric on torso")
        XCTAssertNil(TrackedObjectDescription.parse("""
            {"summary":"x","overallConfidence":1.5,"attributes":{}}
            """))
        XCTAssertNil(TrackedObjectDescription.parse("not json"))
    }

    func testExistingTrackingDatabaseMigratesDescriptionColumns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tracking.sqlite3")
        let trackID = UUID()
        let cameraID = UUID()
        var legacyDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &legacyDB), SQLITE_OK)
        let schema = """
            CREATE TABLE tracked_objects (
                track_id TEXT PRIMARY KEY, camera_id TEXT NOT NULL, camera_name TEXT NOT NULL,
                label TEXT NOT NULL, first_seen REAL NOT NULL, last_seen REAL NOT NULL,
                observation_count INTEGER NOT NULL, best_confidence REAL NOT NULL,
                box_x REAL NOT NULL, box_y REAL NOT NULL, box_width REAL NOT NULL,
                box_height REAL NOT NULL, crop_path TEXT
            );
            INSERT INTO tracked_objects VALUES (
                '\(trackID.uuidString)', '\(cameraID.uuidString)', 'Gate', 'person',
                1000, 1001, 2, 0.9, 0.1, 0.2, 0.3, 0.4, NULL
            );
            """
        XCTAssertEqual(sqlite3_exec(legacyDB, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacyDB)

        let store = try LocalTrackingStore(url: url, now: Date(timeIntervalSince1970: 1002))
        let record = try XCTUnwrap(store.recentTracks().first)
        XCTAssertEqual(record.trackID, trackID)
        XCTAssertNil(record.description)
        let description = try XCTUnwrap(TrackedObjectDescription.parse("""
            {"summary":"Visible dark coat","overallConfidence":0.7,"attributes":{}}
            """))
        try store.saveDescription(description, for: trackID)
        XCTAssertEqual(try store.recentTracks().first?.description, description)
    }

    func testOverlappingDetectionKeepsPerCameraTrackID() {
        var assigner = ObjectTrackAssigner(maximumGap: 2, minimumIoU: 0.2)
        let first = assigner.assign([
            DetectedObject(id: 0, label: "person", confidence: 0.9,
                           box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4))
        ], at: Date(timeIntervalSince1970: 100))
        let next = assigner.assign([
            DetectedObject(id: 4, label: "person", confidence: 0.8,
                           box: CGRect(x: 0.11, y: 0.1, width: 0.2, height: 0.4))
        ], at: Date(timeIntervalSince1970: 101))

        XCTAssertNotNil(first.first?.trackID)
        XCTAssertEqual(first.first?.trackID, next.first?.trackID)
        XCTAssertEqual(next.first?.id, 4)
    }

    func testLowConfidenceDetectionPreservesButDoesNotCreateTrack() {
        var assigner = ObjectTrackAssigner(maximumGap: 2, minimumIoU: 0.2)
        let start = Date(timeIntervalSince1970: 100)
        let first = assigner.assign([
            DetectedObject(id: 0, label: "person", confidence: 0.8,
                           box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4))
        ], at: start)
        let originalTrackID = first[0].trackID
        let weakMatch = assigner.assign([
            DetectedObject(id: 1, label: "person", confidence: 0.2,
                           box: CGRect(x: 0.11, y: 0.1, width: 0.2, height: 0.4))
        ], at: start.addingTimeInterval(0.5))
        let weakUnmatched = assigner.assign([
            DetectedObject(id: 2, label: "person", confidence: 0.2,
                           box: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.4))
        ], at: start.addingTimeInterval(0.6))
        let laterStrong = assigner.assign([
            DetectedObject(id: 3, label: "person", confidence: 0.75,
                           box: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.4))
        ], at: start.addingTimeInterval(0.7))

        XCTAssertEqual(weakMatch.first?.trackID, originalTrackID)
        XCTAssertNil(weakUnmatched.first?.trackID)
        XCTAssertNotEqual(laterStrong.first?.trackID, originalTrackID)
        XCTAssertNotNil(laterStrong.first?.trackID)
    }

    func testTrackIsNotReusedAcrossClassOrLongGap() {
        var assigner = ObjectTrackAssigner(maximumGap: 1, minimumIoU: 0.2)
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4)
        let first = assigner.assign([
            DetectedObject(id: 0, label: "person", confidence: 0.9, box: box)
        ], at: Date(timeIntervalSince1970: 100))[0]
        let differentClass = assigner.assign([
            DetectedObject(id: 0, label: "car", confidence: 0.9, box: box)
        ], at: Date(timeIntervalSince1970: 100.5))[0]
        let afterGap = assigner.assign([
            DetectedObject(id: 0, label: "person", confidence: 0.9, box: box)
        ], at: Date(timeIntervalSince1970: 102))[0]

        XCTAssertNotEqual(first.trackID, differentClass.trackID)
        XCTAssertNotEqual(first.trackID, afterGap.trackID)
    }

    func testNonPersonAndVehicleDetectionsAreNotTracked() {
        var assigner = ObjectTrackAssigner()
        let object = DetectedObject(id: 5, label: "backpack", confidence: 0.9,
                                    box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))

        let result = assigner.assign([object], at: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(result, [object])
        XCTAssertNil(result[0].trackID)
    }

    func testResetStartsANewTrackForSameBox() {
        var assigner = ObjectTrackAssigner()
        let object = DetectedObject(id: 0, label: "person", confidence: 0.9,
                                    box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4))
        let first = assigner.assign([object], at: Date(timeIntervalSince1970: 100))[0]
        assigner.reset()
        let next = assigner.assign([object], at: Date(timeIntervalSince1970: 100.1))[0]

        XCTAssertNotEqual(first.trackID, next.trackID)
    }

    func testStoreUpsertsTrackAndPurgesAfterThirtyDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.sqlite3")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = try LocalTrackingStore(url: url, now: now)
        let cameraID = UUID()
        let trackID = UUID()
        let first = DetectedObject(id: 0, label: "person", confidence: 0.8,
                                   box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                   trackID: trackID)
        let update = DetectedObject(id: 2, label: "person", confidence: 0.95,
                                    box: CGRect(x: 0.12, y: 0.2, width: 0.3, height: 0.4),
                                    trackID: trackID)
        let crop = Data("jpeg evidence".utf8)
        let cutout = Data("png evidence".utf8)
        let embedding = (0..<512).map { Float($0 + 1) / 512 }
        let improvedCrop = Data("improved jpeg evidence".utf8)
        let improvedCutout = Data("improved png evidence".utf8)
        let improvedEmbedding = (0..<512).map { Float($0 + 2) / 512 }

        XCTAssertTrue(try store.shouldCaptureCrop(for: trackID, confidence: first.confidence))
        XCTAssertTrue(try store.record(first, cameraID: cameraID, cameraName: "Gate",
                           cropJPEG: crop, cutoutPNG: cutout,
                           reidEmbedding: embedding, at: now))
        XCTAssertFalse(try store.shouldCaptureCrop(for: trackID, confidence: first.confidence))
        XCTAssertTrue(try store.shouldCaptureCrop(for: trackID, confidence: update.confidence))
        XCTAssertFalse(try store.record(update, cameraID: cameraID, cameraName: "Gate",
                   cropJPEG: improvedCrop, cutoutPNG: improvedCutout,
                   reidEmbedding: improvedEmbedding, at: now.addingTimeInterval(5)))
        let lowerConfidence = DetectedObject(id: 3, label: "person", confidence: 0.9,
                             box: CGRect(x: 0.14, y: 0.2, width: 0.3, height: 0.4),
                             trackID: trackID)
        XCTAssertFalse(try store.shouldCaptureCrop(for: trackID, confidence: lowerConfidence.confidence))
        XCTAssertFalse(try store.record(lowerConfidence, cameraID: cameraID, cameraName: "Gate",
                   cropJPEG: Data("lower confidence crop".utf8), at: now.addingTimeInterval(6)))
        let records = try store.recentTracks()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].observationCount, 3)
        XCTAssertEqual(records[0].bestConfidence, 0.95)
        XCTAssertEqual(records[0].box.origin.x, 0.14, accuracy: 0.0001)
        let cropURL = try XCTUnwrap(store.imageURL(for: records[0]))
        let cutoutURL = try XCTUnwrap(store.cutoutURL(for: records[0]))
        XCTAssertEqual(try Data(contentsOf: cropURL), improvedCrop)
        XCTAssertEqual(try Data(contentsOf: cutoutURL), improvedCutout)
        XCTAssertEqual(try store.reidEmbedding(for: trackID), improvedEmbedding)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: cropURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: cropURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        let description = try XCTUnwrap(TrackedObjectDescription.parse("""
            {"summary":"Dark jacket","overallConfidence":0.8,"attributes":{"clothing":{"value":"dark jacket","confidence":0.9,"evidence":"Visible dark fabric"}}}
            """))
        try store.saveDescription(description, for: trackID, at: now.addingTimeInterval(6))
        let described = try XCTUnwrap(store.recentTracks().first)
        XCTAssertEqual(described.description, description)
        XCTAssertEqual(described.describedAt, now.addingTimeInterval(6))

        let oldTrack = UUID()
        let old = DetectedObject(id: 3, label: "car", confidence: 0.7,
                                 box: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
                                 trackID: oldTrack)
        _ = try store.record(old, cameraID: cameraID, cameraName: "Gate",
                             cropJPEG: crop,
                             cutoutPNG: cutout,
                             at: now.addingTimeInterval(-31 * 24 * 60 * 60))
        let oldRecord = try XCTUnwrap(store.recentTracks().first(where: { $0.trackID == oldTrack }))
        let oldCropURL = try XCTUnwrap(store.imageURL(for: oldRecord))
        let oldCutoutURL = try XCTUnwrap(store.cutoutURL(for: oldRecord))
        XCTAssertEqual(try store.purgeExpired(now: now.addingTimeInterval(5)), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCropURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCutoutURL.path))
        XCTAssertEqual(try store.recentTracks().map(\.trackID), [trackID])

        try store.delete(trackID: trackID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cropURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutoutURL.path))
    }

    func testOperatorMergeCombinesGroupsAndDetachIsReversible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let cameraID = UUID()
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let people = (0..<3).map { _ in UUID() }
        let carID = UUID()
        for id in people {
            let object = DetectedObject(id: 0, label: "person", confidence: 0.9, box: box, trackID: id)
            _ = try store.record(object, cameraID: cameraID, cameraName: "Gate")
        }
        let car = DetectedObject(id: 1, label: "car", confidence: 0.9, box: box, trackID: carID)
        _ = try store.record(car, cameraID: cameraID, cameraName: "Gate")

        let firstGroup = try store.mergeTracks(Array(people.prefix(2)))
        let mergedGroup = try store.mergeTracks([people[1], people[2]])
        XCTAssertEqual(firstGroup, mergedGroup)
        XCTAssertThrowsError(try store.mergeTracks([people[0], carID]))
        XCTAssertNil(try store.recentTracks().first(where: { $0.trackID == carID })?.operatorGroupID)

        try store.detachTrack(people[1])
        let records = try store.recentTracks()
        XCTAssertEqual(records.first(where: { $0.trackID == people[0] })?.operatorGroupID, firstGroup)
        XCTAssertNil(records.first(where: { $0.trackID == people[1] })?.operatorGroupID)
        XCTAssertEqual(records.first(where: { $0.trackID == people[2] })?.operatorGroupID, firstGroup)
    }

    func testRetentionRemovesOperatorGroupLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"), now: now)
        let cameraID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        for trackID in [firstID, secondID] {
            let object = DetectedObject(id: 0, label: "person", confidence: 0.9, box: box, trackID: trackID)
            _ = try store.record(object, cameraID: cameraID, cameraName: "Gate",
                                 at: now.addingTimeInterval(-31 * 24 * 60 * 60))
        }
        _ = try store.mergeTracks([firstID, secondID])

        XCTAssertEqual(try store.purgeExpired(now: now), 2)
        let replacement = DetectedObject(id: 1, label: "person", confidence: 0.9, box: box, trackID: firstID)
        _ = try store.record(replacement, cameraID: cameraID, cameraName: "Gate", at: now)
        XCTAssertNil(try store.recentTracks().first?.operatorGroupID)
    }

    func testValidationPairsNormalizeLabelsAndReplaceDifferentWithOperatorGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let first = UUID()
        let second = UUID()
        try recordValidationTrack(store, id: first, cameraID: UUID(), embeddingIndex: 0)
        try recordValidationTrack(store, id: second, cameraID: UUID(), embeddingIndex: 1)

        try store.labelDifferent(trackA: second, trackB: first)
        try store.labelDifferent(trackA: first, trackB: second)
        var samples = try store.reidValidationSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertFalse(try XCTUnwrap(samples.first).pair.sameObject)
        XCTAssertEqual(try XCTUnwrap(samples.first).pair.distance, 1, accuracy: 0.0001)

        _ = try store.mergeTracks([first, second])
        samples = try store.reidValidationSamples()
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(try XCTUnwrap(samples.first).pair.sameObject)
        XCTAssertEqual(try XCTUnwrap(samples.first).pair.distance, 1, accuracy: 0.0001)
    }

    func testValidationLabelsRequireEmbeddingsAndAreRemovedOnDeleteAndRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"), now: now)
        let oldA = UUID()
        let oldB = UUID()
        let freshA = UUID()
        let freshB = UUID()
        let cameraA = UUID()
        let cameraB = UUID()
        try recordValidationTrack(store, id: oldA, cameraID: cameraA, embeddingIndex: 0,
                                  at: now.addingTimeInterval(-31 * 24 * 60 * 60))
        try recordValidationTrack(store, id: oldB, cameraID: cameraB, embeddingIndex: 1,
                                  at: now.addingTimeInterval(-31 * 24 * 60 * 60))
        try recordValidationTrack(store, id: freshA, cameraID: cameraA, embeddingIndex: 0, at: now)
        try recordValidationTrack(store, id: freshB, cameraID: cameraB, embeddingIndex: 1, at: now)
        let noEmbedding = UUID()
        let unembeddedObject = DetectedObject(id: 1, label: "person", confidence: 0.9,
                              box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                              trackID: noEmbedding)
        _ = try store.record(unembeddedObject, cameraID: cameraA, cameraName: "Camera", at: now)

        XCTAssertThrowsError(try store.labelDifferent(trackA: noEmbedding, trackB: freshB))
        try store.labelDifferent(trackA: oldA, trackB: oldB)
        try store.labelDifferent(trackA: freshA, trackB: freshB)
        XCTAssertEqual(try store.reidValidationSamples().count, 2)

        XCTAssertEqual(try store.purgeExpired(now: now), 2)
        XCTAssertEqual(try store.reidValidationSamples().count, 1)

        let laterA = UUID()
        let laterB = UUID()
        try recordValidationTrack(store, id: laterA, cameraID: cameraA, embeddingIndex: 0, at: now)
        try recordValidationTrack(store, id: laterB, cameraID: cameraB, embeddingIndex: 1, at: now)
        try store.labelDifferent(trackA: laterA, trackB: laterB)
        try store.delete(trackID: laterA)
        XCTAssertEqual(try store.reidValidationSamples().count, 1)
    }

    private func recordValidationTrack(_ store: LocalTrackingStore, id: UUID, cameraID: UUID,
                                       embeddingIndex: Int, at time: Date = Date()) throws {
        let object = DetectedObject(id: 0, label: "person", confidence: 0.9,
                                    box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), trackID: id)
        var embedding = [Float](repeating: 0, count: 512)
        embedding[embeddingIndex] = 1
        _ = try store.record(object, cameraID: cameraID, cameraName: "Camera", reidEmbedding: embedding, at: time)
    }
}