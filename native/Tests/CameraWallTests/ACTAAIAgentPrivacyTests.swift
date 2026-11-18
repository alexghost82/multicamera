import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor AgentPrivacyProbe {
    var requests: [(String, [Data])] = []
    var urls: [URL] = []

    func record(prompt: String, images: [Data]) {
        requests.append((prompt, images))
    }

    func record(url: URL) {
        urls.append(url)
    }
}

private struct PrivacyStructuredResponse: Codable, Sendable {
    let value: String
}

final class ACTAAIAgentPrivacyTests: XCTestCase {
    private func request() -> ACTAAgentRequest {
        ACTAAgentRequest(instructions: "Use tools", fullInput: [
            .user(text: "private question", images: (0..<5).map { Data([UInt8($0)]) }),
            .functionOutput(callID: "previous", output: "private tool result")
        ], previousResponseID: "old-cloud-chain", tools: [
            ACTAAgentToolSpec(name: "inspect", description: "Inspect", parametersSchemaJSON: "{}")
        ])
    }

    func testOnlyExplicitInProcessModeRunsAndReceivesFullContext() async throws {
        let probe = AgentPrivacyProbe()
        let client = ACTAAIClient(
            config: ACTAAIConfiguration(mode: .mlxInProcess, allowExternalAI: true),
            transport: { request in
                await probe.record(url: request.url!)
                throw URLError(.notConnectedToInternet)
            },
            keyProvider: { _ in XCTFail("Agent must not access credentials"); return nil },
            localAgentInference: { prompt, images in
                await probe.record(prompt: prompt, images: images)
                return #"{"tool_calls":[{"name":"inspect","arguments":{"value":1}}]}"#
            }
        )
        let result = try await client.runAgentStep(request: request(), pinnedBackend: .mlx)
        XCTAssertEqual(result.backend, .mlx)
        XCTAssertNil(result.responseID)
        XCTAssertFalse(result.usedChain)
        XCTAssertEqual(result.functionCalls.first?.name, "inspect")
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].0.contains("private question"))
        XCTAssertTrue(requests[0].0.contains("private tool result"))
        XCTAssertEqual(requests[0].1, (1..<5).map { Data([UInt8($0)]) })
        let urls = await probe.urls
        XCTAssertTrue(urls.isEmpty)
    }

    func testRemoteAndLoopbackModesAndPinnedBackendsFailClosed() async throws {
        let probe = AgentPrivacyProbe()
        let client = ACTAAIClient(
            config: ACTAAIConfiguration(mode: .mlxInProcess, allowExternalAI: true),
            transport: { request in
                await probe.record(url: request.url!)
                throw URLError(.notConnectedToInternet)
            },
            keyProvider: { _ in XCTFail("Agent must not access credentials"); return nil },
            localAgentInference: { prompt, images in
                await probe.record(prompt: prompt, images: images)
                return "{}"
            }
        )
        for mode in [ACTAAIBackendMode.localVLLM, .openAI, .hybridAuto, .dryRun] {
            for url in ["http://127.0.0.1:8000/v1", "https://example.invalid/v1"] {
                client.updateConfiguration(ACTAAIConfiguration(mode: mode, vllmBaseURL: url, allowExternalAI: true))
                do {
                    _ = try await client.runAgentStep(request: request())
                    XCTFail("Unexpected inference for \(mode)")
                } catch {
                    XCTAssertEqual(error as? ACTAAgentError, .noBackendAvailable)
                }
            }
        }
        client.updateConfiguration(ACTAAIConfiguration(mode: .mlxInProcess, allowExternalAI: true))
        for backend in [ACTAAgentBackend.openAI, .vllm, .offline] {
            do {
                _ = try await client.runAgentStep(request: request(), pinnedBackend: backend)
                XCTFail("Unexpected pinned backend \(backend)")
            } catch {
                XCTAssertEqual(error as? ACTAAgentError, .noBackendAvailable)
            }
        }
        let requests = await probe.requests
        let urls = await probe.urls
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(urls.isEmpty)
    }

    func testLocalFailureDoesNotFallBackAndNonAgentCloudStillWorks() async throws {
        let probe = AgentPrivacyProbe()
        let client = ACTAAIClient(
            config: ACTAAIConfiguration(mode: .mlxInProcess, allowExternalAI: true),
            transport: { request in
                await probe.record(url: request.url!)
                let body = #"{"output_text":"{\"value\":\"cloud\"}"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            keyProvider: { _ in "fake-key" },
            localAgentInference: { _, _ in throw URLError(.cannotLoadFromNetwork) }
        )
        do {
            _ = try await client.runAgentStep(request: request())
            XCTFail("Expected local failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotLoadFromNetwork)
        }
        let before = await probe.urls
        XCTAssertTrue(before.isEmpty)

        client.updateConfiguration(ACTAAIConfiguration(mode: .openAI, openAIBaseURL: "https://example.invalid/responses", allowExternalAI: true))
        let result = await client.generateStructured(lane: .chat, tier: .full, prompt: "non-agent",
            useContentCache: false, responseType: PrivacyStructuredResponse.self,
            fallbackFactory: { PrivacyStructuredResponse(value: "fallback") })
        XCTAssertEqual(result.value, "cloud")
        let after = await probe.urls
        XCTAssertEqual(after.map(\.absoluteString), ["https://example.invalid/responses"])
    }

    func testMissingInProcessModelDoesNotFallBack() async throws {
        let client = ACTAAIClient(
            config: ACTAAIConfiguration(mode: .mlxInProcess, allowExternalAI: true),
            transport: { _ in XCTFail("Agent must not use HTTP"); throw URLError(.notConnectedToInternet) },
            keyProvider: { _ in XCTFail("Agent must not access credentials"); return nil }
        )
        do {
            _ = try await client.runAgentStep(request: request())
            XCTFail("Expected missing model failure")
        } catch {
            XCTAssertEqual(error as? ACTAAgentError, .noBackendAvailable)
        }
    }
}
