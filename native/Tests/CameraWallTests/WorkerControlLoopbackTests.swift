import XCTest
import Security
import CameraCore
@testable import CameraWall

final class WorkerControlLoopbackTests: XCTestCase {
    func testMutualTLSCoordinatorAndWorkerExchangeStaticCameraLease() async throws {
        guard let openssl = ["/opt/homebrew/bin/openssl", "/usr/bin/openssl"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("OpenSSL is required to generate ephemeral loopback test certificates.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                                      isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let rootKey = directory.appendingPathComponent("root.key")
        let rootCertificate = directory.appendingPathComponent("root.pem")
        let rootDER = directory.appendingPathComponent("root.der")
        let extensions = directory.appendingPathComponent("node.ext")
        try runOpenSSL(openssl, [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", rootKey.path, "-out", rootCertificate.path,
            "-sha256", "-days", "2", "-subj", "/CN=CameraWall Loopback Test CA",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign"
        ])
        try Data("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:127.0.0.1\n".utf8)
            .write(to: extensions)
        try runOpenSSL(openssl, ["x509", "-in", rootCertificate.path, "-outform", "DER", "-out", rootDER.path])
        let rootData = try Data(contentsOf: rootDER)
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, rootData as CFData))

        let coordinatorIdentity = try makeIdentity(name: "coordinator", directory: directory,
                                                   rootCertificate: rootCertificate, rootKey: rootKey,
                                                   extensions: extensions, openssl: openssl)
        let workerIdentity = try makeIdentity(name: "worker", directory: directory,
                                              rootCertificate: rootCertificate, rootKey: rootKey,
                                              extensions: extensions, openssl: openssl)
        let coordinatorCertificate = try certificate(for: coordinatorIdentity)
        let workerCertificate = try certificate(for: workerIdentity)
        let coordinatorID = UUID()
        let workerID = UUID()
        let cameraID = UUID()
        let coordinatorTLS = try WorkerTLSConfiguration(
            localIdentity: coordinatorIdentity,
            trustAnchors: [root],
            trustedPeerIDsByFingerprint: [WorkerTLSIdentity.fingerprint(workerCertificate): workerID]
        )
        let workerTLS = try WorkerTLSConfiguration(
            localIdentity: workerIdentity,
            trustAnchors: [root],
            trustedPeerIDsByFingerprint: [WorkerTLSIdentity.fingerprint(coordinatorCertificate): coordinatorID]
        )
        let coordinator = WorkerCoordinator()
        let server = WorkerControlServer(coordinator: coordinator, tlsConfiguration: coordinatorTLS,
                                         assignmentPlan: [cameraID: workerID])
        let port = try await server.start(bindAddress: "127.0.0.1", port: 0)
        defer { server.stop() }

        let registration = WorkerRegistration(workerID: workerID, sessionID: UUID(),
                                              displayName: "loopback-worker", cameraIDs: [cameraID],
                                              maximumCameraCount: 1,
                                              modelIdentifiers: [YOLO26PoseDetector.modelIdentifier])
        let registered = try await WorkerControlClient.request(
            WorkerControlRequest(registration: registration), host: "127.0.0.1", port: port,
            tlsConfiguration: workerTLS
        )
        XCTAssertTrue(registered.accepted)

        let firstHeartbeat = WorkerHeartbeat(workerID: workerID, sessionID: registration.sessionID,
                                             sequence: 1, activeCameraIDs: [],
                                             processedFramesPerSecond: 0, queueDepth: 0)
        let firstResponse = try await WorkerControlClient.request(
            WorkerControlRequest(heartbeat: firstHeartbeat), host: "127.0.0.1", port: port,
            tlsConfiguration: workerTLS
        )
        XCTAssertEqual(firstResponse.leases.count, 1)
        XCTAssertEqual(firstResponse.leases.first?.cameraID, cameraID)

        let secondHeartbeat = WorkerHeartbeat(workerID: workerID, sessionID: registration.sessionID,
                                              sequence: 2, activeCameraIDs: [cameraID],
                                              processedFramesPerSecond: 1, queueDepth: 0)
        let secondResponse = try await WorkerControlClient.request(
            WorkerControlRequest(heartbeat: secondHeartbeat), host: "127.0.0.1", port: port,
            tlsConfiguration: workerTLS
        )
        XCTAssertEqual(secondResponse.leases.first?.leaseID, firstResponse.leases.first?.leaseID)
        XCTAssertGreaterThan(secondResponse.leases.first!.expiresAt, firstResponse.leases.first!.expiresAt)
    }

    private func makeIdentity(name: String, directory: URL, rootCertificate: URL, rootKey: URL,
                              extensions: URL, openssl: String) throws -> SecIdentity {
        let privateKey = directory.appendingPathComponent("\(name).key")
        let request = directory.appendingPathComponent("\(name).csr")
        let certificate = directory.appendingPathComponent("\(name).pem")
        let bundle = directory.appendingPathComponent("\(name).p12")
        let serial = directory.appendingPathComponent("root.srl")
        try runOpenSSL(openssl, ["genrsa", "-out", privateKey.path, "2048"])
        try runOpenSSL(openssl, ["req", "-new", "-key", privateKey.path,
                                 "-out", request.path, "-subj", "/CN=\(name)"])
        var signArguments = ["x509", "-req", "-in", request.path, "-CA", rootCertificate.path,
                             "-CAkey", rootKey.path]
        if FileManager.default.fileExists(atPath: serial.path) {
            signArguments += ["-CAserial", serial.path]
        } else {
            signArguments.append("-CAcreateserial")
        }
        signArguments += ["-out", certificate.path, "-days", "2", "-sha256", "-extfile", extensions.path]
        try runOpenSSL(openssl, signArguments)
        try runOpenSSL(openssl, ["pkcs12", "-export", "-out", bundle.path,
                                 "-inkey", privateKey.path, "-in", certificate.path,
                                 "-certfile", rootCertificate.path, "-passout", "pass:loopback-test-only"])

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: "loopback-test-only",
            kSecImportToMemoryOnly as String: true
        ]
        var imported: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: bundle) as CFData, options as CFDictionary, &imported)
          guard status == errSecSuccess,
              let item = (imported as? [[String: Any]])?.first,
              let rawIdentity = item[kSecImportItemIdentity as String] else {
            throw WorkerTransportError.identityUnavailable
        }
          return rawIdentity as! SecIdentity
    }

    private func certificate(for identity: SecIdentity) throws -> SecCertificate {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { throw WorkerTransportError.invalidPeerCertificate }
        return certificate
    }

    private func runOpenSSL(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WorkerControlLoopbackTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errorOutput, as: UTF8.self)])
        }
    }
}