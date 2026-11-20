import Foundation
import XCTest
@testable import CameraWall

final class CameraMissionStoreIntegrityTests: XCTestCase {
    private func fixture() throws -> (URL, CameraMission, CameraMissionRun, CameraMissionConsultMessage) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".mission-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let mission = try CameraMission(cameraID: UUID(), name: "Synthetic", brief: "Inspect",
                                        intervalSeconds: 60, enabled: true)
        let run = CameraMissionRun(missionID: mission.id, cameraID: mission.cameraID,
                                   missionName: mission.name, status: .completed, summary: "Synthetic")
        let consult = try CameraMissionConsultMessage(missionID: mission.id, role: .operatorMessage, text: "Question")
        return (directory.appendingPathComponent("missions.json"), mission, run, consult)
    }

    func testDuplicateIdentifiersFailOnLoadAndSaveWithoutOverwriting() throws {
        let (url, mission, run, consult) = try fixture()
        try CameraMissionStore.save([mission], runs: [run], consults: [consult], to: url)
        let original = try Data(contentsOf: url)
        let documents = [
            CameraMissionStoreDocument(schemaVersion: 3, missions: [mission, mission], runs: [run], consults: [consult]),
            CameraMissionStoreDocument(schemaVersion: 3, missions: [mission], runs: [run, run], consults: [consult]),
            CameraMissionStoreDocument(schemaVersion: 3, missions: [mission], runs: [run], consults: [consult, consult])
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for document in documents {
            XCTAssertThrowsError(try CameraMissionStore.save(document.missions, runs: document.runs,
                                                             consults: document.consults, to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
            let invalid = try encoder.encode(document)
            try invalid.write(to: url)
            XCTAssertThrowsError(try CameraMissionStore.loadDocument(from: url))
            XCTAssertEqual(try Data(contentsOf: url), invalid)
            try original.write(to: url)
        }
    }

    func testRemovingMissionRequiresRemovingConsultsButPreservesRunHistory() throws {
        let (url, mission, run, consult) = try fixture()
        try CameraMissionStore.save([mission], runs: [run], consults: [consult], to: url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try CameraMissionStore.save([], runs: [run], to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try CameraMissionStore.save([], runs: [run], consults: [consult], to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let orphaned = try encoder.encode(CameraMissionStoreDocument(
            schemaVersion: 3, missions: [], runs: [run], consults: [consult]))
        try orphaned.write(to: url)
        XCTAssertThrowsError(try CameraMissionStore.loadDocument(from: url))
        XCTAssertEqual(try Data(contentsOf: url), orphaned)
        try original.write(to: url)
        try CameraMissionStore.save([], runs: [run], consults: [], to: url)
        let document = try CameraMissionStore.loadDocument(from: url)
        XCTAssertTrue(document.missions.isEmpty)
        XCTAssertEqual(document.runs.map(\.id), [run.id])
        XCTAssertTrue(document.consults.isEmpty)
    }

    func testOlderDocumentsWithMissingHistoryFieldsStillLoadAndSave() throws {
        let (url, mission, run, _) = try fixture()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for version in [1, 2] {
            let document = CameraMissionStoreDocument(schemaVersion: version, missions: [mission], runs: [run])
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
            json.removeValue(forKey: "consults")
            if version == 1 { json.removeValue(forKey: "runs") }
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            let loaded = try CameraMissionStore.loadDocument(from: url)
            XCTAssertEqual(loaded.missions.map(\.id), [mission.id])
            XCTAssertEqual(loaded.runs.map(\.id), version == 1 ? [] : [run.id])
            XCTAssertTrue(loaded.consults.isEmpty)
            try CameraMissionStore.save(loaded.missions, runs: loaded.runs, consults: loaded.consults, to: url)
            let reloaded = try CameraMissionStore.loadDocument(from: url)
            XCTAssertEqual(reloaded.missions.map(\.id), loaded.missions.map(\.id))
            XCTAssertEqual(reloaded.runs.map(\.id), loaded.runs.map(\.id))
        }
    }

    func testSaveRejectsHistoryThatItsOwnLoaderWouldReject() throws {
        let (url, mission, run, consult) = try fixture()
        try CameraMissionStore.save([mission], runs: [run], consults: [consult], to: url)
        let original = try Data(contentsOf: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func changedJSON<T: Encodable>(_ value: T, key: String, replacement: Any) throws -> Data {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
            object[key] = replacement
            return try JSONSerialization.data(withJSONObject: object)
        }

        let invalidRuns = try [
            decoder.decode(CameraMissionRun.self, from: changedJSON(run, key: "summary", replacement: String(repeating: "x", count: 4001))),
            decoder.decode(CameraMissionRun.self, from: changedJSON(run, key: "sceneChangeScore", replacement: 1.5))
        ]
        let invalidConsult = try decoder.decode(CameraMissionConsultMessage.self, from:
            changedJSON(consult, key: "text", replacement: String(repeating: "x", count: 4001)))
        for invalidRun in invalidRuns {
            XCTAssertThrowsError(try CameraMissionStore.save([mission], runs: [invalidRun], consults: [consult], to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
            try encoder.encode(CameraMissionStoreDocument(schemaVersion: 3, missions: [mission],
                                                           runs: [invalidRun], consults: [consult])).write(to: url)
            XCTAssertThrowsError(try CameraMissionStore.loadDocument(from: url))
            try original.write(to: url)
        }
        XCTAssertThrowsError(try CameraMissionStore.save([mission], runs: [run], consults: [invalidConsult], to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try encoder.encode(CameraMissionStoreDocument(schemaVersion: 3, missions: [mission],
                                                       runs: [run], consults: [invalidConsult])).write(to: url)
        XCTAssertThrowsError(try CameraMissionStore.loadDocument(from: url))
        try original.write(to: url)
        XCTAssertNoThrow(try CameraMissionStore.loadDocument(from: url))
    }
}
