import XCTest
@testable import CameraWall

final class LocalShowcaseServerTests: XCTestCase {
    @MainActor
    func testLoopbackServerRequiresTokenAndServesOnlyLocalReadOnlyRoutes() async throws {
        guard ProcessInfo.processInfo.environment["CAMERAWALL_RUN_SHOWCASE_NETWORK_INTEGRATION"] == "1" else {
            throw XCTSkip("Set CAMERAWALL_RUN_SHOWCASE_NETWORK_INTEGRATION=1 to run the loopback server integration test.")
        }
        let cameraID = UUID()
        let expectedSnapshot = Data("local frame".utf8)
        let server = LocalShowcaseServer(
            cameraProvider: { [LocalShowcaseCamera(id: cameraID, name: "Entrance")] },
            snapshotProvider: { id in
                guard id == cameraID else { throw LocalVLMError.invalidImage }
                return expectedSnapshot
            },
            questionHandler: { id, question in
                guard id == cameraID, question == "What is visible?" else { throw LocalVLMError.invalidResponse }
                return "A vehicle is visible."
            },
            statusHandler: { _, _, _ in }
        )
        try server.start()
        defer { server.stop() }

        for _ in 0..<100 where server.shareURL == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let shareURL = try XCTUnwrap(server.shareURL)
        XCTAssertEqual(shareURL.host, "127.0.0.1")
        let shareComponents = try XCTUnwrap(URLComponents(url: shareURL, resolvingAgainstBaseURL: false))
        let token = try XCTUnwrap(shareComponents.queryItems?.first(where: { $0.name == "token" })?.value)

        var rootRequest = URLRequest(url: shareURL)
        rootRequest.timeoutInterval = 3
        let (page, _) = try await URLSession.shared.data(for: rootRequest)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Local CameraWall"))

        var camerasURL = try XCTUnwrap(URLComponents(url: shareURL, resolvingAgainstBaseURL: false))
        camerasURL.path = "/api/cameras"
        camerasURL.queryItems = nil
        var camerasRequest = URLRequest(url: try XCTUnwrap(camerasURL.url))
        camerasRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        camerasRequest.timeoutInterval = 3
        let (camerasData, camerasResponse) = try await URLSession.shared.data(for: camerasRequest)
        XCTAssertEqual((camerasResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: camerasData, as: UTF8.self).contains("Entrance"))

        var snapshotURL = camerasURL
        snapshotURL.path = "/api/snapshot"
        snapshotURL.queryItems = [URLQueryItem(name: "id", value: cameraID.uuidString)]
        var snapshotRequest = URLRequest(url: try XCTUnwrap(snapshotURL.url))
        snapshotRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        snapshotRequest.timeoutInterval = 3
        let (snapshot, snapshotResponse) = try await URLSession.shared.data(for: snapshotRequest)
        XCTAssertEqual((snapshotResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(snapshot, expectedSnapshot)

        var askURL = camerasURL
        askURL.path = "/api/ask"
        var askRequest = URLRequest(url: try XCTUnwrap(askURL.url))
        askRequest.httpMethod = "POST"
        askRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "cameraID": cameraID.uuidString,
            "question": "What is visible?"
        ])
        askRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        askRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        askRequest.timeoutInterval = 3
        let (answerData, answerResponse) = try await URLSession.shared.data(for: askRequest)
        XCTAssertEqual((answerResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: answerData, as: UTF8.self).contains("A vehicle is visible."))

        var unauthorized = camerasRequest
        unauthorized.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, unauthorizedResponse) = try await URLSession.shared.data(for: unauthorized)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)
    }

    func testParsesAuthenticatedLoopbackAPIRequest() throws {
        let cameraID = UUID()
        let body = try JSONSerialization.data(withJSONObject: ["cameraID": cameraID.uuidString, "question": "Describe the scene"])
        let header = "POST /api/ask HTTP/1.1\r\nAuthorization: Bearer token\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        var requestData = Data(header.utf8)
        requestData.append(body)

        let request = try XCTUnwrap(LocalShowcaseRequest.parse(requestData))

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/ask")
        XCTAssertEqual(request.headers["authorization"], "Bearer token")
        XCTAssertEqual(try JSONDecoder().decode(LocalShowcaseQuestion.self, from: request.body).cameraID, cameraID)
    }

    func testRejectsOversizedAndIncompleteRequests() throws {
        let oversized = Data(repeating: 65, count: LocalShowcaseRequest.maximumRequestBytes + 1)
        XCTAssertNil(LocalShowcaseRequest.parse(oversized))
        let incomplete = Data("POST /api/ask HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)
        XCTAssertNil(LocalShowcaseRequest.parse(incomplete))
    }

    func testBearerTokenAuthorizationRequiresExactToken() throws {
        let requestData = Data("GET /api/cameras HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Length: 0\r\n\r\n".utf8)
        let request = try XCTUnwrap(LocalShowcaseRequest.parse(requestData))

        XCTAssertTrue(LocalShowcaseRequest.authorizes(request, token: "secret"))
        XCTAssertFalse(LocalShowcaseRequest.authorizes(request, token: "other"))

        let unauthenticated = try XCTUnwrap(LocalShowcaseRequest.parse(
            Data("GET /api/cameras HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        ))
        XCTAssertFalse(LocalShowcaseRequest.authorizes(unauthenticated, token: "secret"))
    }
}