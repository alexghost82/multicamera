import Foundation
import Testing
@testable import CameraCore

private actor JSONActionProbe {
    private(set) var executions: [String] = []
    func record(_ name: String) { executions.append(name) }
}

private actor JSONActionGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct JSONProbeAction: ACTAActionProtocol {
    let id = "test.json"
    let title = "JSON probe"
    let description = "Test action"
    let classification: ACTAActionClassification
    let parameters: [ACTAActionParameterSchema]
    let marker: String
    let probe: JSONActionProbe
    var gate: JSONActionGate? = nil

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        if let gate { await gate.suspend() }
        await probe.record(marker)
        return ACTAActionResult(actionID: id, success: true, summary: marker)
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

private final class JSONAuditProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

struct ACTAJSONActionRegistryTests {
    private func field(_ type: String) -> ACTAActionParameterSchema {
        ACTAActionParameterSchema(name: "value", type: type, description: "Test", isRequired: true)
    }

    @Test func rejectsInvalidJSONAndTypesBeforeAuditOrConfirmation() async throws {
        let registry = ACTAActionRegistry()
        let probe = JSONActionProbe()
        let audit = JSONAuditProbe()
        let invalid: [(String, [String])] = [
            ("boolean", [#"{"value":"true"}"#, #"{"value":1}"#, #"{"value":0}"#, #"{"value":null}"#,
                         #"{"value":true,"extra":1}"#, #"{"value":true,"value":false}"#,
                         #"{"value":true"#, "", "null", "[]"]),
            ("integer", [#"{"value":true}"#, #"{"value":false}"#, #"{"value":1.5}"#,
                         #"{"value":1.0000000000000001}"#, #"{"value":1e-9999}"#, #"{"value":"1"}"#]),
            ("number", [#"{"value":"1"}"#, #"{"value":true}"#, #"{"value":null}"#,
                        #"{"value":NaN}"#, #"{"value":1e9999}"#]),
            ("string", [#"{"value":true}"#, #"{"value":1}"#, #"{"value":null}"#])
        ]
        for (type, cases) in invalid {
            await registry.register(JSONProbeAction(classification: .securitySensitive, parameters: [field(type)],
                                                     marker: type, probe: probe))
            for json in cases {
                let result = try await registry.executeJSON(actionID: "test.json", argumentsJSON: json,
                                                            beforeExecution: { _ in audit.record() })
                #expect(result.error?.hasPrefix("INVALID_ARGUMENT:") == true, "\(type): \(json)")
                #expect(!result.requiresOperatorConfirmation)
                #expect(result.confirmationToken == nil)
            }
        }
        #expect(audit.value() == 0)
        let executions = await probe.executions
        #expect(executions.isEmpty)
    }

    @Test func acceptsCorrectTypesAndKeepsStringAPICompatibility() async throws {
        let registry = ACTAActionRegistry()
        let probe = JSONActionProbe()
        let cases = [("boolean", #"{"value":true}"#),
                     ("boolean", #"{"value":false}"#),
                     ("integer", #"{"value":42}"#),
                     ("integer", #"{"value":42.0}"#),
                     ("integer", #"{"value":1e2}"#),
                     ("number", #"{"value":1.25}"#),
                     ("number", #"{"value":2}"#),
                     ("string", #"{"value":"true"}"#)]
        for (type, json) in cases {
            await registry.register(JSONProbeAction(classification: .reversible, parameters: [field(type)],
                                                     marker: type, probe: probe))
            let result = try await registry.executeJSON(actionID: "test.json", argumentsJSON: json)
            #expect(result.success, "\(type): \(json): \(result.summary)")
        }
        await registry.register(JSONProbeAction(classification: .reversible, parameters: [field("boolean")],
                                                 marker: "direct", probe: probe))
        let direct = try await registry.execute(actionID: "test.json", parameters: ["value": "1"])
        #expect(direct.success)
        let executions = await probe.executions
        #expect(executions.count == cases.count + 1)
    }

    @Test func replacementUsesCapturedActionAndRevokesPendingToken() async throws {
        let registry = ACTAActionRegistry()
        let probe = JSONActionProbe()
        let gate = JSONActionGate()
        await registry.register(JSONProbeAction(classification: .reversible, parameters: [field("boolean")],
                                                 marker: "old", probe: probe, gate: gate))
        let running = Task { try await registry.executeJSON(actionID: "test.json", argumentsJSON: #"{"value":true}"#) }
        await gate.waitUntilStarted()
        await registry.register(JSONProbeAction(classification: .securitySensitive, parameters: [field("integer")],
                                                 marker: "new", probe: probe))
        await gate.release()
        let oldResult = try await running.value
        #expect(oldResult.success)
        let beforeConfirmation = await probe.executions
        #expect(beforeConfirmation == ["old"])

        let wrongType = try await registry.executeJSON(actionID: "test.json", argumentsJSON: #"{"value":true}"#)
        #expect(wrongType.error?.hasPrefix("INVALID_ARGUMENT:") == true)
        #expect(!wrongType.requiresOperatorConfirmation)
        let proposed = try await registry.executeJSON(actionID: "test.json", argumentsJSON: #"{"value":1}"#)
        let token = try #require(proposed.confirmationToken)
        await registry.register(JSONProbeAction(classification: .reversible, parameters: [field("boolean")],
                                                 marker: "replacement", probe: probe))
        let revoked = try await registry.confirmAndExecute(token: token, confirmed: true)
        #expect(!revoked.success)
        let afterConfirmation = await probe.executions
        #expect(afterConfirmation == ["old"])
    }

    @Test func failedAuditPreventsConfirmationAndMutation() async throws {
        let registry = ACTAActionRegistry()
        let probe = JSONActionProbe()
        await registry.register(JSONProbeAction(classification: .securitySensitive, parameters: [field("boolean")],
                                                 marker: "protected", probe: probe))
        let result = try await registry.executeJSON(actionID: "test.json", argumentsJSON: #"{"value":true}"#,
            beforeExecution: { _ in throw ConfigurationError.invalid("Audit unavailable") })
        #expect(!result.success)
        #expect(result.confirmationToken == nil)
        #expect(!result.requiresOperatorConfirmation)
        let executions = await probe.executions
        #expect(executions.isEmpty)
    }
}
