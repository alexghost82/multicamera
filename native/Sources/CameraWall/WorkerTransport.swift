import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security
import CameraCore

enum WorkerTransportError: Error, LocalizedError {
    case invalidConfiguration
    case identityUnavailable
    case untrustedPeer
    case invalidPeerCertificate
    case connectionFailed
    case remoteRejected(String?)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Worker transport configuration is invalid."
        case .identityUnavailable: return "The configured worker TLS identity is unavailable in Keychain."
        case .untrustedPeer, .invalidPeerCertificate: return "Worker peer authentication failed."
        case .connectionFailed: return "Worker control connection failed."
        case .remoteRejected(let code): return "Worker coordinator rejected the request: \(code ?? "unknown")."
        }
    }
}

struct WorkerTLSConfiguration {
    let identityLabel: String
    let trustedPeerIDsByFingerprint: [String: UUID]
    let localIdentityOverride: SecIdentity?
    let trustAnchors: [SecCertificate]

    init(identityLabel: String, trustedPeerIDsByFingerprint: [String: UUID]) throws {
        let label = identityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let peers = try Self.normalize(trustedPeerIDsByFingerprint)
        guard !label.isEmpty, label.count <= 256, !peers.isEmpty else {
            throw WorkerTransportError.invalidConfiguration
        }
        self.identityLabel = label
        self.trustedPeerIDsByFingerprint = peers
        self.localIdentityOverride = nil
        self.trustAnchors = []
    }

    init(localIdentity: SecIdentity, trustAnchors: [SecCertificate],
         trustedPeerIDsByFingerprint: [String: UUID]) throws {
        let peers = try Self.normalize(trustedPeerIDsByFingerprint)
        guard !peers.isEmpty, !trustAnchors.isEmpty else {
            throw WorkerTransportError.invalidConfiguration
        }
        self.identityLabel = "in-memory-test-identity"
        self.trustedPeerIDsByFingerprint = peers
        self.localIdentityOverride = localIdentity
        self.trustAnchors = trustAnchors
    }

    private static func normalize(_ values: [String: UUID]) throws -> [String: UUID] {
        var peers: [String: UUID] = [:]
        for (fingerprint, workerID) in values {
            let normalized = fingerprint.lowercased().replacingOccurrences(of: ":", with: "")
            guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit), peers[normalized] == nil else {
                throw WorkerTransportError.invalidConfiguration
            }
            peers[normalized] = workerID
        }
        return peers
    }
}

enum WorkerTLSIdentity {
    static func load(label: String) throws -> SecIdentity {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw WorkerTransportError.identityUnavailable
        }
        return result as! SecIdentity
    }

    static func fingerprint(_ certificate: SecCertificate) -> String {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func peerFingerprint(for connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var leaf: SecCertificate?
        let accessible = sec_protocol_metadata_access_peer_certificate_chain(
            metadata.securityProtocolMetadata
        ) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        guard accessible, let leaf else { return nil }
        return fingerprint(leaf)
    }

    static func parameters(identity: SecIdentity, trustedFingerprints: Set<String>,
                           trustAnchors: [SecCertificate] = [], queue: DispatchQueue) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let protocolIdentity = sec_identity_create(identity) else {
            throw WorkerTransportError.identityUnavailable
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, protocolIdentity)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetNetworkFetchAllowed(trustRef, false)
            if !trustAnchors.isEmpty {
                SecTrustSetAnchorCertificates(trustRef, trustAnchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trustRef, true)
            }
            var trustError: CFError?
            guard SecTrustEvaluateWithError(trustRef, &trustError),
                  let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            complete(trustedFingerprints.contains(fingerprint(leaf)))
        }, queue)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

final class WorkerControlServer: @unchecked Sendable {
    private let coordinator: WorkerCoordinator
    private let tlsConfiguration: WorkerTLSConfiguration
    private let assignmentPlan: [UUID: UUID]
    private let queue = DispatchQueue(label: "CameraWall.WorkerControlServer", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let lock = NSLock()
    private let maximumConnections = 32
    private let connectionTimeout: TimeInterval = 10

    init(coordinator: WorkerCoordinator, tlsConfiguration: WorkerTLSConfiguration,
         assignmentPlan: [UUID: UUID] = [:]) {
        self.coordinator = coordinator
        self.tlsConfiguration = tlsConfiguration
        self.assignmentPlan = assignmentPlan
    }

    func start(bindAddress: String, port: UInt16) async throws -> UInt16 {
        guard port == 0 || port >= 1024, bindAddress != "0.0.0.0", bindAddress != "::" else {
            throw WorkerTransportError.invalidConfiguration
        }
        let host: NWEndpoint.Host
        if let address = IPv4Address(bindAddress) {
            host = .ipv4(address)
        } else if let address = IPv6Address(bindAddress) {
            host = .ipv6(address)
        } else {
            throw WorkerTransportError.invalidConfiguration
        }
        let identity = try tlsConfiguration.localIdentityOverride
            ?? WorkerTLSIdentity.load(label: tlsConfiguration.identityLabel)
        let parameters = try WorkerTLSIdentity.parameters(
            identity: identity,
            trustedFingerprints: Set(tlsConfiguration.trustedPeerIDsByFingerprint.keys),
            trustAnchors: tlsConfiguration.trustAnchors,
            queue: queue
        )
        let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: endpointPort)
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let completion = WorkerListenerStartCompletion(continuation)
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let newListener else {
                    completion.finish(.failure(WorkerTransportError.connectionFailed))
                    return
                }
                switch state {
                case .ready:
                    guard let actualPort = newListener.port?.rawValue else {
                        completion.finish(.failure(WorkerTransportError.connectionFailed))
                        return
                    }
                    completion.finish(.success(actualPort))
                case .failed(let error):
                    completion.finish(.failure(error))
                    self?.clear(newListener)
                case .cancelled:
                    completion.finish(.failure(WorkerTransportError.connectionFailed))
                    self?.clear(newListener)
                default:
                    break
                }
            }
            lock.lock()
            guard listener == nil else {
                lock.unlock()
                newListener.cancel()
                completion.finish(.failure(WorkerTransportError.invalidConfiguration))
                return
            }
            listener = newListener
            lock.unlock()
            newListener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        let currentListener = listener
        listener = nil
        let active = Array(connections.values)
        let timeouts = Array(connectionTimeouts.values)
        connections.removeAll()
        connectionTimeouts.removeAll()
        lock.unlock()
        currentListener?.cancel()
        timeouts.forEach { $0.cancel() }
        active.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        guard connections.count < maximumConnections else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[identifier] = connection
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.cancel()
            self.finish(connection)
        }
        connectionTimeouts[identifier] = timeout
        lock.unlock()
        queue.asyncAfter(deadline: .now() + connectionTimeout, execute: timeout)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                guard let fingerprint = WorkerTLSIdentity.peerFingerprint(for: connection),
                      let peerID = self.tlsConfiguration.trustedPeerIDsByFingerprint[fingerprint] else {
                    connection.cancel()
                    return
                }
                self.receiveFrame(on: connection, peerID: peerID)
            case .failed, .cancelled:
                self.finish(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveFrame(on connection: NWConnection, peerID: UUID) {
        WorkerNetworkIO.receiveFrame(on: connection, queue: queue) { [weak self] result in
            guard let self else { connection.cancel(); return }
            Task {
                var requestID = UUID()
                let response: WorkerControlResponse
                do {
                    let payload = try WorkerWireCodec.decode(result.get(), as: WorkerControlRequest.self)
                    requestID = payload.requestID
                    try payload.validate(supportedProtocolVersion: 1)
                    switch payload.kind {
                    case .register:
                        guard let registration = payload.registration else {
                            throw WorkerCoordinatorError.invalidRegistration
                        }
                        try await self.coordinator.register(registration, authenticatedWorkerID: peerID)
                        response = WorkerControlResponse(requestID: requestID, accepted: true)
                    case .heartbeat:
                        guard let heartbeat = payload.heartbeat else {
                            throw WorkerCoordinatorError.invalidHeartbeat
                        }
                        _ = try await self.coordinator.heartbeat(heartbeat, authenticatedWorkerID: peerID)
                        let cameraIDs = self.assignmentPlan.filter { $0.value == peerID }.map(\.key)
                            .sorted { $0.uuidString < $1.uuidString }
                        _ = try await self.coordinator.assign(cameraIDs: cameraIDs, to: peerID)
                        let leases = await self.coordinator.leases(for: peerID)
                        response = WorkerControlResponse(requestID: requestID, accepted: true, leases: leases)
                    }
                } catch let error as WorkerCoordinatorError {
                    response = WorkerControlResponse(requestID: requestID, accepted: false,
                                                     errorCode: error.code)
                } catch {
                    response = WorkerControlResponse(requestID: requestID, accepted: false,
                                                     errorCode: "invalid_request")
                }
                guard let frame = try? WorkerWireCodec.encode(response) else {
                    connection.cancel()
                    self.finish(connection)
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { _ in
                    connection.cancel()
                    self.finish(connection)
                })
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        lock.lock()
        let identifier = ObjectIdentifier(connection)
        connections.removeValue(forKey: identifier)
        let timeout = connectionTimeouts.removeValue(forKey: identifier)
        lock.unlock()
        timeout?.cancel()
    }

    private func clear(_ candidate: NWListener) {
        lock.lock()
        if listener === candidate { listener = nil }
        lock.unlock()
    }
}

private final class WorkerListenerStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<UInt16, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}

enum WorkerControlClient {
    static func request(_ request: WorkerControlRequest, host: String, port: UInt16,
                        tlsConfiguration: WorkerTLSConfiguration) async throws -> WorkerControlResponse {
        guard port >= 1024, tlsConfiguration.trustedPeerIDsByFingerprint.count == 1,
              let expectedPeerID = tlsConfiguration.trustedPeerIDsByFingerprint.values.first else {
            throw WorkerTransportError.invalidConfiguration
        }
        let endpointHost: NWEndpoint.Host
        if let address = IPv4Address(host) {
            endpointHost = .ipv4(address)
        } else if let address = IPv6Address(host) {
            endpointHost = .ipv6(address)
        } else {
            throw WorkerTransportError.invalidConfiguration
        }
        let identity = try tlsConfiguration.localIdentityOverride
            ?? WorkerTLSIdentity.load(label: tlsConfiguration.identityLabel)
        let parameters = try WorkerTLSIdentity.parameters(
            identity: identity,
            trustedFingerprints: Set(tlsConfiguration.trustedPeerIDsByFingerprint.keys),
            trustAnchors: tlsConfiguration.trustAnchors,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        let connection = NWConnection(to: .hostPort(host: endpointHost, port: NWEndpoint.Port(rawValue: port)!),
                                      using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let operation = WorkerControlRequestOperation(connection: connection, request: request,
                                                          expectedPeerID: expectedPeerID,
                                                          trustedPeerIDsByFingerprint: tlsConfiguration.trustedPeerIDsByFingerprint,
                                                          continuation: continuation)
            operation.startTimeout()
            connection.stateUpdateHandler = { state in operation.update(state) }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }
}

private final class WorkerControlRequestOperation {
    private let connection: NWConnection
    private let request: WorkerControlRequest
    private let expectedPeerID: UUID
    private let trustedPeerIDsByFingerprint: [String: UUID]
    private let continuation: CheckedContinuation<WorkerControlResponse, Error>
    private let lock = NSLock()
    private var completed = false
    private var sent = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(connection: NWConnection, request: WorkerControlRequest, expectedPeerID: UUID,
         trustedPeerIDsByFingerprint: [String: UUID],
         continuation: CheckedContinuation<WorkerControlResponse, Error>) {
        self.connection = connection
        self.request = request
        self.expectedPeerID = expectedPeerID
        self.trustedPeerIDsByFingerprint = trustedPeerIDsByFingerprint
        self.continuation = continuation
    }

    func startTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(WorkerTransportError.connectionFailed))
        }
        lock.lock()
        timeoutWorkItem = timeout
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func update(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let fingerprint = WorkerTLSIdentity.peerFingerprint(for: connection),
                  trustedPeerIDsByFingerprint[fingerprint] == expectedPeerID else {
                finish(.failure(WorkerTransportError.untrustedPeer))
                return
            }
            lock.lock()
            let shouldSend = !sent && !completed
            sent = true
            lock.unlock()
            if shouldSend { send() }
        case .failed:
            finish(.failure(WorkerTransportError.connectionFailed))
        case .cancelled:
            finish(.failure(WorkerTransportError.connectionFailed))
        default:
            break
        }
    }

    private func send() {
        do {
            let frame = try WorkerWireCodec.encode(request)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.finish(.failure(WorkerTransportError.connectionFailed))
                } else {
                    WorkerNetworkIO.receiveFrame(on: self.connection, queue: .global(qos: .userInitiated)) { result in
                        do {
                            let response = try WorkerWireCodec.decode(result.get(), as: WorkerControlResponse.self)
                            guard response.requestID == self.request.requestID,
                                  response.protocolVersion == self.request.protocolVersion else {
                                throw WorkerTransportError.connectionFailed
                            }
                            guard response.accepted else { throw WorkerTransportError.remoteRejected(response.errorCode) }
                            self.finish(.success(response))
                        } catch {
                            self.finish(.failure(error))
                        }
                    }
                }
            })
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<WorkerControlResponse, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let timeout = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()
        timeout?.cancel()
        connection.cancel()
        continuation.resume(with: result)
    }
}

private enum WorkerNetworkIO {
    static func receiveFrame(on connection: NWConnection, queue: DispatchQueue,
                             completion: @escaping (Result<Data, Error>) -> Void) {
        receiveExactly(on: connection, count: WorkerWireCodec.frameHeaderBytes, accumulated: Data(), queue: queue) { headerResult in
            do {
                let header = try headerResult.get()
                let payloadLength = try WorkerWireCodec.payloadLength(from: header)
                receiveExactly(on: connection, count: payloadLength, accumulated: Data(), queue: queue) { payloadResult in
                    completion(payloadResult)
                }
            } catch { completion(.failure(error)) }
        }
    }

    private static func receiveExactly(on connection: NWConnection, count: Int, accumulated: Data,
                                       queue: DispatchQueue, completion: @escaping (Result<Data, Error>) -> Void) {
        guard accumulated.count < count else { completion(.success(accumulated)); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { data, _, complete, error in
            if let error { completion(.failure(error)); return }
            guard let data, !data.isEmpty else {
                completion(.failure(WorkerTransportError.connectionFailed))
                return
            }
            var next = accumulated
            next.append(data)
            if next.count == count {
                completion(.success(next))
            } else if complete || next.count > count {
                completion(.failure(WorkerTransportError.connectionFailed))
            } else {
                receiveExactly(on: connection, count: count, accumulated: next, queue: queue, completion: completion)
            }
        }
    }
}
