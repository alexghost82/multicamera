import XCTest
import CameraCore
@testable import CameraWall

final class ISAPIEventMonitorTests: XCTestCase {
    override func tearDown() {
        ISAPIStubURLProtocol.responseData = nil
        ISAPIStubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testEndpointUsesConfiguredSchemePortAndStreamHost() throws {
        let camera = Camera(name: "Gate", substream: "rtsp://[2001:db8::10]:554/live",
                            isapiEventsEnabled: true, isapiHTTPS: true, isapiPort: 8443)

        let endpoint = try XCTUnwrap(ISAPIEventMonitor.endpoint(for: camera))

        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "2001:db8::10")
        XCTAssertEqual(endpoint.port, 8443)
        XCTAssertEqual(endpoint.path, "/ISAPI/Event/notification/alertStream")
        XCTAssertNil(endpoint.user)
        XCTAssertNil(endpoint.password)
    }

    func testEndpointRejectsLocalCamera() {
        let camera = Camera(name: "Mac", substream: "", localDeviceID: "device")
        XCTAssertNil(ISAPIEventMonitor.endpoint(for: camera))
    }

    @MainActor
    func testAlertStreamRequestParsesEventsWithoutPuttingCredentialsInURL() async throws {
        ISAPIStubURLProtocol.responseData = Data("--boundary\r\nContent-Type: application/xml\r\n\r\n<EventNotificationAlert><eventType>VMD</eventType><eventState>active</eventState><channelID>2</channelID></EventNotificationAlert>\r\n--boundary--\r\n".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ISAPIStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let cameraID = UUID()
        let camera = Camera(id: cameraID, name: "Gate", substream: "rtsp://camera.local/live",
                            isapiEventsEnabled: true)
        let monitor = ISAPIEventMonitor(camera: camera,
                                        credentials: Credentials(username: "operator", password: "secret"),
                                        session: session)
        var received: [ISAPIEventRecord] = []

        try await monitor.receiveOnce(onEvent: { received.append($0) })

        let request = try XCTUnwrap(ISAPIStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/ISAPI/Event/notification/alertStream")
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.password)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "multipart/mixed, application/xml")
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].cameraID, cameraID)
        XCTAssertEqual(received[0].eventType, "VMD")
        XCTAssertEqual(received[0].eventState, "active")
        XCTAssertEqual(received[0].channelID, "2")
    }

    @MainActor
    func testCancelledSyntheticStreamJoinsSessionInvalidation() async throws {
        ISAPIStubURLProtocol.responseData = Data("--boundary--\r\n".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ISAPIStubURLProtocol.self]
        let camera = Camera(name: "synthetic", substream: "rtsp://fixture.invalid/live",
                            isapiEventsEnabled: true)
        let monitor = ISAPIEventMonitor(camera: camera,
            credentials: Credentials(username: "", password: ""), configuration: configuration)
        var connected = false
        let run = Task { await monitor.run(onState: { if $0 == "Connected" { connected = true } },
                                            onEvent: { _ in }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(connected)
        monitor.cancel()
        run.cancel()
        await run.value
        try await monitor.waitForShutdown()
    }

    @MainActor
    func testCancellingPendingSyntheticRequestJoinsMonitor() async throws {
        let started = expectation(description: "synthetic request started")
        let stopped = expectation(description: "synthetic request stopped")
        ISAPIPendingURLProtocol.configure(start: { started.fulfill() }, stop: { stopped.fulfill() })
        defer { ISAPIPendingURLProtocol.configure(start: nil, stop: nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ISAPIPendingURLProtocol.self]
        let camera = Camera(name: "synthetic", substream: "rtsp://fixture.invalid/live")
        let monitor = ISAPIEventMonitor(camera: camera,
            credentials: Credentials(username: "", password: ""), configuration: configuration)
        var states: [String] = []
        let run = Task { await monitor.run(onState: { states.append($0) }, onEvent: { _ in }) }
        await fulfillment(of: [started], timeout: 1)
        monitor.cancel()
        run.cancel()
        await run.value
        try await monitor.waitForShutdown()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(states, ["Connecting"])
    }

    @MainActor
    func testShutdownWaitsForInFlightAuthenticationCallbackAndRejectsLateOne() async throws {
        let camera = Camera(name: "synthetic", substream: "rtsp://fixture.invalid/live")
        let monitor = ISAPIEventMonitor(camera: camera,
            credentials: Credentials(username: "synthetic", password: "synthetic"))
        let probe = SyntheticISAPIChallenge(monitor: monitor)
        let entered = expectation(description: "authentication callback entered")
        DispatchQueue.global().async {
            probe.deliver {
                entered.fulfill()
                _ = probe.release.wait(timeout: .now() + 2)
            }
        }
        defer { probe.release.signal(); probe.session.invalidateAndCancel() }
        await fulfillment(of: [entered], timeout: 1)
        monitor.cancel()
        var drained = false
        let drain = Task { @MainActor in
            try await monitor.waitForShutdown()
            drained = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(drained)
        probe.release.signal()
        try await drain.value
        XCTAssertTrue(drained)
        var disposition: URLSession.AuthChallengeDisposition?
        monitor.urlSession(probe.session, task: probe.task, didReceive: probe.challenge) { value, _ in
            disposition = value
        }
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
    }
}

private final class ISAPIPendingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var onStart: (() -> Void)?
    private static var onStop: (() -> Void)?
    static func configure(start: (() -> Void)?, stop: (() -> Void)?) {
        lock.lock()
        onStart = start
        onStop = stop
        lock.unlock()
    }
    private static func callback(start: Bool) -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return start ? onStart : onStop
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.callback(start: true)?() }
    override func stopLoading() { Self.callback(start: false)?() }
}

private final class SyntheticChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class SyntheticISAPIChallenge: @unchecked Sendable {
    let session = URLSession(configuration: .ephemeral)
    let task: URLSessionDataTask
    let challenge: URLAuthenticationChallenge
    let release = DispatchSemaphore(value: 0)
    let monitor: ISAPIEventMonitor

    init(monitor: ISAPIEventMonitor) {
        self.monitor = monitor
        task = session.dataTask(with: URL(string: "http://fixture.invalid/")!)
        let space = URLProtectionSpace(host: "fixture.invalid", port: 80, protocol: "http",
                                       realm: "synthetic", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: SyntheticChallengeSender())
    }

    func deliver(_ entered: @escaping () -> Void) {
        monitor.urlSession(session, task: task, didReceive: challenge) { _, _ in entered() }
    }
}

private final class ISAPIStubURLProtocol: URLProtocol {
    static var responseData: Data?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let data = Self.responseData,
              let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "multipart/mixed; boundary=boundary"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}