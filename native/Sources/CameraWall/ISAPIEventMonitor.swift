import Foundation
import CameraCore

private final class ISAPIInvalidationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        lock.lock()
        invalidated = true
        let current = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if invalidated {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class ISAPIEventMonitor: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private enum MonitorError: Error {
        case invalidEndpoint
        case invalidResponse
        case streamEnded
        case untrackedSession
    }

    private let camera: Camera
    private let credentials: Credentials
    private let delegateWork = CameraRuntimeWorkGroup()
    private let invalidation = ISAPIInvalidationSignal()
    private let delegateQueue = OperationQueue()
    private let ownsDelegateSession: Bool
    private var session: URLSession!

    init(camera: Camera, credentials: Credentials, session testSession: URLSession? = nil,
         configuration testConfiguration: URLSessionConfiguration? = nil) {
        self.camera = camera
        self.credentials = credentials
        self.ownsDelegateSession = testSession == nil
        let configuration = testConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.connectionProxyDictionary = [:]
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        session = testSession ?? URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    static func endpoint(for camera: Camera) -> URL? {
        guard let source = URLComponents(string: camera.substream), let host = source.host else { return nil }
        var endpoint = URLComponents()
        endpoint.scheme = camera.isapiHTTPS ? "https" : "http"
        endpoint.host = host
        endpoint.port = camera.isapiPort
        endpoint.path = "/ISAPI/Event/notification/alertStream"
        return endpoint.url
    }

    func run(onState: @escaping @MainActor @Sendable (String) -> Void,
             onEvent: @escaping @MainActor @Sendable (ISAPIEventRecord) -> Void) async {
        var retryDelay: UInt64 = 1
        while !Task.isCancelled {
            await onState("Connecting")
            do {
                try Task.checkCancellation()
                try await receiveOnce(onConnected: { onState("Connected") }, onEvent: onEvent)
                throw MonitorError.streamEnded
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                await onState("Retrying in \(retryDelay)s")
                do {
                    try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
                } catch {
                    break
                }
                retryDelay = min(retryDelay * 2, 15)
            }
        }
        cancel()
    }

    func cancel() {
        delegateWork.fence()
        session.invalidateAndCancel()
    }

    func waitForShutdown() async throws {
        guard ownsDelegateSession else { throw MonitorError.untrackedSession }
        await invalidation.wait()
        await delegateWork.wait()
    }

    func receiveOnce(onConnected: @escaping @MainActor @Sendable () async -> Void = {},
                     onEvent: @escaping @MainActor @Sendable (ISAPIEventRecord) -> Void) async throws {
        guard let endpoint = Self.endpoint(for: camera) else { throw MonitorError.invalidEndpoint }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 180
        request.setValue("multipart/mixed, application/xml", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MonitorError.invalidResponse
        }
        await onConnected()
        try Task.checkCancellation()

        var decoder = ISAPIEventStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= ISAPIEventXMLParser.maximumEventBytes else {
                throw ISAPIEventParseError.oversizedEvent
            }
            for payload in try decoder.append(Data((line + "\n").utf8)) {
                await onEvent(ISAPIEventRecord(cameraID: camera.id, cameraName: camera.name, payload: payload))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                   didReceive challenge: URLAuthenticationChallenge,
                   completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let ticket = delegateWork.begin() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        defer { ticket.finish() }
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              !credentials.username.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let credential = URLCredential(user: credentials.username, password: credentials.password,
                                       persistence: .forSession)
        completionHandler(.useCredential, credential)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        delegateQueue.addOperation { [invalidation] in invalidation.finish() }
    }
}