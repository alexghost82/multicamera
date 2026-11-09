import Foundation
import CameraCore

final class ISAPIEventMonitor: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private enum MonitorError: Error {
        case invalidEndpoint
        case invalidResponse
        case streamEnded
    }

    private let camera: Camera
    private let credentials: Credentials
    private var session: URLSession!

    init(camera: Camera, credentials: Credentials, session testSession: URLSession? = nil) {
        self.camera = camera
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.connectionProxyDictionary = [:]
        super.init()
        session = testSession ?? URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
                try await receiveOnce(onConnected: { onState("Connected") }, onEvent: onEvent)
                throw MonitorError.streamEnded
            } catch is CancellationError {
                break
            } catch {
                await onState("Retrying in \(retryDelay)s")
                do {
                    try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
                } catch {
                    break
                }
                retryDelay = min(retryDelay * 2, 15)
            }
        }
        session.invalidateAndCancel()
    }

    func cancel() {
        session.invalidateAndCancel()
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
}