import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
enum IsolatedWallFixtureSupport {
    static let modelDiscovery = AnalyticsModelDiscovery(modelURL: { _ in nil },
        integrity: { _ in (hash: "synthetic", sizeBytes: 0) })

    static func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(".wall-fixture-\(UUID().uuidString)", isDirectory: true)
    }

    static func modelPreferences() -> ModelSelectionPreferences {
        ModelSelectionPreferences(
            enabled: Set(LocalModelService.allCases.filter { ModelSelectionRegistry.isEnabled($0) }),
            paths: Dictionary(uniqueKeysWithValues: LocalModelService.allCases.compactMap { service in
                ModelSelectionRegistry.path(service).map { (service, $0.path) }
            }))
    }

    static func prepare(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try ConfigurationStore.save(WallConfiguration(), to: root.appendingPathComponent("cameras.json"))
        try ModelSelectionPreferences(enabled: []).save(to: root.appendingPathComponent("model-preferences.json"))
    }

    static func client() -> ACTAAIClient {
        ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            XCTFail("Unexpected network request")
            throw URLError(.notConnectedToInternet)
        }, keyProvider: { _ in
            XCTFail("Unexpected AI credential access")
            return nil
        })
    }

    static func assertSafe(_ model: WallModel) {
        XCTAssertTrue(model.config.cameras.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.featurePreferences.enabledFeatures.contains(.independentWatcher))
        XCTAssertTrue(LocalModelService.allCases.allSatisfy { !ModelSelectionRegistry.isEnabled($0) })
    }
}
