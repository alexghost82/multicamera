import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class AnalyticsModelDiscoveryTests: XCTestCase {
    private func engine(root: URL, pose: URL? = nil, discovery: AnalyticsModelDiscovery) -> LocalVideoAnalyticsEngine {
        LocalVideoAnalyticsEngine(
            settingsURL: root.appendingPathComponent("settings.json"),
            incidentsURL: root.appendingPathComponent("incidents.json"),
            evidenceDirectoryURL: root.appendingPathComponent("evidence"),
            auditLogURL: root.appendingPathComponent("audit.json"),
            poseModelURL: pose, modelDiscovery: discovery)
    }

    func testProductionDescriptorLogicUsesRealIntegrityOnSyntheticModel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".discovery-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model.bin")
        try Data("abc".utf8).write(to: file)
        let discovery = AnalyticsModelDiscovery(
            modelURL: { id in id == .yoloObject || id == .yoloPose ? file : nil },
            integrity: AnalyticsModelDiscovery.production.integrity)
        let model = engine(root: root, discovery: discovery)
        let object = try XCTUnwrap(model.modelDescriptors[.yoloObject])
        let pose = try XCTUnwrap(model.modelDescriptors[.yoloPose])
        XCTAssertEqual(object.status, .ready)
        XCTAssertEqual(object.filePath, file.path)
        XCTAssertEqual(object.sizeBytes, 3)
        XCTAssertEqual(object.sha256Checksum, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(pose.status, .disabled)
        XCTAssertEqual(pose.sha256Checksum, object.sha256Checksum)
        XCTAssertEqual(model.modelDescriptors[.yoloSegmentation]?.status, .missing)
        XCTAssertEqual(model.modelDescriptors[.personReID]?.status, .missing)
        XCTAssertEqual(model.modelDescriptors[.vehicleReID]?.status, .missing)
        XCTAssertEqual(model.modelDescriptors[.fightClassifier]?.status, .modelNotValidated)
        model.refreshModelDescriptors()
        XCTAssertEqual(model.modelDescriptors[.yoloObject], object)
        XCTAssertEqual(model.modelDescriptors[.yoloPose], pose)
    }

    func testFakeDiscoveryIsUsedOnInitializationAndRefresh() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".discovery-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pose = root.appendingPathComponent("custom-pose")
        var requests: [AnalyticsModelID] = []
        var hashes: [URL] = []
        let discovery = AnalyticsModelDiscovery(modelURL: { id in
            requests.append(id)
            return nil
        }, integrity: { url in
            hashes.append(url)
            return (hash: "fake", sizeBytes: 17)
        })
        let model = engine(root: root, pose: pose, discovery: discovery)
        XCTAssertEqual(model.modelDescriptors[.yoloPose]?.filePath, pose.path)
        XCTAssertEqual(model.modelDescriptors[.yoloPose]?.sha256Checksum, "fake")
        XCTAssertEqual(model.modelDescriptors[.yoloPose]?.sizeBytes, 17)
        XCTAssertEqual(hashes, [pose])
        XCTAssertFalse(requests.contains(.yoloPose))
        XCTAssertEqual(Set(requests), [.yoloObject, .yoloSegmentation, .personReID, .vehicleReID])
        model.refreshModelDescriptors()
        XCTAssertEqual(hashes, [pose, pose])
        XCTAssertEqual(requests.count, 8)
    }

    func testOptionalModelDescriptorsAndIntegrityFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".discovery-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = AnalyticsModelDiscovery(modelURL: { id in
            switch id {
            case .yoloSegmentation, .personReID, .vehicleReID:
                return root.appendingPathComponent(id.rawValue)
            default: return nil
            }
        }, integrity: { url in
            if url.lastPathComponent == AnalyticsModelID.personReID.rawValue {
                throw CocoaError(.fileReadNoPermission)
            }
            return (hash: "synthetic", sizeBytes: 11)
        })
        let model = engine(root: root, discovery: discovery)
        XCTAssertEqual(model.modelDescriptors[.yoloSegmentation]?.status, .ready)
        XCTAssertEqual(model.modelDescriptors[.yoloSegmentation]?.sha256Checksum, "synthetic")
        XCTAssertEqual(model.modelDescriptors[.personReID]?.status, .ready)
        XCTAssertNil(model.modelDescriptors[.personReID]?.sha256Checksum)
        XCTAssertEqual(model.modelDescriptors[.personReID]?.sizeBytes, 0)
        XCTAssertEqual(model.modelDescriptors[.vehicleReID]?.status, .ready)
        XCTAssertEqual(model.modelDescriptors[.vehicleReID]?.sizeBytes, 11)
    }
}
