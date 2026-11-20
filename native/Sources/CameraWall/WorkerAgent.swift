import Darwin
import Foundation
import Network
import CameraCore

struct WorkerNodeConfiguration: Codable {
    enum Role: String, Codable {
        case coordinator
        case worker
    }

    var role: Role
    var nodeID: UUID
    var displayName: String
    var tlsIdentityLabel: String
    var trustedPeerIDsByFingerprint: [String: UUID]
    var bindAddress: String?
    var listenPort: UInt16?
    var coordinatorAddress: String?
    var coordinatorPort: UInt16?
    var cameraConfigurationPath: String?
    var poseModelPath: String?
    var maximumCameraCount: Int
    var cameraAssignments: [WorkerCameraAssignment]

    func validate() throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.count <= 256,
              (1...256).contains(maximumCameraCount),
              Set(cameraAssignments.map(\.cameraID)).count == cameraAssignments.count else {
            throw WorkerTransportError.invalidConfiguration
        }
        _ = try WorkerTLSConfiguration(identityLabel: tlsIdentityLabel,
                                        trustedPeerIDsByFingerprint: trustedPeerIDsByFingerprint)
        switch role {
        case .coordinator:
            guard let bindAddress, Self.isLiteralIPAddress(bindAddress),
                  bindAddress != "0.0.0.0", bindAddress != "::",
                  let listenPort, listenPort >= 1024 else {
                throw WorkerTransportError.invalidConfiguration
            }
        case .worker:
            guard trustedPeerIDsByFingerprint.count == 1,
                  let coordinatorAddress, Self.isLiteralIPAddress(coordinatorAddress),
                  coordinatorAddress != "0.0.0.0", coordinatorAddress != "::",
                  let coordinatorPort, coordinatorPort >= 1024,
                  let cameraConfigurationPath, cameraConfigurationPath.hasPrefix("/"),
                  let poseModelPath, poseModelPath.hasPrefix("/") else {
                throw WorkerTransportError.invalidConfiguration
            }
        }
    }

    private static func isLiteralIPAddress(_ value: String) -> Bool {
        IPv4Address(value) != nil || IPv6Address(value) != nil
    }
}

struct WorkerCameraAssignment: Codable, Equatable {
    var cameraID: UUID
    var workerID: UUID
}

enum WorkerNodeConfigurationStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CameraWall/worker.json")
    }

    static func load(from url: URL) throws -> WorkerNodeConfiguration {
        let configuration = try JSONDecoder().decode(WorkerNodeConfiguration.self, from: Data(contentsOf: url))
        try configuration.validate()
        return configuration
    }

    static func save(_ configuration: WorkerNodeConfiguration, to url: URL) throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class WorkerAgent {
    private let configuration: WorkerNodeConfiguration
    private let sessionID = UUID()
    private var coordinatorServer: WorkerControlServer?
    private var wallModel: WallModel?
    private var drainingWallModel: WallModel?
    private var drainingAnalytics: LocalVideoAnalyticsEngine?
    private let cameraRuntime = ACTAWorkerCameraRuntime()
    private var signalSources: [DispatchSourceSignal] = []
    private var stopping = false

    private init(configuration: WorkerNodeConfiguration) {
        self.configuration = configuration
    }

    static func startFromCommandLine(arguments: [String]) {
        if arguments.contains("--bootstrap-worker-agent") {
            do { try WorkerLaunchAgent.bootstrap() }
            catch { FileHandle.standardError.write(Data("Worker agent bootstrap failed: \(error.localizedDescription)\n".utf8)); Darwin.exit(1) }
            Darwin.exit(0)
        }
        if arguments.contains("--bootout-worker-agent") {
            do { try WorkerLaunchAgent.bootout() }
            catch { FileHandle.standardError.write(Data("Worker agent bootout failed: \(error.localizedDescription)\n".utf8)); Darwin.exit(1) }
            Darwin.exit(0)
        }
        if arguments.contains("--uninstall-worker-agent") {
            do { try WorkerLaunchAgent.uninstall() }
            catch { FileHandle.standardError.write(Data("Worker agent uninstall failed: \(error.localizedDescription)\n".utf8)); Darwin.exit(1) }
            Darwin.exit(0)
        }
        let configURL: URL
        if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
            configURL = URL(fileURLWithPath: arguments[index + 1])
        } else {
            configURL = WorkerNodeConfigurationStore.defaultURL
        }

        let agent: WorkerAgent
        do {
            let configuration = try WorkerNodeConfigurationStore.load(from: configURL)
            if arguments.contains("--install-worker-agent") {
                _ = try WorkerTLSIdentity.load(label: configuration.tlsIdentityLabel)
                try WorkerLaunchAgent.install(executablePath: arguments[0], configurationURL: configURL)
                Darwin.exit(0)
            }
            agent = WorkerAgent(configuration: configuration)
        } catch {
            FileHandle.standardError.write(Data("Worker configuration error: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak agent] in
                Task { @MainActor [weak agent] in agent?.stop() }
            }
            source.resume()
            agent.signalSources.append(source)
        }
        Task { @MainActor in
            do {
                try await agent.run()
                await agent.finishShutdown()
                Darwin.exit(0)
            } catch {
                if !agent.stopping {
                    FileHandle.standardError.write(Data("Worker startup failed: \(error.localizedDescription)\n".utf8))
                }
                await agent.finishShutdown()
                Darwin.exit(error is CancellationError ? 0 : 1)
            }
        }
        RunLoop.main.run()
    }

    private func run() async throws {
        let tls = try WorkerTLSConfiguration(
            identityLabel: configuration.tlsIdentityLabel,
            trustedPeerIDsByFingerprint: configuration.trustedPeerIDsByFingerprint
        )
        switch configuration.role {
        case .coordinator:
            guard let bindAddress = configuration.bindAddress, let port = configuration.listenPort else {
                throw WorkerTransportError.invalidConfiguration
            }
            let coordinator = WorkerCoordinator()
            let server = WorkerControlServer(coordinator: coordinator, tlsConfiguration: tls,
                                                            assignmentPlan: Dictionary(uniqueKeysWithValues:
                                                                configuration.cameraAssignments.map { ($0.cameraID, $0.workerID) }))
            _ = try await server.start(bindAddress: bindAddress, port: port)
            coordinatorServer = server
            while !stopping { try await Task.sleep(nanoseconds: 1_000_000_000) }
        case .worker:
            try await runWorker(tls: tls)
        }
        stop()
    }

    private func runWorker(tls: WorkerTLSConfiguration) async throws {
        guard let path = configuration.cameraConfigurationPath,
              let poseModelPath = configuration.poseModelPath,
              let coordinatorAddress = configuration.coordinatorAddress,
              let coordinatorPort = configuration.coordinatorPort else {
            throw WorkerTransportError.invalidConfiguration
        }
        try ensureWorkerActive()
        let cameraConfigurationURL = URL(fileURLWithPath: path)
        let localConfiguration = try cameraRuntime.open(cameraConfigurationURL)
        let localCameras = localConfiguration.cameras.filter {
            $0.enabled && $0.localDeviceID == nil && $0.screenDisplayID == nil && $0.fileURL == nil
        }
        guard !localCameras.isEmpty else { throw WorkerTransportError.invalidConfiguration }
        guard configuration.maximumCameraCount <= localCameras.count else {
            throw WorkerTransportError.invalidConfiguration
        }
        let poseModelURL = URL(fileURLWithPath: poseModelPath)
        guard FileManager.default.fileExists(atPath: poseModelURL.path) else {
            throw YOLO26PoseDetectorError.modelUnavailable
        }
        let cameraLease = try cameraRuntime.activeLease()
        let model = WallModel(configURL: cameraConfigurationURL, workerMode: true, poseModelURL: poseModelURL,
                              relayFactory: { Go2RTC(cameraLease: cameraLease) })
        wallModel = model
        var expectedWorkerConfiguration = localConfiguration
        expectedWorkerConfiguration.cameras = localCameras.map {
            var camera = $0
            camera.enabled = false
            camera.yoloEnabled = true
            return camera
        }
        guard model.config == expectedWorkerConfiguration else {
            throw WorkerTransportError.invalidConfiguration
        }
        try await model.prepareWorkerRuntime()
        try ensureWorkerActive()
        model.startWorker()

        let registration = WorkerRegistration(workerID: configuration.nodeID, sessionID: sessionID,
                                              displayName: configuration.displayName,
                                              cameraIDs: Set(localCameras.map(\.id)),
                                              maximumCameraCount: configuration.maximumCameraCount,
                                              modelIdentifiers: [YOLO26PoseDetector.modelIdentifier])
        try await register(registration, address: coordinatorAddress, port: coordinatorPort, tls: tls)
        try ensureWorkerActive()

        var sequence: UInt64 = 0
        var previousInferenceCount = model.workerDetectionCount
        var previousSampleAt = ProcessInfo.processInfo.systemUptime
        var lastAcknowledgement = previousSampleAt
        var retryDelay: TimeInterval = 2
        while !stopping {
            sequence &+= 1
            let now = ProcessInfo.processInfo.systemUptime
            let currentInferenceCount = model.workerDetectionCount
            let elapsed = max(0.001, now - previousSampleAt)
            let processedFramesPerSecond = Double(currentInferenceCount - previousInferenceCount) / elapsed
            previousInferenceCount = currentInferenceCount
            previousSampleAt = now
            let heartbeat = WorkerHeartbeat(workerID: configuration.nodeID, sessionID: sessionID,
                                            sequence: sequence, activeCameraIDs: model.workerActiveCameraIDs(at: now),
                                            processedFramesPerSecond: processedFramesPerSecond,
                                            queueDepth: 0)
            do {
                let response = try await WorkerControlClient.request(WorkerControlRequest(heartbeat: heartbeat),
                                                                      host: coordinatorAddress, port: coordinatorPort,
                                                                      tlsConfiguration: tls)
                try ensureWorkerActive()
                model.applyWorkerLeases(response.leases)
                lastAcknowledgement = ProcessInfo.processInfo.systemUptime
                retryDelay = 2
            } catch WorkerTransportError.remoteRejected(let code)
                where code == WorkerCoordinatorError.workerNotRegistered.code ||
                      code == WorkerCoordinatorError.sessionMismatch.code {
                try ensureWorkerActive()
                model.applyWorkerLeases([])
                do {
                    try await register(registration, address: coordinatorAddress, port: coordinatorPort, tls: tls)
                    try ensureWorkerActive()
                    lastAcknowledgement = ProcessInfo.processInfo.systemUptime
                    retryDelay = 2
                } catch {
                    try ensureWorkerActive()
                    retryDelay = min(15, retryDelay * 2)
                }
            } catch {
                try ensureWorkerActive()
                if ProcessInfo.processInfo.systemUptime - lastAcknowledgement >= 10 {
                    model.applyWorkerLeases([])
                }
                retryDelay = min(15, retryDelay * 2)
            }
            try ensureWorkerActive()
            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }
    }

    private func ensureWorkerActive() throws {
        try cameraRuntime.checkActive()
        guard !stopping else { throw CancellationError() }
    }

    private func finishShutdown() async {
        stop()
        do {
            try await drainingAnalytics?.stopAndDrain()
            try await drainingWallModel?.waitForCameraNetworkStop()
            await Go2RTC.waitForAllPendingRequests()
            try await CameraReconnectAttempt.waitForStoppedSessions()
            try await CameraSession.waitForStoppedSessions()
            await Go2RTC.waitForAllChildrenToExit()
            await Go2RTC.waitForAllPendingRequests()
        } catch {
            FileHandle.standardError.write(Data("Worker shutdown could not verify camera cleanup; retaining the camera lease.\n".utf8))
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
    }

    private func register(_ registration: WorkerRegistration, address: String, port: UInt16,
                         tls: WorkerTLSConfiguration) async throws {
        _ = try await WorkerControlClient.request(WorkerControlRequest(registration: registration),
                                                  host: address, port: port, tlsConfiguration: tls)
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        cameraRuntime.stop()
        coordinatorServer?.stop()
        coordinatorServer = nil
        drainingWallModel = wallModel
        drainingAnalytics = wallModel?.localAnalyticsEngine
        wallModel?.shutdown()
        wallModel = nil
    }
}

enum WorkerLaunchAgent {
    static let label = "com.camerawall.worker"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func install(executablePath: String, configurationURL: URL) throws {
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              FileManager.default.isReadableFile(atPath: configurationURL.path) else {
            throw WorkerTransportError.invalidConfiguration
        }
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data = try propertyListData(executableURL: executableURL, configurationURL: configurationURL)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
    }

    static func propertyListData(executableURL: URL, configurationURL: URL) throws -> Data {
        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path, "--worker", "--config", configurationURL.standardizedFileURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    static func bootstrap() throws {
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func bootout() throws {
        try runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    static func uninstall() throws {
        try? bootout()
        try FileManager.default.removeItem(at: plistURL)
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkerTransportError.connectionFailed }
    }
}