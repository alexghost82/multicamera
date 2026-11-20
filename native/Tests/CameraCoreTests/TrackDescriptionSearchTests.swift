import XCTest
@testable import CameraCore

final class TrackDescriptionSearchTests: XCTestCase {
    func testSearchFindsDescriptionAttributeEvidenceAndCameraFields() throws {
        let redTrack = makeRecord(
            camera: "North entrance",
            summary: "Person wearing a red coat",
            attribute: TrackedAttribute(value: "red", confidence: 0.9, evidence: "red coat visible")
        )
        let vehicleTrack = makeRecord(
            camera: "Garage",
            summary: "Dark vehicle",
            attribute: TrackedAttribute(value: "sedan", confidence: 0.8, evidence: "four doors")
        )

        XCTAssertEqual(TrackDescriptionSearch.filter([redTrack, vehicleTrack], query: "red coat"), [redTrack])
        XCTAssertEqual(TrackDescriptionSearch.filter([redTrack, vehicleTrack], query: "four doors"), [vehicleTrack])
        XCTAssertEqual(TrackDescriptionSearch.filter([redTrack, vehicleTrack], query: "north entrance"), [redTrack])
        XCTAssertEqual(TrackDescriptionSearch.filter([redTrack, vehicleTrack], query: ""), [redTrack, vehicleTrack])
    }

    func testSearchPagesAcrossHistoryAndCapsOnlyDisplayedRecords() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let cameraID = UUID()
        let timestamp = Date(timeIntervalSince1970: 2_000_000)
        var matchingIDs = Set<UUID>()

        for index in 0..<7 {
            let trackID = UUID()
            let object = DetectedObject(id: index, label: "person", confidence: 0.8,
                                        box: .zero, trackID: trackID)
            _ = try store.record(object, cameraID: cameraID, cameraName: "Gate", at: timestamp.addingTimeInterval(Double(index)))
            if index.isMultiple(of: 2) {
                matchingIDs.insert(trackID)
                try store.saveDescription(TrackedObjectDescription(
                    summary: "Person wearing a red coat", attributes: [:], overallConfidence: 0.9
                ), for: trackID)
            }
        }

        let result = try TrackDescriptionSearch.search(store: store, query: "red coat", limit: 2, pageSize: 2)

        XCTAssertEqual(result.matchCount, 4)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(Set(result.records.map(\.trackID)).isSubset(of: matchingIDs))
        XCTAssertEqual(result.records.map(\.lastSeen), result.records.map(\.lastSeen).sorted(by: >))
    }

    func testSearchFindsMatchesBeyondFiveHundredRecentTracks() throws {
        let fixture = try IsolatedStoreTestDirectory()
        defer { try? fixture.remove() }
        let directory = fixture.url
        let store = try LocalTrackingStore(url: directory.appendingPathComponent("tracking.sqlite3"))
        let cameraID = UUID()
        let timestamp = Date(timeIntervalSince1970: 2_000_000)
        var matches: [UUID] = []
        for index in 0..<503 {
            let trackID = UUID()
            let object = DetectedObject(id: index, label: "person", confidence: 0.8,
                                        box: .zero, trackID: trackID)
            _ = try store.record(object, cameraID: cameraID, cameraName: "Gate",
                                 at: timestamp.addingTimeInterval(Double(index)))
            if index < 3 {
                matches.append(trackID)
                try store.saveDescription(TrackedObjectDescription(
                    summary: "red coat", attributes: [:], overallConfidence: 0.9
                ), for: trackID)
            }
        }

        let result = try TrackDescriptionSearch.search(store: store, query: "red coat", limit: 2, pageSize: 50)

        XCTAssertEqual(result.matchCount, 3)
        XCTAssertEqual(result.records.map(\.trackID), [matches[2], matches[1]])
    }

    private func makeRecord(camera: String, summary: String, attribute: TrackedAttribute) -> TrackedObjectRecord {
        TrackedObjectRecord(
            trackID: UUID(), cameraID: UUID(), cameraName: camera, label: "person",
            firstSeen: Date(), lastSeen: Date(), observationCount: 1, bestConfidence: 0.9,
            box: .zero, cropPath: nil, cutoutPath: nil, operatorGroupID: nil,
            description: TrackedObjectDescription(
                summary: summary, attributes: ["clothing_color": attribute], overallConfidence: 0.9
            ),
            describedAt: Date()
        )
    }
}