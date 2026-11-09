import Foundation

public struct WorkerRegistration: Codable, Equatable, Sendable {
    public let workerID: UUID
    public let sessionID: UUID
    public let displayName: String
    public let protocolVersion: Int
    public let cameraIDs: Set<UUID>
    public let maximumCameraCount: Int
    public let modelIdentifiers: Set<String>

    public init(workerID: UUID, sessionID: UUID, displayName: String, protocolVersion: Int = 1,
                cameraIDs: Set<UUID>, maximumCameraCount: Int, modelIdentifiers: Set<String>) {
        self.workerID = workerID
        self.sessionID = sessionID
        self.displayName = displayName
        self.protocolVersion = protocolVersion
        self.cameraIDs = cameraIDs
        self.maximumCameraCount = maximumCameraCount
        self.modelIdentifiers = modelIdentifiers
    }

    fileprivate func validate() throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...256).contains(displayName.count),
              (1...256).contains(maximumCameraCount),
              modelIdentifiers.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
            throw WorkerCoordinatorError.invalidRegistration
        }
    }
}

public struct WorkerHeartbeat: Codable, Equatable, Sendable {
    public let workerID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let activeCameraIDs: Set<UUID>
    public let processedFramesPerSecond: Double
    public let queueDepth: Int
    public let availableMemoryBytes: UInt64?

    public init(workerID: UUID, sessionID: UUID, sequence: UInt64, activeCameraIDs: Set<UUID>,
                processedFramesPerSecond: Double, queueDepth: Int, availableMemoryBytes: UInt64? = nil) {
        self.workerID = workerID
        self.sessionID = sessionID
        self.sequence = sequence
        self.activeCameraIDs = activeCameraIDs
        self.processedFramesPerSecond = processedFramesPerSecond
        self.queueDepth = queueDepth
        self.availableMemoryBytes = availableMemoryBytes
    }
}

public struct WorkerCameraLease: Codable, Equatable, Sendable {
    public let leaseID: UUID
    public let cameraID: UUID
    public let workerID: UUID
    public let generation: UInt64
    public let expiresAt: Date
}

public struct WorkerHeartbeatStatus: Codable, Equatable, Sendable {
    public let workerID: UUID
    public let sessionID: UUID
    public let lastHeartbeatAt: Date
    public let processedFramesPerSecond: Double
    public let queueDepth: Int
    public let availableMemoryBytes: UInt64?
}

public struct WorkerControlRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case register
        case heartbeat
    }

    public let requestID: UUID
    public let protocolVersion: Int
    public let kind: Kind
    public let registration: WorkerRegistration?
    public let heartbeat: WorkerHeartbeat?

    public init(requestID: UUID = UUID(), protocolVersion: Int = 1,
                registration: WorkerRegistration) {
        self.requestID = requestID
        self.protocolVersion = protocolVersion
        self.kind = .register
        self.registration = registration
        self.heartbeat = nil
    }

    public init(requestID: UUID = UUID(), protocolVersion: Int = 1,
                heartbeat: WorkerHeartbeat) {
        self.requestID = requestID
        self.protocolVersion = protocolVersion
        self.kind = .heartbeat
        self.registration = nil
        self.heartbeat = heartbeat
    }

    public func validate(supportedProtocolVersion: Int) throws {
        guard protocolVersion == supportedProtocolVersion else {
            throw WorkerCoordinatorError.unsupportedProtocolVersion
        }
        switch kind {
        case .register:
            guard registration != nil, heartbeat == nil else { throw WorkerCoordinatorError.invalidRegistration }
        case .heartbeat:
            guard heartbeat != nil, registration == nil else { throw WorkerCoordinatorError.invalidHeartbeat }
        }
    }
}

public struct WorkerControlResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let protocolVersion: Int
    public let accepted: Bool
    public let leases: [WorkerCameraLease]
    public let errorCode: String?

    public init(requestID: UUID, protocolVersion: Int = 1, accepted: Bool,
                leases: [WorkerCameraLease] = [], errorCode: String? = nil) {
        self.requestID = requestID
        self.protocolVersion = protocolVersion
        self.accepted = accepted
        self.leases = leases
        self.errorCode = errorCode
    }
}

public enum WorkerWireCodec {
    public static let maximumPayloadBytes = 64 * 1024
    public static let frameHeaderBytes = 4

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(value)
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw WorkerWireError.invalidPayloadSize
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func payloadLength(from header: Data) throws -> Int {
        guard header.count == frameHeaderBytes else { throw WorkerWireError.invalidHeader }
        let length = header.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumPayloadBytes else { throw WorkerWireError.invalidPayloadSize }
        return Int(length)
    }

    public static func decode<T: Decodable>(_ payload: Data, as type: T.Type) throws -> T {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw WorkerWireError.invalidPayloadSize
        }
        return try JSONDecoder().decode(type, from: payload)
    }
}

public enum WorkerWireError: Error, Equatable {
    case invalidHeader
    case invalidPayloadSize
}

public enum WorkerCoordinatorError: Error, Equatable {
    case unauthenticatedWorker
    case invalidRegistration
    case unsupportedProtocolVersion
    case duplicateRegistration
    case workerNotRegistered
    case sessionMismatch
    case staleHeartbeat
    case invalidHeartbeat
    case cameraNotProvisioned
    case cameraAlreadyLeased
    case leaseNotOwned
    case invalidAssignment
    case workerAtCapacity
    case workerNotHealthy

    public var code: String {
        switch self {
        case .unauthenticatedWorker: return "unauthenticated_worker"
        case .invalidRegistration: return "invalid_registration"
        case .unsupportedProtocolVersion: return "unsupported_protocol_version"
        case .duplicateRegistration: return "duplicate_registration"
        case .workerNotRegistered: return "worker_not_registered"
        case .sessionMismatch: return "session_mismatch"
        case .staleHeartbeat: return "stale_heartbeat"
        case .invalidHeartbeat: return "invalid_heartbeat"
        case .cameraNotProvisioned: return "camera_not_provisioned"
        case .cameraAlreadyLeased: return "camera_already_leased"
        case .leaseNotOwned: return "lease_not_owned"
        case .invalidAssignment: return "invalid_assignment"
        case .workerAtCapacity: return "worker_at_capacity"
        case .workerNotHealthy: return "worker_not_healthy"
        }
    }
}

public actor WorkerCoordinator {
    public let protocolVersion: Int
    public let leaseDuration: TimeInterval
    public let heartbeatTimeout: TimeInterval

    private struct WorkerState {
        var registration: WorkerRegistration
        var lastHeartbeatSequence: UInt64?
        var lastHeartbeatAt: Date?
        var processedFramesPerSecond = 0.0
        var queueDepth = 0
        var availableMemoryBytes: UInt64?
    }

    private var workers: [UUID: WorkerState] = [:]
    private var leases: [UUID: WorkerCameraLease] = [:]
    private var leaseGenerations: [UUID: UInt64] = [:]

    public init(protocolVersion: Int = 1, leaseDuration: TimeInterval = 30,
                heartbeatTimeout: TimeInterval = 10) {
        precondition(protocolVersion > 0)
        precondition(leaseDuration.isFinite && leaseDuration > 0)
        precondition(heartbeatTimeout.isFinite && heartbeatTimeout > 0 && heartbeatTimeout < leaseDuration)
        self.protocolVersion = protocolVersion
        self.leaseDuration = leaseDuration
        self.heartbeatTimeout = heartbeatTimeout
    }

    public func register(_ registration: WorkerRegistration, authenticatedWorkerID: UUID,
                         at time: Date = Date()) throws {
        guard registration.workerID == authenticatedWorkerID else {
            throw WorkerCoordinatorError.unauthenticatedWorker
        }
        try registration.validate()
        guard registration.protocolVersion == protocolVersion else {
            throw WorkerCoordinatorError.unsupportedProtocolVersion
        }
        if workers[registration.workerID]?.registration.sessionID == registration.sessionID {
            throw WorkerCoordinatorError.duplicateRegistration
        }

        let previousCameraIDs = leases.values.filter { $0.workerID == registration.workerID }.map(\.cameraID)
        for cameraID in previousCameraIDs { leases.removeValue(forKey: cameraID) }
        workers[registration.workerID] = WorkerState(registration: registration)
        _ = expireLeases(at: time)
    }

    @discardableResult
    public func heartbeat(_ heartbeat: WorkerHeartbeat, authenticatedWorkerID: UUID,
                          at time: Date = Date()) throws -> [WorkerCameraLease] {
        guard heartbeat.workerID == authenticatedWorkerID else {
            throw WorkerCoordinatorError.unauthenticatedWorker
        }
        guard var worker = workers[heartbeat.workerID] else {
            throw WorkerCoordinatorError.workerNotRegistered
        }
        guard heartbeat.sessionID == worker.registration.sessionID else {
            throw WorkerCoordinatorError.sessionMismatch
        }
        if let lastSequence = worker.lastHeartbeatSequence, heartbeat.sequence <= lastSequence {
            throw WorkerCoordinatorError.staleHeartbeat
        }
        _ = expireLeases(at: time)
        guard heartbeat.processedFramesPerSecond.isFinite,
              heartbeat.processedFramesPerSecond >= 0,
              heartbeat.queueDepth >= 0,
              heartbeat.activeCameraIDs.count <= worker.registration.maximumCameraCount else {
            throw WorkerCoordinatorError.invalidHeartbeat
        }

        let workerLeases = leases.values.filter { $0.workerID == heartbeat.workerID && $0.expiresAt > time }
        let assignedCameraIDs = Set(workerLeases.map(\.cameraID))
        guard heartbeat.activeCameraIDs.isSubset(of: assignedCameraIDs) else {
            throw WorkerCoordinatorError.invalidHeartbeat
        }

        worker.lastHeartbeatSequence = heartbeat.sequence
        worker.lastHeartbeatAt = time
        worker.processedFramesPerSecond = heartbeat.processedFramesPerSecond
        worker.queueDepth = heartbeat.queueDepth
        worker.availableMemoryBytes = heartbeat.availableMemoryBytes
        workers[heartbeat.workerID] = worker

        let renewed = workerLeases.map { lease in
            WorkerCameraLease(leaseID: lease.leaseID, cameraID: lease.cameraID, workerID: lease.workerID,
                              generation: lease.generation, expiresAt: time.addingTimeInterval(leaseDuration))
        }
        for lease in renewed { leases[lease.cameraID] = lease }
        return renewed.sorted { $0.cameraID.uuidString < $1.cameraID.uuidString }
    }

    public func assign(cameraID: UUID, to workerID: UUID, at time: Date = Date()) throws -> WorkerCameraLease {
        guard let lease = try assign(cameraIDs: [cameraID], to: workerID, at: time).first(where: { $0.cameraID == cameraID }) else {
            throw WorkerCoordinatorError.invalidAssignment
        }
        return lease
    }

    public func assign(cameraIDs: [UUID], to workerID: UUID, at time: Date = Date()) throws -> [WorkerCameraLease] {
        _ = expireLeases(at: time)
        guard let worker = workers[workerID] else { throw WorkerCoordinatorError.workerNotRegistered }
        guard Set(cameraIDs).count == cameraIDs.count,
              cameraIDs.allSatisfy(worker.registration.cameraIDs.contains) else {
            throw WorkerCoordinatorError.cameraNotProvisioned
        }
        guard let lastHeartbeatAt = worker.lastHeartbeatAt,
              time.timeIntervalSince(lastHeartbeatAt) < heartbeatTimeout else {
            throw WorkerCoordinatorError.workerNotHealthy
        }

        for cameraID in cameraIDs {
            if let lease = leases[cameraID], lease.workerID != workerID {
                throw WorkerCoordinatorError.cameraAlreadyLeased
            }
        }
        let currentLeases = leases.values.filter { $0.workerID == workerID && $0.expiresAt > time }
        let currentCameraIDs = Set(currentLeases.map(\.cameraID))
        let newCameraIDs = Set(cameraIDs).subtracting(currentCameraIDs)
        guard currentLeases.count + newCameraIDs.count <= worker.registration.maximumCameraCount else {
            throw WorkerCoordinatorError.workerAtCapacity
        }

        for cameraID in newCameraIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let generation = (leaseGenerations[cameraID] ?? 0) &+ 1
            leaseGenerations[cameraID] = generation
            leases[cameraID] = WorkerCameraLease(leaseID: UUID(), cameraID: cameraID, workerID: workerID,
                                                 generation: generation,
                                                 expiresAt: time.addingTimeInterval(leaseDuration))
        }
        return leases.values.filter { $0.workerID == workerID && $0.expiresAt > time }
            .sorted { $0.cameraID.uuidString < $1.cameraID.uuidString }
    }

    public func release(cameraID: UUID, from workerID: UUID, authenticatedWorkerID: UUID) throws {
        guard workerID == authenticatedWorkerID else { throw WorkerCoordinatorError.unauthenticatedWorker }
        guard let lease = leases[cameraID], lease.workerID == workerID else {
            throw WorkerCoordinatorError.leaseNotOwned
        }
        leases.removeValue(forKey: cameraID)
    }

    @discardableResult
    public func expire(at time: Date = Date()) -> [WorkerCameraLease] {
        return expireLeases(at: time)
    }

    public func lease(for cameraID: UUID, at time: Date = Date()) -> WorkerCameraLease? {
        guard let lease = leases[cameraID], lease.expiresAt > time,
              let worker = workers[lease.workerID], let lastHeartbeatAt = worker.lastHeartbeatAt,
              time.timeIntervalSince(lastHeartbeatAt) < heartbeatTimeout else { return nil }
        return lease
    }

    public func leases(for workerID: UUID, at time: Date = Date()) -> [WorkerCameraLease] {
        _ = expireLeases(at: time)
        return leases.values.filter { $0.workerID == workerID && $0.expiresAt > time }
            .sorted { $0.cameraID.uuidString < $1.cameraID.uuidString }
    }

    public func workerStatus(_ workerID: UUID) -> WorkerHeartbeatStatus? {
        guard let worker = workers[workerID], let lastHeartbeatAt = worker.lastHeartbeatAt else { return nil }
        return WorkerHeartbeatStatus(workerID: workerID, sessionID: worker.registration.sessionID,
                                     lastHeartbeatAt: lastHeartbeatAt,
                                     processedFramesPerSecond: worker.processedFramesPerSecond,
                                     queueDepth: worker.queueDepth,
                                     availableMemoryBytes: worker.availableMemoryBytes)
    }

    private func expireLeases(at time: Date) -> [WorkerCameraLease] {
        let expiredCameraIDs = leases.compactMap { cameraID, lease -> UUID? in
            guard lease.expiresAt > time,
                  let worker = workers[lease.workerID],
                  let lastHeartbeatAt = worker.lastHeartbeatAt,
                  time.timeIntervalSince(lastHeartbeatAt) < heartbeatTimeout else { return cameraID }
            return nil
        }
        let expired = expiredCameraIDs.compactMap { leases.removeValue(forKey: $0) }
        return expired.sorted { $0.cameraID.uuidString < $1.cameraID.uuidString }
    }
}