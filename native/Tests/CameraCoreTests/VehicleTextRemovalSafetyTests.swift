import CoreGraphics
import SQLite3
import XCTest
@testable import CameraCore

final class VehicleTextRemovalSafetyTests: XCTestCase {
    func testTrackOnlyRemovalRejectsMissingTrackAndPreservesSearchData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".vehicle-text-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.sqlite3")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try LocalTrackingStore(url: url, now: now)
        let id = UUID()
        let cameraID = UUID()
        try store.record(DetectedObject(id: 1, label: "car", confidence: 0.9, box: .zero, trackID: id),
                         cameraID: cameraID, cameraName: "Fake camera", at: now)
        let description = TrackedObjectDescription(summary: "blue vehicle", attributes: [:], overallConfidence: 0.9)
        try store.saveDescription(description, for: id, at: now)
        let evidence = VehicleTextEvidence(trackID: id,
            candidates: [VehicleTextCandidate(text: "FAKE123", confidence: 0.9)],
            readAt: now, cropSHA256: String(repeating: "a", count: 64))
        try store.saveVehicleTextEvidence(evidence)
        try store.indexACTATrackKnowledge(
            trackID: id.uuidString, identityID: UUID().uuidString, cameraID: cameraID.uuidString,
            capturedAt: now, cropQuality: 0.8,
            description: ACTACropDescription(cellIndex: 0, kind: "vehicle", summary: "FAKE123"),
            chromaSignature: nil, kind: "vehicle"
        )
        let before = try snapshot(url)
        XCTAssertTrue(before.contains(where: { $0.contains("FAKE123") }))

        XCTAssertThrowsError(try store.clearVehicleTextEvidence(for: UUID())) {
            guard case LocalTrackingStoreError.missingTrack = $0 else {
                return XCTFail("Expected missing track, got \($0)")
            }
        }
        try store.clearVehicleTextEvidence(for: id)
        XCTAssertNil(try store.vehicleTextEvidence(for: id))
        XCTAssertEqual(try store.track(trackID: id)?.description, description)
        XCTAssertEqual(try snapshot(url), before)
    }

    private func snapshot(_ url: URL) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "FixtureSQLite", code: 1)
        }
        defer { sqlite3_close(db) }
        var rows: [[String]] = []
        for table in ["ghost_attribute_index", "ghost_crop_fts",
                      "ghost_identity_dossiers", "ghost_identity_fts"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT * FROM \(table) ORDER BY rowid", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw NSError(domain: "FixtureSQLite", code: 2) }
            defer { sqlite3_finalize(statement) }
            rows.append([table])
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { column in
                    guard let text = sqlite3_column_text(statement, column) else { return "<null>" }
                    return String(cString: text)
                })
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw NSError(domain: "FixtureSQLite", code: 3) }
        }
        return rows
    }
}
