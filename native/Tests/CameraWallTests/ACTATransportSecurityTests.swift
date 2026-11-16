import Foundation
import XCTest
@testable import CameraWall

final class ACTATransportSecurityTests: XCTestCase {
    func testCurrentConsentIsCheckedBeforeEveryNetworkTransmission() async throws {
        let calls = SecurityCallCounter()
        var config = ACTAAIConfiguration(mode: .openAI, allowExternalAI: true)
        let client = ACTAAIClient(config: config, transport: { request in
            calls.increment()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let remote = URLRequest(url: URL(string: "https://example.com/v1/responses")!)
        _ = try await client.sendAuthorized(remote)
        config.allowExternalAI = false
        client.updateConfiguration(config)
        do {
            _ = try await client.sendAuthorized(remote)
            XCTFail("Revoked consent must prevent transmission")
        } catch {}
        XCTAssertEqual(calls.value, 1)
        _ = try await client.sendAuthorized(URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!))
        XCTAssertEqual(calls.value, 2)
        do {
            _ = try await client.sendAuthorized(URLRequest(url: URL(string: "http://127.0.0.1:8018/api/backup/responses")!), requiresExternalConsent: true)
            XCTFail("A loopback cloud relay still needs external consent")
        } catch {}
        XCTAssertEqual(calls.value, 2)
        config.allowExternalAI = true
        config.mode = .mlxInProcess
        client.updateConfiguration(config)
        do {
            _ = try await client.sendAuthorized(remote, requiresExternalConsent: true)
            XCTFail("Switching to local mode must block queued cloud requests")
        } catch {}
        XCTAssertEqual(calls.value, 2)
    }

    func testLoopbackRedirectCannotExfiltrateDataOrChangePort() {
        let local = URL(string: "http://127.0.0.1:8000/v1/chat/completions")!
        XCTAssertFalse(ACTAHTTPRedirectPolicy.allowsRedirect(from: local, to: URL(string: "https://example.com/upload")))
        XCTAssertFalse(ACTAHTTPRedirectPolicy.allowsRedirect(from: local, to: URL(string: "http://127.0.0.1:9000/upload")))
        XCTAssertTrue(ACTAHTTPRedirectPolicy.allowsRedirect(from: local, to: URL(string: "http://127.0.0.1:8000/new-path")))
    }
}

private final class SecurityCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
