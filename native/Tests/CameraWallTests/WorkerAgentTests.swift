import XCTest
@testable import CameraWall

final class WorkerAgentTests: XCTestCase {
    func testWorkerTLSConfigurationNormalizesPinsAndRejectsCollisions() throws {
        let peerID = UUID()
        let fingerprint = String(repeating: "ab", count: 32)
        let configuration = try WorkerTLSConfiguration(
            identityLabel: "CameraWall coordinator",
            trustedPeerIDsByFingerprint: [fingerprint.uppercased().enumerated().map { index, character in
                index.isMultiple(of: 2) ? "\(character):" : String(character)
            }.joined(): peerID]
        )
        XCTAssertEqual(configuration.trustedPeerIDsByFingerprint[fingerprint], peerID)

        XCTAssertThrowsError(try WorkerTLSConfiguration(
            identityLabel: "duplicate pins",
            trustedPeerIDsByFingerprint: [fingerprint: peerID, fingerprint.uppercased(): UUID()]
        ))
    }

    func testLaunchAgentUsesHeadlessWorkerCommandAndRunAtLoad() throws {
        let executableURL = URL(fileURLWithPath: "/Applications/CameraWall.app/Contents/MacOS/CameraWall")
        let configurationURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/CameraWall/worker.json")
        let data = try WorkerLaunchAgent.propertyListData(executableURL: executableURL,
                                                          configurationURL: configurationURL)
        let propertyList = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(propertyList["Label"] as? String, WorkerLaunchAgent.label)
        XCTAssertEqual(propertyList["ProgramArguments"] as? [String], [
            executableURL.path, "--worker", "--config", configurationURL.path
        ])
        XCTAssertEqual(propertyList["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(propertyList["KeepAlive"] as? Bool, true)
    }

    func testWorkerNodeConfigurationRejectsWildcardAndDNSEndpoints() throws {
        let fingerprint = String(repeating: "cd", count: 32)
        var configuration = WorkerNodeConfiguration(
            role: .coordinator,
            nodeID: UUID(),
            displayName: "coordinator",
            tlsIdentityLabel: "CameraWall coordinator",
            trustedPeerIDsByFingerprint: [fingerprint: UUID()],
            bindAddress: "192.168.10.8",
            listenPort: 19443,
            coordinatorAddress: nil,
            coordinatorPort: nil,
            cameraConfigurationPath: nil,
            poseModelPath: nil,
            maximumCameraCount: 8,
            cameraAssignments: []
        )
        XCTAssertNoThrow(try configuration.validate())

        configuration.bindAddress = "0.0.0.0"
        XCTAssertThrowsError(try configuration.validate())
        configuration.bindAddress = "coordinator.local"
        XCTAssertThrowsError(try configuration.validate())
    }
}