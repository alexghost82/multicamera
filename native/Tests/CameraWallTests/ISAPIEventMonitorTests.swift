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